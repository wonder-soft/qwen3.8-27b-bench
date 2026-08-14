#!/usr/bin/env python3
"""Serving throughput across concurrency levels, against llama-server.

Replaces the DeepSeek repo's bench_throughput.sh, which shelled out to
`vllm bench serve` and is unusable here.

Two numbers matter for the OpenCode question and they are different:
  - single-stream tok/s -> how fast one agent turn feels
  - aggregate tok/s     -> how many agents the box can host
Only the first one decides whether OpenCode is pleasant to use.

Concurrency above 1 requires llama-server started with --parallel N. With
--parallel 1 the requests queue, aggregate tok/s stays flat at the
single-stream figure, and the flat line reads like a scaling wall rather than
a configuration mistake.
"""
import argparse, json, os, statistics, sys, time
import urllib.request
from concurrent.futures import ThreadPoolExecutor

PROMPT = (
    "Write a detailed technical explanation of how a write-ahead log keeps a "
    "database durable across crashes. Cover the fsync boundary, checkpointing, "
    "and recovery. Be thorough."
)


def one_request(base_url, model, out_len, temp, top_p, top_k):
    body = {
        "model": model,
        "messages": [{"role": "user", "content": PROMPT}],
        "max_tokens": out_len,
        "temperature": temp, "top_p": top_p, "top_k": top_k,
        "stream": True,
    }
    req = urllib.request.Request(
        f"{base_url}/v1/chat/completions",
        data=json.dumps(body).encode(),
        headers={"Content-Type": "application/json"},
    )
    t0 = time.perf_counter()
    ttft = None
    n_tok = 0
    with urllib.request.urlopen(req, timeout=1800) as resp:
        for raw in resp:
            line = raw.decode("utf-8", "replace").strip()
            if not line.startswith("data: "):
                continue
            payload = line[6:]
            if payload == "[DONE]":
                break
            try:
                d = json.loads(payload)
            except json.JSONDecodeError:
                continue
            delta = (d.get("choices") or [{}])[0].get("delta") or {}
            # Count reasoning tokens too. With thinking on they ARE the latency
            # the user waits through; excluding them flatters the model.
            if delta.get("content") or delta.get("reasoning_content"):
                if ttft is None:
                    ttft = time.perf_counter() - t0
                n_tok += 1
    total = time.perf_counter() - t0
    decode = total - (ttft or 0)
    return {
        "ttft_s": ttft,
        "total_s": total,
        "tokens": n_tok,
        "decode_tok_s": (n_tok - 1) / decode if decode > 0 and n_tok > 1 else None,
    }


def run_level(base_url, model, conc, reps, out_len, temp, top_p, top_k):
    n = conc * reps
    t0 = time.perf_counter()
    with ThreadPoolExecutor(max_workers=conc) as pool:
        results = list(pool.map(
            lambda _: one_request(base_url, model, out_len, temp, top_p, top_k),
            range(n)))
    wall = time.perf_counter() - t0
    tokens = sum(r["tokens"] for r in results)
    per = [r["decode_tok_s"] for r in results if r["decode_tok_s"]]
    ttfts = [r["ttft_s"] for r in results if r["ttft_s"]]
    return {
        "concurrency": conc,
        "requests": n,
        "wall_s": wall,
        "total_tokens": tokens,
        "aggregate_tok_s": tokens / wall if wall else None,
        "single_stream_tok_s_median": statistics.median(per) if per else None,
        "ttft_s_median": statistics.median(ttfts) if ttfts else None,
        "ttft_s_p99": max(ttfts) if ttfts else None,
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--base-url", default="http://127.0.0.1:8000")
    ap.add_argument("--model", default="qwen3.8-27b")
    ap.add_argument("--concurrency", default="1,2,4,8")
    ap.add_argument("--reps", type=int, default=3, help="requests per worker")
    ap.add_argument("--out-len", type=int, default=1024)
    ap.add_argument("--temperature", type=float, default=0.6)
    ap.add_argument("--top-p", type=float, default=0.95)
    ap.add_argument("--top-k", type=int, default=20)
    ap.add_argument("--label", default="run")
    ap.add_argument("--out", default="throughput.json")
    a = ap.parse_args()

    rows = []
    for conc in [int(c) for c in a.concurrency.split(",") if c.strip()]:
        print(f"##### concurrency={conc} #####", flush=True)
        row = run_level(a.base_url, a.model, conc, a.reps, a.out_len,
                        a.temperature, a.top_p, a.top_k)
        rows.append(row)
        print(json.dumps(row, indent=2), flush=True)

    os.makedirs(os.path.dirname(os.path.abspath(a.out)), exist_ok=True)
    with open(a.out, "w") as f:
        json.dump({"label": a.label, "model": a.model, "rows": rows}, f, indent=2)

    print("\n=== summary ===")
    print(f"{'conc':>5} {'single tok/s':>13} {'aggregate tok/s':>16} {'ttft med':>9} {'ttft p99':>9}")
    for r in rows:
        f = lambda v: f"{v:.1f}" if isinstance(v, (int, float)) else "-"
        print(f"{r['concurrency']:>5} {f(r['single_stream_tok_s_median']):>13} "
              f"{f(r['aggregate_tok_s']):>16} {f(r['ttft_s_median']):>9} {f(r['ttft_s_p99']):>9}")
    print(f"\nwrote {a.out}")
    if rows and len(rows) > 1 and rows[0]["aggregate_tok_s"] and rows[-1]["aggregate_tok_s"]:
        ratio = rows[-1]["aggregate_tok_s"] / rows[0]["aggregate_tok_s"]
        if ratio < 1.2:
            print("\nAggregate barely moved with concurrency. Check that llama-server")
            print("was started with --parallel >= the highest concurrency here.")


if __name__ == "__main__":
    sys.exit(main())
