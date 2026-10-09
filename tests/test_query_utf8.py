"""S2-T11: `ss_query` rejects a query text that is not valid UTF-8, on every
analyzer and mode, and never hangs. Each call runs in a child process under a
hard timeout, so a regression to the old behaviour (an endless loop on an
`analyzer-v2` snapshot in the shipped ReleaseSmall library, or on an
`ascii-alnum-v1` snapshot a report whose `query` is a JSON byte array) fails
this test instead of the suite timeout. Library: `SEARCH_SIMPLI_LIBRARY_PATH`,
else the shipped macOS arm64 library; skipped where neither exists."""

import os
import platform
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SHIPPED = ROOT / "bindings" / "dart" / "search_simpli" / "native" / "macos-arm64" / "libsearch_simpli.dylib"

CHILD = r"""
import ctypes, json, sys
lib = ctypes.CDLL(sys.argv[1])
lib.ss_index_folder.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_char_p]
lib.ss_index_folder.restype = ctypes.c_void_p
lib.ss_open.argtypes = [ctypes.c_char_p]
lib.ss_open.restype = ctypes.c_void_p
lib.ss_query.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_size_t, ctypes.c_char_p]
lib.ss_query.restype = ctypes.c_void_p
lib.ss_last_error.restype = ctypes.c_char_p
lib.ss_free.argtypes = [ctypes.c_void_p]
report = lib.ss_index_folder(sys.argv[3].encode(), sys.argv[2].encode(), json.dumps({"analyzer": sys.argv[4]}).encode())
assert report, lib.ss_last_error()
handle = lib.ss_open(sys.argv[3].encode())
assert handle, lib.ss_last_error()
text = bytes.fromhex(sys.argv[5])
out = lib.ss_query(handle, text, None, 0, 3, json.dumps({"retrieval_mode": sys.argv[6]}).encode())
if out:
    print("OK", ctypes.string_at(out).decode())
else:
    print("ERR", lib.ss_last_error().decode())
"""


def library_path():
    override = os.environ.get("SEARCH_SIMPLI_LIBRARY_PATH")
    if override:
        return override
    if platform.system() == "Darwin" and platform.machine() == "arm64" and SHIPPED.exists():
        return str(SHIPPED)
    return None


@unittest.skipUnless(library_path(), "needs the shipped macOS arm64 library")
class InvalidUtf8QueryTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        cls.folder = Path(cls.tmp.name) / "docs"
        cls.folder.mkdir()
        (cls.folder / "a.md").write_text("hybrid retrieval ranks documents\n", encoding="utf-8")
        (cls.folder / "b.md").write_text("café au lait\n", encoding="utf-8")

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def call(self, analyzer, text: bytes, mode="lexical"):
        snapshot = Path(self.tmp.name) / f"snap-{analyzer}-{os.getpid()}"
        try:
            done = subprocess.run(
                [sys.executable, "-I", "-c", CHILD, library_path(), str(self.folder), str(snapshot), analyzer, text.hex(), mode],
                capture_output=True, text=True, timeout=30,
            )
        except subprocess.TimeoutExpired:
            self.fail(f"ss_query hung ({analyzer}, {text!r}, {mode}): no answer in 30 s")
        self.assertEqual(done.returncode, 0, done.stderr)
        return done.stdout.strip()

    def test_invalid_utf8_is_rejected_on_both_analyzers_and_every_mode(self):
        for analyzer in ("v1", "v2"):
            for text in (b"caf\xff", b"\xfe", b"\x80", b"hybrid \xff\xfe", b"\xc3", b"\xed\xa0\x80"):
                for mode in ("lexical", "vector", "hybrid"):
                    with self.subTest(analyzer=analyzer, text=text, mode=mode):
                        answer = self.call(analyzer, text, mode)
                        self.assertTrue(answer.startswith("ERR "), answer)
                        self.assertIn("query_text is not valid UTF-8", answer)
                        self.assertIn("SS_ERR_INVALID_ARGUMENT", answer)

    def test_valid_queries_still_answer_with_a_string_query(self):
        for analyzer in ("v1", "v2"):
            answer = self.call(analyzer, "café".encode(), "lexical")
            self.assertTrue(answer.startswith("OK "), answer)
            self.assertIn('"query":"café"', answer)


if __name__ == "__main__":
    unittest.main()
