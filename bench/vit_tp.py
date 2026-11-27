#!/usr/bin/env python3
"""ViT inference with Megatron-style Tensor Parallelism over torch.distributed.

Per ViTLayer (world size = TP degree):
  attention.attention.{query,key,value} -> column-parallel (heads split across ranks)
  attention.output.dense                -> row-parallel  (+ all-reduce)
  intermediate.dense                    -> column-parallel
  output.dense                          -> row-parallel  (+ all-reduce)
=> 2 all-reduces per layer, each of size batch x tokens x hidden.
Embeddings, LayerNorms, final norm are replicated.

Run (both boards, via bench/run_torch.sh) or locally on CPU with gloo:
  torchrun --nproc-per-node 2 bench/vit_tp.py --model google/vit-base-patch16-224 --batches 1 4 --verify
"""
import argparse, copy, json, os, statistics, time

import torch
import torch.distributed as dist
import torch.nn as nn
import torch.nn.functional as F


# ----------------------------------------------------------------- TP layers --
class CommStats:
    def __init__(self):
        self.enabled = False
        self.sync = None
        self.reset()

    def reset(self):
        self.calls, self.bytes, self.seconds = 0, 0, 0.0


STATS = CommStats()


def tp_all_reduce(y):
    if STATS.enabled:
        STATS.sync()
        t0 = time.perf_counter()
        dist.all_reduce(y)
        STATS.sync()
        STATS.seconds += time.perf_counter() - t0
    else:
        dist.all_reduce(y)
    STATS.calls += 1
    STATS.bytes += y.numel() * y.element_size()
    return y


