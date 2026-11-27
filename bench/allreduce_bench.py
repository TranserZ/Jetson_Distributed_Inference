#!/usr/bin/env python3
"""All-reduce bandwidth/latency sweep through torch.distributed (NCCL on Jetson).

Launch with torchrun on both boards (bench/run_torch.sh does it). Rank 0 writes JSON.
Reported like nccl-tests: algbw = bytes / time, busbw = algbw * 2(n-1)/n.
Works on CPU with gloo for local testing:
  torchrun --nproc-per-node 2 bench/allreduce_bench.py --max-bytes 1048576
"""
import argparse, json, os, statistics, time

import torch
import torch.distributed as dist


def parse():
    p = argparse.ArgumentParser()
    p.add_argument("--min-bytes", type=int, default=8)
    p.add_argument("--max-bytes", type=int, default=256 << 20)
    p.add_argument("--factor", type=int, default=2)
    p.add_argument("--dtype", default="float16", choices=["float16", "bfloat16", "float32"])
    p.add_argument("--warmup", type=int, default=5)
    p.add_argument("--iters", type=int, default=20)
    p.add_argument("--repeats", type=int, default=1, help="repeat whole sweep, report median")
    p.add_argument("--out", default="")
    return p.parse_args()


def main():
    a = parse()
    use_cuda = torch.cuda.is_available()
    dist.init_process_group("nccl" if use_cuda else "gloo")
    rank, world = dist.get_rank(), dist.get_world_size()
    dev = torch.device("cuda", int(os.environ.get("LOCAL_RANK", 0))) if use_cuda else torch.device("cpu")
    if use_cuda:
        torch.cuda.set_device(dev)
    dtype = getattr(torch, a.dtype)
    if not use_cuda and dtype != torch.float32:
        dtype = torch.float32  # gloo CPU half support is limited
    esz = torch.tensor([], dtype=dtype).element_size()

    def sync():
        if use_cuda:
            torch.cuda.synchronize()

    sizes, s = [], max(a.min_bytes, esz)
    while s <= a.max_bytes:
        sizes.append(s)
        s *= a.factor

    rows = []
    for nbytes in sizes:
        n = max(1, nbytes // esz)
        x = torch.empty(n, dtype=dtype, device=dev)
        # correctness: sum over ranks of (rank+1)
        x.fill_(rank + 1)
        dist.all_reduce(x)
        sync()
        expect = world * (world + 1) / 2
        ok = bool(torch.allclose(x.float()[:16], torch.full((min(16, n),), expect, device=dev)))
        t_runs = []
        for _ in range(a.repeats):
            for _ in range(a.warmup):
                dist.all_reduce(x)
            sync()
            dist.barrier()
            t0 = time.perf_counter()
            for _ in range(a.iters):
                dist.all_reduce(x)
            sync()
            t_runs.append((time.perf_counter() - t0) / a.iters)
        t = statistics.median(t_runs)
        real_bytes = n * esz
        algbw = real_bytes / t / 1e9
        busbw = algbw * 2 * (world - 1) / world
        rows.append(dict(bytes=real_bytes, count=n, time_us=t * 1e6, algbw_GBps=algbw,
                         busbw_GBps=busbw, correct=ok, runs_us=[r * 1e6 for r in t_runs]))
        if rank == 0:
            print(f"{real_bytes:>12d} B  {t*1e6:>10.1f} us  algbw {algbw:7.3f} GB/s  "
                  f"busbw {busbw:7.3f} GB/s  {'OK' if ok else 'WRONG'}", flush=True)

    if rank == 0:
        res = dict(bench="allreduce", world=world, dtype=str(dtype), backend=dist.get_backend(),
                   transport=os.environ.get("JDI_TRANSPORT", ""),
                   nccl_socket_ifname=os.environ.get("NCCL_SOCKET_IFNAME", ""), rows=rows)
        if a.out:
            os.makedirs(os.path.dirname(a.out) or ".", exist_ok=True)
            json.dump(res, open(a.out, "w"), indent=2)
            print("wrote", a.out)
    dist.barrier()
    dist.destroy_process_group()


if __name__ == "__main__":
    main()
