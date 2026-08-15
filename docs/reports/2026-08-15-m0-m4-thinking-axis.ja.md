# M0〜M4: RTX 5090 1 枚の Qwen3.8-27B と、thinking の代償

[English](2026-08-15-m0-m4-thinking-axis.md) | **日本語**

2026-08-15。このリポジトリ初の実測。これ以前はすべて骨組みだった。

## 測定条件

これが無い数字は再現できない。

| | |
|---|---|
| モデル | `unsloth/Qwen3.8-27B-GGUF` :: `Qwen3.8-27B-Q4_K_M.gguf` |
| サイズ / 検証 | 17,106,775,008 B、sha256 `7e78da5d7e3ae28d178121f58646953305f3e5bd3cb46f4a75584e8b6c6fe169`（LFS oid と一致） |
| アーキテクチャ | `qwen3_5`。llama.cpp 側は `LLM_ARCH_QWEN35` で解決 |
| サーバ | llama.cpp `llama-server`、commit `9d57ce4`、`-DGGML_CUDA=ON -DCMAKE_CUDA_ARCHITECTURES=120` でビルド |
| 機材 | RTX 5090 32,607 MiB × 1、driver 580.126.09、CUDA 12.8、128 vCPU |
| コンテキスト | 全ベンチで `CTX=262144`（M1 参照） |
| KV cache | `q8_0` / `q8_0`、`--flash-attn on` |
| 並列 | M2 のみ `--parallel 8`、M3・M4 は `--parallel 1` |
| reasoning | `--reasoning-format deepseek`。`--reasoning on --reasoning-budget -1`（M3）/ `--reasoning off`（M4） |
| サンプリング | temp 0.6 / top_p 0.95 / top_k 20 — cab のコーディングプリセット。**モデルカード値ではない**（比較可能性を優先） |
| `MAX_TOKENS` | 24000 |
| n | コーディング各タスク 5、tool calling 30 プロンプト、agent 各タスク 13 エピソード |

