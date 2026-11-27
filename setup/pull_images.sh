#!/usr/bin/env bash
# Pull the container image on both boards (run on Board A) and record its digest.
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
log "pull $IMAGE (local)"
docker pull "$IMAGE"
if [[ $(detect_role) == rp ]]; then
  log "pull $IMAGE (EP)"
  ep_ssh "docker pull '$IMAGE'"
  a=$(docker image inspect --format '{{index .RepoDigests 0}}' "$IMAGE")
  b=$(ep_ssh "docker image inspect --format '{{index .RepoDigests 0}}' '$IMAGE'")
  [[ $a == "$b" ]] && ok "same digest on both: $a" || warn "digest differs! A=$a B=$b"
fi
log "image self-check (NCCL / torch / vllm versions)"
docker run --rm --runtime nvidia "$IMAGE" python3 -c "
import torch, vllm
print('torch', torch.__version__, 'cuda', torch.version.cuda, 'nccl', torch.cuda.nccl.version())
print('vllm', vllm.__version__)
print('gpu', torch.cuda.get_device_name(0))
"
