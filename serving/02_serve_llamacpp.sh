#!/usr/bin/env bash
# Start llama-server. Prints the exact invocation first — copy that line into
# the report, because a number without its serving flags is not reproducible.
set -uo pipefail
cd "$(dirname "$0")"
[ -f env.sh ] && . ./env.sh || . ./env.example.sh

GGUF_PATH="$MODEL_DIR/$GGUF_FILE"
[ -f "$GGUF_PATH" ] || { echo "missing $GGUF_PATH — run ./01_download_model.sh"; exit 1; }

ARGS=(
  --model "$GGUF_PATH"
  --alias "$SERVED_NAME"
  --host 0.0.0.0 --port "$PORT"
  --n-gpu-layers "$NGL"
  --ctx-size "$CTX"
  --parallel "$N_PARALLEL"
  --flash-attn "$FLASH_ATTN"
  --cache-type-k "$KV_TYPE_K"
  --cache-type-v "$KV_TYPE_V"
  # --jinja is mandatory for OpenAI-shaped tool calls. Without it the server
  # falls back to a generic template, tool_calls comes back empty, and both
  # tool_call_fidelity.py and OpenCode fail in a way that looks like the model
  # refusing to call tools.
  --jinja
  --reasoning-format "$REASONING_FORMAT"
  --reasoning "$REASONING"
  --reasoning-budget "$REASONING_BUDGET"
)

# Vision only if explicitly asked for; it costs VRAM the KV cache wants.
if [ "${WANT_MMPROJ:-0}" = "1" ] && [ -f "$MODEL_DIR/$MMPROJ_FILE" ]; then
  ARGS+=(--mmproj "$MODEL_DIR/$MMPROJ_FILE")
fi

echo "== serving =="
printf '  %s\n' "$LLAMA_SERVER"
printf '    %s\n' "${ARGS[@]}"
echo
echo "  quant     : $GGUF_FILE"
echo "  context   : $CTX  (kv ${KV_TYPE_K}/${KV_TYPE_V})"
echo "  reasoning : $REASONING (budget $REASONING_BUDGET, format $REASONING_FORMAT)"
echo
echo "Record ALL of the above in the report. Then run ./03_smoke.sh from another shell."
echo

exec "$LLAMA_SERVER" "${ARGS[@]}"
