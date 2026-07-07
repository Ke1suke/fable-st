# 引き継ぎ指示書 — sas7bdat→Parquet 高速変換プロジェクト

> 前任セッション(Fable 5)から Sonnet 5 への引き継ぎ文書。2026-07-07 作成。
> ユーザーの目的: **ローカルにある sas7bdat を高速・メモリセーフに Parquet 化する**。

## 0. まず読むべきもの

1. この文書(全体方針とハマりポイント)
2. `README.md`(ユーザー向けの結論と使い方)
3. `experiments/sasq/README.md`(Rust実験の現状)

**注意: 前セッションの作業環境(venv・ベンチ用フィクスチャ・cargoビルド)はコンテナごと消えている。** §5 の手順で再構築すること。リポジトリに残っているものだけが真実。

## 1. 現在地 — 何がどこまで終わっているか

`src/sas2parquet/` に3エンジン構成の変換ツールが完成・テスト済み(11テスト全合格):

- **polars** エンジン: polars-readstat の遅延スキャン→`sink_parquet`。zstdレベル1デフォルト適用済み。最速(1GB≈1.05〜1.2秒)だが**リーダーがファイル全体相当をメモリに載せる**(1GBファイルで RSS≈1GB、500MB cgroup で OOM 確認済み)
- **sas7** エンジン: 純Rust `sas7` CLI へのサブプロセス委譲。1GB を 6.8秒・RSS 64MB
- **pyreadstat** エンジン: C製ReadStatのチャンク読み+pyarrow逐次書き込み。26秒・RSS 313MB(サイズ非依存)。互換性の最後の砦
- `--engine auto`: ファイルサイズ vs 空きRAM(`POLARS_RAM_SHARE=0.4`)で自動選択、失敗時は次候補へフォールバック
- 正しさ対応済み: 行順序保証(`preserve_order=True`デフォルト)、SAS特殊欠損値(`--informative-nulls`)、ラベルのKVメタデータ埋め込み

`experiments/sasq/` に実験中のRust融合コンバータ(§4)。

### 確定ベンチマーク(1.0GB / 270万行×43列 / 4コア15GB / warmキャッシュ)

| 方式 | 時間 | ピークRSS | 500MB cgroupで1GB |
|---|---:|---:|:---:|
| polars (zstd lvl1, stats on) | 1.05〜1.2s | ≈1.06GB | ❌ OOM |
| **sasq(実験)** | 3.1s | 338MB | ✅ |
| sas7 CLI | 6.8s | 64MB | ✅ |
| pyreadstat chunked | 26s | 313MB | ✅ |
| pandas.read_sas | 7.8s | 1.23GB | 未測 |

時間内訳(polars): 読みだけ 0.3s / zstd(3) 1.64s→zstd(1) 1.20s→+stats off 1.05s。
コールドI/O: この環境のディスクは 1GB 読むのに 29秒(≈35MB/s)。**遅いディスクでは変換最適化より I/O が支配的**。ベンチは必ず warm/cold を区別すること(§6-9)。

## 2. 一番効くポイント(優先順)

**P0 — 実データでの検証。** ここまでの数字は全部「合成フィクスチャ」(doubles中心・ASCII文字列・非圧縮 or RLE)。ユーザーの実ファイルでは (a) 文字列比率が高い、(b) COMPRESS=CHAR(RDC圧縮)、(c) 日本語エンコーディング(cp932系)の可能性があり、エンジン間の勝敗が変わり得る。ユーザーに実ファイル(またはその特性: サイズ・列数・型構成・PROC CONTENTSの出力)をもらうのが最大のレバー。

**P1 — 日本語エンコーディング対応。** ユーザーは日本語話者。SJIS系SASファイルで pyreadstat エンジンに `encoding="cp932"` を渡すオプション(`--encoding`)は未実装。polars-readstat / sas7 CLI が日本語エンコーディングをどう扱うかも未検証。文字化けはデータ破壊なので優先度高。

**P2 — sasq の続き(§4)。** 「メモリ有界クラス最速」は取れた。残る野心は 1秒切り(=全クラス最速)だが、行ストライプ並列の実装が必要。費用対効果は薄め — ユーザーが「やってみて」と言った経緯があるので、P0/P1 が済んでから。

**P3 — README の更新。** zstdレベル1デフォルト化・sasq の結果・コールドI/Oの知見が README に未反映(HANDOFF優先で時間切れ)。§1 の表を反映するだけで良い。

