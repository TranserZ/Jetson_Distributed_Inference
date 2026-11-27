#!/usr/bin/env bash
# Two-board orchestration helpers (run on Board A / RP).
# requires lib/common.sh and lib/transport.sh sourced.

CPATH() { echo "${1/#$JDI_ROOT//jdi}"; }   # host path -> container path

cluster_up() {      # cluster_up <transport>
  local tr="$1"
  "${JDI_ROOT}/docker/run_node.sh" "$tr"
  if [[ $tr != single ]]; then on_ep docker/run_node.sh "$tr"; fi
}

cluster_down() {
  "${JDI_ROOT}/docker/run_node.sh" stop || true
  on_ep docker/run_node.sh stop || true
}

# run_torch <transport> <logdir> <script.py> [args...]
# torchrun with 1 process per board; rank 0 = Board A.
run_torch() {
  local tr="$1" logdir="$2"; shift 2
  local port=$((29500 + RANDOM % 400))
  if [[ $tr == single ]]; then
    docker exec "$CONTAINER_NAME" torchrun --nnodes 1 --nproc-per-node 1 "$@" 2>&1 | tee "$logdir/rank0.log"
    return "${PIPESTATUS[0]}"
  fi
  local common=(torchrun --nnodes 2 --nproc-per-node 1 --master-addr "$RP_CTRL_IP" --master-port "$port")
  ep_ssh "docker exec $CONTAINER_NAME $(printf '%q ' "${common[@]}" --node-rank 1 "$@")" \
    > "$logdir/rank1.log" 2>&1 &
  local epid=$!
  docker exec "$CONTAINER_NAME" "${common[@]}" --node-rank 0 "$@" 2>&1 | tee "$logdir/rank0.log"
  local rc=${PIPESTATUS[0]}
  wait "$epid" || { warn "rank1 failed — see $logdir/rank1.log"; rc=1; }
  # show which interface NCCL really used (proof of the data path)
  grep -hE "NET/(Socket|Plugin).*Using|NCCL_SOCKET_IFNAME|Using network" "$logdir"/rank*.log | sort -u | head -n 6 | sed 's/^/    [nccl] /' || true
  return $rc
}
