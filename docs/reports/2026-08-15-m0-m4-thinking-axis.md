# M0–M4: Qwen3.8-27B on one RTX 5090, and what thinking costs

**English** | [日本語](2026-08-15-m0-m4-thinking-axis.ja.md)

Date: 2026-08-15. First measured run of this repo — everything before this was scaffolding.

## Measurement conditions

A number without these is not reproducible.

| | |
|---|---|
| Model | `unsloth/Qwen3.8-27B-GGUF` :: `Qwen3.8-27B-Q4_K_M.gguf` |
| Size / checksum | 17,106,775,008 B, sha256 `7e78da5d7e3ae28d178121f58646953305f3e5bd3cb46f4a75584e8b6c6fe169` (matches the LFS oid) |
| Architecture | `qwen3_5`, resolved by llama.cpp as `LLM_ARCH_QWEN35` |
| Server | llama.cpp `llama-server`, commit `9d57ce4`, built `-DGGML_CUDA=ON -DCMAKE_CUDA_ARCHITECTURES=120` |
| Hardware | RTX 5090 32,607 MiB × 1, driver 580.126.09, CUDA 12.8, 128 vCPU |
| Context | `CTX=262144` for all bench runs (see M1) |
| KV cache | `q8_0` / `q8_0`, `--flash-attn on` |
| Parallel | `--parallel 8` for M2 only; `--parallel 1` for M3 and M4 |
| Reasoning | `--reasoning-format deepseek`; `--reasoning on --reasoning-budget -1` (M3) / `--reasoning off` (M4) |
| Sampling | temp 0.6 / top_p 0.95 / top_k 20 — cab's coding preset, **not** the model card values, for comparability |
| `MAX_TOKENS` | 24000 |
| n | 5 per coding task; 30 prompts for tool calling; 13 episodes per agent task |

