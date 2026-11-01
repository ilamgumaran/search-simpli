"""Supplement S3's frozen pack with exact BOM/CR read boundaries."""

import hashlib
import tempfile
import unittest
from pathlib import Path

from src.search_platform.core import build_index, read_span


class SourceBoundaryTests(unittest.TestCase):
    def test_bom_first_line_and_cr_only_files_through_indexed_reads(self):
        cases = {
            "bom.md": (b"\xef\xbb\xbf# Metals\r\nCopper\r\nSilver", 1, 1, b"# Metals\r\n"),
            "cr-only.txt": (b"Copper\rSilver\rGold\r", 1, 3, b"Copper\rSilver\rGold\r"),
            "cr-final.txt": (b"Copper\rSilver", 2, 2, b"Silver"),
        }
        with tempfile.TemporaryDirectory() as scratch:
            root = Path(scratch)
            for name, (data, _, _, _) in cases.items():
                (root / name).write_bytes(data)
            index = build_index(root)
            for name, (_, start, end, expected) in cases.items():
                with self.subTest(name=name):
                    result = read_span(index, name, start, end, context_lines=0)
                    self.assertTrue(result["byte_exact"])
                    self.assertEqual(result["text"].encode("utf-8"), expected)
                    self.assertEqual(result["sha256"], hashlib.sha256(expected).hexdigest())


if __name__ == "__main__":
    unittest.main()
