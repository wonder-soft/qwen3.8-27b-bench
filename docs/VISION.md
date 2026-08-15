# Vision

**English** | [日本語](VISION.ja.md)

Qwen3.8-27B is multimodal. Loading the vision projector alongside the GGUF lets
you send images to the same endpoint the coding bench uses, and to OpenCode.

Measured 2026-08-15 on RTX 5090 32 GB × 1, llama.cpp `9d57ce4`. None of the
M0–M4 numbers in the report were taken with vision loaded — `WANT_MMPROJ`
defaults to `0` for exactly that reason.

## Enable it

```bash
WANT_MMPROJ=1 MMPROJ_FILE=mmproj-F16.gguf ./serving/01_download_model.sh   # 0.93 GB
WANT_MMPROJ=1 ./serving/02_serve_llamacpp.sh
```

`loaded multimodal model` in the startup log is the confirmation. Without it,
image parts in a request are silently dropped and the model answers as if you
had sent text only.

## What it costs

| | without mmproj | with mmproj |
|---|---:|---:|
| VRAM at `CTX=262144` | 26,134 MiB | **27,358 MiB** |
| free on a 32,607 MiB card | 6,473 | 5,249 |

**+1.2 GB. The context ceiling does not move** — 262,144 still fits, so vision
costs no history on this card. There is no reason to trade context for it.

## Calling it

Standard OpenAI-shaped `image_url` parts, data URI or remote URL:

```python
body = {
  "model": "qwen3.8-27b",
  "messages": [{"role": "user", "content": [
    {"type": "text", "text": "What is in this screenshot?"},
    {"type": "image_url", "image_url": {"url": "data:image/jpeg;base64," + b64}},
  ]}],
  "max_tokens": 4096,
}
```

## The one trap: `max_tokens`

**With thinking on, the reasoning runs before the answer, and an image pushes
that reasoning well past what a small `max_tokens` can hold.**

Same image, same server, only the budget changed:

| `max_tokens` | reasoning chars | content | looks like |
|---:|---:|---|---|
| 512 | 1,732 | **empty string** | "the model cannot see images" |
| 4096 | 4,511 | full, correct answer | works |

The 512 case returns HTTP 200 with `content: ""`. Nothing errors. It reads as a
broken vision stack when the image was in fact parsed fine — the budget simply
ran out mid-thought. Give image requests a few thousand tokens, or cap thinking
with `REASONING_BUDGET`.

This is the same failure shape as the Rust and Scala non-termination in the
[M0–M4 report](reports/2026-08-15-m0-m4-thinking-axis.md): thinking consumes the
budget and the empty result gets blamed on the model's competence rather than on
the token ceiling.

## OpenCode

Two fields in the model entry, both required. With either missing, OpenCode will
let you attach an image in the UI but will not send it.

```json
"attachment": true,
"modalities": { "input": ["text", "image"], "output": ["text"] }
```

Full file: [`opencode/opencode.json.example`](../opencode/opencode.json.example).

## Observed quality

One 1668×718 screenshot of an OpenCode session, `temperature 0`, 21 s,
1,226 prompt tokens / 1,413 completion tokens. The model:

- named the application and read its version out of the status bar
- quoted an exact line of terminal output when asked for one
- identified the language as Scala from the file path, the sbt output, and the
  `IOApp` / `Compile / run / fork` references
- **flagged that the sidebar task title said "Rust axum todo REST API" while the
  code actually on screen was the Scala example**

The last one is the interesting result: it is reasoning about the layout of the
screen, not transcribing it. This was a single observation, not a benchmark —
there is no vision axis in `bench/` and these numbers should not be quoted as
one.
