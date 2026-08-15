# qwen3.8-27b-bench

**English** | [日本語](README.ja.md)

A benchmark for deciding, on our own GPU, whether **Qwen3.8-27B on a single
RTX 5090 32GB is usable as an OpenCode backend**.

The axes and the whole task set are carried over **unmodified** from
[letusfly85/coding-agent-bench](https://github.com/letusfly85/coding-agent-bench)
(cab). Because `bench/tasks/` is untouched, the numbers line up directly against
cab's Qwen3.6-27B and Qwen3-Coder-Next 80B, and against the DeepSeek-V4-Flash
284B numbers in
[deepseek-v4-flash-bench](https://github.com/wonder-soft/deepseek-v4-flash-bench).

> **Status: M0–M4 measured, 2026-08-15.** Full write-up in
> [`docs/reports/2026-08-15-m0-m4-thinking-axis.md`](docs/reports/2026-08-15-m0-m4-thinking-axis.md).
> M5 (OpenCode in real use) is still open — start at
> [`docs/RESUMING.md`](docs/RESUMING.md).

## Target

| | |
|---|---|
| Model | `Qwen/Qwen3.8-27B` (dense 27B / 262k ctx, 1M via YaRN / multimodal / Apache 2.0, released 2026-08-14) |
| Weights | `Qwen3.8-27B-Q4_K_M.gguf` from `unsloth/Qwen3.8-27B-GGUF` — **17.11 GB** |
| Hardware | **RTX 5090 32GB ×1** |
| Server | llama.cpp (`llama-server`, `--jinja`) |
| Client | OpenCode (as an OpenAI-compatible provider) |

The architecture is a Gated DeltaNet hybrid: 64 layers laid out as
`16 × (3 × GatedDeltaNet → 1 × GatedAttention)`, so **only 16 layers are full
attention**. KV cache should be far smaller than a conventional 27B, which is
what makes a long context on one 32GB card plausible. **That is an expectation,
not a measurement.** Pinning it down is M1.

## Why this configuration

**Q4_K_M and the RTX 5090 were chosen for comparability, not quality.** cab's
Qwen3.6-27B was measured on one RTX 5090 32GB with llama.cpp at Q4_K_M. Holding
the quant, the hardware, and the task files fixed leaves **the 3.6 → 3.8
generation gap as the only moving variable**. Change any of them and the
comparison this repo exists for disappears.

There is headroom on 32GB, so quality-side quants are worth sweeping *after* the
comparison is banked:

| GGUF | Size | Role |
|---|---:|---|
| `Q4_K_M` | 17.11 GB | **Baseline. Matches cab** |
| `UD-Q4_K_XL` | 17.92 GB | unsloth dynamic; should beat Q4_K_M at the same size |
| `Q5_K_M` | 19.83 GB | Comfortably within budget |
| `Q6_K` | 22.88 GB | Quality-ceiling probe |
| `Q8_0` | 29.05 GB | Leaves no room for KV on 32GB |
| `mmproj-F16` | 0.93 GB | Vision; not needed for coding |

## What we are comparing against

`bench/tasks/` is unmodified, so these columns can sit side by side.

### pass@1 (n=5, build **and** test passing)

| Language | DeepSeek-V4-Flash 284B | Qwen3.6-27B | **Qwen3.8-27B (think)** | **Qwen3.8-27B (instruct)** |
|---|---:|---:|---:|---:|
| Go / net/http | 5/5 | 5/5 | **5/5** | **5/5** |
| Python / FastAPI | 4/5 | 5/5 | **4/5** | **5/5** |
| Rust / axum 0.8 | 2/5 | **0/5** | **0/5** | **0/5** |
| Scala / http4s | 0/5 | **0/5** | **0/5** | **0/5** |

The two Qwen3.8 zeros are not the same failure in both columns. In thinking mode
the model emitted **no output at all** — it spent the whole 24,000-token budget
inside its reasoning block, in 10/10 runs. In instruct mode it produced a real
implementation that fails to compile on one recurring library idiom. See the
report.

### Everything else

| Axis | DeepSeek 284B | Qwen3.6-27B | **Qwen3.8-27B** |
|---|---:|---:|---:|
| Tool selection accuracy (n=30) | 93.3% | 90.0% | **83.3%** |
| Invalid tool calls | 0/169 | 0/166 | **0/196** |
| Agent episodes completed | 18/18 | 18/18 | **26/26** |
| Scala repair loop | converged round 2 | **never converged in 3** | not run |
| Context ceiling on one 32 GB card | — | — | **262,144 (native max)** |
| Single-stream decode | — | — | **68.3 tok/s**, TTFT 0.52 s |

**The bold cells are the hypothesis.** Rust tests (0/5), Scala (0/5), and the
non-converging repair loop are Qwen3.6's sharp failures. If 3.8's published
figures (SWE-Bench Pro 61.7%, LiveCodeBench v6 90.3%) are real, those cells
should move. If they don't, that is evidence about the published figures.

## The point: making thinking mode an independent variable

**This is the main reason the repo exists.**

§7 of the deepseek-v4-flash-bench M4 report ends on this caveat: the 284B
reported `reasoning_chars = 0` across all 20 generations — it ran **non-thinking**
throughout — while cab's Qwen3.6 numbers were taken with reasoning making up
roughly 80% of the output. `chat_template_kwargs.thinking` had no effect (the
checkpoint ships no chat template), so the report closes with **"284B ties 27B"
possibly being a statement about modes rather than about models.**

Qwen3.8-27B exposes `reasoning_effort`, and llama-server exposes
`--reasoning on|off` plus `--reasoning-budget N`. That means **thinking can be
swept on its own**, with the model, the tasks, and the sampling held fixed.
Without solving DeepSeek's template problem, we can measure what thinking is
worth on this task set and put a number on that caveat.

`bench/scripts/thinking_sweep.sh` does this. **The mode is a server-start flag**,
so the server has to be restarted between modes. The script probes the live
server for `reasoning_chars` first and **aborts** if it disagrees with the
requested mode — the risk being guarded against is silent: measure twice, get
identical numbers, and write up "thinking makes no difference".

## Layout

```
serving/
  env.example.sh          sourced by every script; copy to env.sh
  00_preflight.sh         VRAM, disk, llama.cpp flags, toolchains
  01_download_model.sh    fetch one GGUF (17.11 GB)
  02_serve_llamacpp.sh    start llama-server; prints every flag it used
  03_smoke.sh             /v1/models, one completion, thinking, tool call
bench/
  scripts/
    thinking_sweep.sh      [new] whole task set, once per thinking mode
    bench_throughput.py    [new] per-concurrency single/aggregate tok/s
    run_coding_task.py     generation task -> files on disk (from cab)
    run_repeat.sh          N repetitions -> pass@1 (from cab)
    run_repair.sh          feed the build error back and regenerate (from cab)
    run_prompt_variants.sh prompt-variant comparison (from cab)
    tool_call_fidelity.py  single tool call: JSON/schema/selection (from cab)
    agent_loop.py          multi-turn agent loop (from cab)
    run_all.sh             runs 1-4 in order
  tasks/                   unmodified from cab. Do not touch
opencode/
  opencode.json.example  point OpenCode at the local llama-server
  README.md              what to measure on the OpenCode side
docs/
  SETUP.md               host prep through OpenCode connection
  RESUMING.md            handoff to another session <- start here
  reports/               measurement reports (empty)
results/                 artifacts and raw logs
```

Docs are bilingual: the plain filename is English, `*.ja.md` is Japanese.
Fix one, fix the other in the same commit.

## Axes

cab's six, plus two specific to this setup.

| Axis | What it shows | Origin |
|---|---|---|
| Throughput | single-stream tok/s, aggregate tok/s, TTFT | cab |
| VRAM / context | how many tokens fit after 17 GB of weights | cab |
| pass@1 | does generated code build and test unmodified | cab |
| Instruction following | does it honor the output format (file splitting) | cab |
| Tool calling | JSON validity, schema conformance, selection accuracy | cab |
| Agent completion | can it finish a multi-turn loop over real files | cab |
| **Effect of thinking** | how completion rate and wall time move with on/off/budget | **new** |
| **OpenCode in practice** | does a real OpenCode session finish the task | **new** |

## Measurement discipline

Four rules carried over from cab and deepseek-v4-flash-bench. All four come from
mistakes actually made.

**Never report pass@1 from one sample.** In cab's first run, n=1 gave the
opposite of n=5 (Rust: n=1 pass → 0/5 at n=5; Go: n=1 fail → 5/5 at n=5).
Trial-to-trial variance is larger than the gap between quants. Use
`run_repeat.sh`.

**Hold sampling fixed.** Otherwise you are measuring sampling, not the model.
Pin `TEMP`/`TOP_P`/`TOP_K` in `serving/env.sh` across everything being compared,
and **use cab's values, not the model card's** (temp 0.6 / top_p 0.95 /
top_k 20). Comparability wins.

**When output looks wrong, suspect the harness first.** What once looked like
"Q2 broke the model" turned out to be a parser that could not read the model's
output format. Hit the raw API with `03_smoke.sh` and confirm the model is fine
before interpreting any harness result.

**Modes fail quietly.** If `--reasoning-format` is not `deepseek`, thoughts land
in `message.content`, `run_coding_task.py` hunts for `### FILE:` inside the
thinking text, and every task fails — with no error, looking like the model's
fault. Pass the thinking check in `03_smoke.sh` before every real run.

## References

- [Qwen/Qwen3.8-27B](https://huggingface.co/Qwen/Qwen3.8-27B)
- [unsloth/Qwen3.8-27B-GGUF](https://huggingface.co/unsloth/Qwen3.8-27B-GGUF)
- [ggml-org/Qwen3.8-27B-GGUF](https://huggingface.co/ggml-org/Qwen3.8-27B-GGUF)
- [Qwen3.8 — Unsloth Docs](https://unsloth.ai/docs/models/qwen3.8)
- [letusfly85/coding-agent-bench](https://github.com/letusfly85/coding-agent-bench) — origin of the tasks and axes
- [wonder-soft/deepseek-v4-flash-bench](https://github.com/wonder-soft/deepseek-v4-flash-bench) — the 284B column; its M4 §7 is where this repo starts
