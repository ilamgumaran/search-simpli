#!/usr/bin/env python3
"""S5-T12 attribution: one call per (workload, query) through an instrumented
library that prints a line per documentFrequency call to stderr.
    python3 -I count_df.py LIB ONE_ROOT TWO_ROOT WORKLOAD QUERY"""
import ctypes, json, os, sys
lib_path, one, two, workload, query = sys.argv[1:6]
lib = ctypes.CDLL(lib_path)
lib.ss_open.argtypes = [ctypes.c_char_p]; lib.ss_open.restype = ctypes.c_void_p
lib.ss_query.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_size_t, ctypes.c_char_p]
lib.ss_query.restype = ctypes.c_void_p
lib.ss_free.argtypes = [ctypes.c_void_p]
extra = {"both": {"search_field": "both"}, "both-scoped": {"search_field": "both", "roots": ["r-left"]},
         "content-scoped": {"search_field": "content", "roots": ["r-left"]}}[workload]
h = lib.ss_open((one if workload == "both" else two).encode())
sys.stderr.write("BEGIN\n"); sys.stderr.flush()
p = lib.ss_query(h, query.encode(), None, 0, 10, json.dumps({"retrieval_mode": "lexical", **extra}).encode())
lib.ss_free(p)
