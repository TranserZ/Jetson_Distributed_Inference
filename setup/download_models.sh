#!/usr/bin/env bash
# Download models + tiktoken encodings into $DATA_DIR on THIS board.
# Run on Board A with --both to also do Board B (each board loads its own copy).
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

if [[ "${1:-}" == "--both" && $(detect_role) == rp ]]; then
  on_ep setup/download_models.sh &
  pid=$!
fi

mkdir -p "$DATA_DIR/hf" "$DATA_DIR/encodings"
# gpt-oss tokenizer needs these offline (same as dusty-nv TIKTOKEN_ENCODINGS_BASE)
for e in o200k_base cl100k_base; do
  [[ -s $DATA_DIR/encodings/$e.tiktoken ]] || \
    curl -fsSL -o "$DATA_DIR/encodings/$e.tiktoken" "https://openaipublic.blob.core.windows.net/encodings/$e.tiktoken"
done
ok "tiktoken encodings"

# shellcheck disable=SC2086
docker run --rm --runtime nvidia -v "$DATA_DIR:/data" -e HF_HOME=/data/hf -e HF_TOKEN="${HF_TOKEN}" \
  "$IMAGE" python3 -c "
import sys
from huggingface_hub import snapshot_download
for m in sys.argv[1:]:
    p = snapshot_download(m, allow_patterns=['*.json','*.safetensors','*.txt','*.model','*.jinja','*.tiktoken','tokenizer*'],
                          ignore_patterns=['original/*', 'metal/*'])
    print('OK', m, '->', p)
" $LLM_MODEL $VIT_MODELS
ok "models in $DATA_DIR/hf on $(hostname)"

if [[ -n "${pid:-}" ]]; then wait "$pid" && ok "EP download done"; fi
