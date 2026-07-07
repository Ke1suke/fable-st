"""Core conversion logic: .sas7bdat -> .parquet.

Two engines:

- "polars"     polars-readstat (Rust). Lazy scan + sink_parquet so the file is
               streamed in batches and never fully materialized in memory.
               Fastest path; works for files larger than RAM.
- "pyreadstat" pyreadstat (ReadStat C library) read in chunks, each chunk
               appended to the Parquet file via pyarrow.ParquetWriter.
               Slower, but ReadStat has the longest track record with odd
               encodings and exotic sas7bdat variants, so it is the fallback.

"auto" tries polars first and falls back to pyreadstat on any read error.
"""

from __future__ import annotations

import json
import time
from dataclasses import dataclass
from pathlib import Path

import pyarrow as pa
import pyarrow.parquet as pq
import pyreadstat

DEFAULT_CHUNK_ROWS = 100_000

Engine = str  # "auto" | "polars" | "pyreadstat"


@dataclass
class ConversionResult:
    source: Path
    dest: Path
    engine_used: str
    rows: int
    seconds: float
    source_bytes: int
    dest_bytes: int


def read_sas_metadata(src: Path) -> dict:
    """Read only the header of a sas7bdat (no rows) and return label info.

    Column labels and value-format names have no native slot in Parquet, so we
    embed them as key-value metadata to avoid losing them in the conversion.
    """
    _, meta = pyreadstat.read_sas7bdat(str(src), metadataonly=True)
    return {
        "source_file": src.name,
        "file_encoding": meta.file_encoding,
        "number_rows": meta.number_rows,
        "column_labels": meta.column_names_to_labels,
        "variable_formats": meta.original_variable_types,
    }


def _kv_metadata(src: Path) -> dict[str, str]:
    try:
        return {"sas7bdat_metadata": json.dumps(read_sas_metadata(src), ensure_ascii=False)}
    except Exception:
        # Metadata embedding is best-effort; never fail the conversion for it.
        return {}


def _convert_polars(
    src: Path,
    dst: Path,
    *,
    compression: str,
    threads: int | None,
    row_group_size: int,
) -> int:
    import polars as pl
    from polars_readstat import scan_readstat

    lf = scan_readstat(str(src), threads=threads)
    lf.sink_parquet(
        str(dst),
        compression=compression,
        row_group_size=row_group_size,
        metadata=_kv_metadata(src),
    )
    return pl.scan_parquet(str(dst)).select(pl.len()).collect().item()


def _convert_pyreadstat(
    src: Path,
    dst: Path,
    *,
    compression: str,
    chunk_rows: int,
    row_group_size: int,
) -> int:
    writer: pq.ParquetWriter | None = None
    rows = 0
    try:
        for df, _meta in pyreadstat.read_file_in_chunks(
            pyreadstat.read_sas7bdat, str(src), chunksize=chunk_rows
        ):
            table = pa.Table.from_pandas(df, preserve_index=False)
            if writer is None:
                schema = table.schema.with_metadata(_kv_metadata(src))
                writer = pq.ParquetWriter(str(dst), schema, compression=compression)
                table = table.cast(pa.schema(table.schema, metadata=schema.metadata))
            writer.write_table(table, row_group_size=row_group_size)
            rows += len(df)
    finally:
        if writer is not None:
            writer.close()
    return rows


def convert_file(
    src: Path | str,
    dst: Path | str,
    *,
    engine: Engine = "auto",
    compression: str = "zstd",
    chunk_rows: int = DEFAULT_CHUNK_ROWS,
    threads: int | None = None,
    row_group_size: int = 512 * 1024,
) -> ConversionResult:
    """Convert one .sas7bdat file to Parquet. Returns stats about the run."""
    src, dst = Path(src), Path(dst)
    if engine not in ("auto", "polars", "pyreadstat"):
        raise ValueError(f"unknown engine: {engine!r}")
    dst.parent.mkdir(parents=True, exist_ok=True)

    t0 = time.perf_counter()
    if engine in ("auto", "polars"):
        try:
            rows = _convert_polars(
                src, dst, compression=compression, threads=threads, row_group_size=row_group_size
            )
            used = "polars"
        except Exception:
            if engine == "polars":
                raise
            rows = _convert_pyreadstat(
                src, dst, compression=compression, chunk_rows=chunk_rows,
                row_group_size=row_group_size,
            )
            used = "pyreadstat (fallback)"
    else:
        rows = _convert_pyreadstat(
            src, dst, compression=compression, chunk_rows=chunk_rows,
            row_group_size=row_group_size,
        )
        used = "pyreadstat"

    return ConversionResult(
        source=src,
        dest=dst,
        engine_used=used,
        rows=rows,
        seconds=time.perf_counter() - t0,
        source_bytes=src.stat().st_size,
        dest_bytes=dst.stat().st_size,
    )
