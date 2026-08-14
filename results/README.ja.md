# results/

[English](README.md) | **日本語**

ベンチ実行の生成物。

## 何をコミットするか

| | |
|---|---|
| `YYYY-MM-DD-<topic>-results.tgz` | **計測 1 回につきアーカイブ 1 つ。git-lfs 管理** |
| 展開状態の生ログ・ビルド成果物 | **gitignore 対象**。そのままコミットしない |

この方針は deepseek-v4-flash-bench から引き継いでいる。あちらは初回計測の
生成物を pod ごと失い、レポートの表をスクロールバックから書き起こす羽目に
なった。アーカイブは安い。公開した数字の根拠を失うことは安くない。

アーカイブの中身（計測ごと）: モデルの生の応答（`raw/answer.md`・
`raw/reasoning.md`）、実際にビルドされた抽出済みソース、全試行の
`verify.log`、`metrics.json`、実行ログ。**ビルド成果物は除外**
（Rust の `target/` だけで GB 単位になる）。

**thinking モードごとにアーカイブを分けること。** `repeat-think/` と
`repeat-instruct/` を 1 つに混ぜると、後から `reasoning_chars` を数えるまで
どちらがどちらか分からなくなる。

**ホストを落とす前に `$BENCH_OUT` を退避すること。**
このディレクトリの中身は、後からでは復元できない。

| アーカイブ | 対応するレポート |
|---|---|
| *（まだ無い）* | |

コミットする値には必ず測定条件を添えること:

- llama.cpp のバージョン（`llama-server --version`）
- `GGUF_FILE`
- `CTX` / `KV_TYPE_K` / `KV_TYPE_V` / `FLASH_ATTN` / `N_PARALLEL`
- `REASONING` / `REASONING_BUDGET` / `REASONING_FORMAT`
- `TEMP` / `TOP_P` / `TOP_K` / `MAX_TOKENS`
- 試行回数 n

**書いていない数字は再現できない。**