Task files under `bench/tasks/` are unmodified from
[coding-agent-bench](https://github.com/letusfly85/coding-agent-bench), so the
DeepSeek-V4-Flash 284B and Qwen3.6-27B columns below are directly comparable.

## Headline

**On this task set, thinking is not a quality/latency trade — on two of four
tasks it is strictly worse.** Rust and Scala in thinking mode produced *zero
output* in 10/10 runs: the model consumed the entire 24,000-token budget inside
its reasoning block and never emitted an answer. Turning thinking off produced
a real implementation for both, in 1/12th the wall time. Neither compiles, so
pass@1 stays 0/5 either way — but "wrote nothing" and "wrote something with one
recurring type error" are different failures, and only the second one is a
statement about coding ability.

This is a direct, quantitative answer to the caveat left open in
[deepseek-v4-flash-bench's M4 report §7](https://github.com/wonder-soft/deepseek-v4-flash-bench/blob/main/docs/reports/2026-08-02-m4-coding-quality-vs-qwen3.6-27b.md):
mode is not a nuisance variable here. It moves pass@1.

## M1 — context ceiling

All four configurations loaded. The full native context fits on one card.

| CTX | VRAM used | free | loaded |
|---:|---:|---:|---|
| 32,768 | 17,398 MiB | 15,209 | yes |
| 65,536 | 18,646 MiB | 13,961 | yes |
| 131,072 | 21,142 MiB | 11,465 | yes |
| **262,144** | **26,134 MiB** | **6,473** | **yes** |

262,144 is `n_ctx_train` — the ceiling without YaRN, not a limit we hit. KV cost
is ~38 MiB per 1,024 tokens; weights account for ~16.2 GiB of the total.

The README predicted 131,072 was "plausible" because only 16 of 64 layers are
full attention (`16 × (3 × GatedDeltaNet → 1 × GatedAttention)`). The measurement
beats the prediction: the whole native context fits with 6.4 GiB to spare.

## M2 — throughput

`--parallel 8`, 1,024-token outputs, thinking on.

| concurrency | single-stream tok/s | aggregate tok/s | TTFT median | TTFT p99 |
|---:|---:|---:|---:|---:|
| **1** | **68.3** | 65.9 | **0.52 s** | 0.60 s |
| 2 | 51.2 | 100.0 | 0.53 s | 0.85 s |
| 4 | 37.0 | 140.5 | 1.24 s | 1.97 s |
| 8 | 19.6 | 152.0 | 2.08 s | 2.94 s |

Only the concurrency=1 row describes how one agent turn feels. Aggregate
throughput saturates near 152 tok/s between 4 and 8 concurrent streams.

Note the GGUF carries an unused `blk.64` MTP / `nextn` head that llama.cpp
ignores. Whatever speculative decoding this model was built to support is *not*
reflected in these numbers.

## M3 — coding, tool calling, agents (thinking on)

### pass@1, n=5

| Task | DeepSeek-V4-Flash 284B | Qwen3.6-27B | **Qwen3.8-27B (think)** | failure mode |
|---|---:|---:|---:|---|
| Go / net/http | 5/5 | 5/5 | **5/5** | — |
| Python / FastAPI | 4/5 | 5/5 | **4/5** | 1 test failure; code was produced |
| Rust / axum 0.8 | 2/5 | 0/5 | **0/5** | **no output at all** |
| Scala / http4s | 0/5 | 0/5 | **0/5** | **no output at all** |

The Rust and Scala zeros are `build=missing`, not `build=fail` — `verify.sh`
could not find a project directory because no files were ever extracted.

### Token cost, per-task medians

| Task | reasoning chars | completion tokens | wall s |
|---|---:|---:|---:|
| go-nethttp-rest | 33,784 | 11,915 | 178 |
| python-fastapi-rest | 20,823 | 6,225 | 92 |
| rust-axum-rest | 87,650 | **24,000 (cap)** | 365 |
| scala-http4s-rest | 85,075 | **24,000 (cap)** | 366 |

All ten Rust and Scala runs stopped at exactly `completion_tokens = 24000` with
`answer_chars = 0`. Zero variance across samples — this is deterministic, not a
bad temperature roll.

### Is 24,000 simply too small?

No. One diagnostic Rust generation at double the budget, same mode, same
sampling:

| | 24,000 budget | 48,000 budget |
|---|---:|---:|
| completion tokens | 24,000 (cap) | 48,000 (cap) |
| reasoning chars | 87,650 | **187,633** |
| answer chars | 0 | **0** |
| wall s | 365 | 760 |

Doubling the budget doubled the reasoning and produced nothing. This is
non-termination, not a budget shortfall. (Kept out of the pass@1 table:
comparability with cab requires `MAX_TOKENS=24000`.)

### Tool calling, n=30

| | DeepSeek 284B | Qwen3.6-27B | **Qwen3.8-27B** |
|---|---:|---:|---:|
| selection accuracy | 93.3% | 90.0% | **83.3%** |
| malformed calls | 0/169 | 0/166 | **0/196** |
| median latency | — | — | 1.36 s |

All five failures are wrong-tool selection; the JSON and schema side is clean.
The errors are reproducible rather than random — "Run the test suite and tell me
if it passes" selected `list_dir` in 3 of 3 repetitions.

### Agent loops

| Task | episodes solved | total turns | malformed | median turn latency |
|---|---:|---:|---:|---:|
| agent-fix-bug | **13/13** | 125 | 0 | 1.63 s |
| agent-multi-bug | **13/13** | 163 | 0 | 1.73 s |

26/26, matching the 18/18 of both comparison models.

**The 83.3% single-shot tool accuracy did not translate into agent failures.**
Multi-turn recovery absorbed the wrong-tool picks. Single-shot tool selection
and agent completion measure different things; do not use one to predict the
other.

**Agent turns barely think.** Completion was 44–69 tokens per turn against the
same `--reasoning on` server that could not stop thinking on a Rust one-shot.
Runaway reasoning is a property of the *task shape*, not of the model globally —
which is why M5 (OpenCode, many short tool-calling turns) may behave much more
like the agent loop than like the one-shot coding tasks.

## M4 — the thinking axis

Same model, same tasks, same sampling. Only `--reasoning` moved.

### pass@1

| Task | think | instruct |
|---|---:|---:|
| Go / net/http | 5/5 | **5/5** |
| Python / FastAPI | 4/5 | **5/5** |
| Rust / axum 0.8 | 0/5 (no output) | 0/5 (**compiles-attempted**) |
| Scala / http4s | 0/5 (no output) | 0/5 (**compiles-attempted**) |

### Cost, per-task medians

| Task | think tok | instruct tok | think s | instruct s | think answer ch | instruct answer ch |
|---|---:|---:|---:|---:|---:|---:|
| go-nethttp-rest | 11,915 | 2,283 | 178 | 34 | 8,491 | 7,132 |
| python-fastapi-rest | 6,225 | 942 | 92 | 14 | 3,401 | 3,452 |
| rust-axum-rest | 24,000 | 2,044 | 365 | 30 | **0** | **7,333** |
| scala-http4s-rest | 24,000 | 1,867 | 366 | 28 | **0** | **6,569** |

Thinking bought nothing on any of the four tasks. It cost 5–12× the wall time
everywhere, lost a Python sample, and turned two tasks into silence.

### What the instruct failures actually are

Both remaining zeros are single, repeated library-idiom gaps — not diffuse
incompetence.

**Rust / axum 0.8** — `error[E0308]` in 3 of 3 inspected runs: match or if arms
returning `(StatusCode, Json<Task>)` in one branch and `(StatusCode, String)` in
another. The model does not reach for `.into_response()` or
`Result<impl IntoResponse, StatusCode>` to unify them.

**Scala / http4s** — `value orElse is not a member of org.http4s.HttpRoutes[IO]`
in 2 of 3 inspected runs: routes composed with `orElse` instead of `<+>`, i.e. a
missing `cats.syntax.semigroupk` import.

Each is one fact the model is missing, applied consistently. That makes
`bench/scripts/run_prompt_variants.sh` (the cheatsheet and skeleton variants
already sitting in `bench/tasks/scala-http4s-rest/variants/`) the obvious next
measurement: if a cheatsheet closes it, this is a retrieval problem, not a
reasoning one.

## Harness incidents

Recorded because each one would have been reported as a model result.

**A false 0/5 caught in flight.** The first M3 attempt gated readiness on
`/v1/models`, which answers as soon as the HTTP server binds — before 17 GB of
weights finish loading. Every generation took HTTP 503 and five empty
`go-nethttp-rest` directories appeared in about 20 seconds. Fixed by gating on
`/health` **and** a completed test generation. Results were discarded and M3
re-run from clean.

**`scala-cli` installed but not on PATH.** The installer succeeded and left the
binary in its own cache directory, so `command -v scala-cli` was empty. Left
alone this is a fake 0/5 for the Scala task — the exact failure `00_preflight.sh`
exists to catch, which it did.

**`hf download` is no longer the fast path.** huggingface_hub 1.27 dropped
`hf_transfer` and routes through Xet, which ran at 0.26 MB/s here while the CUDA
build had the CPUs busy, and did not resume — a second invocation started a
fresh `.incomplete` and orphaned 2.5 GB. Plain 6-way ranged HTTP sustained
~27 MB/s. `serving/01_download_model.sh` should be revisited.

## Verdict on the original question

**Can Qwen3.8-27B back OpenCode on one RTX 5090 32 GB?** On serving grounds,
comfortably: full 262,144 context, 68 tok/s single-stream, 0.52 s TTFT, clean
tool-call JSON, 26/26 agent completions.

On coding grounds the answer is language-dependent and unchanged from Qwen3.6:
Go and Python are solid, Rust and Scala do not build. The 3.8 release notes
(SWE-Bench Pro 61.7%, LiveCodeBench v6 90.3%) are not visible in these two
languages at Q4_K_M.

**Run OpenCode with thinking off, or capped.** Full thinking is a liability
here: 5–12× the latency for no pass@1 gain, and a hard hang on the two hardest
tasks. `REASONING_BUDGET=2048` is the untested middle point and is the next
thing worth measuring.

## Not done

- `REASONING_BUDGET=2048` — the capped-thinking midpoint, the likely practical
  setting for OpenCode.
- M5, OpenCode in real use, against the same `agent-*` tasks.
- `run_prompt_variants.sh` on Rust and Scala, to test whether the two idiom gaps
  above are retrieval-shaped.
- `run_repair.sh` — whether feeding the compiler error back closes either gap,
  and in how many rounds. Qwen3.6 did not converge in 3.

Raw artifacts: `results/results-2026-08-15.tgz` (git-lfs).
