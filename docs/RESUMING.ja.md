# セッション再開手順

[English](RESUMING.md) | **日本語**

**現状: 未計測。** リポジトリの骨組みだけがある状態で、RTX 5090 にはまだ
触れていない。`serving/` の 4 本も**未検証**（deepseek-v4-flash-bench の
vLLM 版から llama.cpp 向けに書き直したもので、実機で通したことはない）。
M0 から始める。

## 0. 最初に読むもの

| ドキュメント | 内容 |
|---|---|
| [`README.md`](../README.ja.md) | 何を測るか、比較先の既存数値、計測の作法 |
| [`docs/SETUP.md`](SETUP.ja.md) | ホスト準備から OpenCode 接続までの手順 |
| [`opencode/README.md`](../opencode/README.ja.md) | OpenCode 側で何を測るか |
| [deepseek-v4-flash-bench の M4 レポート](https://github.com/wonder-soft/deepseek-v4-flash-bench/blob/main/docs/reports/2026-08-02-m4-coding-quality-vs-qwen3.6-27b.ja.md) | **§7 がこのリポジトリの出発点。** 比較先の全数値もここ |
| [letusfly85/coding-agent-bench](https://github.com/letusfly85/coding-agent-bench) | タスクと評価軸の出どころ |

## 1. 現在の到達点

| フェーズ | 状態 |
|---|---|
| 機材選定 | **完了**。RTX 5090 32GB ×1。cab の Qwen3.6-27B と同一クラスに揃えるため |
| 量子化の選定 | **完了**。`Q4_K_M`（17.11 GB）。cab と揃える。理由は README |
| `bench/tasks/` | **cab から無改変で持ち込み済み。触らないこと** |
| `bench/scripts/` | cab / dsv4 から持ち込み。モデル名と repo パスは書き換え済み。**未検証** |
| `serving/` 00〜03 | **未検証**。llama.cpp 向けに新規作成 |
| `bench/scripts/thinking_sweep.sh` | **未検証**。このリポジトリの主眼 |
| `bench/scripts/bench_throughput.py` | **未検証**。`vllm bench serve` 依存を外して新規作成 |
| M0〜M5 | **すべて未着手** |

## 2. 次にやること（この順で）

### M0. 起動を通す

```bash
# llama.cpp は Gated DeltaNet の新しいオペレータが要る。
# ディストリのパッケージが古いなら master からビルドする。
cd serving
cp env.example.sh env.sh     # gitignore 済み。環境固有の値はこちらに
./00_preflight.sh            # ここが赤いまま先に進まない
./01_download_model.sh       # 17.11 GB
./02_serve_llamacpp.sh
./03_smoke.sh                # 別シェルから
```

**`03_smoke.sh` の 4 項目すべてを通してから先へ進む。** 特に後半 2 つ:

- **thinking**: `reasoning_chars` が 0 より大きいこと。0 なら
  `REASONING=off` になっているか、`--reasoning-format` が `deepseek` でなく
  思考が `message.content` に混ざっている。後者だと
  `run_coding_task.py` が思考テキストから `### FILE:` を探して**全タスクが落ちる**。
  エラーは出ず、モデルのせいに見える。
- **tool call**: `tool_calls: NONE` なら `--jinja` が付いていない。
  OpenCode が一切動かなくなる。

**未知が集中しているのは llama.cpp のビルドだけ。** 3.8 のアーキ文字列が
手元のビルドに登録されているかは確認していない。`00_preflight.sh` が
フラグの有無までは見るが、モデルが実際にロードできるかは
`02_serve_llamacpp.sh` を叩くまで分からない。落ちたら master からビルドし直す。

### M1. 載る上限を確定する

`ctx_vram_sweep.sh` は vLLM 専用だったので**持ってきていない**。手で振る:

```bash
for C in 32768 65536 131072 262144; do
  CTX=$C ./serving/02_serve_llamacpp.sh   # 起動するか、VRAM がいくつ残るか
done
```

フルアテンションが 64 層中 16 層しかないので、**通常の 27B より深く載るはず**。
これは見込みなので実測すること。出た上限を `serving/env.sh` の `CTX` と
`opencode/opencode.json` の `limit.context` の**両方**に反映する。

### M2. スループットのベースライン

```bash
python3 bench/scripts/bench_throughput.py \
  --model qwen3.8-27b --concurrency 1,2,4,8 --out "$BENCH_OUT/throughput.json"
```

**OpenCode の体感を決めるのは concurrency=1 の行だけ。** 合計 tok/s は
「この箱で何人ホストできるか」の話であって、1 人の待ち時間ではない。

concurrency > 1 を測るなら `N_PARALLEL` を上げてサーバを立て直すこと。
`--parallel 1` のままだとリクエストが待ち行列に並び、合計 tok/s が単発値のまま
横ばいになる。**それがスケーリングの壁に見える。**

### M3. コーディング性能（cab / dsv4 と同条件）

```bash
export BENCH_REPO=/root/qwen3.8-27b-bench BENCH_OUT=/root/results
export PATH=/usr/local/go/bin:$HOME/.cargo/bin:$PATH

N=5 TEMP=0.6 TOP_P=0.95 TOP_K=20 MAX_TOKENS=24000 bash bench/scripts/run_repeat.sh
python3 bench/scripts/tool_call_fidelity.py --model qwen3.8-27b --out "$BENCH_OUT/tool_call.json"
python3 bench/scripts/agent_loop.py --model qwen3.8-27b \
  --task-dir bench/tasks/agent-fix-bug/project \
  --work-root "$BENCH_OUT/agent/fix-bug" --out "$BENCH_OUT/agent_loop_fixbug.json" \
  --episodes 13 --max-turns 30 --pytest-bin "$(command -v python3)"
```

**計測前に `cargo` と `scala-cli` を暖機すること。** 初回実行は依存の
ダウンロードが走るため、1 回目のサンプルだけが不当に遅くなり、
タイムアウトで偽の失敗を生む。

**注視するセル**は README の比較表の太字。Qwen3.6 の Rust テスト 0/5 と
Scala 0/5。ここが動けば 3.8 の公称値は本物。

`bench/scripts/run_all.sh` が M2〜M3 をまとめて回す。

### M4. thinking を振る ← **このリポジトリの主眼**

```bash
# think モードでサーバを立てる
REASONING=on REASONING_BUDGET=-1 ./serving/02_serve_llamacpp.sh
MODE=think N=5 bash bench/scripts/thinking_sweep.sh

# サーバを落として instruct で立て直す
REASONING=off ./serving/02_serve_llamacpp.sh
MODE=instruct N=5 bash bench/scripts/thinking_sweep.sh
```

**モードはサーバ起動時のフラグなので、立て直しは省略できない。**
`thinking_sweep.sh` は実行前にライブのサーバを叩いて `reasoning_chars` を確認し、
要求したモードと違えば中断する。この安全弁を外さないこと — 守っているのは
「2 回測って同じ数字が出て、thinking は無意味だったと書いてしまう」という
静かな失敗で、dsv4 の M4 はこれに近いことが起きて §7 の留保になっている。

**完遂率だけで判断しない。** スクリプトが reasoning 文字数・完了トークン・
実時間も出す。「Rust が +1/5 になったが 6 倍のトークンを食った」と
「+1/5 がタダで手に入った」は別の結論。

余裕があれば `REASONING_BUDGET=2048` の中間点も取る。OpenCode の実用ラインは
たぶんここ。

### M5. OpenCode 実運用

[`opencode/README.md`](../opencode/README.ja.md) の手順。
`agent_loop.py` と**同じタスク**で比べて、モデルの限界か OpenCode の
足回りかを切り分ける。thinking の 3 設定すべてで触ること。

## 3. 1 セッションでどこまで進むか

dsv4（157 GiB + vLLM の JIT）と違って、ここは**軽い**。

| | 内容 | 目安 |
|---|---|---:|
| M0 | ホスト準備・17 GB 取得・起動・疎通 | **30 分〜2 時間** |
| M1 | ctx を手で振る（設定ごとに再起動） | 45 分 |
| M2 | スループット | 20 分 |
| M3 | コーディング 4 タスク × n=5 + 検証ビルド + agent loop | 2〜3 時間 |
| M4 | thinking sweep（もう 1 モード分の M3 相当） | 2〜3 時間 |
| M5 | OpenCode 実運用 | 1 時間〜 |

**M0 の幅は llama.cpp のビルド次第。** パッケージ版がそのまま動けば 30 分、
master からビルドが要れば 2 時間見る。重みの取得は 17 GB なので数分。

**半日しか取れないなら M0〜M3 を目標にする。** それで cab / dsv4 と並ぶ列が
1 本埋まる。M4 は次のセッションでよい（サーバの立て直しが要るので、
どのみち区切りが入る）。

## 4. レポートの置き場

`docs/reports/YYYY-MM-DD-<topic>.md`。cab / dsv4 と同じ命名。
測定条件（llama.cpp のバージョン・GGUF ファイル名・`CTX`・`REASONING` と
`REASONING_BUDGET`・`--reasoning-format`・`TEMP`/`TOP_P`/`TOP_K`・n）を
必ず先頭に書く。**書いていない数字は再現できない。**

**ホストを落とす前に `$BENCH_OUT` を退避すること。** dsv4 の 2026-08-02 の
生成物は pod と共に消えて、レポートの表を実行時の出力から書き起こす羽目になった。
2 回目からは git-lfs でコミットする運用にしている。

## 5. 公開範囲と言語

**private。ただし public 前提で書く。** インフラ情報（ホスト名・
エンドポイント URL・トークン）を最初のコミットから混ぜないこと。
`serving/env.sh` は gitignore 済みで、環境固有の値はすべてそこに置く。
`env.example.sh` には環境非依存の既定値しか書かない。

ドキュメントは日英併記。既定のファイル名が英語、`*.ja.md` が日本語。
**片方を直したら同じコミットでもう片方も直すこと。** 古い翻訳は無いより悪い。
コードと食い違っていることが黙って伝わってしまうため。
