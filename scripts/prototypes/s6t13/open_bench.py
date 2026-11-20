#!/usr/bin/env python3
"""S6-T13 open time: one library, one index, one process (ctypes).

    python3 -I open_bench.py LIB INDEX BUILD CORPUS RUN OUT.jsonl

5 warm-up then 60 timed `ss_open` + `ss_close` pairs; the wall time of each
`ss_open` alone (perf_counter) and its thread CPU time (thread_time); p50 and
min of each, in ms. One JSON line appended to OUT. Not part of any library or
the build.
"""
import ctypes
import json
import statistics
import sys
import time

WARM = 5
OPENS = 60


def main() -> int:
    lib_path, index, build, corpus, run, out = sys.argv[1:7]
    lib = ctypes.CDLL(lib_path)
    lib.ss_open.argtypes = [ctypes.c_char_p]
    lib.ss_open.restype = ctypes.c_void_p
    lib.ss_close.argtypes = [ctypes.c_void_p]
    lib.ss_close.restype = None
    lib.ss_last_error.restype = ctypes.c_char_p
    path = index.encode()
    walls, cpus = [], []
    for i in range(WARM + OPENS):
        c0 = time.thread_time()
        w0 = time.perf_counter()
        handle = lib.ss_open(path)
        w1 = time.perf_counter()
        c1 = time.thread_time()
        if not handle:
            raise SystemExit(f"ss_open failed: {lib.ss_last_error()!r}")
        lib.ss_close(handle)
        if i >= WARM:
            walls.append((w1 - w0) * 1000.0)
            cpus.append((c1 - c0) * 1000.0)
    row = {"build": build, "corpus": corpus, "run": run, "opens": OPENS,
           "open_p50": statistics.median(walls), "open_min": min(walls),
           "cpu_p50": statistics.median(cpus), "cpu_min": min(cpus),
           "at": time.strftime("%Y-%m-%d %H:%M:%S")}
    with open(out, "a") as f:
        f.write(json.dumps(row) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
