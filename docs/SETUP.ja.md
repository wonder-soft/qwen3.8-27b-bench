# セットアップ

[English](SETUP.md) | **日本語**

RTX 5090 32GB 1 枚のホストで、Qwen3.8-27B を llama.cpp で立てて OpenCode から
叩けるようにするまで。

> **この文書はまだ「効いた設定」ではなく「これから試す手順」。**
> 実機で通したら §0 に確定値を書き戻すこと。dsv4 のときは、この §0 が
> 半日分の試行錯誤を次のセッションに渡す役目を果たした。

## 0. 実際に効いた設定

*（未計測。M0 を通したらここを埋める。）*

| 項目 | 値 |
|---|---|
| llama.cpp のバージョン | — |
| GGUF | `Qwen3.8-27B-Q4_K_M.gguf`（予定） |
| `CTX` の実測上限 | — |
| KV cache 型 | — |
| VRAM 使用量 | — |
| 単発 decode tok/s | — |

## 1. ホストを用意する

| | |
|---|---|
| GPU | **RTX 5090 32GB ×1** |
| ディスク | **60 GB 以上**（重み 17 GB + 生成物 + 2 本目の量子化の余地） |
| CUDA | ドライバは Blackwell（sm_120）対応のもの |

**1 枚であることが条件。** 比較先の cab / Qwen3.6-27B が RTX 5090 32GB ×1 で
測られている。複数枚のホストしか取れなかった場合は
`CUDA_VISIBLE_DEVICES=0` で 1 枚に絞ること。増やすと比較が壊れる。

ディスクは**ローカル**に確保する。llama.cpp は GGUF を mmap するので、
ネットワークボリューム（FUSE / NFS）に置くと目に見えて遅くなる。

## 2. 環境設定

```bash
git clone https://github.com/wonder-soft/qwen3.8-27b-bench
cd qwen3.8-27b-bench/serving
cp env.example.sh env.sh    # gitignore 済み
```

環境固有の値（パス・ポート）はすべて `env.sh` に書く。
`env.example.sh` には環境非依存の既定値しか置かない。

**`env.sh` の末尾に上書きを追記しないこと。** 2 通りの書き方が、
どちらも逆向きに静かに壊れる。理由は `env.example.sh` の冒頭コメントにある。
dsv4 では実際にこれで sweep を 2 回無駄にしている。

### llama.cpp を入れる

Gated DeltaNet ハイブリッドのオペレータが要る。**ディストリのパッケージが
古いと、モデルのロード自体ができない。**

```bash
# CUDA ビルド
git clone https://github.com/ggml-org/llama.cpp
cd llama.cpp
cmake -B build -DGGML_CUDA=ON -DCMAKE_CUDA_ARCHITECTURES=120
cmake --build build --config Release -j
export PATH="$PWD/build/bin:$PATH"
```

`-DCMAKE_CUDA_ARCHITECTURES=120` が sm_120（Blackwell）。
省くとビルドは通るがカーネルが最適でない、あるいは動かない。

### ツールチェイン

ベンチは実際に 4 言語のプロジェクトをビルドする。**足りないと
エラーではなく偽の 0/N が出る。** `00_preflight.sh` がここを見る。

```bash
# go / cargo / scala-cli / java / python3 がすべて要る
```

dsv4 では `python-fastapi-rest` の `verify.sh` が存在しない Python を
指していたせいで**偽の 0/5** が出た。ハーネスの既定値を疑うこと。

## 3. 重みを取る

```bash
./01_download_model.sh    # 17.11 GB
```

量子化を変えるなら `GGUF_FILE` を渡す:

```bash
GGUF_FILE=Qwen3.8-27B-UD-Q4_K_XL.gguf ./01_download_model.sh
```

**ただし基準の計測は `Q4_K_M` で取ること。** cab の Qwen3.6-27B と
量子化を揃えるためで、品質の話ではない。他の量子化は基準を取り切った後。

## 4. 起動

```bash
./02_serve_llamacpp.sh
```

使ったフラグを全部標準出力に出すので、**その出力をレポートに貼る**。
フラグの無い数字は再現できない。

### thinking の 3 設定

このリポジトリの主眼。サーバ起動時に決まる。

```bash
REASONING=on  REASONING_BUDGET=-1   ./02_serve_llamacpp.sh   # フル思考
REASONING=on  REASONING_BUDGET=2048 ./02_serve_llamacpp.sh   # 思考を絞る
REASONING=off                       ./02_serve_llamacpp.sh   # instruct
```

**`--reasoning-format deepseek` は外せない。** 思考を
`message.reasoning_content` に振り分けるフラグで、既定のままだと思考が
`message.content` に混ざる。すると `run_coding_task.py` が思考テキストから
`### FILE:` を探し、**全タスクが落ちる**。エラーは出ないのでモデルのせいに見える。
`env.example.sh` が既定で `deepseek` にしてある。

### コンテキスト（M1、未計測）

64 層のうちフルアテンションは 16 層だけ
（`16 × (3 × GatedDeltaNet → 1 × GatedAttention)`）。KV cache は通常の 27B より
かなり軽いはずで、32GB 1 枚で 131072 は載る見込み。**見込みであって測定値ではない。**

```bash
for C in 32768 65536 131072 262144; do
  CTX=$C ./02_serve_llamacpp.sh
done
```

出た上限を `env.sh` の `CTX` と `opencode/opencode.json` の
`limit.context` の**両方**に入れる。片方だけ直すと、OpenCode が履歴を切らずに
投げてサーバ側で 400 になる。

### 並列（M2 用）

`N_PARALLEL` は既定 1。**concurrency > 1 を測るなら上げて立て直すこと。**
`--parallel 1` のままだとリクエストが待ち行列に並び、合計 tok/s が単発値のまま
横ばいになる。それがスケーリングの壁に見える。

## 5. 疎通確認

```bash
./03_smoke.sh    # 別シェルから
```

4 項目すべて通ってから先へ進む。

| 項目 | 落ちたときの意味 |
|---|---|
| `/v1/models` | サーバが上がっていない |
| 単発生成 | ロードは通ったがテンプレート周りが怪しい |
| **thinking** | `reasoning_chars = 0` → `REASONING=off` か `--reasoning-format` が違う |
| **tool call** | `tool_calls: NONE` → `--jinja` が無い。OpenCode が動かない |

**モデルを疑う前にここを通す。** dsv4 では「Q2 量子化で壊れた」と見えた事象の
真因が、モデルの出力形式を読めないパーサだった。生の API が正常なことを
確かめてから、ハーネスの結果を解釈する。

## 6. OpenCode を繋ぐ

[`opencode/README.md`](../opencode/README.ja.md) を参照。要点だけ:

```bash
# 手元から繋ぐなら、エンドポイントを公開せず SSH で閉じる
ssh -N -L 8000:127.0.0.1:8000 <host>
export LLAMA_API_KEY=dummy
```

`opencode/opencode.json.example` を
`~/.config/opencode/opencode.json` にコピーして `limit.context` を M1 の実測値に。

## 7. 片付け

**ホストを落とす前に `$BENCH_OUT` を退避すること。**
dsv4 の 2026-08-02 の生成物は pod と共に消えて、レポートの表を実行時の出力から
書き起こす羽目になった。

```bash
tar czf results-$(date +%Y-%m-%d).tgz -C "$BENCH_OUT" .
# 手元に scp してから terminate する
```
