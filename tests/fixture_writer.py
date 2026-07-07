"""Generate a .sas7bdat test fixture without SAS.

ReadStat (the C library inside pyreadstat) ships an experimental sas7bdat
*writer* that pyreadstat does not expose in Python. Its symbols are exported
by pyreadstat's compiled extension, so we call them directly with ctypes.
Only used to build test data; production code never writes sas7bdat.
"""

from __future__ import annotations

import ctypes
import glob
import os
from pathlib import Path

READSTAT_TYPE_STRING = 0
READSTAT_TYPE_DOUBLE = 5

_DATA_WRITER = ctypes.CFUNCTYPE(ctypes.c_ssize_t, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_void_p)


def _load_readstat() -> ctypes.CDLL:
    import pyreadstat

    pattern = os.path.join(os.path.dirname(pyreadstat.__file__), "_readstat_writer*.so")
    matches = glob.glob(pattern)
    if not matches:
        raise OSError(f"no compiled pyreadstat writer found at {pattern}")
    lib = ctypes.CDLL(matches[0])
    lib.readstat_writer_init.restype = ctypes.c_void_p
    lib.readstat_set_data_writer.argtypes = [ctypes.c_void_p, _DATA_WRITER]
    lib.readstat_add_variable.restype = ctypes.c_void_p
    lib.readstat_add_variable.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_int, ctypes.c_size_t]
    lib.readstat_variable_set_label.argtypes = [ctypes.c_void_p, ctypes.c_char_p]
    lib.readstat_begin_writing_sas7bdat.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_long]
    lib.readstat_begin_row.argtypes = [ctypes.c_void_p]
    lib.readstat_insert_double_value.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_double]
    lib.readstat_insert_string_value.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_char_p]
    lib.readstat_insert_missing_value.argtypes = [ctypes.c_void_p, ctypes.c_void_p]
    lib.readstat_end_row.argtypes = [ctypes.c_void_p]
    lib.readstat_end_writing.argtypes = [ctypes.c_void_p]
    lib.readstat_writer_free.argtypes = [ctypes.c_void_p]
    return lib


def write_fixture(path: Path | str, n_rows: int = 10_000) -> Path:
    """Write a 3-column fixture: ID (double), VALUE (double, ~1% missing), NAME (string)."""
    path = Path(path)
    lib = _load_readstat()
    with open(path, "wb") as fh:

        @_DATA_WRITER
        def _sink(data, length, _ctx):
            fh.write(ctypes.string_at(data, length))
            return length

        w = lib.readstat_writer_init()
        lib.readstat_set_data_writer(w, _sink)
        v_id = lib.readstat_add_variable(w, b"ID", READSTAT_TYPE_DOUBLE, 8)
        v_val = lib.readstat_add_variable(w, b"VALUE", READSTAT_TYPE_DOUBLE, 8)
        v_name = lib.readstat_add_variable(w, b"NAME", READSTAT_TYPE_STRING, 32)
        lib.readstat_variable_set_label(v_val, b"Measured value")

        rc = lib.readstat_begin_writing_sas7bdat(w, None, n_rows)
        if rc != 0:
            raise RuntimeError(f"readstat_begin_writing_sas7bdat failed: {rc}")
        for i in range(n_rows):
            lib.readstat_begin_row(w)
            lib.readstat_insert_double_value(w, v_id, float(i + 1))
            if i % 100 == 7:
                lib.readstat_insert_missing_value(w, v_val)
            else:
                lib.readstat_insert_double_value(w, v_val, i * 1.5)
            lib.readstat_insert_string_value(w, v_name, f"item_{i % 97}".encode())
            lib.readstat_end_row(w)
        rc = lib.readstat_end_writing(w)
        if rc != 0:
            raise RuntimeError(f"readstat_end_writing failed: {rc}")
        lib.readstat_writer_free(w)
    return path
