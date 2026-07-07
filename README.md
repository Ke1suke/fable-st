# sas2parquet — sas7bdat を高速・省メモリで Parquet に変換する

SAS の `.sas7bdat` ファイルを、**高速** かつ **メモリセーフ** に Parquet へ変換するツールです。単一のライブラリを勧めるのではなく、**実測に基づいて3つのエンジンを使い分ける**設計になっています。

## TL;DR — 実測して分かった「本当のベスト」

1.0GB(270万行×43列)の sas7bdat をこのリポジトリで実測した結果:

| エンジン | 変換時間 | ピークメモリ | 500MB制限下(cgroup)で1GBを変換 |
|---|---:|---:|:---:|
| **polars-readstat**(Rust, 遅延スキャン→sink) | **2〜4秒** | 約1.06GB(≒ファイルサイズ) | ❌ **OOM killed** |
| **`sas7` CLI**(純Rust) | 6.8秒 | **64MB** | ✅ 成功 |
| **pyreadstat チャンク読み**(C) | 26秒 | 313MB(サイズ非依存) | ✅ 成功 |
| pandas `read_sas`(参考: 全件ロード) | 7.8秒 | 1.23GB(サイズ比例) | — |

つまり:

- **「速さ」のベスト**は polars-readstat。ただし俗説と違い、`sink_parquet` でストリーミング書き込みしても**リーダー側がファイル全体相当をメモリに保持する**ため、「RAM より大きいファイルでも OK」は誤り(上表のとおり実際に OOM します)
- **「メモリセーフ」のベスト**は純Rustの [`sas7` CLI](https://crates.io/crates/sas7bdat)。1GB を**ピーク64MB**で変換でき、速度もpolarsに近い。真の意味で RAM を超えるファイルに耐えるのはこれ
- **「互換性」のベスト**は [pyreadstat](https://github.com/Roche/pyreadstat)(C製 [ReadStat](https://github.com/WizardMac/ReadStat))。遅いがメモリ有界で、古いSASファイル・特殊エンコーディングの実績が最長

本ツールの `--engine auto` は **ファイルサイズと空きRAMを比較して自動選択**します: RAMに余裕があれば polars(最速)、大きすぎるファイルは sas7 CLI(未導入なら pyreadstat)へ。どのエンジンが失敗しても次の候補に自動フォールバックします。3エンジンの出力データが一致することはテストで検証済みです。

## 見落とされがちな2つの正しさの罠(今回の深掘りで発見)

### 1. polars-readstat のデフォルトは行順序を保証しない

`scan_readstat` のデフォルト `preserve_order=False` は「スループット優先でバッチ順序の保証なし」。マルチスレッド読みでは**実際に行順が入れ替わります**(手元で再現済み)。SAS データセットは順序に意味があることが多いので、本ツールは **`preserve_order=True` をデフォルト**にし、順序不要なら `--no-preserve-order` で約1.5倍のスループットを選べるようにしています。

### 2. SAS の特殊欠損値(.A〜.Z, ._)は普通に変換すると消える

どの方法でも特殊欠損値はただの null に潰れ、「欠損の理由」の情報が失われます。polars-readstat の informative nulls 機能を `--informative-nulls` で公開しており、`VALUE_null` のようなインジケータ列として保全できます。

## インストール・使い方

```bash
uv pip install -e .                                  # Python エンジン2種
cargo install sas7bdat --features cli,parquet        # 任意: sas7 エンジン(推奨)
```

```bash
sas2parquet data.sas7bdat                        # auto: サイズとRAMを見て自動選択
sas2parquet huge.sas7bdat --engine sas7          # 巨大ファイルを省メモリで
sas2parquet data.sas7bdat --engine polars        # 速度最優先(RAMに載る場合)
sas2parquet ./sas_data -o ./out --workers 8      # ディレクトリ再帰 + プロセス並列
sas2parquet data.sas7bdat --no-preserve-order    # 行順不問で最速
sas2parquet data.sas7bdat --engine polars --informative-nulls  # 特殊欠損値を保全
```

Python から:

```python
from sas2parquet import convert_file

r = convert_file("data.sas7bdat", "data.parquet")   # engine="auto"
print(r.rows, r.engine_used, r.seconds)
```

## 選択肢の全体比較

| 方法 | 速度 | メモリ | 備考 |
|---|---|---|---|
| **polars-readstat** | ◎ 最速 | △ ≒ファイルサイズ | 変換前の filter/select の pushdown が効く |
| **`sas7` CLI**(純Rust) | ◎ | ◎ 64MB固定級 | Python不要。ラベル埋め込み不可・`--compression` も効かず CLI 既定の圧縮になる |
| **pyreadstat チャンク** | ○ | ◎ 有界(~300MB) | 互換性最強。最後の砦 |
| pandas `read_sas` | △ ファイル依存 | × 全件ロード | 単純な非圧縮ファイルなら意外と速いが順不同に遅くなる |
| DuckDB [read_stat 拡張](https://duckdb.org/community_extensions/extensions/read_stat) | × 大規模で実用外(公式Discussion評) | ○ | `FROM read_stat('x.sas7bdat')` は手軽。小データ向け |
| [sas7bdat](https://pypi.org/project/sas7bdat/) (PyPI) | × メンテ停止 | ○ | 非推奨 |
| R: haven + [parquetize](https://ddotta.github.io/parquetize/) | ○ | ○ `max_rows`指定 | Rユーザー向け |
| Spark ([spark-sas7bdat](https://github.com/saurfang/spark-sas7bdat)) | ○ 分散 | ◎ | クラスタ前提。単機では過剰 |

補足の実測(300k行×43列):

- RLE圧縮(86MB): polars 0.8s / sas7 0.9s / pyreadstat 3.1s / pandas 1.7s
- 非圧縮(112MB): polars 1.2〜1.8s / sas7 0.8s / pyreadstat 3.1s / pandas 1.2s
- pyreadstat の「pandas を介さず dict→arrow」も試したが、**pandas 経由より30%遅くメモリ1.7倍**だったため不採用(pyreadstat の dict 出力は object 配列のため)

## そもそも変換しない、という選択肢

一度しか読まないデータなら、変換せずにその場でクエリするほうが速いこともあります:

```python
from polars_readstat import scan_readstat

# 必要な列・行だけ読む(pushdown が効くので全変換より速い)
df = scan_readstat("data.sas7bdat").filter(pl.col("AGE") > 40).select("ID", "AGE").collect()
```

繰り返し読むデータ・チームで共有するデータは Parquet 化が正解です(zstd で元の1/10〜1/25になり、以後の読み込みはミリ秒単位)。

## SAS メタデータの保全

Parquet には SAS の変数ラベル・フォーマットの標準置き場がないため、polars / pyreadstat エンジンでは Parquet フッターの key-value メタデータ `sas7bdat_metadata` に JSON で埋め込みます(sas7 エンジンは対象外):

```python
import json, pyarrow.parquet as pq
meta = json.loads(pq.ParquetFile("data.parquet").metadata.metadata[b"sas7bdat_metadata"])
print(meta["column_labels"])   # {'VALUE': 'Measured value', ...}
```

## チューニングの目安

- **圧縮**: 既定 `zstd`(サイズ/速度バランス最良)。読み込み最優先なら `snappy` / `lz4`
- **並列の掛け方**: 巨大ファイル1本 → polars のスレッド並列(`--threads`)。小ファイル多数 → `--workers` のプロセス並列。両方同時に上げると CPU の取り合いになるだけ
- **`--chunk-rows`**(pyreadstat): 既定10万行。列数が数百のファイルはメモリピーク抑制に1〜5万へ
- **日本語 SAS データ**(SJIS系)で文字化けする場合は pyreadstat エンジンに `encoding="cp932"` を渡す拡張が容易

## テスト

SAS 本体なしでテストできるよう、ReadStat の実験的 sas7bdat ライターを ctypes で直接呼び出してフィクスチャを生成します(`tests/fixture_writer.py`)。RLE圧縮ファイルの生成やワイドファイルのベンチマークにも同じ仕組みを使っています。

```bash
uv pip install -e '.[dev]'
pytest
```

検証内容: 3エンジンの出力一致 / 行順序(マルチバッチ強制) / 欠損値 / ラベルのメタデータ埋め込み / CLI ディレクトリモード。
