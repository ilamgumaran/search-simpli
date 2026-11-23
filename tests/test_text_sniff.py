"""S6-T23 (CAP-24, docs/decisions/0005-which-files-are-text.md): which files a walk reads.

`text-sniff-v1`: a walked file is read when its bytes are text. The Python reference
(`search_platform.core`) and the engine (`zig/src/core/indexer.zig`) apply the same rule:

- the sniff's verdicts on the same bytes as the Zig test "S6-T23: sniff's verdicts";
- the reference walk's files and not-read counts on a folder of every kind;
- through the real `searchd`: the same files and counts, a folder holding names with a
  carriage return indexes and searches (exit 0), the `not_read` field on `index --update`,
  the total on the `index` line and on the `search` stderr line, and the reference's file set
  equals the engine's on the repository's `fixtures/` folder.

Finding the binary as `test_direct_search.py` does: `$SEARCHD_BINARY`, else one
`zig build --prefix <tmp>`; `SEARCH_SIMPLI_NO_ZIG=1` (CI) skips the engine tests. All
content is invented."""

import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "src"))
sys.path.insert(0, str(ROOT / "tests"))

from search_platform import core  # noqa: E402

from test_direct_search import build_searchd  # noqa: E402

CASES = [
    (b"", 0, "text"),
    (b"plain words\n", 12, "text"),
    (b"\xef\xbb\xbfa UTF-8 mark\n", 16, "text"),
    (b"2026-11-01 \x1b[32mINFO\x1b[0m done\n", 31, "text"),
    (b"\xff\xfeh\x00i\x00", 6, "other_encoding"),
    (b"\xfe\xff\x00h\x00i", 6, "other_encoding"),
    (b"\x00\x00\xfe\xff\x00\x00\x00h", 8, "other_encoding"),
    (b"ab\x00cd", 5, "binary"),
    (b"a" * 99 + b"\x01", 100, "text"),
    (b"a" * 98 + b"\x01\x02", 100, "binary"),
    (b"caf\xe9\n", 5, "not_utf8"),
    (b"abc\xe2\x82", 9000, "text"),
    (b"abc\xe2\x82", 5, "not_utf8"),
    (b"abc\xf0\x9f\x98", 9000, "text"),
    (b"abc\xff", 9000, "not_utf8"),
    (b"abc\xe2\x82\xac", 9000, "text"),
    (b"\x80\x80\x80\x80", 9000, "not_utf8"),
]

# The Zig tests' folder (`writeKindsFolder`).
KINDS = {
    "notes/a.md": b"# A\n\nThe kestrel nests by the mill.\n",
    "README": b"The russet folder holds the orchard plans.\n",
    "data.csv": b"item,shelf\ntilecutter,S20\n",
    "logo.svg": b"<svg><title>orchard</title></svg>\n",
    "scan.pdf": b"%PDF-1.7 orchard\n",
    "blob": b"orchard\x00\x01\x02",
    "known.txt": b"orchard with a NUL\x00 inside\n",
    "a\rb.md": b"orchard behind a carriage return\n",
    "Icon\r": b"",
    ".env": b"TOKEN=orchard\n",
    ".config/settings.ini": b"orchard = hidden\n",
    "node_modules/pkg/readme": b"orchard in node_modules\n",
}
READ = ["README", "data.csv", "notes/a.md"]
NOT_READ = {"bad_name": 2, "binary": 2, "document": 1, "image": 1}


def write_bytes(folder: Path, files: dict) -> None:
    for name, data in files.items():
        path = folder / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)


class SniffTests(unittest.TestCase):
    def test_the_same_verdicts_as_the_engine(self) -> None:
        for head, size, verdict in CASES:
            self.assertEqual(core._sniff(head, size), verdict, head)

    def test_the_rule_and_its_parameters(self) -> None:
        self.assertEqual(core.READABLE_RULE_ID, "text-sniff-v1")
        self.assertEqual(core.SNIFF_HEAD_BYTES, 8192)
        self.assertEqual(core._SKIP[".svg"], "image")
        self.assertEqual(core._lower_extension("Backup.TAR.GZ"), ".gz")
        self.assertNotIn(core._lower_extension("loans.csv"), core._SKIP)


