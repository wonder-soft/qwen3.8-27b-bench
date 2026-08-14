#!/usr/bin/env bash
# Full sweep against an already-running llama-server. Assumes 03_smoke.sh passed.
#
# Order matters: establish that thinking is actually on BEFORE spending hours on
# coding tasks. The DeepSeek run discovered reasoning_chars = 0 only while
# writing the report, which invalidated the headline comparison after the fact.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SERVING="$(cd "$HERE/../../serving" && pwd)"
[ -f "$SERVING/env.sh" ] && . "$SERVING/env.sh" || . "$SERVING/env.example.sh"
mkdir -p "$BENCH_OUT"

echo "############ 0/4 mode check ############"
bash "$SERVING/03_smoke.sh" 2>&1 | sed -n '/thinking is actually on/,/^$/p'
echo ">> If reasoning_chars was 0 and you intended MODE=think, stop here."
echo

echo "############ 1/4 throughput ############"
python3 "$HERE/bench_throughput.py" \
  --base-url "http://127.0.0.1:$PORT" --model "$SERVED_NAME" \
  --concurrency "${CONC:-1,2,4,8}" --label "${LABEL:-run}" \
  --out "$BENCH_OUT/throughput.json"
echo
echo ">> Only the concurrency=1 row speaks to how OpenCode will feel."
echo

echo "############ 2/4 tool call fidelity ############"
python3 "$HERE/tool_call_fidelity.py" \
  --base-url "http://127.0.0.1:$PORT" --model "$SERVED_NAME" \
  --out "$BENCH_OUT/tool_call.json" 2>&1 | tail -30

echo "############ 3/4 coding tasks (n=${N:-5}) ############"
N=${N:-5} bash "$HERE/run_repeat.sh"

echo "############ 4/4 agent loops ############"
for T in agent-fix-bug agent-multi-bug; do
  python3 "$HERE/agent_loop.py" \
    --base-url "http://127.0.0.1:$PORT" --model "$SERVED_NAME" \
    --task-dir "$BENCH_REPO/bench/tasks/$T/project" \
    --work-root "$BENCH_OUT/agent/${T#agent-}" \
    --out "$BENCH_OUT/agent_loop_${T#agent-}.json" \
    --episodes "${EPISODES:-13}" --max-turns 30 \
    --pytest-bin "$(command -v python3)" 2>&1 | tail -20
done

echo
echo "=== DONE. results in $BENCH_OUT ==="
echo "This covered ONE thinking mode. Restart the server in the other mode and"
echo "run bench/scripts/thinking_sweep.sh to get the axis this repo exists for."
echo "Write it up under docs/reports/ with the full measurement conditions."