**やらないこと(検証済みの袋小路):** pyreadstat の dict→arrow 経路(pandas経由より30%遅い)、DuckDB read_stat拡張(大規模で実用外)、polarsの型ダウンキャスト`compress=True`のデフォルト化(3倍遅い)、RLIMIT_ASでのメモリ制限テスト(jemallocと衝突して無意味)。

## 3. リポジトリ構成

```
src/sas2parquet/convert.py   # 3エンジン + auto選択。全ロジックここ
src/sas2parquet/cli.py       # argparse CLI(convert.pyの薄いラッパ)
tests/fixture_writer.py      # ★SAS無しでsas7bdatを生成する仕掛け(§6-1)
tests/test_convert.py        # 11テスト。エンジン間出力一致が肝
experiments/sasq/            # Rust融合コンバータ実験
HANDOFF.md                   # 本書
```

ブランチ: `claude/sas7dbat-conversion-g1iydv` で開発し、同ブランチに push する。

## 4. sasq(Rust実験)の技術メモ

### 設計
reader(1スレッド: SASページ走査→Arrow配列化) → bounded channel → encoder×Ncore(parquet列エンコード+zstd並列) → writer(BTreeMapで元順に行グループ追記)。

### これまでの学び(重要、同じ穴に落ちないこと)
1. **列方向イテレーションはメモリ帯域で死ぬ。** SASは行指向。43列を列ごとに `iter_numeric_bits()` で走査すると 900MB×43回=39GB のトラフィックでリーダーが5.6秒に。**行方向1パス**(行ループ内で全列のビルダーに追記)に直して2.0秒。
2. **`sas7bdat`クレート(v0.2.0)の公開APIには壁がある。** `MaterializedColumn` はフィールド非公開・アクセサ無しで外部から使えない。行の生バイトも非公開。現状はセル単位 `iter_numeric_bits_range(row,1)` / `iter_strings_range(row,1)` で凌いでおり、これがリーダー2秒の主因。
3. デコード仕様(必要なら自前実装可、MIT): 数値はwidth≤8の切詰めdouble。LE なら slice を反転して先頭詰め→`u64::from_be_bytes`。欠損は NaN パターン(exp全1かつ仮数≠0)。SAS epoch は 1960-01-01(日数オフセット3653日、秒オフセット315,619,200)。
4. Date→Date32 / DateTime→Timestamp(µs) / Time→Time64(µs)(クレートのParquetSinkと同じマッピング)。
5. parquet-rs の並列エンコードは `get_column_writers` + `compute_leaves` + `ArrowColumnChunk::append_to_row_group`(parquet 57系で動作確認済み)。

### 1秒切りを狙う場合の設計案
スレッドごとに `SasReader::open`(ヘッダパースは安価)して行範囲を分担。skip は生バッチ走査(デコード無しなら全ファイル0.63秒)で到達。各スレッドが自分のストライプを行グループ化→順序付きライターへ。推定 wall 0.8〜1.0秒。
上流PR(行の生バイト公開 or MaterializedColumnアクセサ追加)が通ればもっと素直に書ける。

## 5. 環境の再構築手順

```bash
# Python
uv venv .venv && uv pip install --python .venv/bin/python -e '.[dev]'
.venv/bin/python -m pytest tests/ -q        # 11 passed を確認

# sas7 CLI(sas7エンジン用。--features必須! §6-6)
cargo install sas7bdat --features cli,parquet

# ベンチ用フィクスチャ(SAS不要。§6-1 の仕掛けで生成)
.venv/bin/python -c "
import sys; sys.path.insert(0, 'tests')
from fixture_writer import write_fixture
write_fixture('/tmp/big.sas7bdat', n_rows=2_700_000, n_extra_double_cols=40)  # ≈1.0GB、80秒
write_fixture('/tmp/wide.sas7bdat', n_rows=300_000, n_extra_double_cols=40)   # ≈112MB
"

# sasq
cd experiments/sasq && cargo build --release   # 初回3分
```

## 6. ハマりポイント集(症状→原因→抜け道)

