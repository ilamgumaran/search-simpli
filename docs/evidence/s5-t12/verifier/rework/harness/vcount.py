#!/usr/bin/env python3
"""Verifier: one ss_query per (workload, query) through an instrumented
library that prints WALK per visible-collection walk and DF <term> per
documentFrequency call to stderr.
    python3 -I vcount.py LIB ONE_ROOT TWO_ROOT WORKLOAD QUERY"""
import ctypes, json, sys
lib_path, one, two, workload, query = sys.argv[1:6]
lib = ctypes.CDLL(lib_path)
lib.ss_open.argtypes = [ctypes.c_char_p]; lib.ss_open.restype = ctypes.c_void_p
lib.ss_query.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_size_t, ctypes.c_char_p]
lib.ss_query.restype = ctypes.c_void_p
lib.ss_free.argtypes = [ctypes.c_void_p]
extra = {"content": ("one", {"search_field": "content"}), "both": ("one", {"search_field": "both"}),
         "both-all": ("two", {"search_field": "both"}),
         "content-scoped": ("two", {"search_field": "content", "roots": ["r-left"]}),
         "both-scoped": ("two", {"search_field": "both", "roots": ["r-left"]})}[workload]
h = lib.ss_open((one if extra[0] == "one" else two).encode())
sys.stderr.write("BEGIN\n"); sys.stderr.flush()
p = lib.ss_query(h, query.encode(), None, 0, 10, json.dumps({"retrieval_mode": "lexical", **extra[1]}).encode())
lib.ss_free(p)
