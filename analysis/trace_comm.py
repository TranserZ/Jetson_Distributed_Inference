#!/usr/bin/env python3
"""Communication share of GPU time from torch-profiler (Chrome) traces.

comm % = time in NCCL kernels / time in all GPU kernels, per rank, averaged over ranks.
With NCCL's Socket/plugin transports the NCCL kernel stays resident while data
crosses the link, so its duration includes the wire time.

  python3 analysis/trace_comm.py <dir-with-*.json[.gz]> [...]
"""
import glob, gzip, json, os, sys


def load(path):
    op = gzip.open if path.endswith(".gz") else open
    with op(path, "rt") as f:
        return json.load(f)


def kernel_times(path):
    ev = load(path)
    ev = ev.get("traceEvents", ev) if isinstance(ev, dict) else ev
    total = nccl = 0.0
    n_nccl = 0
    for e in ev:
        if e.get("ph") != "X" or e.get("cat") not in ("kernel", "Kernel"):
            continue
        d = float(e.get("dur", 0))
        total += d
        if "nccl" in e.get("name", "").lower():
            nccl += d
            n_nccl += 1
    return {"file": os.path.basename(path), "kernel_us": total, "nccl_us": nccl, "nccl_kernels": n_nccl}


def dir_summary(dirs):
    """Average over every trace file (= one per rank) found in the given dirs."""
    per = []
    for d in dirs:
        for p in sorted(glob.glob(os.path.join(d, "*.json")) + glob.glob(os.path.join(d, "*.json.gz"))):
            try:
                per.append(kernel_times(p))
            except Exception as e:
                print(f"warn: cannot parse {p}: {e}", file=sys.stderr)
    if not per:
        return None
    k = sum(x["kernel_us"] for x in per) / len(per)
    c = sum(x["nccl_us"] for x in per) / len(per)
    return {"ranks": len(per), "kernel_us": k, "nccl_us": c, "comm_fraction": c / k if k else None, "per_rank": per}


def prefill_decode(pre, full):
    """pre = in=L,out=1 (prefill only); full = in=L,out=N.  decode = full - prefill."""
    if not pre or not full:
        return None
    dk, dc = full["kernel_us"] - pre["kernel_us"], full["nccl_us"] - pre["nccl_us"]
    return {"prefill": pre["comm_fraction"], "full": full["comm_fraction"],
            "decode": dc / dk if dk > 0 else None}


if __name__ == "__main__":
    s = dir_summary(sys.argv[1:])
    print(json.dumps({k: v for k, v in (s or {}).items() if k != "per_rank"}, indent=2))
