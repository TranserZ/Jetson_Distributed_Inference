#!/usr/bin/env bash
# Raw link throughput/latency between the boards over the PCIe VNET IP path.
#   bench/link/iperf.sh <transport> <outdir>      (run on Board A)
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/common.sh"
source "${JDI_ROOT}/lib/transport.sh"
tr="${1:?transport}"; out="${2:?outdir}"; mkdir -p "$out"
read -r RP_IP EP_IP < <(transport_peer_ips "$tr")
D="${IPERF_DURATION:-20}"

ep_ssh "pkill -x iperf3 || true; iperf3 -s -D -B $EP_IP -p 5201"
sleep 1
trap 'ep_ssh "pkill -x iperf3" || true' EXIT

declare -A TESTS=(
  [tcp_p1]="-t $D"
  [tcp_p4]="-t $D -P 4"
  [tcp_p1_reverse]="-t $D -R"
  [tcp_p4_reverse]="-t $D -P 4 -R"
  [udp_48k]="-t $D -u -b 0 -l 48K"
  [udp_48k_p4]="-t $D -u -b 0 -l 48K -P 4"
)
summary="$out/iperf_summary.tsv"
echo -e "test\tGbps\tlost_pct\tretransmits" > "$summary"
for t in tcp_p1 tcp_p4 tcp_p1_reverse tcp_p4_reverse udp_48k udp_48k_p4; do
  for r in $(seq 1 "${REPEATS:-1}"); do
    f="$out/iperf_${t}_r${r}.json"
    # shellcheck disable=SC2086
    iperf3 -c "$EP_IP" -B "$RP_IP" -p 5201 -J ${TESTS[$t]} > "$f" || { warn "$t failed"; continue; }
    if [[ $t == udp* ]]; then
      jq -r --arg t "$t" '[$t, (.end.sum.bits_per_second/1e9), .end.sum.lost_percent, 0] | @tsv' "$f" >> "$summary"
    else
      jq -r --arg t "$t" '[$t, (.end.sum_received.bits_per_second/1e9), 0, (.end.sum_sent.retransmits // 0)] | @tsv' "$f" >> "$summary"
    fi
    sleep 1
  done
done
ping -q -c 100 -i 0.2 -I "$RP_IP" "$EP_IP" > "$out/ping.txt" || true
column -t "$summary"
tail -n1 "$out/ping.txt"
