# Pointing OpenCode at a local llama-server

**English** | [日本語](README.ja.md)

This repo exists to answer whether Qwen3.8-27B on a single RTX 5090 is usable as
an OpenCode backend, so this is the part that matters. Not a synthetic score —
**whether OpenCode actually finishes the task.**

## Steps

1. Start the server (`serving/02_serve_llamacpp.sh`)
2. Copy `opencode.json.example` to `~/.config/opencode/opencode.json` on the
   machine running OpenCode and fix `baseURL`
   - Same host as the server: leave `127.0.0.1:8000`
   - From your laptop: SSH port-forward instead of exposing the endpoint —
     `ssh -N -L 8000:127.0.0.1:8000 <host>`
3. `export LLAMA_API_KEY=dummy` — the AI SDK requires a non-empty key even when
   llama-server runs without `--api-key`
4. Launch `opencode` → `/models` → `qwen38-local/qwen3.8-27b`

## Check first

**The tool-call round trip in `serving/03_smoke.sh` must pass.** Starting
OpenCode while that returns `tool_calls: NONE` produces a confusing failure —
a model that reasons well and can do nothing. The cause is almost always a
missing `--jinja`.

**Set `limit.context` to the measured value.** Anything larger than `CTX` in
`serving/env.sh` means OpenCode sends untrimmed history and the server returns
400. Put the M1 result in both places.

**Decide the thinking setting before you start.** The default is thinking on,
which can be thousands of reasoning tokens per turn. OpenCode runs dozens of
turns per task, so this is what dominates how it feels. Try all three:

| Setting | Server flags |
|---|---|
| Full thinking | `REASONING=on REASONING_BUDGET=-1` |
| Capped thinking | `REASONING=on REASONING_BUDGET=2048` |
| Instruct | `REASONING=off` |

`REASONING_BUDGET` is the only knob that moves continuously between "fast and
shallow" and "slow and correct", so finding the usable line for OpenCode means
sweeping it.

## What to measure

| Signal | How |
|---|---|
| Felt latency | TTFT and decode tok/s for one turn; cross-check against the concurrency=1 row from `bench/scripts/bench_throughput.py` |
| Task completion | Drop `bench/tasks/agent-*` into a working dir, hand it to OpenCode, judge with `verify.sh` |
| Tool-call quality | How often it whiffs, passes bad arguments, or re-reads the same file |
| Long-history decay | Whether instruction-following drops past ~30 turns |
| Cost of thinking | Same task at all three settings; report completion rate AND wall time |

Comparing against `bench/scripts/agent_loop.py` (the harness carried over from
coding-agent-bench) **on the same tasks** is what separates a model limit from
an OpenCode plumbing problem. Do not conclude from one of them alone.
