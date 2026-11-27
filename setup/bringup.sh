#!/usr/bin/env bash
# Run on Board A (RP). Switches BOTH boards into a PCIe mode in the right order.
#   setup/bringup.sh vnet      # Exp 1
#   setup/bringup.sh dmatest   # Exp 2a
#   setup/bringup.sh off
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
[[ $(detect_role) == rp ]] || die "run on Board A (RP)"
mode="${1:?usage: $0 vnet|dmatest|off}"

case "$mode" in
  vnet)
    log "EP: start VNET function";      on_ep_sudo setup/pcie_mode.sh vnet
    log "RP: enumerate + tegra_vnet";   sudo -n "${JDI_ROOT}/setup/pcie_mode.sh" vnet
    log "EP: assign VNET IP";           on_ep_sudo setup/pcie_mode.sh vnet-ip
    log "ping test over VNET"
    ping -c 3 -W 2 "$EP_VNET_IP" && ok "VNET up: ${RP_VNET_IP} <-> ${EP_VNET_IP}"
    ;;
  dmatest)
    on_ep_sudo setup/pcie_mode.sh dmatest
    sudo -n "${JDI_ROOT}/setup/pcie_mode.sh" dmatest
    ;;
  off)
    sudo -n "${JDI_ROOT}/setup/pcie_mode.sh" off
    on_ep_sudo setup/pcie_mode.sh off
    ;;
  *) die "unknown mode $mode" ;;
esac
