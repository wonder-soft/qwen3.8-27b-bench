# results/

**English** | [日本語](README.ja.md)

Artifacts from bench runs.

## What gets committed

| | |
|---|---|
| `YYYY-MM-DD-<topic>-results.tgz` | **One archive per measurement, tracked by git-lfs** |
| Unpacked raw logs and build output | **gitignored.** Do not commit as-is |

This policy is inherited from deepseek-v4-flash-bench, which lost its first
run's artifacts along with the pod and had to reconstruct the report tables from
scrollback. Archives are cheap. Losing the basis for published numbers is not.

Each archive holds: the model's raw responses (`raw/answer.md`,
`raw/reasoning.md`), the extracted sources that were actually built, every
trial's `verify.log`, `metrics.json`, and the run logs. **Build output is
excluded** — Rust's `target/` alone runs to gigabytes.

**Keep one archive per thinking mode.** Merging `repeat-think/` and
`repeat-instruct/` into one means nobody can tell them apart later without
counting `reasoning_chars`.

**Copy `$BENCH_OUT` off the host before terminating it.** Nothing in this
directory can be recovered afterwards.

| Archive | Report |
|---|---|
| *(none yet)* | |

Every committed number needs its measurement conditions alongside it:

- llama.cpp version (`llama-server --version`)
- `GGUF_FILE`
- `CTX` / `KV_TYPE_K` / `KV_TYPE_V` / `FLASH_ATTN` / `N_PARALLEL`
- `REASONING` / `REASONING_BUDGET` / `REASONING_FORMAT`
- `TEMP` / `TOP_P` / `TOP_K` / `MAX_TOKENS`
- trial count n

**A number without them is not reproducible.**
