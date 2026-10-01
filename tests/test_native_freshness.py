"""S1-T6 criterion 7: the prebuilt native libraries must not be older than the Zig source."""

import importlib.util
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PACKAGE = ROOT / "bindings" / "dart" / "search_simpli"


def _load_digest():
    spec = importlib.util.spec_from_file_location("source_digest", PACKAGE / "tool" / "source_digest.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.source_digest


class NativeFreshnessTest(unittest.TestCase):
    def test_prebuilt_libraries_match_zig_source(self):
        recorded = (PACKAGE / "native" / "SOURCE-SHA256").read_text().strip()
        self.assertEqual(
            recorded,
            _load_digest()(ROOT),
            "prebuilt libraries are older than the Zig source; run tool/build_native.sh",
        )


if __name__ == "__main__":
    unittest.main()
