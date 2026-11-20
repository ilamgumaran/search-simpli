#!/usr/bin/env python3
"""S6-T13: the MANIFEST read across real processes (a race, not the deterministic test; supplementary evidence).

    python3 -I xproc.py writer INDEX MANIFEST_A MANIFEST_B SECONDS
    python3 -I xproc.py reader INDEX LIB SECONDS

The writer replaces INDEX/MANIFEST by rename, alternating two whole manifests whose generations' sections are all
present (as a publish renames its MANIFEST in). The reader runs ss_open + ss_close on INDEX in a loop and prints the
number of opens and of each ss_last_error message. Not part of any library or the build.
"""
import collections
import ctypes
import os
import sys
import time


def writer(index, a, b, seconds):
    blobs = [open(a, "rb").read(), open(b, "rb").read()]
    end = time.monotonic() + seconds
    n = 0
    while time.monotonic() < end:
        tmp = os.path.join(index, f"MANIFEST.xproc-{n % 2}")
        with open(tmp, "wb") as f:
            f.write(blobs[n % 2])
        os.rename(tmp, os.path.join(index, "MANIFEST"))
        n += 1
    print(f"writer: {n} renames")


def reader(index, lib_path, seconds):
    lib = ctypes.CDLL(lib_path)
    lib.ss_open.argtypes = [ctypes.c_char_p]
    lib.ss_open.restype = ctypes.c_void_p
    lib.ss_close.argtypes = [ctypes.c_void_p]
    lib.ss_last_error.restype = ctypes.c_char_p
    errors = collections.Counter()
    opens = 0
    end = time.monotonic() + seconds
    path = index.encode()
    while time.monotonic() < end:
        handle = lib.ss_open(path)
        opens += 1
        if handle:
            lib.ss_close(handle)
        else:
            errors[lib.ss_last_error().decode()] += 1
    print(f"reader {os.path.basename(os.path.dirname(lib_path))}: {opens} opens, errors {dict(errors) or 'none'}")


if __name__ == "__main__":
    if sys.argv[1] == "writer":
        writer(sys.argv[2], sys.argv[3], sys.argv[4], float(sys.argv[5]))
    else:
        reader(sys.argv[2], sys.argv[3], float(sys.argv[4]))