class ColumnParallelLinear(nn.Module):
    """y_local = x W_local^T + b_local   (output features split)"""

    def __init__(self, lin: nn.Linear, rank, world):
        super().__init__()
        out = lin.out_features
        assert out % world == 0, f"out_features {out} not divisible by {world}"
        sl = slice(rank * out // world, (rank + 1) * out // world)
        self.weight = nn.Parameter(lin.weight.data[sl].clone(), requires_grad=False)
        self.bias = None if lin.bias is None else nn.Parameter(lin.bias.data[sl].clone(), requires_grad=False)

    def forward(self, x):
        return F.linear(x, self.weight, self.bias)


class RowParallelLinear(nn.Module):
    """y = allreduce(x_local W_local^T) + b   (input features split)"""

    def __init__(self, lin: nn.Linear, rank, world):
        super().__init__()
        inp = lin.in_features
        assert inp % world == 0, f"in_features {inp} not divisible by {world}"
        sl = slice(rank * inp // world, (rank + 1) * inp // world)
        self.weight = nn.Parameter(lin.weight.data[:, sl].clone(), requires_grad=False)
        self.bias = None if lin.bias is None else nn.Parameter(lin.bias.data.clone(), requires_grad=False)

    def forward(self, x):
        y = tp_all_reduce(F.linear(x, self.weight))
        return y if self.bias is None else y + self.bias


def shard_vit(model, rank, world):
    enc = model.encoder if hasattr(model, "encoder") else model.vit.encoder
    for layer in enc.layer:
        sa = layer.attention.attention
        assert sa.num_attention_heads % world == 0
        for name in ("query", "key", "value"):
            setattr(sa, name, ColumnParallelLinear(getattr(sa, name), rank, world))
        sa.num_attention_heads //= world
        sa.all_head_size //= world
        layer.attention.output.dense = RowParallelLinear(layer.attention.output.dense, rank, world)
        layer.intermediate.dense = ColumnParallelLinear(layer.intermediate.dense, rank, world)
        layer.output.dense = RowParallelLinear(layer.output.dense, rank, world)
    return model


# --------------------------------------------------------------------- main --
def parse():
    p = argparse.ArgumentParser()
    p.add_argument("--model", required=True)
    p.add_argument("--batches", type=int, nargs="+", default=[1, 8, 32])
    p.add_argument("--dtype", default="float16", choices=["float16", "bfloat16", "float32"])
    p.add_argument("--warmup", type=int, default=5)
    p.add_argument("--iters", type=int, default=30)
    p.add_argument("--verify", action="store_true", help="compare TP output with unsharded model")
    p.add_argument("--random-init", action="store_true", help="no checkpoint (offline tests): build from config")
    p.add_argument("--out", default="")
    return p.parse_args()


def load_model(a, dtype):
    from transformers import ViTConfig, ViTModel
    if a.random_init:
        cfg = ViTConfig.from_pretrained(a.model) if os.path.isdir(a.model) else _tiny_or_named_cfg(a.model)
        torch.manual_seed(0)
        m = ViTModel(cfg, add_pooling_layer=False)
    else:
        m = ViTModel.from_pretrained(a.model, add_pooling_layer=False, attn_implementation="sdpa")
    return m.to(dtype).eval()


def _tiny_or_named_cfg(name):
    from transformers import ViTConfig
    presets = {  # (hidden, layers, heads, mlp, patch)
        "vit-tiny-test": (192, 2, 4, 768, 16),
        "google/vit-base-patch16-224": (768, 12, 12, 3072, 16),
        "google/vit-huge-patch14-224-in21k": (1280, 32, 16, 5120, 14),
    }
    h, l, nh, mlp, p = presets[name]
    return ViTConfig(hidden_size=h, num_hidden_layers=l, num_attention_heads=nh,
                     intermediate_size=mlp, patch_size=p, image_size=224)


def main():
    a = parse()
    use_cuda = torch.cuda.is_available()
    dist.init_process_group("nccl" if use_cuda else "gloo")
    rank, world = dist.get_rank(), dist.get_world_size()
    dev = torch.device("cuda", int(os.environ.get("LOCAL_RANK", 0))) if use_cuda else torch.device("cpu")
    if use_cuda:
        torch.cuda.set_device(dev)
    dtype = getattr(torch, a.dtype) if use_cuda else torch.float32
    STATS.sync = torch.cuda.synchronize if use_cuda else (lambda: None)

    model = load_model(a, dtype)
    ref = copy.deepcopy(model).to(dev) if a.verify else None
    if world > 1:
        model = shard_vit(model, rank, world)
    model = model.to(dev)
    cfg = model.config
    n_tok = (cfg.image_size // cfg.patch_size) ** 2 + 1
    nparams = sum(p.numel() for p in model.parameters())
    if rank == 0:
        print(f"[vit_tp] model={a.model} world={world} dtype={dtype} tokens={n_tok} "
              f"hidden={cfg.hidden_size} layers={cfg.num_hidden_layers} params/rank={nparams/1e6:.1f}M", flush=True)

    def sync():
        if use_cuda:
            torch.cuda.synchronize()

    results = []
    with torch.inference_mode():
        for bs in a.batches:
            g = torch.Generator().manual_seed(1234 + bs)  # identical input on every rank
            x = torch.randn(bs, 3, cfg.image_size, cfg.image_size, generator=g).to(dev, dtype)

            max_err = None
            if ref is not None:
                y_ref = ref(pixel_values=x).last_hidden_state
                y_tp = model(pixel_values=x).last_hidden_state
                max_err = (y_ref.float() - y_tp.float()).abs().max().item()

            for _ in range(a.warmup):
                model(pixel_values=x)
            sync()
            dist.barrier()

            # pass 1: end-to-end latency (no extra syncs)
            STATS.enabled = False
            lat = []
            for _ in range(a.iters):
                t0 = time.perf_counter()
                model(pixel_values=x)
                sync()
                lat.append(time.perf_counter() - t0)

            # pass 2: communication time (sync around every all-reduce)
            comm_ms = calls = ar_bytes = 0
            if world > 1:
                STATS.enabled = True
                STATS.reset()
                n2 = max(3, a.iters // 3)
                t0 = time.perf_counter()
                for _ in range(n2):
                    model(pixel_values=x)
                sync()
                tot2 = (time.perf_counter() - t0) / n2
                comm_ms = STATS.seconds / n2 * 1e3
                calls = STATS.calls // n2
                ar_bytes = STATS.bytes // max(1, STATS.calls)
                STATS.enabled = False
            else:
                tot2 = statistics.mean(lat)

            lat_ms = sorted(t * 1e3 for t in lat)
            mean_ms = statistics.mean(lat_ms)
            row = dict(batch=bs, latency_ms_mean=mean_ms, latency_ms_p50=lat_ms[len(lat_ms) // 2],
                       latency_ms_p90=lat_ms[int(len(lat_ms) * 0.9) - 1], images_per_s=bs / (mean_ms / 1e3),
                       comm_ms_per_forward=comm_ms, comm_fraction=(comm_ms / (tot2 * 1e3)) if world > 1 else 0.0,
                       allreduce_calls=calls, allreduce_bytes=ar_bytes, verify_max_abs_err=max_err)
            results.append(row)
            if rank == 0:
                print(f"  bs={bs:<4d} {mean_ms:8.2f} ms  {row['images_per_s']:8.1f} img/s  "
                      f"comm {comm_ms:7.2f} ms ({row['comm_fraction']*100:4.1f}%)  "
                      f"AR {calls}x{ar_bytes/1e6:.2f}MB" + (f"  verify_err={max_err:.2e}" if max_err is not None else ""),
                      flush=True)

    if rank == 0 and a.out:
        os.makedirs(os.path.dirname(a.out) or ".", exist_ok=True)
        json.dump(dict(bench="vit_tp", model=a.model, world=world, dtype=str(dtype), tokens=n_tok,
                       hidden=cfg.hidden_size, layers=cfg.num_hidden_layers,
                       transport=os.environ.get("JDI_TRANSPORT", ""), rows=results), open(a.out, "w"), indent=2)
        print("wrote", a.out)
    dist.barrier()
    dist.destroy_process_group()


if __name__ == "__main__":
    main()
