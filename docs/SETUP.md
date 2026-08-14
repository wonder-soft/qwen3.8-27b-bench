# Setup

**English** | [日本語](SETUP.ja.md)

Getting from a bare single-RTX-5090 host to Qwen3.8-27B served by llama.cpp and
reachable from OpenCode.

> **This is still "the plan", not "what worked".** Once M0 passes on real
> hardware, write the settled values back into §0. On dsv4 that section is what
> carried half a day of trial and error into the next session.

## 0. What actually worked

*(Not yet measured. Fill this in after M0.)*

| Item | Value |
|---|---|
| llama.cpp version | — |
| GGUF | `Qwen3.8-27B-Q4_K_M.gguf` (planned) |
| Measured `CTX` ceiling | — |
| KV cache type | — |
| VRAM used | — |
| Single-stream decode tok/s | — |

## 1. Host

| | |
|---|---|
| GPU | **RTX 5090 32GB ×1** |
| Disk | **60 GB+** (17 GB weights + artifacts + room for a second quant) |
| CUDA | Driver with Blackwell (sm_120) support |

**One card is a requirement.** The comparison target, cab's Qwen3.6-27B, was
measured on a single RTX 5090 32GB. If only a multi-GPU host is available, pin
to one with `CUDA_VISIBLE_DEVICES=0`. Adding cards breaks the comparison.

Put the disk **local**. llama.cpp mmaps the GGUF, so a network volume
(FUSE / NFS) is visibly slower.

## 2. Environment

```bash
git clone https://github.com/wonder-soft/qwen3.8-27b-bench
cd qwen3.8-27b-bench/serving
cp env.example.sh env.sh    # gitignored
```

All host-specific values (paths, ports) go in `env.sh`. `env.example.sh` holds
only environment-independent defaults.

**Do not append overrides to the end of `env.sh`.** Both spellings break
quietly, in opposite directions — the reasoning is in the header comment of
`env.example.sh`. On dsv4 this cost two full sweeps.

### Install llama.cpp

The Gated DeltaNet hybrid needs recent operators. **A stale distro package will
fail to load the model at all.**

```bash
git clone https://github.com/ggml-org/llama.cpp
cd llama.cpp
cmake -B build -DGGML_CUDA=ON -DCMAKE_CUDA_ARCHITECTURES=120
cmake --build build --config Release -j
export PATH="$PWD/build/bin:$PATH"
```

`-DCMAKE_CUDA_ARCHITECTURES=120` is sm_120 (Blackwell). Omit it and the build
succeeds but the kernels are wrong or absent.

### Toolchains

The bench builds real projects in four languages. **A missing toolchain does not
error — it produces a fake 0/N.** `00_preflight.sh` checks for them.

```bash
# go, cargo, scala-cli, java, python3 are all required
```

On dsv4, `verify.sh` for `python-fastapi-rest` pointed at a Python that did not
exist and produced a **fake 0/5**. Distrust harness defaults.

## 3. Weights

```bash
./01_download_model.sh    # 17.11 GB
```

For a different quant:

```bash
GGUF_FILE=Qwen3.8-27B-UD-Q4_K_XL.gguf ./01_download_model.sh
```

**But take the baseline measurement at `Q4_K_M`.** That matches cab's
Qwen3.6-27B quant; it is not a quality judgment. Other quants come after the
baseline is banked.

## 4. Serving

```bash
./02_serve_llamacpp.sh
```

It prints every flag it used — **paste that output into the report.** A number
without its flags is not reproducible.

### The three thinking settings

The point of this repo. Fixed at server start.

```bash
REASONING=on  REASONING_BUDGET=-1   ./02_serve_llamacpp.sh   # full thinking
REASONING=on  REASONING_BUDGET=2048 ./02_serve_llamacpp.sh   # capped
REASONING=off                       ./02_serve_llamacpp.sh   # instruct
```

**`--reasoning-format deepseek` is not optional.** It routes thoughts into
`message.reasoning_content`. Left at the default, thoughts land in
`message.content`, `run_coding_task.py` hunts for `### FILE:` inside the thinking
text, and **every task fails** — silently, looking like the model's fault.
`env.example.sh` defaults it to `deepseek`.

### Context (M1, unmeasured)

Only 16 of 64 layers are full attention
(`16 × (3 × GatedDeltaNet → 1 × GatedAttention)`). KV cache should be much
lighter than a conventional 27B, so 131072 on one 32GB card looks plausible.
**Plausible, not measured.**

```bash
for C in 32768 65536 131072 262144; do
  CTX=$C ./02_serve_llamacpp.sh
done
```

Put the result in **both** `CTX` in `env.sh` and `limit.context` in
`opencode/opencode.json`. Fixing only one means OpenCode sends untrimmed history
and the server returns 400.

### Parallelism (for M2)

`N_PARALLEL` defaults to 1. **To measure concurrency > 1, raise it and restart.**
Left at `--parallel 1`, requests queue, aggregate tok/s stays flat at the
single-stream figure, and that flat line reads like a scaling wall.

## 5. Smoke test

```bash
./03_smoke.sh    # from another shell
```

All four must pass before going further.

| Check | What a failure means |
|---|---|
| `/v1/models` | Server is not up |
| Single completion | It loaded, but something is off in the template path |
| **thinking** | `reasoning_chars = 0` → `REASONING=off`, or wrong `--reasoning-format` |
| **tool call** | `tool_calls: NONE` → no `--jinja`. OpenCode will not work |

**Pass this before suspecting the model.** On dsv4, what looked like "Q2 broke
the model" turned out to be a parser that could not read the output format.
Confirm the raw API is healthy, then interpret harness results.

## 6. Connecting OpenCode

See [`opencode/README.md`](../opencode/README.md). The essentials:

```bash
# From your laptop: tunnel instead of exposing the endpoint
ssh -N -L 8000:127.0.0.1:8000 <host>
export LLAMA_API_KEY=dummy
```

Copy `opencode/opencode.json.example` to `~/.config/opencode/opencode.json` and
set `limit.context` to the M1 measurement.

## 7. Teardown

**Copy `$BENCH_OUT` off the host before terminating it.** dsv4's 2026-08-02
artifacts died with the pod and the report tables had to be reconstructed from
scrollback.

```bash
tar czf results-$(date +%Y-%m-%d).tgz -C "$BENCH_OUT" .
# scp it home, then terminate
```