`bench/tasks/` は
[coding-agent-bench](https://github.com/letusfly85/coding-agent-bench)
から無改変なので、以下の DeepSeek-V4-Flash 284B 列と Qwen3.6-27B 列はそのまま比較できる。

## 結論

**このタスク群において thinking は品質とレイテンシのトレードオフではなく、4 タスク中 2 つで純粋に有害だった。**
thinking モードの Rust と Scala は 10/10 で**出力ゼロ**。24,000 トークンの予算を
思考ブロックの中で使い切り、回答を 1 文字も出さなかった。thinking を切ると
両方とも実際の実装を、12 分の 1 の実時間で生成した。どちらもコンパイルは
通らないので pass@1 はいずれも 0/5 のままだが、「何も書かなかった」と
「1 種類の型エラーを繰り返しながら書いた」は別の失敗であり、
コーディング能力についての主張になるのは後者だけである。

これは
[deepseek-v4-flash-bench の M4 レポート §7](https://github.com/wonder-soft/deepseek-v4-flash-bench/blob/main/docs/reports/2026-08-02-m4-coding-quality-vs-qwen3.6-27b.ja.md)
が残した留保に対する直接的で定量的な答えになる。ここではモードは
交絡因子ではない。pass@1 を動かす。

## M1 — コンテキスト上限

4 設定すべてロードできた。ネイティブコンテキストが 1 枚に丸ごと載る。

| CTX | VRAM 使用 | 残り | ロード |
|---:|---:|---:|---|
| 32,768 | 17,398 MiB | 15,209 | 可 |
| 65,536 | 18,646 MiB | 13,961 | 可 |
| 131,072 | 21,142 MiB | 11,465 | 可 |
| **262,144** | **26,134 MiB** | **6,473** | **可** |

262,144 は `n_ctx_train`、すなわち YaRN 無しの上限であって、
VRAM の限界に当たった値ではない。KV は 1,024 トークンあたり約 38 MiB、
重みが約 16.2 GiB を占める。

README は「フルアテンションが 64 層中 16 層だけ
（`16 × (3 × GatedDeltaNet → 1 × GatedAttention)`）なので 131,072 は載る見込み」
としていた。実測はこの予測を上回り、ネイティブコンテキスト全体が
6.4 GiB の余裕を残して載った。

## M2 — スループット

`--parallel 8`、出力 1,024 トークン、thinking on。

| 並列数 | 単発 tok/s | 合計 tok/s | TTFT 中央値 | TTFT p99 |
|---:|---:|---:|---:|---:|
| **1** | **68.3** | 65.9 | **0.52 s** | 0.60 s |
| 2 | 51.2 | 100.0 | 0.53 s | 0.85 s |
| 4 | 37.0 | 140.5 | 1.24 s | 1.97 s |
| 8 | 19.6 | 152.0 | 2.08 s | 2.94 s |

1 ターンの体感を表すのは並列数 1 の行だけ。合計スループットは
4〜8 並列のあたりで約 152 tok/s に飽和する。

なお GGUF には llama.cpp が無視する未使用の `blk.64`（MTP / `nextn` ヘッド）が
含まれている。このモデルが想定していた投機デコードの効果は、
**上記の数字に反映されていない。**

## M3 — コーディング・tool calling・エージェント（thinking on）

### pass@1、n=5

| タスク | DeepSeek-V4-Flash 284B | Qwen3.6-27B | **Qwen3.8-27B（think）** | 失敗の質 |
|---|---:|---:|---:|---|
| Go / net/http | 5/5 | 5/5 | **5/5** | — |
| Python / FastAPI | 4/5 | 5/5 | **4/5** | test 失敗 1 件。コードは生成された |
| Rust / axum 0.8 | 2/5 | 0/5 | **0/5** | **出力が一切ない** |
| Scala / http4s | 0/5 | 0/5 | **0/5** | **出力が一切ない** |

Rust と Scala のゼロは `build=fail` ではなく `build=missing` である。
ファイルが 1 つも抽出されなかったため、`verify.sh` が
プロジェクトディレクトリを見つけられなかった。

### 思考コスト（タスクごとの中央値）

| タスク | reasoning 文字数 | 生成トークン | 実時間 |
|---|---:|---:|---:|
| go-nethttp-rest | 33,784 | 11,915 | 178 s |
| python-fastapi-rest | 20,823 | 6,225 | 92 s |
| rust-axum-rest | 87,650 | **24,000（上限）** | 365 s |
| scala-http4s-rest | 85,075 | **24,000（上限）** | 366 s |

Rust と Scala の 10 本すべてが、ちょうど `completion_tokens = 24000` で止まり
`answer_chars = 0` だった。サンプル間の分散はゼロ。
温度のブレではなく決定論的な挙動である。

### 24,000 が小さすぎただけではないのか

違う。同一モード・同一サンプリングで、予算だけ倍にした Rust 1 本を切り分けに使った。

| | 24,000 予算 | 48,000 予算 |
|---|---:|---:|
| 生成トークン | 24,000（上限） | 48,000（上限） |
| reasoning 文字数 | 87,650 | **187,633** |
| answer 文字数 | 0 | **0** |
| 実時間 | 365 s | 760 s |

予算を倍にしたら思考が倍になり、出力はゼロのままだった。
予算不足ではなく非終端である。（cab との比較可能性のため `MAX_TOKENS=24000` が
必要なので、この 1 本は pass@1 の表には含めていない。）

### tool calling、n=30

| | DeepSeek 284B | Qwen3.6-27B | **Qwen3.8-27B** |
|---|---:|---:|---:|
| 選択精度 | 93.3% | 90.0% | **83.3%** |
| 不正な tool call | 0/169 | 0/166 | **0/196** |
| レイテンシ中央値 | — | — | 1.36 s |

失敗 5 件はすべて tool の選択誤りで、JSON とスキーマの側は健全。
誤りはランダムではなく再現する — 「Run the test suite and tell me if it passes」は
3 回中 3 回とも `list_dir` を選んだ。

### エージェントループ

| タスク | 完遂エピソード | 総ターン | 不正 | ターン遅延中央値 |
|---|---:|---:|---:|---:|
| agent-fix-bug | **13/13** | 125 | 0 | 1.63 s |
| agent-multi-bug | **13/13** | 163 | 0 | 1.73 s |

26/26。比較対象 2 モデルの 18/18 と同じく満点。

**単発 83.3% の tool 選択精度は、エージェントの失敗に転化しなかった。**
マルチターンの回復力が選択誤りを吸収している。単発の tool 選択と
エージェント完遂率は別のものを測っており、一方から他方を予測してはいけない。

**エージェントのターンはほとんど思考しない。** Rust 一発生成では思考を
止められなかったのと同じ `--reasoning on` のサーバに対して、
1 ターンあたりの生成は 44〜69 トークンだった。思考の暴走はモデル全体の
性質ではなく**タスクの型**の性質である。だからこそ M5（OpenCode、
短い tool 呼び出しターンが多数）は、一発生成のコーディングタスクよりも
エージェントループに近い挙動になる可能性が高い。

## M4 — thinking 軸

同一モデル・同一タスク・同一サンプリング。動かしたのは `--reasoning` だけ。

### pass@1

| タスク | think | instruct |
|---|---:|---:|
| Go / net/http | 5/5 | **5/5** |
| Python / FastAPI | 4/5 | **5/5** |
| Rust / axum 0.8 | 0/5（出力なし） | 0/5（**コンパイルまで到達**） |
| Scala / http4s | 0/5（出力なし） | 0/5（**コンパイルまで到達**） |

### コスト（タスクごとの中央値）

| タスク | think tok | instruct tok | think s | instruct s | think answer 文字 | instruct answer 文字 |
|---|---:|---:|---:|---:|---:|---:|
| go-nethttp-rest | 11,915 | 2,283 | 178 | 34 | 8,491 | 7,132 |
| python-fastapi-rest | 6,225 | 942 | 92 | 14 | 3,401 | 3,452 |
| rust-axum-rest | 24,000 | 2,044 | 365 | 30 | **0** | **7,333** |
| scala-http4s-rest | 24,000 | 1,867 | 366 | 28 | **0** | **6,569** |

thinking は 4 タスクのいずれでも何も買わなかった。どこでも実時間を 5〜12 倍にし、
Python のサンプルを 1 つ落とし、2 タスクを沈黙に変えた。

### instruct の失敗の中身

残る 2 つのゼロは、拡散した無能さではなく**単一のライブラリイディオムの欠落が
繰り返されている**だけだった。

**Rust / axum 0.8** — 確認した 3 本すべてで `error[E0308]`。`match` や `if` の
一方の腕が `(StatusCode, Json<Task>)` を、他方が `(StatusCode, String)` を返している。
`.into_response()` や `Result<impl IntoResponse, StatusCode>` で型を揃える、
という発想に至らない。

**Scala / http4s** — 確認した 3 本中 2 本で
`value orElse is not a member of org.http4s.HttpRoutes[IO]`。
ルートを `<+>` ではなく `orElse` で合成しており、
`cats.syntax.semigroupk` の import が欠けている。

いずれも「モデルが知らない事実が 1 つあり、それが一貫して適用されている」形。
したがって次に測るべきは `bench/scripts/run_prompt_variants.sh`
（`bench/tasks/scala-http4s-rest/variants/` に cheatsheet と skeleton の変種が既にある）である。
cheatsheet で埋まるなら、これは推論の問題ではなく検索の問題だということになる。

## ハーネス側の事故

いずれも放置すればモデルの結果として報告されていたので記録する。

**偽の 0/5 を実行中に捕捉。** M3 の 1 回目は `/v1/models` の応答で
準備完了を判定していたが、これは HTTP サーバが bind した時点で応答する — 
17 GB の重みロードが終わる前である。全生成が HTTP 503 になり、
空の `go-nethttp-rest` ディレクトリ 5 つが約 20 秒で生成された。
`/health` の 200 **かつ** テスト生成の成功を待つように修正。
汚染された結果は破棄し、M3 をクリーンな状態からやり直した。

**`scala-cli` は入っていたが PATH に無かった。** インストーラは成功しており、
バイナリを自身のキャッシュディレクトリに置くだけだったため
`command -v scala-cli` が空だった。放置すれば Scala タスクの偽 0/5 になる。
`00_preflight.sh` が存在する理由そのもので、実際にここで捕捉された。

**`hf download` はもう速い経路ではない。** huggingface_hub 1.27 は
`hf_transfer` を廃止して Xet を経由するようになった。CUDA ビルドで CPU が
埋まっている状態では 0.26 MB/s しか出ず、しかもレジュームしなかった — 
2 回目の実行は新しい `.incomplete` を作り、2.5 GB を孤児にした。
素の 6 並列 range HTTP は約 27 MB/s を維持した。
`serving/01_download_model.sh` は見直すべきである。

## 当初の問いに対する判定

**Qwen3.8-27B は RTX 5090 32GB 1 枚で OpenCode のバックエンドとして使えるか。**
サービング面では余裕をもって使える。262,144 のフルコンテキスト、
単発 68 tok/s、TTFT 0.52 秒、tool call の JSON は健全、エージェント完遂 26/26。

コーディング面では言語依存で、Qwen3.6 から変わっていない。
Go と Python は堅い、Rust と Scala はビルドが通らない。
3.8 の公称値（SWE-Bench Pro 61.7% / LiveCodeBench v6 90.3%）は、
Q4_K_M のこの 2 言語では観測されない。

**OpenCode は thinking を切るか、絞って使うこと。** フル思考はここでは負債である。
pass@1 の利得ゼロに対してレイテンシ 5〜12 倍、そして最も難しい 2 タスクでは
完全に停止する。`REASONING_BUDGET=2048` が未検証の中間点であり、
次に測る価値があるのはここ。

## 未実施

- `REASONING_BUDGET=2048` — 思考を絞った中間点。OpenCode の実用ラインはおそらくここ。
- M5、OpenCode の実運用。`agent-*` と同じタスクで比較する。
- Rust と Scala に対する `run_prompt_variants.sh`。上記 2 つのイディオム欠落が
  検索で埋まる形かどうかを見る。
- `run_repair.sh` — コンパイルエラーを返せばどちらかが埋まるのか、何ラウンドかかるのか。
  Qwen3.6 は 3 ラウンドで収束しなかった。

生データ: `results/results-2026-08-15.tgz`（git-lfs）。
