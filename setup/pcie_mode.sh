#!/usr/bin/env bash
# PCIe C5 link mode control. Run as root on EACH board (role auto-detected).
#
#   sudo setup/pcie_mode.sh status
#   sudo setup/pcie_mode.sh off                 # tear down EP function / RP drivers
#   sudo setup/pcie_mode.sh vnet                # Exp 1: Ethernet over PCIe
#   sudo setup/pcie_mode.sh dmatest             # Exp 2a: NVIDIA eDMA test function
#   sudo setup/pcie_mode.sh rescan              # RP only: re-enumerate the EP
#
# Order matters (EP first, then RP). setup/bringup.sh does it for you from Board A.
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

ROLE=$(detect_role)
CFS=/sys/kernel/config/pci_ep
CTRL="$CFS/controllers/${PCIE_EP_ADDR}.pcie-ep"
RP_PLAT="${PCIE_EP_ADDR}.pcie"     # same controller (C5) in RP mode on Board A

ifaces() { ls /sys/class/net | sort; }

wait_new_iface() {  # wait_new_iface <before-list-file> <timeout>
  local before="$1" t="${2:-60}" i new
  for ((i = 0; i < t; i++)); do
    new=$(comm -13 "$before" <(ifaces) | grep -vE '^(lo|docker|veth|br-|virbr)' | head -n1 || true)
    if [[ -n "$new" ]]; then echo "$new"; return 0; fi
    sleep 1
  done
  return 1
}

set_ip() {  # set_ip <iface> <ip/prefix>
  local ifc="$1" addr="$2"
  if command -v nmcli >/dev/null; then nmcli dev set "$ifc" managed no 2>/dev/null || true; fi
  ip addr flush dev "$ifc"
  ip addr add "$addr" dev "$ifc"
  ip link set dev "$ifc" up
  ok "$ifc = $addr (mtu $(cat /sys/class/net/"$ifc"/mtu))"
}

