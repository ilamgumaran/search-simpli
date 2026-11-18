#!/usr/bin/env python3
"""S6-T7 Phase 2 bench: one library, one index, one process (ctypes), for
ruling 13's expectations on the open and on `read_span`/`outline`.

    python3 -I bench.py LIB INDEX VARIANT ROUND OUT.jsonl

- memory: `ri_phys_footprint` before `ss_open`, after it, after one
  `ss_read_span` and one `ss_outline` of the largest file, after `ss_close`
  (first thing in the process);
- open: 3 warm-up then 30 timed `ss_open` + `ss_close` pairs, p50 and min;
- the first `ss_read_span` on a handle (the largest file, lines 1-40), then
  the first `ss_outline` of it, 11 opens, p50 and min;
- later calls on one handle, the largest file: `read_span` lines 1-40, a
  40-line range in the middle, the last 40 lines, and `outline`; per kind 20
  warm-ups then 200 timed calls: p50 and min of the wall time, and the
  process CPU time (user + system, `getrusage`) of the 200 calls divided by
  200; and the same for `read_span` lines 1-40 and `outline` of the smallest
  and the median file.

The files are the largest, the smallest and the median by size of the
indexed files with at least one byte, as `ss_list_files` reports them. All times in ms. One JSON line appended to OUT. Not part of
any library or the build.
"""

from __future__ import annotations

import ctypes
import json
import os
import resource
import sys
import time

OPENS = 30
FIRSTS = 11
WARM = 20
CALLS = 200
SPAN = 40


class RusageInfoV0(ctypes.Structure):
    _fields_ = [("ri_uuid", ctypes.c_uint8 * 16), ("ri_user_time", ctypes.c_uint64),
                ("ri_system_time", ctypes.c_uint64), ("ri_pkg_idle_wkups", ctypes.c_uint64),
                ("ri_interrupt_wkups", ctypes.c_uint64), ("ri_pageins", ctypes.c_uint64),
                ("ri_wired_size", ctypes.c_uint64), ("ri_resident_size", ctypes.c_uint64),
                ("ri_phys_footprint", ctypes.c_uint64), ("ri_proc_start_abstime", ctypes.c_uint64),
                ("ri_proc_exit_abstime", ctypes.c_uint64)]


def footprint() -> int:
    libc = ctypes.CDLL(None)
    info = RusageInfoV0()
    if libc.proc_pid_rusage(os.getpid(), 0, ctypes.byref(info)) != 0:
        raise OSError("proc_pid_rusage failed")
    return int(info.ri_phys_footprint)


def cpu() -> float:
    r = resource.getrusage(resource.RUSAGE_SELF)
    return (r.ru_utime + r.ru_stime) * 1000.0


def load(path: str):
    lib = ctypes.CDLL(path)
    lib.ss_open.argtypes = [ctypes.c_char_p]
    lib.ss_open.restype = ctypes.c_void_p
    lib.ss_close.argtypes = [ctypes.c_void_p]
    lib.ss_close.restype = None
    for name in ("ss_outline", "ss_read_span", "ss_list_files"):
        fn = getattr(lib, name)
        fn.argtypes = [ctypes.c_void_p, ctypes.c_char_p]
        fn.restype = ctypes.c_void_p
    lib.ss_free.argtypes = [ctypes.c_void_p]
    lib.ss_free.restype = None
    lib.ss_last_error.restype = ctypes.c_char_p
    return lib


def must(lib, pointer) -> bytes:
    if not pointer:
        raise SystemExit("call failed: " + lib.ss_last_error().decode())
    value = ctypes.string_at(pointer)
    lib.ss_free(pointer)
    return value


