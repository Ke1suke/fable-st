"""Command-line interface: convert a file or a whole directory tree."""

from __future__ import annotations

import argparse
import sys
from concurrent.futures import ProcessPoolExecutor, as_completed
from pathlib import Path

from .convert import DEFAULT_CHUNK_ROWS, ConversionResult, convert_file


def _dest_for(src: Path, in_root: Path, out_root: Path) -> Path:
    return (out_root / src.relative_to(in_root)).with_suffix(".parquet")


def _report(r: ConversionResult) -> str:
    mb_in = r.source_bytes / 1e6
    mb_out = r.dest_bytes / 1e6
    return (
        f"{r.source.name}: {r.rows:,} rows, {mb_in:.1f}MB -> {mb_out:.1f}MB "
        f"in {r.seconds:.2f}s [{r.engine_used}]"
    )


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(
        prog="sas2parquet",
        description="Convert SAS .sas7bdat files to Parquet, fast and memory-safe.",
    )
    p.add_argument("input", type=Path, help=".sas7bdat file or directory to scan recursively")
    p.add_argument("-o", "--output", type=Path, default=None,
                   help="output .parquet file (file input) or directory (directory input); "
                        "defaults next to the input")
    p.add_argument("--engine", choices=["auto", "polars", "sas7", "pyreadstat"], default="auto",
                   help="auto (default) picks by file size vs free RAM: polars when the "
                        "file fits in memory, otherwise sas7 CLI / pyreadstat (bounded memory)")
    p.add_argument("--compression", default="zstd",
                   choices=["zstd", "snappy", "lz4", "gzip", "uncompressed"])
    p.add_argument("--compression-level", type=int, default=None,
                   help="codec level (default: zstd uses level 1 - fastest with "
                        "near-identical size; other codecs use their default)")
    p.add_argument("--no-statistics", dest="statistics", action="store_false",
                   help="skip parquet min/max statistics (~10%% faster writes, "
                        "but disables row-group pruning when querying the output)")
    p.add_argument("--chunk-rows", type=int, default=DEFAULT_CHUNK_ROWS,
                   help=f"rows per chunk for the pyreadstat engine (default {DEFAULT_CHUNK_ROWS})")
    p.add_argument("--threads", type=int, default=None,
                   help="reader threads for the polars engine (default: all cores)")
    p.add_argument("--workers", type=int, default=1,
                   help="parallel files in directory mode (keep 1 for huge files; "
                        "raise it for many small files)")
    p.add_argument("--overwrite", action="store_true", help="overwrite existing .parquet outputs")
    p.add_argument("--no-preserve-order", dest="preserve_order", action="store_false",
                   help="allow out-of-order rows for higher throughput (polars engine)")
    p.add_argument("--informative-nulls", action="store_true",
                   help="add indicator columns for SAS special missing values "
                        "(.A-.Z, ._); polars engine only")
    args = p.parse_args(argv)
    if args.informative_nulls and args.engine != "polars":
        p.error("--informative-nulls requires --engine polars")

    if not args.input.exists():
        p.error(f"input not found: {args.input}")

    if args.input.is_file():
        dst = args.output or args.input.with_suffix(".parquet")
        if dst.exists() and not args.overwrite:
            p.error(f"{dst} exists (use --overwrite)")
        r = convert_file(args.input, dst, **_convert_kwargs(args))
        print(_report(r))
        return 0

    out_root = args.output or args.input
    sources = sorted(args.input.rglob("*.sas7bdat"))
    if not sources:
        print(f"no .sas7bdat files under {args.input}", file=sys.stderr)
        return 1
    jobs = []
    for src in sources:
        dst = _dest_for(src, args.input, out_root)
        if dst.exists() and not args.overwrite:
            print(f"skip (exists): {dst}", file=sys.stderr)
            continue
        jobs.append((src, dst))

    failures = 0
    if args.workers <= 1:
        for src, dst in jobs:
            failures += _run_one(src, dst, args)
    else:
        with ProcessPoolExecutor(max_workers=args.workers) as pool:
            futs = {
                pool.submit(convert_file, src, dst, **_convert_kwargs(args)): src
                for src, dst in jobs
            }
            for fut in as_completed(futs):
                try:
                    print(_report(fut.result()))
                except Exception as e:
                    failures += 1
                    print(f"FAILED {futs[fut]}: {e}", file=sys.stderr)
    return 1 if failures else 0


def _convert_kwargs(args: argparse.Namespace) -> dict:
    return dict(
        engine=args.engine,
        compression=args.compression,
        compression_level=args.compression_level,
        statistics=args.statistics,
        chunk_rows=args.chunk_rows,
        threads=args.threads,
        preserve_order=args.preserve_order,
        informative_nulls=args.informative_nulls,
    )


def _run_one(src: Path, dst: Path, args: argparse.Namespace) -> int:
    try:
        r = convert_file(src, dst, **_convert_kwargs(args))
        print(_report(r))
        return 0
    except Exception as e:
        print(f"FAILED {src}: {e}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
