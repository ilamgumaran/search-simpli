"""S5-T4 ruling 10: the goldens the Python reference writes over the fixture packs
are what their generators write today, so extending a pack (J2 grew in S5-T3 and
S5-T4) can never leave one stale again. Each generator is run as its docstring says
(`python3 scripts/gen_*.py > fixtures/*.json`, from the repository root) and its
output compared byte for byte, in the pattern of `test_analyzer_v3.py`'s table check.

None of the four generators needs the Zig library today; a generator marked as
needing it is skipped under `SEARCH_SIMPLI_NO_ZIG=1`. The goldens depend on the
interpreter's Unicode tables (the tokenizer reads `unicodedata`), so the check is
skipped on any other Unicode version, as the analyzer-v3 golden's check is.

S5-T6 (review R01): CI's `unicode-13-goldens` job runs these checks on Python 3.9
(Unicode 13.0.0) through `scripts/ci_unicode_goldens.py`, which counts them by name
and fails on a skip, so the 3.11 jobs' skip no longer leaves them unrun."""

import os
import subprocess
import sys
import unicodedata
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "src"))

from search_platform._fold import UNICODE_VERSION  # noqa: E402

# (generator, golden, needs the Zig library)
GOLDENS = [
    ("gen_title_golden.py", "title-field-golden.json", False),
    ("gen_bm25_golden.py", "bm25-golden.json", False),
    ("gen_fuzzy_golden.py", "fuzzy-golden.json", False),
    ("gen_verb_forms_golden.py", "verb-forms-golden.json", False),
]


class GoldensFreshTests(unittest.TestCase):
    def check(self, generator: str, golden: str, needs_zig: bool) -> None:
        if needs_zig and os.environ.get("SEARCH_SIMPLI_NO_ZIG") == "1":
            self.skipTest("SEARCH_SIMPLI_NO_ZIG=1: " + generator + " needs the Zig library")
        if unicodedata.unidata_version != UNICODE_VERSION:
            self.skipTest("goldens generated with Unicode " + UNICODE_VERSION)
        fresh = subprocess.run([sys.executable, str(ROOT / "scripts" / generator)], cwd=str(ROOT),
                               capture_output=True, text=True, check=True, timeout=300).stdout
        committed = (ROOT / "fixtures" / golden).read_text(encoding="utf-8")
        self.assertTrue(fresh == committed,
                        "fixtures/" + golden + " is stale: run python3 scripts/" + generator
                        + " > fixtures/" + golden)

    def test_title_golden_regenerates_byte_for_byte(self):
        self.check(*GOLDENS[0])

    def test_bm25_golden_regenerates_byte_for_byte(self):
        self.check(*GOLDENS[1])

    def test_fuzzy_golden_regenerates_byte_for_byte(self):
        self.check(*GOLDENS[2])

    def test_verb_forms_golden_regenerates_byte_for_byte(self):
        # S5-T5: R's golden (fold-groups-v2), over the same term sets as K's.
        self.check(*GOLDENS[3])


if __name__ == "__main__":
    unittest.main()
