#!/usr/bin/env python3
"""Summarize results/ into Markdown tables, CSVs and plots.

  python3 analysis/report.py                 # latest run of each (experiment, transport)
  python3 analysis/report.py --all           # every run
  python3 analysis/report.py --results results --out analysis/out
"""
import argparse, csv, glob, json, os, statistics, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import trace_comm  # noqa: E402
from collections import defaultdict

ORDER = ["single", "vnet", "dma", "dmatest"]


def runs(root, all_runs):
    found = defaultdict(list)
    for d in sorted(glob.glob(os.path.join(root, "*", "*", "*"))):
        if os.path.isdir(d):
            exp, tr = d.split(os.sep)[-3:-1]
            found[(exp, tr)].append(d)
    out = []
    for (exp, tr), ds in found.items():
        for d in (ds if all_runs else ds[-1:]):
            out.append((exp, tr, d))
    return sorted(out, key=lambda x: (x[0], ORDER.index(x[1]) if x[1] in ORDER else 99, x[2]))


def mean(xs):
    xs = [x for x in xs if x is not None]
    return statistics.mean(xs) if xs else None


def f(x, nd=2):
    return "-" if x is None else f"{x:.{nd}f}"


def md_table(headers, rows):
    s = "| " + " | ".join(headers) + " |\n|" + "|".join("---" for _ in headers) + "|\n"
    for r in rows:
        s += "| " + " | ".join(str(c) for c in r) + " |\n"
    return s


def write_csv(path, headers, rows):
    with open(path, "w", newline="") as fh:
        w = csv.writer(fh)
        w.writerow(headers)
        w.writerows(rows)