class ReferenceWalkTests(unittest.TestCase):
    def test_reads_text_of_any_name_and_counts_the_rest(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            folder = Path(tmp)
            write_bytes(folder, KINDS)
            got = [p.relative_to(folder).as_posix() for p in core._iter_text_files(folder)]
            self.assertEqual(got, READ)
            self.assertEqual(core.not_read_counts(folder), NOT_READ)


class EngineTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        if os.environ.get("SEARCH_SIMPLI_NO_ZIG") == "1":
            raise unittest.SkipTest("SEARCH_SIMPLI_NO_ZIG=1: this environment deliberately has no Zig (CI)")
        cls.binary_dir = tempfile.TemporaryDirectory()
        cls.binary = build_searchd(Path(cls.binary_dir.name))

    @classmethod
    def tearDownClass(cls) -> None:
        cls.binary_dir.cleanup()

    def setUp(self) -> None:
        self.scratch = tempfile.TemporaryDirectory()
        self.work = Path(self.scratch.name)

    def tearDown(self) -> None:
        self.scratch.cleanup()

    def run_searchd(self, *args) -> subprocess.CompletedProcess:
        return subprocess.run([str(self.binary), *[str(a) for a in args]], capture_output=True, timeout=300)

    def indexed_paths(self, index: Path) -> list:
        paths, cursor = [], None
        while True:
            listed = self.run_searchd("list-files", index, "--json", "--page-size", "1000",
                                      *(("--cursor", cursor) if cursor else ()))
            self.assertEqual(listed.returncode, 0, listed.stderr)
            page = json.loads(listed.stdout)
            paths += [f["path"] for f in page["files"] if f["status"] == "indexed"]
            cursor = page["next_cursor"]
            if not cursor:
                return paths

    def test_names_with_a_carriage_return_index_and_search(self) -> None:
        folder = self.work / "kinds"
        write_bytes(folder, KINDS)
        index = self.work / "index"
        full = self.run_searchd("index", folder, "--out", index)
        self.assertEqual(full.returncode, 0, full.stderr)
        self.assertTrue(full.stdout.decode().rstrip("\n").endswith(" not_read=6"), full.stdout)
        update = self.run_searchd("index", folder, "--out", index, "--update")
        self.assertEqual(update.returncode, 0, update.stderr)
        report = json.loads(update.stdout)
        self.assertEqual(report["not_read"], NOT_READ)
        self.assertEqual(report["unchanged"], 3)
        self.assertEqual(self.indexed_paths(index), READ)
        found = self.run_searchd("search", folder, "orchard", "--json")
        self.assertEqual(found.returncode, 0, found.stderr)
        self.assertEqual(found.stderr,
                         b"searchd: search: 6 files not searched (too_large=0 unreadable=0 budget_exhausted=0 not_read=6)\n")
        paths = {hit["path"] for hit in json.loads(found.stdout)["results"]}
        # Every file holds "orchard" but README is the only one read: not the picture, the
        # PDF, the binary files, the name with a carriage return, the dot-files.
        self.assertEqual(paths, {"README"})

    def test_the_reference_walk_is_the_engines_on_the_fixtures(self) -> None:
        index = self.work / "fixtures-index"
        done = self.run_searchd("index", ROOT / "fixtures", "--out", index, "--update")
        self.assertEqual(done.returncode, 0, done.stderr)
        report = json.loads(done.stdout)
        engine = sorted(self.indexed_paths(index) + report["unreadable_paths"] + report["too_large_paths"])
        reference = sorted(p.relative_to(ROOT / "fixtures").as_posix() for p in core._iter_text_files(ROOT / "fixtures"))
        self.assertEqual(engine, reference)
        self.assertEqual(report["not_read"], core.not_read_counts(ROOT / "fixtures"))


if __name__ == "__main__":
    unittest.main()
