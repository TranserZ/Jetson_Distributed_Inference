#!/usr/bin/env python3
"""Greedy-decoding correctness check against a running vLLM server.

Sends fixed prompts (bench/data/llm_prompts.json) with temperature 0 and stores
the answers. analysis/report.py then reports
  - accuracy : prompts with a known answer whose reply contains it
  - match    : replies identical to the single-board (TP=1) reference run
TP changes floating-point summation order, so a few replies may diverge from
TP=1 late in the text; accuracy is the primary check, match is a sanity check.

  python3 bench/llm_correctness.py --model openai/gpt-oss-20b --out x.json
"""
import argparse, json, os, time, urllib.request

ap = argparse.ArgumentParser()
ap.add_argument("--base-url", default="http://127.0.0.1:8000")
ap.add_argument("--model", required=True)
ap.add_argument("--prompts", default=os.path.join(os.path.dirname(__file__), "data", "llm_prompts.json"))
ap.add_argument("--max-tokens", type=int, default=512)
ap.add_argument("--out", required=True)
a = ap.parse_args()


def chat(prompt):
    body = {"model": a.model, "messages": [{"role": "user", "content": prompt}],
            "temperature": 0.0, "top_p": 1.0, "seed": 0, "max_tokens": a.max_tokens,
            "reasoning_effort": "low"}
    req = urllib.request.Request(a.base_url + "/v1/chat/completions", data=json.dumps(body).encode(),
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=600) as r:
        return json.load(r)


rows = []
for p in json.load(open(a.prompts)):
    t0 = time.time()
    try:
        j = chat(p["prompt"])
        ch = j["choices"][0]
        msg = ch["message"]
        content = msg.get("content") or ""
        reasoning = msg.get("reasoning_content") or msg.get("reasoning") or ""
        err = None
    except Exception as e:  # keep going; record the failure
        ch, content, reasoning, err, j = {}, "", "", repr(e), {}
    correct = None
    if p.get("expect"):
        text = content if content.strip() else reasoning
        correct = any(x.lower() in text.lower() for x in p["expect"])
    rows.append({"id": p["id"], "prompt": p["prompt"], "expect": p.get("expect"),
                 "content": content, "reasoning": reasoning, "correct": correct,
                 "finish_reason": ch.get("finish_reason"),
                 "completion_tokens": (j.get("usage") or {}).get("completion_tokens"),
                 "latency_s": round(time.time() - t0, 3), "error": err})
    print(f"[{p['id']}] correct={correct} {content.strip()[:80]!r}", flush=True)

graded = [r for r in rows if r["correct"] is not None]
acc = sum(r["correct"] for r in graded) / len(graded) if graded else None
json.dump({"bench": "llm_correctness", "model": a.model, "accuracy": acc, "rows": rows},
          open(a.out, "w"), indent=2, ensure_ascii=False)
print(f"accuracy = {acc}")