def main():
    ap = argparse.ArgumentParser()
    root_default = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "results")
    ap.add_argument("--results", default=root_default)
    ap.add_argument("--out", default=os.path.join(os.path.dirname(os.path.abspath(__file__)), "out"))
    ap.add_argument("--all", action="store_true")
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    R = runs(a.results, a.all)
    md = ["# Results summary\n"]

    # ---------------------------------------------------------------- link --
    rows = []
    for exp, tr, d in R:
        p = os.path.join(d, "link", "iperf_summary.tsv")
        if os.path.exists(p):
            by = defaultdict(list)
            for r in csv.DictReader(open(p), delimiter="\t"):
                by[r["test"]].append(float(r["Gbps"]))
            for t, v in by.items():
                rows.append([exp, tr, t, f(mean(v)), len(v)])
        for side in ("ep", "rp"):
            p = os.path.join(d, side, f"dma_{side}.tsv")
            if os.path.exists(p):
                by = defaultdict(list)
                for r in csv.DictReader(open(p), delimiter="\t"):
                    by[r["edma_ch"]].append(float(r["Gbps"]))
                for ch, v in by.items():
                    rows.append([exp, tr, f"edma({side}) ch={ch}", f(mean(v)), len(v)])
    if rows:
        H = ["exp", "transport", "test", "Gbps", "n"]
        md += ["## Link bandwidth\n", md_table(H, rows)]
        write_csv(os.path.join(a.out, "link.csv"), H, rows)

    # ----------------------------------------------------------- allreduce --
    ar = {}
    for exp, tr, d in R:
        p = os.path.join(d, "allreduce", "allreduce.json")
        if os.path.exists(p):
            ar[f"{exp}/{tr}"] = json.load(open(p))["rows"]
    if ar:
        picks = [8, 65536, 1 << 20, 16 << 20, 256 << 20]
        H = ["exp/transport", "lat@8B (us)"] + [f"busbw@{p//1024}KiB (GB/s)" for p in picks[1:]]
        rows = []
        for k, rs in ar.items():
            by = {r["bytes"]: r for r in rs}
            def near(b, key):
                x = min(by, key=lambda s: abs(s - b))
                return by[x][key] if 0.5 <= x / b <= 2 else None
            rows.append([k, f(near(8, "time_us"), 1)] + [f(near(p, "busbw_GBps"), 3) for p in picks[1:]])
        md += ["## All-reduce (NCCL)\n", md_table(H, rows)]
        write_csv(os.path.join(a.out, "allreduce.csv"), ["key", "bytes", "time_us", "busbw_GBps"],
                  [[k, r["bytes"], r["time_us"], r["busbw_GBps"]] for k, rs in ar.items() for r in rs])

    # ----------------------------------------------------------------- vit --
    vit = defaultdict(lambda: defaultdict(list))
    for exp, tr, d in R:
        for p in glob.glob(os.path.join(d, "vit", "*", "vit_r*.json")):
            j = json.load(open(p))
            for r in j["rows"]:
                vit[(os.path.basename(j["model"]), r["batch"])][f"{exp}/{tr}"].append(r)
    if vit:
        H = ["model", "batch", "exp/transport", "img/s", "latency ms", "comm ms", "comm %"]
        rows = []
        for (m, b), byk in sorted(vit.items()):
            for k, rs in byk.items():
                rows.append([m, b, k, f(mean([r["images_per_s"] for r in rs]), 1),
                             f(mean([r["latency_ms_mean"] for r in rs])),
                             f(mean([r["comm_ms_per_forward"] for r in rs])),
                             f(100 * mean([r["comm_fraction"] for r in rs]), 1)])
        md += ["## ViT (Tensor Parallel)\n", md_table(H, rows)]
        write_csv(os.path.join(a.out, "vit.csv"), H, rows)

    # ----------------------------------------------------------------- llm --
    llm = defaultdict(lambda: defaultdict(list))
    for exp, tr, d in R:
        for p in glob.glob(os.path.join(d, "llm", "*", "vllm_in*_c*_r*.json")):
            mode = p.split(os.sep)[-2]
            name = os.path.basename(p)
            in_len = int(name.split("_in")[1].split("_")[0])
            conc = int(name.split("_c")[1].split("_")[0])
            llm[(in_len, conc)][f"{exp}/{tr}/{mode}"].append(json.load(open(p)))
    if llm:
        # prefill tok/s  = input tokens per request / TTFT   (per request)
        # decode tok/s   = 1 / TPOT per request, and total output tokens / duration (all requests)
        H = ["input", "conc", "exp/transport/mode", "prefill tok/s", "decode tok/s/req", "out tok/s (total)",
             "TTFT ms", "TPOT ms", "ITL ms", "E2E ms"]
        rows = []
        for (i, c), byk in sorted(llm.items()):
            for k, rs in byk.items():
                ttft = mean([r.get("mean_ttft_ms") for r in rs])
                tpot = mean([r.get("mean_tpot_ms") for r in rs])
                rows.append([i, c, k,
                             f(i / (ttft / 1000), 0) if ttft else "-",
                             f(1000 / tpot, 1) if tpot else "-",
                             f(mean([r.get("output_throughput") for r in rs]), 1),
                             f(ttft, 1), f(tpot, 1),
                             f(mean([r.get("mean_itl_ms") for r in rs]), 1),
                             f(mean([r.get("mean_e2el_ms") for r in rs]), 1)])
        md += ["## GPT-OSS-20B (vLLM)\n", md_table(H, rows)]
        write_csv(os.path.join(a.out, "llm.csv"), H, rows)

    # communication share from profiler traces
    rows = []
    for exp, tr, d in R:
        for md_dir in sorted(glob.glob(os.path.join(d, "llm", "*"))):
            prof = os.path.join(md_dir, "profile")
            if not os.path.isdir(prof):
                continue
            tags = sorted({os.path.basename(t) for t in glob.glob(os.path.join(prof, "in*_out*"))})
            lens = sorted({int(t[2:].split("_")[0]) for t in tags})
            for L in lens:
                def summ(tag):
                    ds = [os.path.join(prof, tag), os.path.join(md_dir, "profile_ep", tag)]
                    return trace_comm.dir_summary([x for x in ds if os.path.isdir(x)])
                pre = summ(f"in{L}_out1")
                fulls = [t for t in tags if t.startswith(f"in{L}_out") and t != f"in{L}_out1"]
                full = summ(fulls[0]) if fulls else None
                pd = trace_comm.prefill_decode(pre, full) or {}
                pct = lambda x: f(100 * x, 1) if x is not None else "-"
                rows.append([L, f"{exp}/{tr}/{os.path.basename(md_dir)}",
                             pct(pd.get("prefill", pre and pre["comm_fraction"])),
                             pct(pd.get("decode")),
                             pct(pd.get("full", full and full["comm_fraction"])),
                             (full or pre or {}).get("ranks", 0)])
    if rows:
        H = ["input", "exp/transport/mode", "prefill comm %", "decode comm %", "whole request comm %", "ranks"]
        md += ["## GPT-OSS-20B communication share (NCCL kernel time / GPU kernel time)\n", md_table(H, rows)]
        write_csv(os.path.join(a.out, "llm_comm.csv"), H, rows)

    # correctness: accuracy on known answers + identity with the TP=1 reference
    corr = {}
    for exp, tr, d in R:
        for p in glob.glob(os.path.join(d, "llm", "*", "correctness.json")):
            corr[f"{exp}/{tr}/{p.split(os.sep)[-2]}"] = json.load(open(p))
    if corr:
        ref_key = next((k for k in corr if "/single/" in k), None)
        ref = {r["id"]: r for r in corr[ref_key]["rows"]} if ref_key else {}
        H = ["exp/transport/mode", "accuracy", "identical to TP=1", "errors"]
        rows = []
        for k, j in corr.items():
            same = [r["content"] == ref[r["id"]]["content"] for r in j["rows"] if r["id"] in ref]
            rows.append([k, f(100 * j["accuracy"], 0) + " %" if j.get("accuracy") is not None else "-",
                         (f"{sum(same)}/{len(same)}" if same and k != ref_key else "ref" if k == ref_key else "-"),
                         sum(1 for r in j["rows"] if r.get("error"))])
        md += ["## GPT-OSS-20B correctness (greedy, fixed prompts)\n", md_table(H, rows)]
        write_csv(os.path.join(a.out, "llm_correctness.csv"), H, rows)

    open(os.path.join(a.out, "summary.md"), "w").write("\n".join(md))
    print("\n".join(md))
    plots(a.out, ar, vit, llm)


