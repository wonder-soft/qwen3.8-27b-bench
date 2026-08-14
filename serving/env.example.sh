#!/usr/bin/env bash
# Copy to serving/env.sh (gitignored) and adjust. Sourced by every script here.
#
# NOTE: host-specific values (hostnames, ports, volume names, tokens) belong in
# the gitignored copy, never here. This repo is written as if public even while
# private, so it must stay free of infra details.
#
# CHANGING A VALUE: edit the assignment in place. Do NOT append overrides to the
# end of env.sh — both spellings fail, in opposite and quiet ways:
#   export CTX=32768                    # wins over the sweep scripts, which set
#                                       # it in the environment. Every row of a
#                                       # sweep then comes back identical and
#                                       # looks like a real flat result.
#   export CTX=${CTX:-32768}            # no-op: the assignment above already set
#                                       # it, so :- never fires and the ORIGINAL
#                                       # default wins.
# Both were hit for real on the DeepSeek-V4-Flash run and each cost a full sweep.

# --- where things live -------------------------------------------------------
# Local disk. A 17 GB GGUF read over FUSE/NFS is slow and llama.cpp mmaps it.
export HF_HOME=${HF_HOME:-/root/.cache/huggingface}
export MODEL_DIR=${MODEL_DIR:-/root/models}
export BENCH_REPO=${BENCH_REPO:-/root/qwen3.8-27b-bench}
export BENCH_OUT=${BENCH_OUT:-/root/results}

# --- model -------------------------------------------------------------------
# Q4_K_M is the PRIMARY quant, and the choice is not about quality — it is the
# quant coding-agent-bench used for Qwen3.6-27B. Same quant, same task files,
# same hardware class means the 3.6 -> 3.8 delta is the only thing moving.
# Change this and you lose the one comparison this repo exists to make.
#
#   Qwen3.8-27B-Q4_K_M.gguf        17.11 GB   <- baseline-matching, use this
#   Qwen3.8-27B-UD-Q4_K_XL.gguf    17.92 GB   unsloth dynamic, better at same size
#   Qwen3.8-27B-Q5_K_M.gguf        19.83 GB   headroom exists on 32 GB
#   Qwen3.8-27B-Q6_K.gguf          22.88 GB   quality-ceiling probe
#   Qwen3.8-27B-Q8_0.gguf          29.05 GB   will NOT leave room for KV on 32 GB
export GGUF_REPO=${GGUF_REPO:-unsloth/Qwen3.8-27B-GGUF}
export GGUF_FILE=${GGUF_FILE:-Qwen3.8-27B-Q4_K_M.gguf}
export SERVED_NAME=${SERVED_NAME:-qwen3.8-27b}

# Vision projector. Not needed for any coding task here; pull it only if you
# want to poke at the multimodal side. ~0.93 GB.
export MMPROJ_FILE=${MMPROJ_FILE:-mmproj-F16.gguf}
export WANT_MMPROJ=${WANT_MMPROJ:-0}

# --- serving -----------------------------------------------------------------
export PORT=${PORT:-8000}
export NGL=${NGL:-99}          # all layers on the GPU; 27B Q4 fits 32 GB

# 64 layers, but only 16 of them are full attention (the layout is
# 16 x (3 x GatedDeltaNet -> 1 x GatedAttention)). KV cache is therefore roughly
# a quarter of what a conventional 27B would need at the same context, which is
# why a long CTX is plausible on one 32 GB card. It is still UNMEASURED here —
# M1 exists to find the real ceiling. Do not quote this number as a result.
export CTX=${CTX:-131072}
export KV_TYPE_K=${KV_TYPE_K:-q8_0}
export KV_TYPE_V=${KV_TYPE_V:-q8_0}
export FLASH_ATTN=${FLASH_ATTN:-on}
export N_PARALLEL=${N_PARALLEL:-1}   # raise only for the throughput runs

# --- thinking ----------------------------------------------------------------
# THE reason this repo exists. DeepSeek-V4-Flash could not be switched into
# thinking mode at all (its checkpoint ships no chat template), so the M4
# comparison was non-thinking 284B vs thinking 27B and every conclusion carried
# that caveat. Qwen3.8-27B exposes the switch, so here it is an independent
# variable instead of an unknown.
#
#   REASONING=on  + REASONING_BUDGET=-1   full thinking (model default)
#   REASONING=on  + REASONING_BUDGET=2048 capped thinking
#   REASONING=off                         instruct mode
#
# --reasoning-format deepseek is NOT optional: it routes thoughts into
# message.reasoning_content. With the default the thoughts land in
# message.content, run_coding_task.py parses `### FILE:` blocks out of the
# reasoning text, and the task fails for a reason that has nothing to do with
# the model. This is the same class of bug as the Q2 incident — harness first.
export REASONING=${REASONING:-on}
export REASONING_BUDGET=${REASONING_BUDGET:--1}
export REASONING_FORMAT=${REASONING_FORMAT:-deepseek}

# --- sampling (keep identical across every run being compared) ---------------
# Qwen3.8-27B model card. Thinking and instruct mode want DIFFERENT values, and
# 02_serve_llamacpp.sh does not pick for you — the bench scripts pass these
# explicitly per request. Switching REASONING without switching these means you
# measured sampling, not the mode.
#
#   thinking : temp 1.0  top_p 0.95  top_k 20  min_p 0.0  presence_penalty 0.0
#   instruct : temp 0.7  top_p 0.80  top_k 20  min_p 0.0  presence_penalty 1.5
#
# The defaults below are neither: they are cab's coding preset (temp 0.6 /
# top_p 0.95 / top_k 20), kept because the Qwen3.6-27B numbers being compared
# against were taken with them. Comparability beats the model card here. Use
# MODEL_CARD_SAMPLING=1 to switch to the card values for a separate run.
export TEMP=${TEMP:-0.6}
export TOP_P=${TOP_P:-0.95}
export TOP_K=${TOP_K:-20}
export MIN_P=${MIN_P:-0.0}
export MAX_TOKENS=${MAX_TOKENS:-24000}

# --- binary ------------------------------------------------------------------
# Gated DeltaNet needs recent operators. The arch landed for Qwen3.6; whether
# THIS model's arch string is registered in your build is the first thing
# 00_preflight.sh checks. Build from source if the distro package is behind.
export LLAMA_SERVER=${LLAMA_SERVER:-llama-server}
export LLAMA_CLI=${LLAMA_CLI:-llama-cli}
