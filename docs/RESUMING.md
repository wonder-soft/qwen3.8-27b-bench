# Resuming a session

**English** | [日本語](RESUMING.ja.md)

**Status: nothing measured.** Only the scaffolding exists; no RTX 5090 has been
touched. The four `serving/` scripts are **unverified** — they were rewritten
from the vLLM versions in deepseek-v4-flash-bench for llama.cpp and have never
been run against real hardware. Start at M0.

## 0. Read first

| Document | Contents |
|---|---|
| [`README.md`](../README.md) | What we measure, the numbers being compared against, measurement discipline |
| [`docs/SETUP.md`](SETUP.md) | Host prep through OpenCode connection |
| [`opencode/README.md`](../opencode/README.md) | What to measure on the OpenCode side |
| [deepseek-v4-flash-bench M4 report](https://github.com/wonder-soft/deepseek-v4-flash-bench/blob/main/docs/reports/2026-08-02-m4-coding-quality-vs-qwen3.6-27b.md) | **§7 is where this repo starts.** All comparison numbers live here |
| [letusfly85/coding-agent-bench](https://github.com/letusfly85/coding-agent-bench) | Origin of the tasks and axes |

## 1. Where things stand

| Phase | State |
|---|---|
| Hardware choice | **Done.** RTX 5090 32GB ×1, to match cab's Qwen3.6-27B class |
| Quant choice | **Done.** `Q4_K_M` (17.11 GB), matching cab. Rationale in the README |
| `bench/tasks/` | **Carried over unmodified from cab. Do not touch** |
| `bench/scripts/` | From cab / dsv4; model name and repo paths rewritten. **Unverified** |
| `serving/` 00–03 | **Unverified.** Newly written for llama.cpp |
| `bench/scripts/thinking_sweep.sh` | **Unverified.** The point of this repo |
| `bench/scripts/bench_throughput.py` | **Unverified.** New, drops the `vllm bench serve` dependency |
| M0–M5 | **All untouched** |

## 2. Do these, in order

### M0. Get it booting

```bash
# llama.cpp needs recent Gated DeltaNet operators.
# Build from master if the distro package is behind.
cd serving
cp env.example.sh env.sh     # gitignored; host-specific values go here
./00_preflight.sh            # do not proceed while this is red
./01_download_model.sh       # 17.11 GB
./02_serve_llamacpp.sh
./03_smoke.sh                # from another shell
```

**All four checks in `03_smoke.sh` must pass** before going further. The last
two especially:

- **thinking**: `reasoning_chars` must be > 0. Zero means either `REASONING=off`,
  or `--reasoning-format` is not `deepseek` and the thoughts are sitting in
  `message.content`. In the latter case `run_coding_task.py` will hunt for
  `### FILE:` inside the thinking text and **every task fails** — with no error,
  looking like the model's fault.
- **tool call**: `tool_calls: NONE` means `--jinja` is missing. OpenCode will not
  work at all.

**The only concentrated unknown is the llama.cpp build.** Whether this model's
arch string is registered in your build has not been checked. `00_preflight.sh`
verifies the flags exist, but whether the model actually loads is unknown until
`02_serve_llamacpp.sh` runs. Rebuild from master if it fails.

### M1. Find the real context ceiling

`ctx_vram_sweep.sh` was vLLM-specific and was **not carried over**. Sweep by hand:

```bash
for C in 32768 65536 131072 262144; do
  CTX=$C ./serving/02_serve_llamacpp.sh   # does it boot, how much VRAM is left
done
```

With only 16 of 64 layers doing full attention, this **should** go deeper than a
conventional 27B. That is an expectation — measure it. Put the result in both
`CTX` in `serving/env.sh` and `limit.context` in `opencode/opencode.json`.

### M2. Throughput baseline

```bash
python3 bench/scripts/bench_throughput.py \
  --model qwen3.8-27b --concurrency 1,2,4,8 --out "$BENCH_OUT/throughput.json"
```

**Only the concurrency=1 row says anything about how OpenCode will feel.**
Aggregate tok/s answers "how many agents can this box host", not "how long does
one person wait".

To measure concurrency > 1, raise `N_PARALLEL` and restart the server. Left at
`--parallel 1`, requests queue, aggregate tok/s stays flat at the single-stream
figure, and **that flat line reads like a scaling wall.**

### M3. Coding performance (same conditions as cab / dsv4)

```bash
export BENCH_REPO=/root/qwen3.8-27b-bench BENCH_OUT=/root/results
export PATH=/usr/local/go/bin:$HOME/.cargo/bin:$PATH

N=5 TEMP=0.6 TOP_P=0.95 TOP_K=20 MAX_TOKENS=24000 bash bench/scripts/run_repeat.sh
python3 bench/scripts/tool_call_fidelity.py --model qwen3.8-27b --out "$BENCH_OUT/tool_call.json"
python3 bench/scripts/agent_loop.py --model qwen3.8-27b \
  --task-dir bench/tasks/agent-fix-bug/project \
  --work-root "$BENCH_OUT/agent/fix-bug" --out "$BENCH_OUT/agent_loop_fixbug.json" \
  --episodes 13 --max-turns 30 --pytest-bin "$(command -v python3)"
```

**Warm up `cargo` and `scala-cli` before measuring.** The first run pulls
dependencies, so only the first sample is unfairly slow and can time out into a
fake failure.

**The cells to watch** are the bold ones in the README table: Qwen3.6's Rust
tests at 0/5 and Scala at 0/5. If those move, 3.8's published figures are real.

`bench/scripts/run_all.sh` runs M2–M3 together.

### M4. Sweep thinking ← **the point of this repo**

```bash
# serve in thinking mode
REASONING=on REASONING_BUDGET=-1 ./serving/02_serve_llamacpp.sh
MODE=think N=5 bash bench/scripts/thinking_sweep.sh

# stop it, serve in instruct mode
REASONING=off ./serving/02_serve_llamacpp.sh
MODE=instruct N=5 bash bench/scripts/thinking_sweep.sh
```

**The mode is a server-start flag, so the restart is not optional.**
`thinking_sweep.sh` probes the live server for `reasoning_chars` first and
aborts if it disagrees with the requested mode. Do not disable that guard — what
it protects against is silent: measure twice, get identical numbers, write up
"thinking makes no difference". dsv4's M4 hit something close to this, and it
became the §7 caveat.

**Do not judge on completion rate alone.** The script also reports reasoning
characters, completion tokens, and wall time. "Rust went to +1/5 but cost 6× the
tokens" and "+1/5 for free" are different conclusions.

If time allows, take the `REASONING_BUDGET=2048` midpoint too. That is probably
where the usable line for OpenCode sits.

### M5. OpenCode in practice

Follow [`opencode/README.md`](../opencode/README.md). Compare against
`agent_loop.py` **on the same tasks** to separate a model limit from OpenCode
plumbing. Try all three thinking settings.

## 3. How far one session gets

Unlike dsv4 (157 GiB plus vLLM JIT), this is **light**.

| | Work | Estimate |
|---|---|---:|
| M0 | Host prep, 17 GB fetch, boot, smoke | **30 min – 2 h** |
| M1 | Manual ctx sweep (restart per setting) | 45 min |
| M2 | Throughput | 20 min |
| M3 | 4 coding tasks × n=5 + verification builds + agent loop | 2–3 h |
| M4 | Thinking sweep (another M3's worth, other mode) | 2–3 h |
| M5 | OpenCode in practice | 1 h+ |

**M0's spread is the llama.cpp build.** 30 minutes if the packaged binary just
works, budget 2 hours if it needs building from master. The weights are 17 GB,
so the download is minutes.

**With half a day, aim for M0–M3.** That fills one full column next to cab and
dsv4. M4 can wait for the next session — it needs server restarts anyway, so
there is a natural break.

## 4. Where reports go

`docs/reports/YYYY-MM-DD-<topic>.md`, same naming as cab and dsv4. Put the
measurement conditions at the top every time: llama.cpp version, GGUF filename,
`CTX`, `REASONING` and `REASONING_BUDGET`, `--reasoning-format`,
`TEMP`/`TOP_P`/`TOP_K`, n. **A number without them is not reproducible.**

**Copy `$BENCH_OUT` off the host before terminating it.** dsv4's 2026-08-02
artifacts died with the pod and the report tables had to be reconstructed from
scrollback. Since then the practice is to commit them via git-lfs.

## 5. Visibility and language

**Private, but written as if public.** Keep infra details (hostnames, endpoint
URLs, tokens) out from the first commit. `serving/env.sh` is gitignored and all
host-specific values belong there; `env.example.sh` holds only environment-
independent defaults.

Docs are bilingual: the plain filename is English, `*.ja.md` is Japanese.
**Fix one, fix the other in the same commit.** A stale translation is worse than
none — it silently communicates that it disagrees with the code.
