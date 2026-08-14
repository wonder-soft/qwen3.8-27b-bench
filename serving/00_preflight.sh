#!/usr/bin/env bash
# Verify the box can hold this model before spending the download.
# Every check here corresponds to a way this run is already known to fail.
set -uo pipefail
cd "$(dirname "$0")"
[ -f env.sh ] && . ./env.sh || . ./env.example.sh

FAIL=0
ok()   { printf '  \033[32mOK\033[0m   %s\n' "$1"; }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=1; }
warn() { printf '  \033[33mWARN\033[0m %s\n' "$1"; }

echo "== GPU =="
if ! command -v nvidia-smi >/dev/null; then
  bad "nvidia-smi not found"
else
  nvidia-smi --query-gpu=index,name,memory.total --format=csv,noheader | sed 's/^/  /'
  # awk, not `paste | bc`: minimal GPU images ship without bc and the failure is
  # silent — an empty sum reads back as "VRAM 0 GiB".
  VRAM_MIB=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits | head -1)
  VRAM_GIB=$((VRAM_MIB / 1024))
  if [ "$VRAM_GIB" -ge 30 ]; then ok "VRAM ${VRAM_GIB} GiB on GPU0"
  else bad "VRAM ${VRAM_GIB} GiB — Q4_K_M weights alone are 17 GB, plus KV"; fi

  # One card is the point. Two would change the comparison, not improve it:
  # cab's Qwen3.6-27B baseline was a single RTX 5090.
  N=$(nvidia-smi --list-gpus | wc -l | tr -d ' ')
  [ "$N" -eq 1 ] || warn "$N GPUs visible. The baseline is ONE card — keep the extras idle or CUDA_VISIBLE_DEVICES=0."
fi

echo "== llama.cpp =="
if ! command -v "$LLAMA_SERVER" >/dev/null; then
  bad "$LLAMA_SERVER not on PATH"
else
  ok "$($LLAMA_SERVER --version 2>&1 | head -1)"
  # Gated DeltaNet operators. If these flags are missing the build predates the
  # hybrid-attention work and will not load this model at all.
  H=$("$LLAMA_SERVER" --help 2>&1)
  for FLAG in --jinja --reasoning-format --reasoning-budget; do
    grep -q -- "$FLAG" <<<"$H" && ok "supports $FLAG" || bad "no $FLAG — build is too old, rebuild from master"
  done
  grep -q -- "--chat-template-kwargs" <<<"$H" \
    && ok "supports --chat-template-kwargs" \
    || warn "no --chat-template-kwargs — the per-request thinking toggle may not work"
fi

echo "== disk =="
# 17 GB model + ~1 GB mmproj + ~5 GB results/artifacts + base.
mkdir -p "$MODEL_DIR" 2>/dev/null || true
MNT=$(df -P "$MODEL_DIR" 2>/dev/null | tail -1 | awk '{print $6}')
AVAIL_GIB=$(df -P "$MODEL_DIR" 2>/dev/null | tail -1 | awk '{print int($4/1024/1024)}')
echo "  MODEL_DIR=$MODEL_DIR  (mount $MNT, ${AVAIL_GIB} GiB free)"
if [ "${AVAIL_GIB:-0}" -ge 60 ]; then ok "${AVAIL_GIB} GiB free, need >=60"
else bad "${AVAIL_GIB} GiB free — need >=60 GiB (model + artifacts + room for a second quant)"; fi
FSTYPE=$(df -PT "$MODEL_DIR" 2>/dev/null | tail -1 | awk '{print $2}')
case "$FSTYPE" in
  fuse*|nfs*|9p|cifs) warn "MODEL_DIR is on $FSTYPE. llama.cpp mmaps the GGUF — use a local disk." ;;
  *) ok "MODEL_DIR filesystem: ${FSTYPE:-unknown}" ;;
esac

echo "== toolchains (the bench builds real projects) =="
# A missing toolchain does not error out of run_repeat.sh — it produces
# build=fail for every sample and reads as a model result. This is exactly how
# the DeepSeek run got a fake 0/5 on Python.
for C in python3 go cargo scala-cli java; do
  command -v "$C" >/dev/null && ok "$C $("$C" --version 2>&1 | head -1 | awk '{print $NF}')" \
                             || bad "$C missing — its task will report a FAKE 0/N"
done

echo "== python / hf cli =="
command -v hf >/dev/null && ok "hf cli present" || warn "hf cli missing — 01_download_model.sh will pip install it"

echo
[ "$FAIL" -eq 0 ] && echo "PREFLIGHT: pass" || { echo "PREFLIGHT: FAIL — fix the above before downloading"; exit 1; }
