# qwen3.8-27b-bench

[English](README.md) | **日本語**

**Qwen3.8-27B を RTX 5090 32GB 1 枚で OpenCode のバックエンドとして実用できるか**を、
自前の GPU 上で判定するためのベンチマーク。

評価軸とタスク一式は [letusfly85/coding-agent-bench](https://github.com/letusfly85/coding-agent-bench)（cab）
から**そのまま持ち込んでいる**。`bench/tasks/` は無改変なので、cab の
Qwen3.6-27B / Qwen3-Coder-Next 80B、および
[deepseek-v4-flash-bench](https://github.com/wonder-soft/deepseek-v4-flash-bench)
の DeepSeek-V4-Flash 284B で取った既存の数字と直接比較できる。

> **現状: 未計測。** リポジトリは組んだが、実機に触っていない。
> 始点は [`docs/RESUMING.ja.md`](docs/RESUMING.ja.md)。

## 対象

| | |
|---|---|
| モデル | `Qwen/Qwen3.8-27B`（dense 27B / 262k ctx（YaRN で 1M）/ multimodal / Apache 2.0、2026-08-14 公開） |
| 使う重み | `unsloth/Qwen3.8-27B-GGUF` の **`Qwen3.8-27B-Q4_K_M.gguf` — 17.11 GB** |
| 機材 | **RTX 5090 32GB ×1** |
| サーバ | llama.cpp（`llama-server`、`--jinja`） |
| クライアント | OpenCode（OpenAI 互換プロバイダとして接続） |

アーキテクチャは Gated DeltaNet ハイブリッド。64 層が
`16 × (3 × GatedDeltaNet → 1 × GatedAttention)` で、**フルアテンションは 16 層だけ**。
通常の 27B より KV cache が大幅に軽いはずで、32GB 1 枚で長いコンテキストが載る
見込みがある。**これは見込みであって計測値ではない。** 確定させるのが M1。

## なぜこの構成か

**Q4_K_M と RTX 5090 は、品質で選んだのではなく比較可能性で選んでいる。**
cab の Qwen3.6-27B は RTX 5090 32GB ×1 / llama.cpp / Q4_K_M で測られている。
量子化・機材・タスクファイルを揃えれば、動く変数は **3.6 → 3.8 の世代差だけ**になる。
ここを変えると、このリポジトリが存在する理由である比較が消える。

32GB には余裕があるので、比較を取り切った**後**に品質側の量子化も振れる:

| GGUF | サイズ | 位置づけ |
|---|---:|---|
| `Q4_K_M` | 17.11 GB | **基準。cab と揃える** |
| `UD-Q4_K_XL` | 17.92 GB | unsloth dynamic。同サイズで上のはず |
| `Q5_K_M` | 19.83 GB | 余裕の範囲 |
| `Q6_K` | 22.88 GB | 品質の上限を見る |
| `Q8_0` | 29.05 GB | 32GB では KV が残らない |
| `mmproj-F16` | 0.93 GB | vision。コーディングには不要 |

## 比較先（既に取れている数字）

`bench/tasks/` が無改変なので、以下はそのまま並べてよい。

### pass@1（n=5、test まで通ったもの）

| 言語 | DeepSeek-V4-Flash 284B | Qwen3.6-27B | **Qwen3.8-27B** |
|---|---:|---:|---:|
| Go / net/http | 5/5 | 5/5 | — |
| Python / FastAPI | 4/5 | 5/5 | — |
| Rust / axum 0.8 | 2/5 | **0/5** | — |
| Scala / http4s | 0/5 | **0/5** | — |

### その他

| 軸 | DeepSeek 284B | Qwen3.6-27B | **Qwen3.8-27B** |
|---|---:|---:|---:|
| tool 選択精度（n=30） | 93.3% | 90.0% | — |
| 不正な tool call | 0/169 | 0/166 | — |
| エージェント完遂 | 18/18 | 18/18 | — |
| Scala 修正ループ | 2 ラウンドで収束 | **3 ラウンドで収束せず** | — |

**太字が仮説の的。** Rust のテスト（0/5）、Scala（0/5）、修正ループの非収束が
Qwen3.6 の明確な弱点で、3.8 の公称値（SWE-Bench Pro 61.7% / LiveCodeBench v6 90.3%）が
本物ならここが動くはず。動かなければ公称値の側を疑う材料になる。

## 主眼: thinking モードを独立変数にする

**このリポジトリの一番の存在理由。**

deepseek-v4-flash-bench の M4 レポート §7 は、こう締めている
— 284B は全 20 生成で `reasoning_chars = 0`、つまり**非 thinking** で動いていた。
一方 cab の Qwen3.6 の数字は reasoning が出力の約 8 割を占める条件のもの。
`chat_template_kwargs.thinking` は効かず（チェックポイントにチャットテンプレートが無い）、
**「284B は 27B と互角」はモデルの話ではなくモードの話かもしれない**という
留保が付いたまま終わっている。

Qwen3.8-27B は `reasoning_effort` を持ち、llama-server 側にも
`--reasoning on|off` と `--reasoning-budget N` がある。つまり
**同一モデル・同一タスク・同一サンプリングで thinking だけを振れる。**
DeepSeek 側のテンプレート問題を解かなくても、「このタスク群で thinking は
何ポイント分か」を独立に測って、M4 の留保に定量的な幅を与えられる。

`bench/scripts/thinking_sweep.sh` がこれをやる。**モードはサーバ起動時のフラグ**
なので、モードごとにサーバを立て直す必要がある。スクリプトは実行前に
ライブのサーバを叩いて `reasoning_chars` を確認し、要求したモードと違えば
**中断する** — このリスクは「2 回測って同じ数字が出て、thinking は無意味だったと
書いてしまう」という静かな失敗なので、明示的に守る。

## 構成

```
serving/
  env.example.sh          全スクリプトが source する設定。コピーして env.sh に
  00_preflight.sh         VRAM・ディスク・llama.cpp のフラグ・ツールチェインを確認
  01_download_model.sh    GGUF を 1 本取得（17.11 GB）
  02_serve_llamacpp.sh    llama-server を起動。使ったフラグを全部表示する
  03_smoke.sh             /v1/models・単発生成・thinking・tool call の疎通
bench/
  scripts/
    thinking_sweep.sh      [新] thinking モードごとに全タスクを回す
    bench_throughput.py    [新] 並列数ごとの単発/合計スループット（llama.cpp 用に書き直し）
    run_coding_task.py     生成タスクを投げて生成物をファイル化（cab から）
    run_repeat.sh          N 回繰り返して pass@1（cab から）
    run_repair.sh          ビルドエラーを返して再生成（cab から）
    run_prompt_variants.sh プロンプト変種比較（cab から）
    tool_call_fidelity.py  単発 tool call の JSON/スキーマ/選択精度（cab から）
    agent_loop.py          自前の多ターンエージェントループ（cab から）
    run_all.sh             1〜4 をまとめて回す
  tasks/                   cab から無改変。触らないこと
opencode/
  opencode.json.example  OpenCode を自前 llama-server に向ける設定
  README.md              OpenCode 側で何を測るか
docs/
  SETUP.md               ホスト準備から OpenCode 接続まで
  RESUMING.md            別セッションへの引き継ぎ ← ここから読む
  reports/               計測レポート（まだ空）
results/                 生成物・生ログ
```

ドキュメントはすべて日英併記。既定のファイル名が英語、`*.ja.md` が日本語。
片方を直したら同じコミットでもう片方も直す。

## 評価軸

cab の 6 軸に、この構成固有の 2 軸を足している。

| 軸 | 何を見るか | 出どころ |
|---|---|---|
| スループット | 単発 tok/s と並列時の合計 tok/s、TTFT | cab |
| VRAM / コンテキスト | 17 GB の重みを引いた残りで何トークン載るか | cab |
| 一発正答率 | 生成コードが無修正で build / test を通るか | cab |
| 指示追従 | 出力フォーマット（ファイル分割）を守れるか | cab |
| tool calling | tool call の JSON 妥当性・スキーマ準拠・選択精度 | cab |
| エージェント完遂率 | 実ファイルを操作する多ターンループを完遂できるか | cab |
| **thinking の効き** | thinking on/off/budget で完遂率と実時間がどう動くか | **新規** |
| **OpenCode 実運用** | 実際の OpenCode セッションでタスクが終わるか | **新規** |

## 計測の作法

cab と deepseek-v4-flash-bench から引き継ぐ 4 つ。全部、実際に間違えた経験に基づく。

**pass@1 を 1 試行で測らない。** cab の初回計測では n=1 の結果が n=5 と正反対に
なった（Rust: n=1 pass → n=5 で 0/5、Go: n=1 fail → n=5 で 5/5）。量子化間の差より
試行間の分散のほうが大きい。`run_repeat.sh` を使う。

**サンプリング設定を揃える。** 揃えずに比較すると、モデルの差ではなく
サンプリングの差を測る。`serving/env.sh` の `TEMP`/`TOP_P`/`TOP_K` を
比較対象間で固定する。**モデルカードの推奨値ではなく cab の値を使う**
（temp 0.6 / top_p 0.95 / top_k 20）。比較可能性が優先。

**出力がおかしいとき、まずハーネスを疑う。** 過去に「Q2 量子化で壊れた」と
見えた事象の真因が、モデルの出力形式を読めないパーサだったことがある。
`03_smoke.sh` で生の API を叩いて、モデルが正常なことを確かめてから
ハーネスの結果を解釈する。

**モードは静かに間違う。** `--reasoning-format` が `deepseek` でないと思考が
`message.content` に混ざり、`run_coding_task.py` が思考テキストから
`### FILE:` を探しに行って全タスクが落ちる。エラーは出ず、モデルのせいに見える。
`03_smoke.sh` の thinking チェックを毎回通してから本番を回すこと。

## 参照

- [Qwen/Qwen3.8-27B](https://huggingface.co/Qwen/Qwen3.8-27B)
- [unsloth/Qwen3.8-27B-GGUF](https://huggingface.co/unsloth/Qwen3.8-27B-GGUF)
- [ggml-org/Qwen3.8-27B-GGUF](https://huggingface.co/ggml-org/Qwen3.8-27B-GGUF)
- [Qwen3.8 — Unsloth Docs](https://unsloth.ai/docs/models/qwen3.8)
- [letusfly85/coding-agent-bench](https://github.com/letusfly85/coding-agent-bench) — タスクと評価軸の出どころ
- [wonder-soft/deepseek-v4-flash-bench](https://github.com/wonder-soft/deepseek-v4-flash-bench) — 284B 側の比較先。M4 レポート §7 がこのリポジトリの出発点
