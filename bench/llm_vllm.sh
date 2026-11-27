#!/usr/bin/env bash
# GPT-OSS-20B inference benchmark with vLLM (run on Board A).
#   bench/llm_vllm.sh <transport> <tp|tp_ep> <outdir>
# transport=single -> TP=1 on Board A only; otherwise TP=2 over Ray (A=head, B=worker).
# Containers are (re)started here so every run begins from a clean state.
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
source "${JDI_ROOT}/lib/transport.sh"
source "${JDI_ROOT}/lib/cluster.sh"
tr="${1:?transport}"; mode="${2:?tp|tp_ep}"; out="${3:?outdir}"
mkdir -p "$out/logs"
[[ $tr == single && $mode == tp_ep ]] && { log "skip tp_ep for single"; exit 0; }

cluster_up "$tr"
trap cluster_down EXIT
CX() { docker exec "$CONTAINER_NAME" "$@"; }

args=(--port 8000 --max-model-len "$LLM_MAX_MODEL_LEN" --max-num-batched-tokens "$LLM_MAX_MODEL_LEN"
      --max-num-seqs 10 --gpu-memory-utilization "$LLM_GPU_MEM_UTIL" --kv-cache-memory-bytes "$LLM_KV_CACHE_BYTES")
if [[ $tr == single ]]; then
  args+=(--tensor-parallel-size 1)
else
  log "starting Ray cluster"
  CX ray start --head --port 6379 --node-ip-address "$RP_CTRL_IP" --num-gpus 1 --disable-usage-stats > "$out/logs/ray_head.log" 2>&1
  ep_ssh "docker exec $CONTAINER_NAME ray start --address ${RP_CTRL_IP}:6379 --node-ip-address ${EP_CTRL_IP} --num-gpus 1 --disable-usage-stats" > "$out/logs/ray_worker.log" 2>&1
  for _ in $(seq 30); do
    CX ray status 2>/dev/null | grep -qE '([0-9.]+)/2\.0 GPU' && break; sleep 2
  done
  CX ray status | tee "$out/logs/ray_status.txt" | grep -E 'GPU' || true
  args+=(--tensor-parallel-size 2 --distributed-executor-backend ray)
  [[ $mode == tp_ep ]] && args+=(--enable-expert-parallel)
fi

log "vllm serve $LLM_MODEL ${args[*]}"
echo "vllm serve $LLM_MODEL ${args[*]}" > "$out/serve_cmd.txt"
# Profiler is armed but idle until /start_profile (only the profiling pass at the end uses it).
# Ray copies VLLM_* env vars to the worker on Board B; its traces land in B's copy of this dir.
PROF="$out/profile"
penv=()
[[ ${LLM_PROFILE:-1} == 1 ]] && penv=(-e "VLLM_TORCH_PROFILER_DIR=$(CPATH "$PROF")" -e VLLM_TORCH_PROFILER_WITH_STACK=0)
docker exec -d "${penv[@]}" "$CONTAINER_NAME" bash -c "vllm serve $LLM_MODEL $(printf '%q ' "${args[@]}") > $(CPATH "$out")/logs/vllm_server.log 2>&1"

log "waiting for server (first start compiles kernels; can take >10 min)"
t0=$(date +%s)
until CX curl -sf http://127.0.0.1:8000/health >/dev/null 2>&1; do
  sleep 10
  CX pgrep -f "vllm serve" >/dev/null || { tail -n 40 "$out/logs/vllm_server.log"; die "vllm server died"; }
  (( $(date +%s) - t0 > 3600 )) && die "server not ready after 60 min"
done
ok "server ready in $(( $(date +%s) - t0 ))s"
echo "$(( $(date +%s) - t0 ))" > "$out/server_startup_s.txt"

CX curl -s http://127.0.0.1:8000/v1/completions -H 'Content-Type: application/json' \
  -d "{\"model\":\"$LLM_MODEL\",\"prompt\":\"What is a robot?\",\"max_tokens\":32}" > "$out/sample_completion.json"

