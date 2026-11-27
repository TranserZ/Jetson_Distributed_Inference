#!/usr/bin/env bash
# Generic experiment runner (Board A). Runs the same measurement suites for any transport.
#   experiments/run.sh <exp-name> <transport> [suite ...]
#   suites: link allreduce vit llm      (default: all that apply)
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
source "${JDI_ROOT}/lib/transport.sh"
source "${JDI_ROOT}/lib/cluster.sh"
[[ $(detect_role) == rp ]] || die "run on Board A (RP)"

exp="${1:?exp name}"; tr="${2:?transport}"; shift 2
suites=("$@")
if [[ ${#suites[@]} -eq 0 ]]; then
  if [[ $tr == single ]]; then suites=(vit llm); else suites=(link allreduce vit llm); fi
fi

OUT=$(new_result_dir "$exp" "$tr")
write_meta "$OUT" "$exp" "$tr"
[[ $tr != single ]] && on_ep bash -c "source lib/common.sh; head -n1 /etc/nv_tegra_release" > "$OUT/ep_l4t.txt" || true
log "results -> $OUT"
sudo -n /usr/bin/jetson_clocks >/dev/null 2>&1 || true

for s in "${suites[@]}"; do
  case "$s" in
    link)
      log "== link ($tr)"
      "${JDI_ROOT}/bench/link/iperf.sh" "$tr" "$OUT/link" ;;
    allreduce)
      log "== all-reduce sweep ($tr)"
      mkdir -p "$OUT/allreduce"
      cluster_up "$tr"
      run_torch "$tr" "$OUT/allreduce" bench/allreduce_bench.py \
        --min-bytes "$AR_MIN_BYTES" --max-bytes "$AR_MAX_BYTES" --dtype "$AR_DTYPE" \
        --repeats "$REPEATS" --out "$(CPATH "$OUT")/allreduce/allreduce.json" || warn "allreduce failed"
      cluster_down ;;
    vit)
      cluster_up "$tr"
      for m in $VIT_MODELS; do
        tag=$(basename "$m"); mkdir -p "$OUT/vit/$tag"
        log "== ViT $m ($tr)"
        for r in $(seq 1 "$REPEATS"); do
          verify=(); [[ $r == 1 ]] && verify=(--verify)
          # shellcheck disable=SC2086
          run_torch "$tr" "$OUT/vit/$tag" bench/vit_tp.py --model "$m" --batches $VIT_BATCHES \
            --dtype "$VIT_DTYPE" --iters "$VIT_ITERS" "${verify[@]}" \
            --out "$(CPATH "$OUT")/vit/$tag/vit_r${r}.json" || warn "vit $m failed"
        done
      done
      cluster_down ;;
    llm)
      for mode in $LLM_PARALLEL_MODES; do
        [[ $tr == single && $mode != tp ]] && continue
        log "== GPT-OSS-20B mode=$mode ($tr)"
        "${JDI_ROOT}/bench/llm_vllm.sh" "$tr" "$mode" "$OUT/llm/$mode" || warn "llm $mode failed"
      done ;;
    *) die "unknown suite $s" ;;
  esac
done
ok "experiment $exp/$tr finished -> $OUT"
