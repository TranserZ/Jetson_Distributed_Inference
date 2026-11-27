#!/usr/bin/env bash
# Assign the static 10GbE control-plane IP (RP_CTRL_IP / EP_CTRL_IP) on this board.
#   sudo setup/net_ctrl.sh [iface]        (default iface: eth0)
# Skip this if your switch/DHCP already gives the boards the IPs in cluster.env.
# NOTE: if the boards are cabled directly, that port no longer reaches the
# internet — keep Wi-Fi (or a second NIC) for apt/docker/HF downloads.
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
need_root
IFC="${1:-eth0}"
[[ -e /sys/class/net/$IFC ]] || die "no interface $IFC (ip -br link)"
IP=$([[ $(detect_role) == rp ]] && echo "$RP_CTRL_IP" || echo "$EP_CTRL_IP")

if command -v nmcli >/dev/null; then
  nmcli con delete jdi-ctrl >/dev/null 2>&1 || true
  nmcli con add type ethernet ifname "$IFC" con-name jdi-ctrl \
    ipv4.method manual ipv4.addresses "${IP}/${CTRL_PREFIX}" ipv4.never-default yes \
    ipv6.method disabled connection.autoconnect yes >/dev/null
  nmcli con up jdi-ctrl >/dev/null
else
  ip addr add "${IP}/${CTRL_PREFIX}" dev "$IFC" || true
  ip link set "$IFC" up
fi
ok "$IFC = ${IP}/${CTRL_PREFIX}  speed=$(cat /sys/class/net/"$IFC"/speed 2>/dev/null || echo ?)Mb/s"
