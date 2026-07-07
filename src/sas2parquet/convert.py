"""Core conversion logic: .sas7bdat -> .parquet.

Three engines (measured on a 1.0GB, 2.7M x 43 file in a 500MB memory cgroup):

- "polars"     polars-readstat (Rust) lazy scan + sink_parquet. Fastest
               (~2-4s/GB), but its reader holds roughly the whole file in
               memory (OOM-killed under the 500MB limit) - use it when the
               file fits comfortably in RAM.
- "sas7"       The pure-Rust `sas7` CLI (cargo install sas7bdat --features
               cli,parquet), spawned as a subprocess. Nearly as fast
               (~7s/GB) with a tiny fixed footprint (64MB peak on 1GB input;
               passed the 500MB cgroup). No Python needed at runtime.
               SAS label metadata is not embedded on this path.
- "pyreadstat" ReadStat C library read in chunks, appended via
               pyarrow.ParquetWriter. Slowest (~26s/GB) but bounded memory
               (~300MB regardless of file size) and the longest compatibility
               track record with odd encodings / sas7bdat variants.

"auto" picks by file size vs available RAM: polars when the file fits,
otherwise sas7 (if installed) then pyreadstat; any failure falls through
to the next candidate.
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import time
from dataclasses import dataclass
from pathlib import Path

import pyarrow as pa
import pyarrow.parquet as pq
import pyreadstat

DEFAULT_CHUNK_ROWS = 100_000
ENGINES = ("polars", "sas7", "pyreadstat")
# In-memory need of the polars reader is roughly the decoded file size; only
# pick it automatically when the file uses at most this share of available RAM.
POLARS_RAM_SHARE = 0.4

Engine = str  # "auto" | "polars" | "sas7" | "pyreadstat"


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
    compression_level: int | None,
    statistics: bool,
    threads: int | None,
    row_group_size: int,
    preserve_order: bool,
    batch_size: int | None,
    informative_nulls: bool,
) -> int:
    import polars as pl
    from polars_readstat import scan_readstat

    # preserve_order=False (the polars-readstat default) allows batches to be
    # emitted out of order for throughput. SAS datasets are ordered, so we
    # default to ordered output and make reordering an explicit opt-in.
    lf = scan_readstat(
        str(src),
        threads=threads,
        preserve_order=preserve_order,
        batch_size=batch_size,
        informative_nulls={"columns": "all"} if informative_nulls else None,
    )
    lf.sink_parquet(
        str(dst),
        compression=compression,
        compression_level=compression_level,
        statistics=statistics,
        row_group_size=row_group_size,
        metadata=_kv_metadata(src),
    )
    return pl.scan_parquet(str(dst)).select(pl.len()).collect().item()


def _convert_pyreadstat(
    src: Path,
    dst: Path,
    *,
    compression: str,
    compression_level: int | None,
    statistics: bool,
    chunk_rows: int,
    row_group_size: int,
) -> int:
    writer: pq.ParquetWriter | None = None
    rows = 0
    try:
        # Chunks go through pandas deliberately: pyreadstat's dict output holds
        # object arrays, and Table.from_pandas on its DataFrame output benchmarks
        # ~30% faster with ~40% less peak memory than converting those directly.
        for df, _meta in pyreadstat.read_file_in_chunks(
            pyreadstat.read_sas7bdat, str(src), chunksize=chunk_rows
        ):
            table = pa.Table.from_pandas(df, preserve_index=False)
            if writer is None:
                schema = table.schema.with_metadata(_kv_metadata(src))
                writer = pq.ParquetWriter(
                    str(dst), schema, compression=compression,
                    compression_level=compression_level, write_statistics=statistics,
                )
            writer.write_table(table.cast(writer.schema), row_group_size=row_group_size)
            rows += len(df)
    finally:
        if writer is not None:
            writer.close()
    return rows


def sas7_binary() -> str | None:
    """Locate the pure-Rust `sas7` converter, if installed."""
    found = shutil.which("sas7")
    if found:
        return found
    cargo_bin = Path.home() / ".cargo" / "bin" / "sas7"
    return str(cargo_bin) if cargo_bin.exists() else None


def _convert_sas7cli(src: Path, dst: Path, *, threads: int | None) -> int:
    exe = sas7_binary()
    if exe is None:
        raise RuntimeError(
            "sas7 CLI not found (cargo install sas7bdat --features cli,parquet)"
        )
    cmd = [exe, str(src), "--out", str(dst), "--sink", "parquet", "--fail-fast"]
    if threads:
        cmd += ["--jobs", str(threads)]
    proc = subprocess.run(cmd, capture_output=True, text=True)
    if proc.returncode != 0:
        raise RuntimeError(f"sas7 CLI failed: {proc.stderr.strip()[-500:]}")
    return pq.ParquetFile(str(dst)).metadata.num_rows


def _available_ram() -> int:
    return os.sysconf("SC_AVPHYS_PAGES") * os.sysconf("SC_PAGE_SIZE")


def _auto_candidates(src: Path) -> list[str]:
    fits_in_ram = src.stat().st_size <= _available_ram() * POLARS_RAM_SHARE
    order = ["polars", "sas7", "pyreadstat"] if fits_in_ram else ["sas7", "pyreadstat"]
    return [e for e in order if e != "sas7" or sas7_binary()]


def convert_file(
    src: Path | str,
    dst: Path | str,
    *,
    engine: Engine = "auto",
    compression: str = "zstd",
    compression_level: int | None = None,
    statistics: bool = True,
    chunk_rows: int = DEFAULT_CHUNK_ROWS,
    threads: int | None = None,
    row_group_size: int = 512 * 1024,
    preserve_order: bool = True,
    batch_size: int | None = None,
    informative_nulls: bool = False,
) -> ConversionResult:
    """Convert one .sas7bdat file to Parquet. Returns stats about the run.

    preserve_order keeps rows in their original SAS order (small throughput
    cost). informative_nulls adds indicator columns capturing SAS special
    missing values (.A-.Z, ._) that would otherwise collapse into plain nulls;
    it is only supported by the polars engine. compression_level defaults to
    zstd level 1: ~25-35% faster than the codec default with almost no size
    penalty in our benchmarks. statistics=False shaves another ~10% off write
    time but disables row-group pruning for later queries on the file.
    """
    if compression_level is None and compression == "zstd":
        compression_level = 1
    src, dst = Path(src), Path(dst)
    if engine != "auto" and engine not in ENGINES:
        raise ValueError(f"unknown engine: {engine!r}")
    if informative_nulls and engine != "polars":
        raise ValueError("informative_nulls requires engine='polars'")
    dst.parent.mkdir(parents=True, exist_ok=True)

    candidates = _auto_candidates(src) if engine == "auto" else [engine]
    t0 = time.perf_counter()
    rows, used, errors = 0, "", []
    for i, candidate in enumerate(candidates):
        try:
            if candidate == "polars":
                rows = _convert_polars(
                    src, dst, compression=compression,
                    compression_level=compression_level, statistics=statistics,
                    threads=threads, row_group_size=row_group_size,
                    preserve_order=preserve_order, batch_size=batch_size,
                    informative_nulls=informative_nulls,
                )
            elif candidate == "sas7":
                rows = _convert_sas7cli(src, dst, threads=threads)
            else:
                rows = _convert_pyreadstat(
                    src, dst, compression=compression,
                    compression_level=compression_level, statistics=statistics,
                    chunk_rows=chunk_rows, row_group_size=row_group_size,
                )
            used = candidate if i == 0 else f"{candidate} (fallback)"
            break
        except Exception as e:
            errors.append(f"{candidate}: {e}")
            if candidate == candidates[-1]:
                raise RuntimeError(
                    f"all engines failed for {src}: " + " | ".join(errors)
                ) from e

    return ConversionResult(
        source=src,
        dest=dst,
        engine_used=used,
        rows=rows,
        seconds=time.perf_counter() - t0,
        source_bytes=src.stat().st_size,
        dest_bytes=dst.stat().st_size,
    )