def plots(out, ar, vit, llm=None):
    try:
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
    except ImportError:
        print("(matplotlib not installed: skipping plots)")
        return
    if ar:
        fig, ax = plt.subplots(1, 2, figsize=(11, 4))
        for k, rs in ar.items():
            x = [r["bytes"] for r in rs]
            ax[0].loglog(x, [r["time_us"] for r in rs], marker="o", ms=3, label=k)
            ax[1].semilogx(x, [r["busbw_GBps"] for r in rs], marker="o", ms=3, label=k)
        ax[0].set(xlabel="message size (B)", ylabel="latency (us)", title="All-reduce latency")
        ax[1].set(xlabel="message size (B)", ylabel="bus bandwidth (GB/s)", title="All-reduce bandwidth")
        for x in ax:
            x.grid(alpha=.3); x.legend(fontsize=8)
        fig.tight_layout(); fig.savefig(os.path.join(out, "allreduce.png"), dpi=130)
    if vit:
        models = sorted({m for m, _ in vit})
        fig, axs = plt.subplots(1, len(models), figsize=(5.5 * len(models), 4), squeeze=False)
        for ax, m in zip(axs[0], models):
            keys = sorted({k for (mm, _), byk in vit.items() if mm == m for k in byk})
            for k in keys:
                bs = sorted(b for (mm, b) in vit if mm == m and k in vit[(mm, b)])
                ax.plot(bs, [mean([r["images_per_s"] for r in vit[(m, b)][k]]) for b in bs], marker="o", label=k)
            ax.set(title=m, xlabel="batch", ylabel="images/s"); ax.grid(alpha=.3); ax.legend(fontsize=8)
        fig.tight_layout(); fig.savefig(os.path.join(out, "vit.png"), dpi=130)
    if llm:
        fig, ax = plt.subplots(1, 2, figsize=(11, 4))
        keys = sorted({k for byk in llm.values() for k in byk})
        for k in keys:
            ins = sorted(i for (i, c) in llm if c == 1 and k in llm[(i, c)])
            ax[0].semilogx(ins, [mean([r.get("mean_ttft_ms") for r in llm[(i, 1)][k]]) for i in ins], "o-", label=k, base=2)
            ax[1].semilogx(ins, [mean([r.get("mean_tpot_ms") for r in llm[(i, 1)][k]]) for i in ins], "o-", label=k, base=2)
        ax[0].set(xlabel="input tokens", ylabel="TTFT (ms)", title="Prefill (concurrency 1)")
        ax[1].set(xlabel="input tokens", ylabel="TPOT (ms)", title="Decode (concurrency 1)")
        for x in ax:
            x.grid(alpha=.3); x.legend(fontsize=8)
        fig.tight_layout(); fig.savefig(os.path.join(out, "llm.png"), dpi=130)
    print("plots ->", out)


if __name__ == "__main__":
    main()