1. **テスト用sas7bdatが作れない/入手できない。** pyreadstat等はsas7bdat書き込み非対応、サンプル配布サイトはネットワークポリシーで403。→ ReadStatの実験的ライターがpyreadstatの.soにシンボルとして残っているのをctypesで直接叩く(`tests/fixture_writer.py` 実装済み)。RLE圧縮版が欲しければ `readstat_writer_set_compression(w, 1)` を挟む(前セッションでmonkey-patchで実証済み)。
2. **polars-readstatの行順序。** `scan_readstat` デフォルト `preserve_order=False` は**本当に順序が崩れる**(マルチバッチ+複数スレッドで再現済み)。ベンチを取るときも本体を書くときも必ず明示。また `preserve_order=True` のまま `select(pl.len())` のような縮退クエリを投げると27秒に劣化する病理があるので、行数確認は書き出したparquet側から取る。
3. **ParquetのKVメタデータの読み場所。** polarsの`sink_parquet(metadata=...)`はフッター(file-level)に書く。`pq.read_schema(f).metadata` では **None** になる。`pq.ParquetFile(f).metadata.metadata` で読む(スキーマ埋め込みのpyarrow経由でも同所で読める)。
4. **メモリ計測の罠2つ。** (a) `RLIMIT_AS` はpolars(jemalloc)の仮想アドレス予約と衝突して即死するので判定に使えない → cgroup v1 (`/sys/fs/cgroup/memory/<name>/memory.limit_in_bytes`) で実メモリ制限して検証する(この環境はv1、root可)。cgroupは他プロセスに消されることがあるので**テスト直前に毎回作り直す**。 (b) `resource.getrusage(RUSAGE_CHILDREN)` は**全子プロセスの累積max** — 複数の子を順に測ると前の子の値が混ざる。子プロセス自身に `RUSAGE_SELF` を出力させるか、計測ごとに親を分ける。
5. **`/usr/bin/time` は無い。** GNU time前提のハーネスは動かない。Pythonの `time.perf_counter` + `resource` で代替。
6. **`cargo install sas7bdat` は素で入れるとCLIが出てこない。** `--features cli,parquet` が必須(前セッションで一敗)。バイナリ名は `sas7`、`~/.cargo/bin/sas7`。圧縮指定フラグは無い。
7. **ネットワークは pypi / crates.io(static含む) / npm のみ通る。** 一般サイトへのcurlはプロキシが403。サンプルデータのダウンロードは諦めてフィクスチャ生成で。
8. **pyreadstatの「最適化」の罠。** `output_format="dict"` はobject配列を返すため、pandas経由より遅い&メモリ食い。fallback経路はpandas経由のままが正解(実測済み、convert.pyのコメント参照)。
9. **ベンチはページキャッシュを意識する。** `echo 3 > /proc/sys/vm/drop_caches`(root)でcold測定可。この環境のディスクはcold 1GB=29秒なので、コールド込みで測るとエンジン差が消える。エンジン比較はwarmで、ユーザー向けの絶対値はcold注記付きで。
10. **jemallocのRSSは実測が正。** polarsのRSS≈ファイルサイズは「sinkがストリーミングだからメモリ有界」という直感を裏切る(リーダー側が保持)。「ストリーミングと書いてあるから安全」を信じず、cgroupで殺してみて判定する。

## 7. ベストプラクティス(このプロジェクトで効いた進め方)

- **最適化は必ず提案→実測→採否。** 前セッションの的中率は5割程度(dict経路は逆効果、行方向1パスは2.8倍)。直感で本体に入れない。
- **正しさはエンジン間クロスチェックで担保。** 新しい経路を足したら「polars/pyreadstat/sas7/sasqの出力が `pl.DataFrame.equals` で一致」テストに組み込む(既存テストの形式に倣う)。
- **ボトルネックの内訳を先に割る。** 「読みだけ」「デコードまで」「フル」の3段計測(sasqの `SASQ_RAW_ONLY` / `SASQ_DECODE_ONLY` はそのために付けた)。
- **メモリ主張はcgroupで証明する。** 「OOMで死んだ/生き残った」が一番説得力のある証拠。
- コミットは「動く単位+実測値をメッセージに」。ユーザーへの報告は結論(数字)→根拠の順。

## 8. ユーザーコンテキスト

- 日本語話者。報告・README・ドキュメントは日本語。
- 「開発コストに見合わなくてもやってみて」と言うタイプ — 挑戦の結果が負けでも、数字と学びを正直に報告すれば価値として受け取ってくれる。過剰に安全側に倒して挑戦を省略しない。
- 用途は**ローカルファイルの変換**。クラウド/S3の話は不要。ローカルでもディスクが遅ければI/O支配になる、という注意だけ添える。
