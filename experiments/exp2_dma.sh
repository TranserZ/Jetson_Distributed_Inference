#!/usr/bin/env bash
# Exp 2 — PCIe Direct DMA (Board A).
#   experiments/exp2_dma.sh 2a     NVIDIA eDMA test: raw PCIe DMA bandwidth (both sides)
#   experiments/exp2_dma.sh 2b     custom DMA driver ping-pong bench        [phase 2: TODO]
#   experiments/exp2_dma.sh 2c     NCCL net plugin over DMA -> allreduce/vit/llm [phase 2: TODO]
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
[[ $(detect_role) == rp ]] || die "run on Board A (RP)"
stage="${1:-2a}"

case "$stage" in
  2a)
    "${JDI_ROOT}/setup/bringup.sh" dmatest
    OUT=$(new_result_dir exp2 dmatest)
    write_meta "$OUT" exp2 dmatest
    log "EP-initiated eDMA test"
    on_ep_sudo bench/link/dma_test.sh "$(echo "$OUT" | sed "s#^$JDI_ROOT#$EP_REPO_DIR#")/ep" || warn "EP DMA test failed"
    # copy EP results back
    scp -q -r "${EP_SSH_USER}@${EP_CTRL_IP}:$(echo "$OUT" | sed "s#^$JDI_ROOT#$EP_REPO_DIR#")/ep" "$OUT/" 2>/dev/null || true
    log "RP-side eDMA test"
    sudo -n "${JDI_ROOT}/bench/link/dma_test.sh" "$OUT/rp" || warn "RP DMA test unavailable (see docs/02_dma_test.md)"
    ok "results -> $OUT"
    log "switch back to VNET for Exp 1 with: setup/bringup.sh vnet"
    ;;
  2b|2c)
    die "Exp $stage is phase 2 (custom kernel driver + NCCL net plugin). See docs/03_direct_dma_plan.md" ;;
  *) die "usage: $0 2a|2b|2c" ;;
esac
