# sasq — 実験: 融合型 SAS→Parquet コンバータ(Rust)

`sas7bdat`クレートのリーダーとparquet-rsの並列エンコードを直結したプロトタイプ。
詳しい経緯・学び・続きの作業は リポジトリ直下の `HANDOFF.md` を参照。

## 現状の実測(1.0GB / 270万行×43列 / 4コア / warmキャッシュ)

| 指標 | 値 |
|---|---|
| 変換時間 | **3.1〜3.4秒** |
| ピークRSS | **338MB**(行グループ単位で有界) |
| 500MB cgroup制限下の1GB変換 | ✅ 成功 |
| 出力データ | polarsエンジンと完全一致を確認済み |

位置づけ: **「メモリ有界」クラスの最速**(sas7 CLI 6.8秒の2倍強、pyreadstat 26秒の8倍)。
ただしメモリを気にしない速度勝負では tuned polars(1.05秒)に届いていない。

## ビルドと実行

```bash
cd experiments/sasq
cargo build --release
./target/release/sasq in.sas7bdat out.parquet [rg_rows=262144] [zstd_level=1]

# デバッグ計測
SASQ_DEBUG=1       # リーダースレッドの時間とバッチ統計を表示
SASQ_RAW_ONLY=1    # ページ走査のみ(デコードなし)の時間を計測
SASQ_DECODE_ONLY=1 # デコードまで(エンコードなし)の時間を計測
```

## アーキテクチャ

```
[reader thread]                [encoder pool ×Ncore]        [writer thread]
SASページ走査                   parquet列エンコード           行グループを
→ 行方向1パスでArrow配列化  →   + zstd圧縮(並列)       →    元の順序で追記
   (bounded channel)              (bounded channel)          (BTreeMapで並べ直し)
```

## 既知の制約・次の一手

- ボトルネックは**リーダースレッド(約2秒)**。クレートの公開APIの制約で
  セル単位アクセス(`iter_*_range(row,1)`)をしており、ここが遅い。
- 文字列は `iter_strings` 経由(エンコーディング処理はクレート任せ)。
- Date/DateTime/Time は SAS epoch(1960-01-01)から Date32/Timestamp(µs)/Time64(µs) に変換。
- 高速化の残り筋: (1) 行ストライプ並列(スレッドごとに SasReader::open して
  行範囲分担、推定 wall 1秒前後)、(2) クレートへ「行の生バイト公開API」を
  上流PRして帯域最適なデコードを書く。詳細は HANDOFF.md。
