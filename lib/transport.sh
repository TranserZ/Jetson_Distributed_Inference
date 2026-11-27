#!/usr/bin/env bash
# Transport = the path NCCL all-reduce DATA takes between the two boards.
# Control traffic (Ray, vLLM scheduler->worker messages, torch store, gloo,
# NCCL bootstrap in Exp 2) ALWAYS stays on the 10GbE control interface,
# so only the data path differs between experiments.
# 10GbE is control-plane only; it is never used as an NCCL data path.
#
#   single : 1 board, TP=1 (no inter-node traffic)
#   vnet   : NCCL Socket transport over Tegra VNET (PCIe) (Exp 1)
#   dma    : NCCL net plugin over PCIe eDMA               (Exp 2c, not implemented yet)

# prints "-e K=V" docker args for THIS node
transport_docker_env() {
  local tr="$1" cif cip dif
  cif=$(ctrl_if); cip=$(ctrl_ip)
  local -a e=(
    -e "VLLM_HOST_IP=${cip}"
    -e "GLOO_SOCKET_IFNAME=${cif}"
    -e "TP_SOCKET_IFNAME=${cif}"
    -e "UCX_NET_DEVICES=${cif}"
    -e "NCCL_IB_DISABLE=1"
    -e "NCCL_DEBUG=${NCCL_DEBUG:-INFO}"
    -e "NCCL_DEBUG_SUBSYS=${NCCL_DEBUG_SUBSYS:-INIT,NET}"
    -e "JDI_TRANSPORT=${tr}"
  )
  case "$tr" in
    single) dif="$cif" ;;
    vnet)   dif=$(vnet_if); e+=(-e "NCCL_NET=Socket") ;;
    dma)    die "transport 'dma' (Exp 2c) is not implemented yet — see docs/03_direct_dma_plan.md" ;;
    *)      die "unknown transport '$tr' (single|vnet|dma)" ;;
  esac
  e+=(-e "NCCL_SOCKET_IFNAME=${dif}")
  printf '%q ' "${e[@]}"
}

# the data-path IP of the RP (used for logging/iperf)
transport_peer_ips() {   # -> "<rp_ip> <ep_ip>"
  case "$1" in
    single)        echo "$RP_CTRL_IP $EP_CTRL_IP" ;;
    vnet)          echo "$RP_VNET_IP $EP_VNET_IP" ;;
    *)             die "no IP path for transport $1" ;;
  esac
}