# ------------------------------------------------------------------ EP side ---
ep_off() {
  [[ -d $CFS ]] || mount -t configfs none /sys/kernel/config 2>/dev/null || true
  if [[ -f $CTRL/start ]]; then echo 0 > "$CTRL/start" 2>/dev/null || true; fi
  local l
  for l in "$CTRL"/*; do [[ -L $l ]] && rm -f "$l"; done
  for f in pci_epf_tvnet tegra_pcie_dma_epf; do
    [[ -d $CFS/functions/$f/func1 ]] && rmdir "$CFS/functions/$f/func1" 2>/dev/null || true
  done
  modprobe -r pci-epf-tegra-vnet 2>/dev/null || true
  modprobe -r pci-epf-dma-test 2>/dev/null || true
  rm -f "$STATE_DIR/vnet_iface" "$STATE_DIR/pcie_mode"
  ok "EP function removed"
}

ep_start_function() {  # ep_start_function <module> <cfs-function> [vendor device]
  local mod="$1" fn="$2"
  modprobe "$mod"
  local d="$CFS/functions/$fn/func1"
  mkdir -p "$d"
  if [[ $# -ge 4 ]]; then echo "$3" > "$d/vendorid"; echo "$4" > "$d/deviceid"; fi
  echo 16 > "$d/msi_interrupts"
  ln -sf "$d" "$CTRL/"
  echo 1 > "$CTRL/start"
  ok "EP function '$fn' started on ${PCIE_EP_ADDR} — now bring up the RP side"
}

ep_vnet() {
  ep_off
  ifaces > "$STATE_DIR/ifaces_before"
  ep_start_function pci-epf-tegra-vnet pci_epf_tvnet
  echo vnet > "$STATE_DIR/pcie_mode"
}

ep_vnet_ip() {   # after RP loaded tegra_vnet
  local ifc
  ifc=$(wait_new_iface "$STATE_DIR/ifaces_before" 90) || die "EP VNET interface did not appear (is RP tegra_vnet loaded?)"
  echo "$ifc" > "$STATE_DIR/vnet_iface"
  set_ip "$ifc" "${EP_VNET_IP}/${VNET_PREFIX}"
}

ep_dmatest() {
  ep_off
  ep_start_function pci-epf-dma-test tegra_pcie_dma_epf 0x10de 0x229a
  echo dmatest > "$STATE_DIR/pcie_mode"
  ls -d /sys/kernel/debug/*pcie-ep_epf_dma_test* 2>/dev/null || warn "EP debugfs dir not found yet (appears after link-up)"
}

# ------------------------------------------------------------------ RP side ---
rp_link_present() { [[ -e /sys/bus/pci/devices/${PCIE_RP_BDF} ]]; }

rp_rescan() {
  if rp_link_present; then echo 1 > "/sys/bus/pci/devices/${PCIE_RP_BDF}/remove"; sleep 1; fi
  echo 1 > /sys/bus/pci/rescan; sleep 2
  if ! rp_link_present; then
    # Tegra RP powers the controller down if no link at boot: rebind it.
    local drv
    drv=$(basename "$(readlink -f /sys/bus/platform/devices/${RP_PLAT}/driver 2>/dev/null)" 2>/dev/null || true)
    if [[ -n "$drv" && -e /sys/bus/platform/drivers/$drv ]]; then
      log "rebinding ${RP_PLAT} ($drv)"
      echo "$RP_PLAT" > "/sys/bus/platform/drivers/$drv/unbind" || true
      sleep 1
      echo "$RP_PLAT" > "/sys/bus/platform/drivers/$drv/bind" || true
      sleep 3
    elif [[ -e /sys/bus/platform/drivers/tegra194-pcie ]]; then
      echo "$RP_PLAT" > /sys/bus/platform/drivers/tegra194-pcie/bind 2>/dev/null || true
      sleep 3
    fi
  fi
  if rp_link_present; then
    ok "EP enumerated at ${PCIE_RP_BDF}: $(lspci -nn -s "${PCIE_RP_BDF}" | cut -d' ' -f2-)"
    lspci -vv -s "${PCIE_RP_BDF}" 2>/dev/null | grep -E 'LnkCap:|LnkSta:' | sed 's/^/    /' || true
  else
    die "EP not visible at ${PCIE_RP_BDF}. Check cable/jumpers, make sure EP function was started first, or reboot Board A (RP) now that EP is up."
  fi
}

rp_off() {
  modprobe -r tegra_vnet 2>/dev/null || true
  for m in tegra_pcie_dma_test pcie_tegra_dma_test; do modprobe -r "$m" 2>/dev/null || true; done
  rm -f "$STATE_DIR/vnet_iface" "$STATE_DIR/pcie_mode"
  ok "RP drivers unloaded"
}

rp_vnet() {
  rp_off
  ifaces > "$STATE_DIR/ifaces_before"
  rp_rescan
  lspci -nn -d 10de:2296 | grep -q . || warn "no 10de:2296 device — EP is not in VNET mode?"
  modprobe tegra_vnet
  local ifc
  ifc=$(wait_new_iface "$STATE_DIR/ifaces_before" 30) || die "RP VNET interface did not appear (dmesg | grep -i vnet)"
  echo "$ifc" > "$STATE_DIR/vnet_iface"
  echo vnet > "$STATE_DIR/pcie_mode"
  set_ip "$ifc" "${RP_VNET_IP}/${VNET_PREFIX}"
}

rp_dmatest() {
  rp_off
  rp_rescan
  lspci -nn -d 10de:229a | grep -q . || warn "no 10de:229a device — EP is not in dmatest mode?"
  local m loaded=""
  for m in tegra_pcie_dma_test pcie_tegra_dma_test tegra-pcie-dma-test; do
    if modprobe "$m" 2>/dev/null; then loaded="$m"; break; fi
  done
  [[ -n $loaded ]] && ok "RP DMA test driver: $loaded" || warn "no RP DMA test module found (EP-initiated test still works). Candidates: $(find /lib/modules/"$(uname -r)" -name '*dma*test*' -printf '%f ' 2>/dev/null)"
  echo dmatest > "$STATE_DIR/pcie_mode"
  ls -d /sys/kernel/debug/*pcie_dma_test* 2>/dev/null || true
}

status() {
  echo "role          : $ROLE"
  echo "mode          : $(cat "$STATE_DIR/pcie_mode" 2>/dev/null || echo none)"
  echo "vnet iface    : $(cat "$STATE_DIR/vnet_iface" 2>/dev/null || echo -)"
  if [[ $ROLE == ep ]]; then
    echo "ep start      : $(cat "$CTRL/start" 2>/dev/null || echo n/a)"
    echo "ep functions  : $(ls "$CTRL" 2>/dev/null | tr '\n' ' ')"
  else
    lspci -nn -s "${PCIE_RP_BDF}" 2>/dev/null || echo "no device at ${PCIE_RP_BDF}"
    lspci -vv -s "${PCIE_RP_BDF}" 2>/dev/null | grep -E 'LnkSta:' || true
  fi
  ls -d /sys/kernel/debug/*dma_test* 2>/dev/null || true
}

cmd="${1:-status}"
[[ $cmd == status ]] || need_root
case "$ROLE:$cmd" in
  ep:off)      ep_off ;;
  ep:vnet)     ep_vnet ;;
  ep:vnet-ip)  ep_vnet_ip ;;
  ep:dmatest)  ep_dmatest ;;
  rp:off)      rp_off ;;
  rp:vnet)     rp_vnet ;;
  rp:dmatest)  rp_dmatest ;;
  rp:rescan)   rp_rescan ;;
  *:status)    status ;;
  *) die "unknown command '$cmd' for role $ROLE" ;;
esac
