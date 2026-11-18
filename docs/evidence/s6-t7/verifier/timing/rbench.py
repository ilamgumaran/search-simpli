#!/usr/bin/env python3
"""S6-T7 verifier: open, memory after open, first and later read_span/outline, one library and one
index per process (ctypes). Not part of any library.

    rbench.py LIB INDEX FILES.json VARIANT RUN OUT.jsonl

FILES.json: {"corpus": ..., "files": {"small": [root, path, lines], "median": [...], "largest": [...]}}
  - memory: ri_phys_footprint before ss_open and after it (first thing in the process);
  - open: 5 warm-up, then 60 timed ss_open + ss_close, p50 wall and p50 thread CPU;
  - first read_span on a fresh handle (the median file, lines 1-40): 11 opens, p50;
  - first outline on a fresh handle (the median file): 11 opens, p50;
  - later calls on one handle, per file: read_span 1-40 (largest also middle and tail 40 lines) and
    outline; 10 warm-up, 200 timed; p50 wall and CPU per call (thread time over the batch / calls).
All times in ms.
"""
import ctypes
import hashlib
import json
import os
import sys
import time

lib_path, index, files_path, variant, run_no, out_path = sys.argv[1:7]


class RusageInfoV0(ctypes.Structure):
    _fields_ = [("ri_uuid", ctypes.c_uint8 * 16), ("ri_user_time", ctypes.c_uint64),
                ("ri_system_time", ctypes.c_uint64), ("ri_pkg_idle_wkups", ctypes.c_uint64),
                ("ri_interrupt_wkups", ctypes.c_uint64), ("ri_pageins", ctypes.c_uint64),
                ("ri_wired_size", ctypes.c_uint64), ("ri_resident_size", ctypes.c_uint64),
                ("ri_phys_footprint", ctypes.c_uint64), ("ri_proc_start_abstime", ctypes.c_uint64),
                ("ri_proc_exit_abstime", ctypes.c_uint64)]


libc = ctypes.CDLL(None)


def footprint():
    info = RusageInfoV0()
    assert libc.proc_pid_rusage(os.getpid(), 0, ctypes.byref(info)) == 0
    return int(info.ri_phys_footprint)


lib = ctypes.CDLL(lib_path)
lib.ss_open.argtypes = [ctypes.c_char_p]
lib.ss_open.restype = ctypes.c_void_p
lib.ss_close.argtypes = [ctypes.c_void_p]
lib.ss_free.argtypes = [ctypes.c_void_p]
lib.ss_last_error.restype = ctypes.c_char_p
for name in ("ss_read_span", "ss_outline"):
    getattr(lib, name).restype = ctypes.c_void_p
    getattr(lib, name).argtypes = [ctypes.c_void_p, ctypes.c_char_p]
spec = json.load(open(files_path))
idx = index.encode()
row = {"variant": variant, "run": int(run_no), "index": index, "corpus": spec["corpus"],
       "load_before": [round(x, 2) for x in os.getloadavg()], "t_start": time.strftime("%H:%M:%S")}

before = footprint()
h = lib.ss_open(idx)
if not h:
    raise SystemExit("ss_open failed: " + lib.ss_last_error().decode())
row["memory_after_open"] = footprint() - before
lib.ss_close(h)


def p50(xs):
    xs = sorted(xs)
    return xs[(len(xs) - 1) // 2]


wall, cpu = [], []
for i in range(65):
    t0, c0 = time.perf_counter_ns(), time.thread_time_ns()
    hh = lib.ss_open(idx)
    lib.ss_close(hh)
    c1, t1 = time.thread_time_ns(), time.perf_counter_ns()
    if i >= 5:
        wall.append((t1 - t0) / 1e6)
        cpu.append((c1 - c0) / 1e6)
row["open"] = {"p50_ms": p50(wall), "min_ms": min(wall), "cpu_p50_ms": p50(cpu)}


def req_span(f, a, b):
    return json.dumps({"root_id": f[0], "path": f[1], "start_line": a, "end_line": b}).encode()


def req_outline(f):
    return json.dumps({"root_id": f[0], "path": f[1]}).encode()


def call(fn, h, r):
    p = fn(h, r)
    if not p:
        raise SystemExit("call failed: " + lib.ss_last_error().decode())
    s = ctypes.string_at(p)
    lib.ss_free(p)
    return s


med = spec["files"]["median"]
firsts = {"read_span": [], "outline": []}
for kind, fn, r in (("read_span", lib.ss_read_span, req_span(med, 1, min(40, med[2]))),
                    ("outline", lib.ss_outline, req_outline(med))):
    for _ in range(11):
        hh = lib.ss_open(idx)
        t0 = time.perf_counter_ns()
        call(fn, hh, r)
        firsts[kind].append((time.perf_counter_ns() - t0) / 1e6)
        lib.ss_close(hh)
row["first_read_span"] = {"p50_ms": p50(firsts["read_span"]), "min_ms": min(firsts["read_span"])}
row["first_outline"] = {"p50_ms": p50(firsts["outline"]), "min_ms": min(firsts["outline"])}

h = lib.ss_open(idx)
later = []
for size, f in spec["files"].items():
    n = f[2]
    cells = [("read_span head", lib.ss_read_span, req_span(f, 1, min(40, n))), ("outline", lib.ss_outline, req_outline(f))]
    if size == "largest":
        m = max(1, n // 2)
        cells += [("read_span middle", lib.ss_read_span, req_span(f, m, min(n, m + 39))),
                  ("read_span tail", lib.ss_read_span, req_span(f, max(1, n - 39), n))]
    for name, fn, r in cells:
        ans = call(fn, h, r)
        for _ in range(10):
            call(fn, h, r)
        xs = []
        c0 = time.thread_time_ns()
        for _ in range(200):
            t0 = time.perf_counter_ns()
            p = fn(h, r)
            xs.append((time.perf_counter_ns() - t0) / 1e6)
            lib.ss_free(p)
        c1 = time.thread_time_ns()
        later.append({"cell": f"{name} {size}", "p50_ms": p50(xs), "min_ms": min(xs), "cpu_per_call_ms": (c1 - c0) / 1e6 / 200,
                      "answer_sha256": hashlib.sha256(ans).hexdigest()})
lib.ss_close(h)
row["later"] = later
row["load_after"] = [round(x, 2) for x in os.getloadavg()]
row["t_end"] = time.strftime("%H:%M:%S")
with open(out_path, "a") as out:
    out.write(json.dumps(row) + "\n")
