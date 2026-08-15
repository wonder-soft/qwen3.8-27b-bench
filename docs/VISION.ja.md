# vision

[English](VISION.md) | **日本語**

Qwen3.8-27B はマルチモーダル。GGUF と一緒に vision projector を読ませれば、
コーディングベンチが使っているのと同じエンドポイントに、そして OpenCode から
画像を投げられる。

2026-08-15、RTX 5090 32GB × 1、llama.cpp `9d57ce4` での実測。
レポートの M0〜M4 の数字は**いずれも vision を載せずに取っている** — 
`WANT_MMPROJ` の既定が `0` なのはそのため。

## 有効にする

```bash
WANT_MMPROJ=1 MMPROJ_FILE=mmproj-F16.gguf ./serving/01_download_model.sh   # 0.93 GB
WANT_MMPROJ=1 ./serving/02_serve_llamacpp.sh
```

起動ログの `loaded multimodal model` が確認点。これが無いとリクエスト中の
画像パートは黙って捨てられ、テキストだけ送ったかのように応答する。

## コスト

| | mmproj 無し | mmproj 有り |
|---|---:|---:|
| `CTX=262144` での VRAM | 26,134 MiB | **27,358 MiB** |
| 32,607 MiB カードの残り | 6,473 | 5,249 |

**+1.2 GB。コンテキスト上限は動かない** — 262,144 のまま載るので、
このカードでは vision のために履歴を削る必要がない。トレードする理由はない。

## 呼び方

OpenAI 互換の `image_url` パート。data URI でもリモート URL でもよい。

```python
body = {
  "model": "qwen3.8-27b",
  "messages": [{"role": "user", "content": [
    {"type": "text", "text": "このスクリーンショットには何が写っている？"},
    {"type": "image_url", "image_url": {"url": "data:image/jpeg;base64," + b64}},
  ]}],
  "max_tokens": 4096,
}
```

## 唯一の落とし穴: `max_tokens`

**thinking が有効だと思考が回答より先に走り、画像が入るとその思考は
小さい `max_tokens` に収まらない量まで伸びる。**

同じ画像・同じサーバで、予算だけを変えた場合:

| `max_tokens` | reasoning 文字数 | content | どう見えるか |
|---:|---:|---|---|
| 512 | 1,732 | **空文字列** | 「画像が読めていない」 |
| 4096 | 4,511 | 完全で正しい回答 | 動く |

512 のケースは HTTP 200 で `content: ""` を返す。エラーは出ない。
vision が壊れているように読めるが、実際には画像は正しくパースされており、
思考の途中で予算が尽きただけである。画像リクエストには数千トークンの余裕を
与えるか、`REASONING_BUDGET` で思考を絞ること。

これは [M0〜M4 レポート](reports/2026-08-15-m0-m4-thinking-axis.ja.md) の
Rust / Scala 非終端と同じ形の失敗である。思考が予算を食い尽くし、
空の結果がトークン上限ではなくモデルの能力のせいにされる。

## OpenCode

モデルエントリに 2 つのフィールドが要る。どちらが欠けても、
UI 上は画像を添付できるのに送信されない。

```json
"attachment": true,
"modalities": { "input": ["text", "image"], "output": ["text"] }
```

全体は [`opencode/opencode.json.example`](../opencode/opencode.json.example)。

## 観測された品質

OpenCode のセッション画面 1668×718 を 1 枚、`temperature 0`、21 秒、
prompt 1,226 トークン / completion 1,413 トークン。モデルは:

- アプリ名を同定し、ステータスバーからバージョンを読み取った
- 実在する行を 1 つ引用するよう求めたところ、正確に引用した
- ファイルパス・sbt の出力・`IOApp` や `Compile / run / fork` の記述から
  言語を Scala と判定した
- **サイドバーのタスク名が「Rust axum todo REST API」なのに、画面に出ている
  コードは Scala の例である、という食い違いを指摘した**

最後のものが興味深い。画面を転写しているのではなく、画面のレイアウトについて
推論している。ただしこれは 1 回の観測であってベンチマークではない。
`bench/` に vision の軸は無く、**この数字をベンチ結果として引用しないこと。**