def main(argv: list[str]) -> int:
    if len(argv) != 6:
        raise SystemExit(__doc__)
    lib_path, index, variant, round_no, out_path = argv[1:6]
    lib = load(lib_path)
    row = {"variant": variant, "round": int(round_no), "index": os.path.basename(index),
           "load_before": [round(x, 2) for x in os.getloadavg()]}
    before = footprint()
    handle = lib.ss_open(index.encode())
    if not handle:
        raise SystemExit("ss_open failed: " + lib.ss_last_error().decode())
    after_open = footprint()
    files, cursor = [], None
    while True:
        request = {"page_size": 1000, **({"cursor": cursor} if cursor else {})}
        page = json.loads(must(lib, lib.ss_list_files(handle, json.dumps(request).encode())))
        files += page["files"]
        cursor = page.get("next_cursor")
        if not cursor:
            break
    by_size = sorted((f for f in files if f.get("size", 0) > 0 and f.get("status") == "indexed"),
                     key=lambda f: (f["size"], f["path"]))
    biggest = by_size[-1]
    root, path, size = biggest["root_id"], biggest["path"], biggest.get("size")
    others = {"smallest": by_size[0], "median": by_size[(len(by_size) - 1) // 2]}
    target = {"root_id": root, "path": path}
    first = json.loads(must(lib, lib.ss_read_span(handle, json.dumps({**target, "start_line": 1, "end_line": SPAN}).encode())))
    after_read = footprint()
    outline = must(lib, lib.ss_outline(handle, json.dumps(target).encode()))
    after_outline = footprint()
    lib.ss_close(handle)
    after_close = footprint()
    row["file"] = {"root_id": root, "path": path, "bytes": size}
    row["memory"] = {"before": before, "open_delta": after_open - before, "read_delta": after_read - before,
                     "outline_delta": after_outline - before, "close_delta": after_close - before}

    # A file's line count: read 400-line pieces until one ends short.
    def line_count(h, t) -> int:
        start = 1
        while True:
            piece = json.loads(must(lib, lib.ss_read_span(h, json.dumps({**t, "start_line": start, "end_line": start + 399}).encode())))
            if piece["end_line"] < start + 399:
                return piece["end_line"]
            start += 400
    handle = lib.ss_open(index.encode())
    lines = line_count(handle, target)
    row["file"]["lines"] = lines
    other_targets = {}
    for name, f in others.items():
        t = {"root_id": f["root_id"], "path": f["path"]}
        other_targets[name] = (t, line_count(handle, t))
        row[f"file_{name}"] = {**t, "bytes": f["size"], "lines": other_targets[name][1]}
    lib.ss_close(handle)

    def open_close():
        h = lib.ss_open(index.encode())
        if not h:
            raise SystemExit("ss_open failed: " + lib.ss_last_error().decode())
        lib.ss_close(h)
    for _ in range(3):
        open_close()
    samples = []
    for _ in range(OPENS):
        t = time.perf_counter()
        open_close()
        samples.append((time.perf_counter() - t) * 1000.0)
    samples.sort()
    row["open"] = {"p50_ms": samples[(OPENS - 1) // 2], "min_ms": samples[0]}

    head = json.dumps({**target, "start_line": 1, "end_line": SPAN}).encode()
    mid_start = max(1, lines // 2 - SPAN // 2)
    middle = json.dumps({**target, "start_line": mid_start, "end_line": min(lines, mid_start + SPAN - 1)}).encode()
    tail = json.dumps({**target, "start_line": max(1, lines - SPAN + 1), "end_line": lines}).encode()
    outline_request = json.dumps(target).encode()
    first_read, first_outline = [], []
    for _ in range(FIRSTS):
        h = lib.ss_open(index.encode())
        t = time.perf_counter()
        must(lib, lib.ss_read_span(h, head))
        first_read.append((time.perf_counter() - t) * 1000.0)
        t = time.perf_counter()
        must(lib, lib.ss_outline(h, outline_request))
        first_outline.append((time.perf_counter() - t) * 1000.0)
        lib.ss_close(h)
    first_read.sort()
    first_outline.sort()
    row["first_read_span"] = {"p50_ms": first_read[(FIRSTS - 1) // 2], "min_ms": first_read[0]}
    row["first_outline_after"] = {"p50_ms": first_outline[(FIRSTS - 1) // 2], "min_ms": first_outline[0]}

    handle = lib.ss_open(index.encode())
    later = {}
    jobs = [("read_span head", lib.ss_read_span, head), ("read_span middle", lib.ss_read_span, middle),
            ("read_span tail", lib.ss_read_span, tail), ("outline", lib.ss_outline, outline_request)]
    for name, (t, n) in other_targets.items():
        jobs.append((f"{name} read_span", lib.ss_read_span,
                     json.dumps({**t, "start_line": 1, "end_line": min(n, SPAN)}).encode()))
        jobs.append((f"{name} outline", lib.ss_outline, json.dumps(t).encode()))
    for kind, fn, request in jobs:
        for _ in range(WARM):
            must(lib, fn(handle, request))
        samples = []
        c0 = cpu()
        for _ in range(CALLS):
            t = time.perf_counter()
            pointer = fn(handle, request)
            samples.append((time.perf_counter() - t) * 1000.0)
            lib.ss_free(pointer)
        c1 = cpu()
        samples.sort()
        later[kind] = {"p50_ms": samples[(CALLS - 1) // 2], "min_ms": samples[0], "cpu_ms_per_call": (c1 - c0) / CALLS}
    lib.ss_close(handle)
    row["later"] = later
    row["load_after"] = [round(x, 2) for x in os.getloadavg()]
    with open(out_path, "a", encoding="utf-8") as out:
        out.write(json.dumps(row) + "\n")
    print(json.dumps({k: row[k] for k in ("variant", "index", "open", "first_read_span")}))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