for in_len in $LLM_INPUT_LENS; do
  for conc in $LLM_CONCURRENCY; do
    n=$(( conc * LLM_NUM_PROMPTS_PER_CONC )); (( n < 8 )) && n=8
    for r in $(seq 1 "$REPEATS"); do
      f="vllm_in${in_len}_out${LLM_OUTPUT_LEN}_c${conc}_r${r}.json"
      log "bench in=$in_len out=$LLM_OUTPUT_LEN conc=$conc n=$n run=$r"
      CX vllm bench serve --backend vllm --base-url http://127.0.0.1:8000 \
        --model "$LLM_MODEL" --dataset-name random \
        --random-input-len "$in_len" --random-output-len "$LLM_OUTPUT_LEN" --ignore-eos \
        --num-prompts "$n" --max-concurrency "$conc" \
        --percentile-metrics ttft,tpot,itl,e2el --metric-percentiles 50,90,99 \
        --save-result --result-dir "$(CPATH "$out")" --result-filename "$f" \
        > "$out/logs/${f%.json}.log" 2>&1 || warn "bench failed: $f"
      grep -E "Output token throughput|Mean TTFT|Mean TPOT" "$out/logs/${f%.json}.log" | sed 's/^/    /' || true
    done
  done
done
# ---- correctness: fixed prompts, greedy -----------------------------------
if [[ ${LLM_CORRECTNESS:-1} == 1 ]]; then
  log "correctness check (greedy, bench/data/llm_prompts.json)"
  CX python3 /jdi/bench/llm_correctness.py --model "$LLM_MODEL" --max-tokens "${LLM_CORRECTNESS_MAX_TOKENS:-512}" \
    --out "$(CPATH "$out")/correctness.json" > "$out/logs/correctness.log" 2>&1 || warn "correctness check failed"
  tail -n 1 "$out/logs/correctness.log" | sed 's/^/    /' || true
fi

# ---- communication share: torch-profiler traces ---------------------------
# per input length: out=1 (prefill only) and out=$LLM_OUTPUT_LEN (prefill+decode);
# analysis/trace_comm.py derives decode share from the difference.
collect_traces() {   # move fresh top-level traces into $PROF/<tag>/ on both boards
  local mv; mv="cd $(CPATH "$PROF") 2>/dev/null && mkdir -p $1 && find . -maxdepth 1 -type f -name '*.json*' -exec mv {} $1/ \;"
  CX bash -c "$mv" || true
  [[ $tr != single ]] && ep_ssh "docker exec $CONTAINER_NAME bash -c $(printf '%q' "$mv")" || true
}
if [[ ${LLM_PROFILE:-1} == 1 ]]; then
  for in_len in ${LLM_PROFILE_INPUT_LENS:-$LLM_INPUT_LENS}; do
    for olen in 1 "$LLM_OUTPUT_LEN"; do
      tag="in${in_len}_out${olen}"
      log "profile $tag"
      CX vllm bench serve --backend vllm --base-url http://127.0.0.1:8000 \
        --model "$LLM_MODEL" --dataset-name random \
        --random-input-len "$in_len" --random-output-len "$olen" --ignore-eos \
        --num-prompts "${LLM_PROFILE_PROMPTS:-2}" --max-concurrency 1 --profile \
        > "$out/logs/profile_${tag}.log" 2>&1 || warn "profile failed: $tag"
      sleep 5   # traces are exported asynchronously by some versions
      collect_traces "$tag"
    done
  done
  if [[ $tr != single ]]; then   # bring Board B's (rank 1) traces next to ours
    rel="${PROF#"$JDI_ROOT"/}"
    scp -rq -o BatchMode=yes "${EP_SSH_USER}@${EP_CTRL_IP}:${EP_REPO_DIR}/${rel}" "$out/profile_ep" \
      || warn "could not copy Board B traces"
  fi
  python3 "${JDI_ROOT}/analysis/trace_comm.py" "$PROF"/in*_out"$LLM_OUTPUT_LEN" 2>/dev/null | grep comm_fraction | sed 's/^/    [all inputs, rank0] /' || true
fi
ok "LLM benchmark done -> $out"
