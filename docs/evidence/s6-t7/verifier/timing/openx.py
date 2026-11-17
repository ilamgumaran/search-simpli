#!/usr/bin/env python3
"""S6-T7 verifier: open time, interleaved in one process. Every library loaded side by side
(ctypes; each dylib its own image); per round every (library, index) pair opens and closes once,
in a fresh seeded random order. Wall and thread CPU per ss_open+ss_close.

    openx.py V CORPUS ROUNDS SEED RUN OUT.jsonl
Pairs: main, main2, ctl1, ctl2 on main's index; head on the head's index; head-v4 = head's library
on main's index (the new library reading the old format: the code without the format change).
"""
import ctypes
import json
import os
import random
import statistics
import sys
import time

V, corpus, rounds, seed, run_no, out_path = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4]), sys.argv[5], sys.argv[6]
pairs = {"main": ("main", "main"), "main2": ("main2", "main"), "ctl1": ("ctl1", "main"), "ctl2": ("ctl2", "main"),
         "head": ("head", "head"), "head-v4": ("head", "main")}
libs = {}
for name in ("main", "main2", "ctl1", "ctl2", "head"):
    l = ctypes.CDLL(f"{V}/libs/{name}/libsearch_simpli.dylib")
    l.ss_open.argtypes = [ctypes.c_char_p]
    l.ss_open.restype = ctypes.c_void_p
    l.ss_close.argtypes = [ctypes.c_void_p]
    l.ss_last_error.restype = ctypes.c_char_p
    libs[name] = l
paths = {k: f"{V}/idx.noindex/{ix}/{corpus}".encode() for k, (_, ix) in pairs.items()}
row = {"run": int(run_no), "corpus": corpus, "rounds": rounds, "seed": seed, "load_before": [round(x, 2) for x in os.getloadavg()],
       "t_start": time.strftime("%H:%M:%S")}
wall = {k: [] for k in pairs}
cpu = {k: [] for k in pairs}
rng = random.Random(seed)
keys = list(pairs)
for r in range(rounds + 3):
    rng.shuffle(keys)
    for k in keys:
        l = libs[pairs[k][0]]
        t0, c0 = time.perf_counter_ns(), time.thread_time_ns()
        h = l.ss_open(paths[k])
        l.ss_close(h)
        c1, t1 = time.thread_time_ns(), time.perf_counter_ns()
        if not h:
            raise SystemExit(f"{k}: ss_open failed: {l.ss_last_error()}")
        if r >= 3:
            wall[k].append((t1 - t0) / 1e6)
            cpu[k].append((c1 - c0) / 1e6)
row["p50_ms"] = {k: statistics.median(v) for k, v in wall.items()}
row["cpu_p50_ms"] = {k: statistics.median(v) for k, v in cpu.items()}
row["min_ms"] = {k: min(v) for k, v in wall.items()}
row["load_after"] = [round(x, 2) for x in os.getloadavg()]
row["t_end"] = time.strftime("%H:%M:%S")
with open(out_path, "a") as out:
    out.write(json.dumps(row) + "\n")
print(corpus, {k: round(v, 4) for k, v in row["p50_ms"].items()})
