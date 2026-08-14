#!/usr/bin/env bash
# Fetch one GGUF (and optionally the vision projector) into MODEL_DIR.
set -euo pipefail
cd "$(dirname "$0")"
[ -f env.sh ] && . ./env.sh || . ./env.example.sh

# --break-system-packages: PEP 668 hosts refuse a bare `pip install` and the
# script died here before the download ever started on the DeepSeek run.
if ! command -v hf >/dev/null; then
  echo "== installing huggingface_hub[cli] =="
  pip install -q --break-system-packages "huggingface_hub[cli,hf_transfer]" \
    || pip install -q "huggingface_hub[cli,hf_transfer]"
fi
export HF_HUB_ENABLE_HF_TRANSFER=${HF_HUB_ENABLE_HF_TRANSFER:-1}

mkdir -p "$MODEL_DIR"
echo "== $GGUF_REPO :: $GGUF_FILE -> $MODEL_DIR =="
hf download "$GGUF_REPO" "$GGUF_FILE" --local-dir "$MODEL_DIR"

if [ "${WANT_MMPROJ:-0}" = "1" ]; then
  echo "== $GGUF_REPO :: $MMPROJ_FILE (vision) =="
  hf download "$GGUF_REPO" "$MMPROJ_FILE" --local-dir "$MODEL_DIR"
fi

echo
ls -lh "$MODEL_DIR"/*.gguf 2>/dev/null | sed 's/^/  /'
echo
echo "Next: ./02_serve_llamacpp.sh"
