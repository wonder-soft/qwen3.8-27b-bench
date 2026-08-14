#!/usr/bin/env bash
# Prove the endpoint works before blaming the model for anything the harness did.
#
# The DeepSeek run was burned once by attributing garbled output to a quant when
# the real cause was a parser that could not read the model's output format.
# Always hit the raw API first.
set -uo pipefail
cd "$(dirname "$0")"
[ -f env.sh ] && . ./env.sh || . ./env.example.sh
BASE="http://127.0.0.1:$PORT"

echo "== /v1/models =="
curl -s "$BASE/v1/models" | python3 -m json.tool || exit 1

echo
echo "== single completion =="
curl -s "$BASE/v1/chat/completions" -H 'Content-Type: application/json' -d "{
  \"model\": \"$SERVED_NAME\",
  \"messages\": [{\"role\":\"user\",\"content\":\"Reply with exactly: PONG\"}],
  \"max_tokens\": 64, \"temperature\": 0
}" | python3 -c '
import json,sys
d=json.load(sys.stdin)
m=d["choices"][0]["message"]
print("content  :", repr(m.get("content")))
print("reasoning:", repr(m.get("reasoning_content"))[:200])
print("usage    :", d.get("usage"))
'

echo
echo "== thinking is actually on =="
# The whole point of this repo. DeepSeek-V4-Flash reported reasoning_chars = 0
# for all 20 generations and nobody noticed until the report was written. Fail
# loudly here instead.
curl -s "$BASE/v1/chat/completions" -H 'Content-Type: application/json' -d "{
  \"model\": \"$SERVED_NAME\",
  \"messages\": [{\"role\":\"user\",\"content\":\"A bat and a ball cost 1.10 in total. The bat costs 1.00 more than the ball. How much is the ball?\"}],
  \"max_tokens\": 2048, \"temperature\": 0.6
}" | python3 -c '
import json,sys
d=json.load(sys.stdin)
m=d["choices"][0]["message"]
r=m.get("reasoning_content") or ""
print("reasoning_chars:", len(r))
print("content        :", repr(m.get("content"))[:200])
if len(r)==0:
    print()
    print("  reasoning_content is EMPTY.")
    print("  Either REASONING=off, or --reasoning-format is not `deepseek` and the")
    print("  thoughts are sitting inside message.content instead. If they are in")
    print("  content, run_coding_task.py will parse ### FILE: blocks out of the")
    print("  thinking text and every task fails for a non-model reason.")
'

echo
echo "== tool call round-trip =="
curl -s "$BASE/v1/chat/completions" -H 'Content-Type: application/json' -d "{
  \"model\": \"$SERVED_NAME\",
  \"messages\": [{\"role\":\"user\",\"content\":\"What is the weather in Tokyo? Use the tool.\"}],
  \"tools\": [{\"type\":\"function\",\"function\":{\"name\":\"get_weather\",
    \"description\":\"Get weather for a city\",
    \"parameters\":{\"type\":\"object\",\"properties\":{\"city\":{\"type\":\"string\"}},\"required\":[\"city\"]}}}],
  \"max_tokens\": 2048, \"temperature\": 0
}" | python3 -c '
import json,sys
d=json.load(sys.stdin)
tc=(d["choices"][0]["message"].get("tool_calls") or [])
print("tool_calls:", json.dumps(tc, indent=2)[:600] or "NONE  <-- tool parser not wired up")
'

echo
echo "If tool_calls came back NONE, llama-server was started without --jinja."
echo "OpenCode will not work without it."
