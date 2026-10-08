"""S2-T3 criteria 3-5: lexical queries rank only the chunks that matched.

Before S2-T3 every `ss_query` sorted the whole corpus three times, so p50 at
10,000 chunks was 8-12 ms and grew 11-32x for 10x the chunks. This test drives
the shipped ReleaseSmall library (the one the Dart package bundles, or
SEARCH_SIMPLI_LIBRARY_PATH) through the research doc's ctypes harness
(scripts/qbench.py) on generated 1,000- and 10,000-chunk corpora.

Robust to machine load: each figure is the best of five runs (each run is the
p50 of 40 calls), so a noisy moment cannot fail it; the primary assertion is
growth (10k time / 1k time), which load scales out of both sides; the absolute
2 ms bound is secondary. On the pre-change code both fail (growth 11-32x, 10k
p50 8-12 ms).
"""

import ctypes
import json
import os
import platform
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))
import qbench  # noqa: E402

SHIPPED = ROOT / "bindings" / "dart" / "search_simpli" / "native" / "macos-arm64" / "libsearch_simpli.dylib"
QUERIES = qbench.RESEARCH_QUERIES
RUNS = 5
CALLS = 40
MAX_GROWTH = 8.0  # ten times the chunks; the unfixed code measured 11x-32x
MAX_P50_MS_AT_10K = 2.0


def library_path():
    override = os.environ.get("SEARCH_SIMPLI_LIBRARY_PATH")
    if override:
        return override
    if platform.system() == "Darwin" and platform.machine() == "arm64" and SHIPPED.exists():
        return str(SHIPPED)
    return None


def best_p50(lib, handle, query):
    return min(qbench.measure(lib, handle, query, CALLS)["p50"] for _ in range(RUNS))


@unittest.skipUnless(library_path(), "needs the shipped macOS arm64 library")
class QueryLatencyTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        cls.lib = qbench.load(library_path())
        index = cls.lib
        index.ss_index_folder.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_char_p]
        index.ss_index_folder.restype = ctypes.c_void_p
        cls.handles = {}
        for count in (1000, 10000):
            corpus = Path(cls.tmp.name) / f"c{count}"
            subprocess.run(
                [sys.executable, "-I", str(ROOT / "scripts" / "gen_timing_corpus.py"), str(corpus), str(count)],
                check=True,
                stdout=subprocess.DEVNULL,
            )
            snapshot = Path(cls.tmp.name) / f"s{count}"
            report = index.ss_index_folder(str(snapshot).encode(), str(corpus).encode(), b"")
            assert report, index.ss_last_error()
            index.ss_free(report)
            handle = index.ss_open(str(snapshot).encode())
            assert handle, index.ss_last_error()
            cls.handles[count] = handle

    @classmethod
    def tearDownClass(cls):
        for handle in cls.handles.values():
            cls.lib.ss_close(handle)
        cls.tmp.cleanup()

    def test_ten_times_the_chunks_costs_far_less_than_ten_times_more_and_under_2ms(self):
        rows = []
        for query in QUERIES:
            small = best_p50(self.lib, self.handles[1000], query)
            large = best_p50(self.lib, self.handles[10000], query)
            rows.append((query, small, large, large / small))
        print("\n" + json.dumps([{"query": q, "ms_1k": round(s, 4), "ms_10k": round(l, 4), "growth": round(g, 2)} for q, s, l, g in rows]))
        for query, small, large, growth in rows:
            with self.subTest(query=query):
                self.assertLessEqual(growth, MAX_GROWTH, f"10k/1k growth for {query!r}")
                self.assertLessEqual(large, MAX_P50_MS_AT_10K, f"10k p50 (ms) for {query!r}")


if __name__ == "__main__":
    unittest.main()
