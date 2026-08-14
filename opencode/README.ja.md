# OpenCode を自前の llama-server に向ける

[English](README.md) | **日本語**

このリポジトリの最終目的は「Qwen3.8-27B を RTX 5090 1 枚で OpenCode の
バックエンドとして実用できるか」の判定なので、ここが本番。合成スコアではなく
**実際に OpenCode がタスクを完遂できるか**を見る。

## 手順

1. サーバを立てる（`serving/02_serve_llamacpp.sh`）
2. `opencode.json.example` を、OpenCode を動かすマシンの
   `~/.config/opencode/opencode.json` にコピーして `baseURL` を書き換える
   - サーバと同じホストで OpenCode を動かすなら `127.0.0.1:8000` のまま
   - 手元から繋ぐなら SSH ポートフォワード:
     `ssh -N -L 8000:127.0.0.1:8000 <host>`
     エンドポイントを外部に公開するより、これで閉じたほうがよい
3. `export LLAMA_API_KEY=dummy`（llama-server を `--api-key` なしで起動していても
   AI SDK 側がキーを要求するため、空でない何かが要る）
4. `opencode` を起動 → `/models` → `qwen38-local/qwen3.8-27b` を選択

## 先に確認すること

**`serving/03_smoke.sh` の tool call ラウンドトリップが通っていること。**
`tool_calls: NONE` のまま OpenCode を起動すると、モデルが tool を呼べず、
「賢いのに何もできない」という紛らわしい壊れ方をする。原因はほぼ確実に
`--jinja` を付け忘れていること。

**`limit.context` は実測値に合わせること。** `serving/env.sh` の `CTX` より
大きい値を書くと、OpenCode が履歴を切らずに投げてサーバ側で 400 になる。
M1 で確定した値を両方に入れる。

**thinking の扱いを決めてから始めること。** 既定は thinking on で、これは
1 ターンあたりの reasoning が数千トークンになりうる。OpenCode は 1 タスクで
数十ターン回すので、体感が支配されるのはここ。3 通り試して比べる:

| 設定 | サーバ起動時 |
|---|---|
| フル思考 | `REASONING=on REASONING_BUDGET=-1` |
| 思考を絞る | `REASONING=on REASONING_BUDGET=2048` |
| 思考なし | `REASONING=off` |

`REASONING_BUDGET` は「速いが浅い」と「遅いが正しい」の間を連続的に振れる
唯一のつまみなので、OpenCode の実用ラインを探すのはここになる。

## 測ること

| 見るもの | 取り方 |
|---|---|
| 体感速度 | 1 ターンの TTFT と decode tok/s。`bench/scripts/bench_throughput.py` の concurrency=1 の行と突き合わせる |
| タスク完遂率 | `bench/tasks/agent-*` を作業ディレクトリに置いて OpenCode に投げ、`verify.sh` で判定 |
| tool call の質 | 空振り・引数不正・同じファイルの読み直しが何回起きるか |
| 長い履歴での劣化 | 30 ターン超えたあたりで指示追従が落ちないか |
| thinking のコスト | 同じタスクを 3 設定で回して、完遂率と実時間の両方を並べる |

`bench/scripts/agent_loop.py`（coding-agent-bench から持ってきた自前ループ）と
**同じタスクで**比較すると、モデルの限界なのか OpenCode の足回りなのかを
切り分けられる。片方だけ回して結論を出さないこと。
