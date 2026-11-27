#!/usr/bin/env python3
"""Summarize results/ into Markdown tables, CSVs and plots.

  python3 analysis/report.py                 # latest run of each (experiment, transport)
  python3 analysis/report.py --all           # every run
  python3 analysis/report.py --results results --out analysis/out
"""
import argparse, csv, glob, json, os, statistics
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
        H = ["input", "conc", "exp/transport/mode", "out tok/s", "TTFT ms", "TPOT ms", "ITL ms"]
        rows = []
        for (i, c), byk in sorted(llm.items()):
            for k, rs in byk.items():
                rows.append([i, c, k, f(mean([r.get("output_throughput") for r in rs]), 1),
                             f(mean([r.get("mean_ttft_ms") for r in rs]), 1),
                             f(mean([r.get("mean_tpot_ms") for r in rs]), 1),
                             f(mean([r.get("mean_itl_ms") for r in rs]), 1)])
        md += ["## GPT-OSS-20B (vLLM)\n", md_table(H, rows)]
        write_csv(os.path.join(a.out, "llm.csv"), H, rows)

    open(os.path.join(a.out, "summary.md"), "w").write("\n".join(md))
    print("\n".join(md))
    plots(a.out, ar, vit)


def plots(out, ar, vit):
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
    print("plots ->", out)


if __name__ == "__main__":
    main()
