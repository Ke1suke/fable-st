import json

import polars as pl
import pyarrow.parquet as pq
import pytest

from sas2parquet import convert_file, sas7_binary
from sas2parquet.convert import _auto_candidates
from sas2parquet.cli import main as cli_main

from fixture_writer import write_fixture

N_ROWS = 10_000
EXPECTED_MISSING = len([i for i in range(N_ROWS) if i % 100 == 7])


@pytest.fixture(scope="session")
def sas_file(tmp_path_factory):
    return write_fixture(tmp_path_factory.mktemp("data") / "sample.sas7bdat", N_ROWS)


@pytest.mark.parametrize("engine", ["polars", "pyreadstat", "auto"])
def test_roundtrip(sas_file, tmp_path, engine):
    dst = tmp_path / f"out_{engine}.parquet"
    result = convert_file(sas_file, dst, engine=engine)
    assert result.rows == N_ROWS

    df = pl.read_parquet(dst)
    assert df.shape == (N_ROWS, 3)
    assert df.columns == ["ID", "VALUE", "NAME"]
    assert df["ID"].to_list()[:3] == [1.0, 2.0, 3.0]
    assert df["VALUE"][1] == 1.5
    assert df["VALUE"].null_count() == EXPECTED_MISSING
    assert df["NAME"][0] == "item_0"


@pytest.mark.parametrize("engine", ["polars", "pyreadstat"])
def test_labels_embedded_in_parquet_metadata(sas_file, tmp_path, engine):
    dst = tmp_path / f"meta_{engine}.parquet"
    convert_file(sas_file, dst, engine=engine)
    kv = pq.ParquetFile(dst).metadata.metadata
    meta = json.loads(kv[b"sas7bdat_metadata"])
    assert meta["column_labels"]["VALUE"] == "Measured value"
    assert meta["number_rows"] == N_ROWS


def test_engines_produce_identical_data(sas_file, tmp_path):
    a, b = tmp_path / "a.parquet", tmp_path / "b.parquet"
    convert_file(sas_file, a, engine="polars")
    convert_file(sas_file, b, engine="pyreadstat")
    assert pl.read_parquet(a).equals(pl.read_parquet(b))


@pytest.mark.skipif(sas7_binary() is None, reason="sas7 CLI not installed")
def test_sas7_engine_matches_polars(sas_file, tmp_path):
    a, b = tmp_path / "a.parquet", tmp_path / "b.parquet"
    convert_file(sas_file, a, engine="polars")
    r = convert_file(sas_file, b, engine="sas7")
    assert r.rows == N_ROWS
    assert pl.read_parquet(b).equals(pl.read_parquet(a))


def test_auto_prefers_memory_safe_engines_for_huge_files(sas_file, monkeypatch):
    import sas2parquet.convert as c

    monkeypatch.setattr(c, "_available_ram", lambda: 10**15)
    assert _auto_candidates(sas_file)[0] == "polars"
    monkeypatch.setattr(c, "_available_ram", lambda: sas_file.stat().st_size)
    assert "polars" not in _auto_candidates(sas_file)


def test_row_order_preserved_across_batches(sas_file, tmp_path):
    # Small batches + threads force the multi-batch path where polars-readstat
    # would emit rows out of order without preserve_order.
    dst = tmp_path / "ordered.parquet"
    convert_file(sas_file, dst, engine="polars", batch_size=500, threads=4)
    ids = pl.read_parquet(dst)["ID"].to_list()
    assert ids == [float(i + 1) for i in range(N_ROWS)]


def test_informative_nulls_polars_only(sas_file, tmp_path):
    with pytest.raises(ValueError):
        convert_file(sas_file, tmp_path / "x.parquet", engine="pyreadstat",
                     informative_nulls=True)
    dst = tmp_path / "inf.parquet"
    convert_file(sas_file, dst, engine="polars", informative_nulls=True)
    df = pl.read_parquet(dst)
    assert "VALUE_null" in df.columns  # indicator column for special missings


def test_cli_directory_mode(sas_file, tmp_path):
    in_dir = tmp_path / "in" / "nested"
    in_dir.mkdir(parents=True)
    (in_dir / "one.sas7bdat").write_bytes(sas_file.read_bytes())
    (in_dir / "two.sas7bdat").write_bytes(sas_file.read_bytes())
    out_dir = tmp_path / "out"

    rc = cli_main([str(tmp_path / "in"), "-o", str(out_dir)])
    assert rc == 0
    assert (out_dir / "nested" / "one.parquet").exists()
    assert (out_dir / "nested" / "two.parquet").exists()

    # without --overwrite existing outputs are skipped, not clobbered
    rc = cli_main([str(tmp_path / "in"), "-o", str(out_dir)])
    assert rc == 0
