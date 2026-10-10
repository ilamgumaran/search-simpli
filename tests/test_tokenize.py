"""S1-T14: analyzer-v2 tokenization in the Python reference (the Zig side has
the same table in `zig/src/analyzer_v2.zig`; the BM25 and chunk goldens make
the two agree on every fixture)."""

import sys
import unicodedata
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

from search_platform import core  # noqa: E402
from search_platform._marks import MARK_RANGES  # noqa: E402


class TokenizeTests(unittest.TestCase):
    def test_tamil_words_stay_whole(self):
        self.assertEqual(core.tokenize("கணினி"), ["கணினி"])
        self.assertEqual(core.tokenize("யானைகள்"), ["யானைகள்"])
        self.assertEqual(
            core.tokenize("நான் வீட்டிற்கு போகிறேன்"), ["நான்", "வீட்டிற்கு", "போகிறேன்"]
        )

    def test_devanagari_and_latin_accents(self):
        self.assertEqual(core.tokenize("किताब"), ["किताब"])
        self.assertEqual(core.tokenize("café"), ["café"])
        self.assertEqual(core.tokenize("Café"), ["café"])

    def test_ascii_is_unchanged(self):
        self.assertEqual(core.tokenize("x-ray"), ["x", "ray"])
        self.assertEqual(
            core.tokenize("Zig, search-v2! Rocks_on."), ["zig", "search", "v2", "rocks", "on"]
        )

    def test_joiners_stay_inside_a_run_only(self):
        self.assertEqual(core.tokenize("क्‍ष a‍ b"), ["क्‍ष", "a", "b"])
        self.assertEqual(core.tokenize("்தம்"), ["தம்"])
        self.assertEqual(core.tokenize("‌ab"), ["ab"])

    def test_variation_selectors_are_dropped(self):
        self.assertEqual(core.tokenize("1\ufe0f\u20e3"), ["1"])
        self.assertEqual(core.tokenize("a\ufe0fb"), ["ab"])
        self.assertEqual(core.tokenize("\u845b\U000e0100 x"), ["\u845b", "x"])

    def test_decomposed_hangul_and_cjk_compatibility(self):
        self.assertEqual(core.tokenize("\u1112\u1161\u11ab\u1100\u1173\u11af"), ["\ud55c\uae00"])
        self.assertEqual(core.tokenize("\uf900"), ["\u8c48"])
        self.assertEqual(core.tokenize("\u212bngstrom"), ["\u00e5ngstrom"])

    def test_mark_table_matches_this_pythons_unicodedata(self):
        if unicodedata.unidata_version != "13.0.0":
            self.skipTest("table generated with Unicode 13.0.0")
        marks = {cp for lo, hi in MARK_RANGES for cp in range(lo, hi + 1)}
        expected = {
            cp for cp in range(0x110000) if unicodedata.category(chr(cp)) in ("Mn", "Mc")
        }
        self.assertEqual(marks, expected)


if __name__ == "__main__":
    unittest.main()
