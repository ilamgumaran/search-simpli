"""S6-T2: `searchd search <folder> "<query>"`, through the real binary.

`search` answers a query over a folder with no index directory. Its stdout is
byte for byte what `index <folder> --out X --filename-index` followed by
`query X` / `query X --json` / `evidence X` prints with the same options, on
`content`, `filename` and `both`; it writes nothing in or beside the folder,
in its working directory or in the temporary directory, and leaves nothing
behind; a missing folder, a file where a folder is expected and an empty query
are usage errors (exit 2, one stderr line, empty stdout); an empty folder
answers with no results and exit 0. The exhaustive comparison (every J2 query,
every field and form) is `zig/src/direct_search_test.zig`; this module checks
the command itself on a sample.

Finding the binary as `test_cli_process.py` does: `$SEARCHD_BINARY`, else one
`zig build --prefix <tmp>`; `SEARCH_SIMPLI_NO_ZIG=1` (CI) skips. All content is
invented."""

import json
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
J2 = ROOT / "fixtures" / "j2"
FIXTURES = ROOT / "fixtures"
FIELDS = ("content", "filename", "both")
FORMS = ((), ("--json",), ("--evidence",))

RULES_FOLDER = {
    "notes/garden.md": "# Garden\n\n## Tomatoes\n\nThe tomatoes by the shed need water every evening.\n",
    "notes/kitchen.txt": "The kettle is descaled on Sundays.\nThe pantry holds flour and lentils.\n",
    "notes/deep/attic.MD": "# Attic\n\nThe attic holds the winter blankets and the old lantern.\n",
    "code/lantern.py": "def light_lantern():\n    return 'the lantern glows'\n",
    "picture.png": "lantern tomatoes (not a listed extension)\n",
    ".hidden.md": "lantern tomatoes in a dotfile\n",
    ".secret/plans.md": "lantern tomatoes in a dot-directory\n",
    "node_modules/pkg/readme.md": "lantern tomatoes in node_modules\n",
    "notes/__pycache__/cache.txt": "lantern tomatoes in __pycache__\n",
    "zig-out/out.txt": "lantern tomatoes in zig-out\n",
    "big/bulky.txt": "lantern " * 400,
}
RULES_QUERIES = ("lantern", "tomatoes shed", "attic blankets", "node_modules pkg", "hidden", "bulky", "garden")


def build_searchd(scratch: Path) -> Path:
    override = os.environ.get("SEARCHD_BINARY")
    if override:
        return Path(override)
    if shutil.which("zig") is None:
        raise AssertionError("zig is not on PATH and SEARCHD_BINARY is not set")
    prefix = scratch / "prefix"
    built = subprocess.run(["zig", "build", "--prefix", str(prefix)], cwd=ROOT / "zig",
                           capture_output=True, text=True, timeout=540)
    if built.returncode != 0:
        raise AssertionError("zig build failed:\n" + built.stderr)
    return prefix / "bin" / "searchd"


def j2_sample(step: int) -> list:
    queries = json.loads((J2 / "judgments.json").read_text(encoding="utf-8"))["queries"]
    return [row["query"] for row in queries][::step]


def write_tree(folder: Path, files: dict) -> None:
    for name, text in files.items():
        path = folder / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")


def tree(folder: Path) -> list:
    """Every entry under `folder`: path, kind, size and modification time (ns)."""
    entries = []
    for path in sorted(folder.rglob("*")):
        stat = path.lstat()
        kind = "dir" if path.is_dir() else "file"
        entries.append((str(path.relative_to(folder)), kind, stat.st_size, stat.st_mtime_ns))
    return entries


class DirectSearchTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        if os.environ.get("SEARCH_SIMPLI_NO_ZIG") == "1":
            raise unittest.SkipTest("SEARCH_SIMPLI_NO_ZIG=1: this environment deliberately has no Zig (CI)")
        cls.binary_dir = tempfile.TemporaryDirectory()
        cls.binary = build_searchd(Path(cls.binary_dir.name))
        if not cls.binary.is_file():
            raise AssertionError(f"no searchd binary at {cls.binary}")

    @classmethod
    def tearDownClass(cls) -> None:
        cls.binary_dir.cleanup()

    def setUp(self) -> None:
        self.scratch = tempfile.TemporaryDirectory()
        self.work = Path(self.scratch.name)

    def tearDown(self) -> None:
        self.scratch.cleanup()

    def run_searchd(self, *args, cwd=None, env=None) -> subprocess.CompletedProcess:
        return subprocess.run([str(self.binary), *[str(a) for a in args]], capture_output=True,
                              timeout=120, cwd=cwd, env=env)

    def index(self, folder: Path, name: str) -> Path:
        out = self.work / name
        done = self.run_searchd("index", folder, "--out", out, "--filename-index")
        self.assertEqual(done.returncode, 0, done.stderr)
        return out

    def expected(self, index: Path, query: str, field: str, form: tuple, top_k: tuple) -> bytes:
        if form == ("--evidence",):
            done = self.run_searchd("evidence", index, query, "--search-field", field, *top_k)
        else:
            done = self.run_searchd("query", index, query, "--search-field", field, *form, *top_k)
        self.assertEqual(done.returncode, 0, done.stderr)
        return done.stdout

    def assert_same_answers(self, folder: Path, queries, forms=FORMS, top_ks=((),)) -> int:
        index = self.index(folder, "index-" + folder.name)
        compared = 0
        for query in queries:
            for field in FIELDS:
                for form in forms:
                    for top_k in top_ks:
                        got = self.run_searchd("search", folder, query, "--search-field", field, *form, *top_k)
                        self.assertEqual(got.returncode, 0, got.stderr)
                        want = self.expected(index, query, field, form, top_k)
                        self.assertEqual(got.stdout, want, f"{folder.name}: {query!r} {field} {form} {top_k}")
                        compared += 1
        return compared

    def test_same_answers_as_index_then_query_on_the_j2_corpus(self) -> None:
        sample = j2_sample(29)
        self.assertEqual(len(sample), 10)
        self.assertEqual(self.assert_same_answers(J2, sample), 10 * 3 * 3)

    def test_same_answers_on_the_whole_fixtures_folder(self) -> None:
        self.assert_same_answers(FIXTURES, ["volcano project due date", "garden"], forms=(("--evidence",),),
                                 top_ks=(("--top-k", "3"),))

    def test_same_answers_over_the_walk_rules_and_the_caps(self) -> None:
        folder = self.work / "rules"
        write_tree(folder, RULES_FOLDER)
        self.assert_same_answers(folder, RULES_QUERIES, top_ks=((), ("--top-k", "1")))
        # With a file cap the index and the search leave out the same file;
        # the search says so on stderr.
        index = self.work / "rules-capped"
        done = self.run_searchd("index", folder, "--out", index, "--filename-index", "--max-file-bytes", "1000")
        self.assertEqual(done.returncode, 0, done.stderr)
        for field in FIELDS:
            got = self.run_searchd("search", folder, "lantern", "--search-field", field, "--evidence",
                                   "--max-file-bytes", "1000")
            self.assertEqual(got.returncode, 0, got.stderr)
            self.assertEqual(got.stdout, self.expected(index, "lantern", field, ("--evidence",), ()))
            self.assertEqual(got.stderr,
                             b"searchd: search: 1 files not searched (too_large=1 unreadable=0 budget_exhausted=0)\n")
        # The flag changes the answer: `filename` is not `content`.
        names = self.run_searchd("search", folder, "lantern", "--search-field", "filename", "--json")
        bodies = self.run_searchd("search", folder, "lantern", "--search-field", "content", "--json")
        self.assertNotEqual(names.stdout, bodies.stdout)
        self.assertEqual(json.loads(names.stdout)["retrieval"]["search_field"], "filename")

    def test_writes_nothing_and_leaves_nothing_behind(self) -> None:
        parent = self.work / "parent"
        folder = parent / "folder"
        write_tree(folder, RULES_FOLDER)
        tmpdir = self.work / "tmpdir"
        cwd = self.work / "cwd"
        tmpdir.mkdir()
        cwd.mkdir()
        env = dict(os.environ, TMPDIR=str(tmpdir), TMP=str(tmpdir), TEMP=str(tmpdir))
        before = tree(parent)
        for field in FIELDS:
            for form in FORMS:
                done = self.run_searchd("search", folder, "lantern tomatoes", "--search-field", field, *form,
                                        cwd=cwd, env=env)
                self.assertEqual(done.returncode, 0, done.stderr)
                self.assertTrue(done.stdout)
        # Usage errors write nothing either.
        self.assertEqual(self.run_searchd("search", folder, "", cwd=cwd, env=env).returncode, 2)
        self.assertEqual(self.run_searchd("search", folder / "missing", "x", cwd=cwd, env=env).returncode, 2)
        self.assertEqual(tree(parent), before)
        self.assertEqual(list(tmpdir.iterdir()), [])
        self.assertEqual(list(cwd.iterdir()), [])

    def test_usage_errors_are_one_line_and_exit_two(self) -> None:
        plain = self.work / "plain.md"
        plain.write_text("a file, not a folder\n", encoding="utf-8")
        cases = [
            ((self.work / "missing", "x"), b"(no such folder)"),
            ((plain, "x"), b"(not a folder)"),
            ((self.work, ""), b"the query is empty"),
            ((self.work, "  "), b"the query is empty"),
            ((self.work,), b"missing argument"),
            ((self.work, "x", "--out", "y"), b"unknown flag for search"),
            ((self.work, "x", "--search-field", "title"), b"--search-field"),
        ]
        for args, needle in cases:
            done = self.run_searchd("search", *args)
            self.assertEqual(done.returncode, 2, args)
            self.assertEqual(done.stdout, b"", args)
            self.assertEqual(done.stderr.count(b"\n"), 1, done.stderr)
            self.assertIn(needle, done.stderr)

    def test_an_empty_folder_answers_nothing_as_an_empty_index(self) -> None:
        empty = self.work / "empty"
        empty.mkdir()
        index = self.index(empty, "empty-index")
        for field in FIELDS:
            for form in FORMS:
                got = self.run_searchd("search", empty, "anything", "--search-field", field, *form)
                self.assertEqual(got.returncode, 0, got.stderr)
                self.assertEqual(got.stderr, b"")
                self.assertEqual(got.stdout, self.expected(index, "anything", field, form, ()))
        self.assertEqual(list(empty.iterdir()), [])

    def test_help_names_the_command(self) -> None:
        done = self.run_searchd("--help")
        self.assertEqual(done.returncode, 0)
        self.assertIn(b'search <folder> "<query>"', done.stdout)


if __name__ == "__main__":
    unittest.main()
