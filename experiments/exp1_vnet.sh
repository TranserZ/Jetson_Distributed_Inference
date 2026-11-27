#!/usr/bin/env bash
# Exp 1 — PCIe + Tegra VNET (virtual Ethernet) + NCCL Socket transport (Board A).
#   experiments/exp1_vnet.sh [suites...]       (default: link allreduce vit llm)
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
if [[ "$(cat "$STATE_DIR/pcie_mode" 2>/dev/null)" != vnet ]]; then
  log "bringing up VNET on both boards"
  "${JDI_ROOT}/setup/bringup.sh" vnet
fi
ping -c 2 -W 2 "$EP_VNET_IP" >/dev/null || die "VNET peer $EP_VNET_IP unreachable"
"${JDI_ROOT}/experiments/run.sh" exp1 vnet "$@"
