#!/usr/bin/env bash
# Run the whole coding task set once per thinking mode.
#
# This is the axis the DeepSeek-V4-Flash repo could not measure. That report's
# §7 caveat was: the 284B ran non-thinking for all 20 generations while the
# Qwen3.6-27B numbers it was compared against were thinking, so "284B ties 27B"
# might have been a statement about MODES rather than about models. Qwen3.8-27B
# exposes the switch, so here it is an independent variable.
#
# The mode is a SERVER flag, so this script cannot switch it for you. Run it
# once per mode, restarting llama-server in between:
#
#   REASONING=on  REASONING_BUDGET=-1 ./serving/02_serve_llamacpp.sh
#   MODE=think    bash bench/scripts/thinking_sweep.sh
#
#   REASONING=off ./serving/02_serve_llamacpp.sh
#   MODE=instruct bash bench/scripts/thinking_sweep.sh
#
# It probes the live server first and refuses to run against the wrong one,
# because the failure it is guarding against is silent: measure twice, get the
# same numbers, and write them up as "thinking makes no difference".
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SERVING="$(cd "$HERE/../../serving" && pwd)"
[ -f "$SERVING/env.sh" ] && . "$SERVING/env.sh" || . "$SERVING/env.example.sh"

MODE=${MODE:-think}
N=${N:-5}
BASE="http://127.0.0.1:$PORT"

case "$MODE" in
  think)
    # cab's coding preset, NOT the model card's thinking preset. The Qwen3.6-27B
    # numbers being compared against were taken with these, and comparability
    # beats the card here. See env.example.sh.
    S_TEMP=${TEMP:-0.6}; S_TOP_P=${TOP_P:-0.95}; S_TOP_K=${TOP_K:-20}
    WANT_REASONING=1 ;;
  instruct)
    S_TEMP=${TEMP:-0.6}; S_TOP_P=${TOP_P:-0.95}; S_TOP_K=${TOP_K:-20}
    WANT_REASONING=0 ;;
  *) echo "MODE must be think|instruct (got '$MODE')"; exit 2 ;;
esac

echo "== probing the live server =="
PROBE=$(curl -s "$BASE/v1/chat/completions" -H 'Content-Type: application/json' -d "{
  \"model\": \"$SERVED_NAME\",
  \"messages\": [{\"role\":\"user\",\"content\":\"A bat and a ball cost 1.10 total. The bat costs 1.00 more than the ball. How much is the ball? Think it through.\"}],
  \"max_tokens\": 2048, \"temperature\": 0.6
}")
CHARS=$(printf '%s' "$PROBE" | python3 -c '
import json,sys
try: d=json.load(sys.stdin)
except Exception: print(-1); raise SystemExit
print(len((d["choices"][0]["message"].get("reasoning_content") or "")))
')

echo "  reasoning_chars = $CHARS   (MODE=$MODE wants $( [ "$WANT_REASONING" = 1 ] && echo '>0' || echo '0'))"
if [ "$CHARS" -lt 0 ]; then
  echo "  server did not answer. Is 02_serve_llamacpp.sh up on port $PORT?"; exit 1
fi
if [ "$WANT_REASONING" = 1 ] && [ "$CHARS" -eq 0 ]; then
  echo
  echo "  ABORT: MODE=think but the server produced no reasoning."
  echo "  Restart with REASONING=on REASONING_BUDGET=-1 and --reasoning-format deepseek."
  exit 1
fi
if [ "$WANT_REASONING" = 0 ] && [ "$CHARS" -gt 0 ]; then
  echo
  echo "  ABORT: MODE=instruct but the server is still thinking."
  echo "  Restart with REASONING=off."
  exit 1
fi

OUT="${BENCH_OUT:-/root/results}/repeat-$MODE"
mkdir -p "$OUT"
echo
echo "== coding tasks, MODE=$MODE, n=$N -> $OUT =="
OUT="$OUT" N="$N" TEMP="$S_TEMP" TOP_P="$S_TOP_P" TOP_K="$S_TOP_K" \
  bash "$HERE/run_repeat.sh"

echo
echo "== token cost of this mode =="
# The pass rate is half the answer. If thinking buys +1/5 on Rust at 6x the
# tokens, that is a different verdict than +1/5 for free.
python3 - "$OUT" <<'PY'
import glob, json, os, statistics, sys
rows = {}
for p in sorted(glob.glob(os.path.join(sys.argv[1], "*", "metrics.json"))):
    task = os.path.basename(os.path.dirname(p)).rsplit("-run", 1)[0]
    try:
        d = json.load(open(p))
    except Exception:
        continue
    rows.setdefault(task, []).append(d)
print(f"{'task':<24} {'reasoning ch':>13} {'completion tok':>15} {'total s':>9}")
for task, ds in sorted(rows.items()):
    med = lambda k: statistics.median([d.get(k) or 0 for d in ds]) if ds else 0
    print(f"{task:<24} {med('reasoning_chars'):>13.0f} "
          f"{med('completion_tokens'):>15.0f} {med('total_s'):>9.1f}")
if not rows:
    print("  (no metrics.json found — check run_coding_task.py output layout)")
PY

echo
echo "=== $MODE DONE. Now restart the server in the other mode and run again. ==="
