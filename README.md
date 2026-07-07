# sas2parquet — sas7bdat を高速・省メモリで Parquet に変換する

SAS の `.sas7bdat` ファイルを、**高速** かつ **メモリセーフ**(RAM より大きいファイルでも OK)に Parquet へ変換するツールです。

## TL;DR — ベストな方法

**第一候補: [polars-readstat](https://github.com/jrothbaum/polars_readstat)**(Rust 製リーダー + Polars の streaming sink)

```python
from polars_readstat import scan_readstat

scan_readstat("data.sas7bdat").sink_parquet("data.parquet", compression="zstd")
```

これだけで:

- **速い** — Rust 実装でマルチスレッド読み込み。pyreadstat 比で数倍、圧縮あり・列数の多い実データでは pandas 比でさらに大きな差になる(公式ベンチでは特にフィルタ・列選択を伴う読み込みで顕著)
- **メモリセーフ** — `scan_readstat`(遅延スキャン)→ `sink_parquet` はバッチ単位のストリーミング処理なので、ファイル全体を一度もメモリに載せない。RAM を超えるサイズの sas7bdat でも変換できる
- ついでに `.filter()` / `.select()` を挟めば、変換前に列や行を絞ることも可能(pushdown が効く)

**第二候補(フォールバック): [pyreadstat](https://github.com/Roche/pyreadstat) のチャンク読み + pyarrow の逐次書き込み**

pyreadstat は C 製の [ReadStat](https://github.com/WizardMac/ReadStat) ラッパーで、SAS ファイルの方言・エンコーディング対応の実績が最も長いライブラリです。Rust リーダーで読めない特殊なファイル(古い SAS バージョン、特殊圧縮、稀なエンコーディング)への保険として使います。`read_file_in_chunks` でチャンクごとに読み、`pyarrow.ParquetWriter` に逐次追記するのでこちらもメモリセーフです。

本リポジトリの `sas2parquet` は、この2つを **`--engine auto`(polars で試して失敗したら pyreadstat に自動フォールバック)** として実装した CLI / ライブラリです。

## 選択肢の比較

| 方法 | 速度 | メモリ安全性 | 備考 |
|---|---|---|---|
| **polars-readstat** (`scan_readstat` → `sink_parquet`) | ◎ Rust・並列 | ◎ ストリーミング | 本命。Polars エコシステムに直結 |
| **pyreadstat** (`read_file_in_chunks` + ParquetWriter) | ○ C 実装 | ◎ チャンク処理 | 互換性最強。フォールバックに最適 |
| pyreadstat `read_file_multiprocessing` | ◎ 並列 | △ 全行をメモリに保持 | 速いがメモリセーフではない |
| pandas `read_sas` | △ 単純なファイルは速いが、圧縮・ワイドなファイルで急減速 | × 一括読み込み(`chunksize` 指定でチャンク化は可能) | 依存を増やしたくない場合のみ |
| [sas7bdat](https://pypi.org/project/sas7bdat/) (PyPI) | × 純 Python・メンテ停止 | ○ 行イテレータ | 非推奨 |
| Rust CLI([sas7bdat crate](https://crates.io/crates/sas7bdat) の `sas7` など) | ◎ | ◎ | Python 不要な環境ならあり |
| R: haven + [parquetize](https://ddotta.github.io/parquetize/)(`max_rows` 指定) | ○ | ○ | R ユーザー向け |
| Spark ([spark-sas7bdat](https://github.com/saurfang/spark-sas7bdat)) | ○(分散) | ◎ | クラスタがあるなら。単機では過剰 |

このリポジトリの手元ベンチ(20万行 × 3列、約 10MB、コンテナ環境)では polars エンジン **0.07 秒**、pyreadstat エンジン **0.32 秒** でした。列数が多い実データではもっと差が開きます。

## インストール

```bash
uv pip install -e .          # または pip install -e .
```

## 使い方

```bash
# 1ファイル変換(隣に data.parquet ができる)
sas2parquet data.sas7bdat

# 出力先とエンジンを指定
sas2parquet data.sas7bdat -o out/data.parquet --engine polars

# ディレクトリを再帰変換(構造を保ったまま out/ に出力)
sas2parquet ./sas_data -o ./out

# 小さいファイルが大量にあるならプロセス並列で
sas2parquet ./sas_data -o ./out --workers 8

# 巨大ファイル1本なら workers は 1 のまま(polars が内部で全コアを使う)
sas2parquet ./huge.sas7bdat --threads 16
```

Python から:

```python
from sas2parquet import convert_file

result = convert_file("data.sas7bdat", "data.parquet")  # engine="auto"
print(result.rows, result.engine_used, result.seconds)
```

## SAS メタデータの保全

Parquet には SAS の「変数ラベル」「フォーマット」を入れる標準の場所がないため、変換時に `pyreadstat` でヘッダーだけ読み(`metadataonly=True`、一瞬で終わる)、Parquet の key-value メタデータ `sas7bdat_metadata` に JSON で埋め込みます:

```python
import json, pyarrow.parquet as pq
meta = json.loads(pq.ParquetFile("data.parquet").metadata.metadata[b"sas7bdat_metadata"])
print(meta["column_labels"])   # {'VALUE': 'Measured value', ...}
```

## チューニングの目安

- **圧縮**: デフォルトは `zstd`(サイズと速度のバランスが最良)。読み込み最優先なら `--compression snappy` / `lz4`
- **`--chunk-rows`**(pyreadstat エンジン): 既定 10 万行。列数が数百あるファイルではメモリピークを抑えるために 1〜5 万に下げる
- **並列の掛け方**: 「巨大ファイル1本 → polars のスレッド並列(`--threads`)」「小さいファイル多数 → `--workers` でファイル単位のプロセス並列」。両方同時に上げると CPU を取り合うだけなので注意
- **文字コード**: 日本語 SAS データ(SJIS 系)で文字化けする場合は、pyreadstat エンジンに `encoding` を渡す拡張が容易(`pyreadstat.read_sas7bdat(..., encoding="cp932")`)

## テスト

SAS 本体なしでテストできるよう、ReadStat の実験的 sas7bdat ライターを ctypes で直接呼び出してフィクスチャを生成しています(`tests/fixture_writer.py`)。

```bash
uv pip install -e '.[dev]'
pytest
```
