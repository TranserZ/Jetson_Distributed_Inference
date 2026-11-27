#!/usr/bin/env bash
# Start (or restart) the benchmark container on THIS board for a given transport.
#   docker/run_node.sh <transport>      # starts detached container $CONTAINER_NAME
#   docker/run_node.sh stop
# Then run things inside with:  docker exec $CONTAINER_NAME <cmd>
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
source "${JDI_ROOT}/lib/transport.sh"

tr="${1:?usage: $0 <single|vnet|dma>|stop}"
docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
[[ $tr == stop ]] && { ok "container stopped"; exit 0; }

envargs=$(transport_docker_env "$tr")
# shellcheck disable=SC2086
eval docker run -d --runtime nvidia --name "$CONTAINER_NAME" \
  --network host --ipc host --privileged --shm-size=8g \
  -v /dev/shm:/dev/shm \
  -v "${JDI_ROOT}:/jdi" -v "${DATA_DIR}:/data" \
  -e NVIDIA_DRIVER_CAPABILITIES=all \
  -e HF_HOME=/data/hf -e HF_HUB_OFFLINE=1 \
  -e TIKTOKEN_ENCODINGS_BASE=/data/encodings \
  -e PYTHONUNBUFFERED=1 \
  $envargs \
  -w /jdi \
  "$IMAGE" sleep infinity >/dev/null
ok "container '$CONTAINER_NAME' up on $(hostname) [transport=$tr]"
docker exec "$CONTAINER_NAME" env | grep -E '^(NCCL_SOCKET_IFNAME|NCCL_NET|GLOO_SOCKET_IFNAME|VLLM_HOST_IP)=' | sed 's/^/    /'
