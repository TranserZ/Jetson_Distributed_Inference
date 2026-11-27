#!/usr/bin/env bash
# NVIDIA eDMA test (pci-epf-dma-test) — raw PCIe DMA bandwidth (Exp 2a).
# Run as root on EP (EP-initiated DMA) or RP (RP-side test driver, if present):
#   sudo bench/link/dma_test.sh <outdir>
# Requires: setup/bringup.sh dmatest   (EP function + RP enumeration)
# Params (cluster.env): DMA_SIZE DMA_NENTS DMA_STRESS DMA_EDMA_CH (space-separated list allowed)
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/common.sh"
need_root
out="${1:?outdir}"; mkdir -p "$out"
role=$(detect_role)
mount | grep -q debugfs || mount -t debugfs none /sys/kernel/debug

if [[ $role == ep ]]; then
  dir=$(ls -d /sys/kernel/debug/*pcie-ep_epf_dma_test* 2>/dev/null | head -n1 || true)
else
  dir=$(ls -d /sys/kernel/debug/*pcie_dma_test* 2>/dev/null | head -n1 || true)
fi
[[ -n $dir && -d $dir ]] || die "DMA test debugfs dir not found on $role (setup/bringup.sh dmatest; dmesg | tail)"
log "$role debugfs: $dir"

res="$out/dma_${role}.tsv"
echo -e "role\tedma_ch\tdma_size\tnents\tstress\tGbps\trun" > "$res"
for ch in ${DMA_EDMA_CH}; do
  for r in $(seq 1 "${REPEATS:-1}"); do
    echo "$DMA_SIZE"   > "$dir/dma_size"
    echo "$DMA_NENTS"  > "$dir/nents"
    echo "$DMA_STRESS" > "$dir/stress_count"
    echo "$ch"         > "$dir/edma_ch"
    marker="JDI-DMA-$(date +%s%N)"
    echo "$marker" > /dev/kmsg
    cat "$dir/edmalib_test" > /dev/null || warn "edmalib_test returned error"
    sleep 1
    dmesg | sed -n "/$marker/,\$p" > "$out/dmesg_${role}_${ch}_r${r}.txt"
    mbps=$(grep -oE '(Cumulative Perf|Perf is) [0-9]+ Mbps' "$out/dmesg_${role}_${ch}_r${r}.txt" | grep -oE '[0-9]+' | tail -n1 || true)
    gbps=$(awk -v m="${mbps:-0}" 'BEGIN{printf "%.2f", m/1000}')
    echo -e "$role\t$ch\t$DMA_SIZE\t$DMA_NENTS\t$DMA_STRESS\t$gbps\t$r" >> "$res"
    log "edma_ch=$ch run $r: ${gbps} Gbps"
  done
done
column -t "$res"
