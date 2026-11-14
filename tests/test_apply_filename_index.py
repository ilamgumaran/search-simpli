"""S5-T11 (review R08): `searchd apply --filename-index`, through the real binary.

One `apply` on a directory with no index publishes exactly the requested roots
with the file-name channel on; without the flag a fresh index stays plain; an
index that has the channel takes the flag as a no-op; an index without it is
refused (exit 2, one stderr line, nothing written, the index answers as
before). Also: empty roots, labels (a hidden file is neither searched nor
named), a repeated command, the flag given twice, the flag on no other
subcommand, and the two crash points of a first write (sections written but no
`MANIFEST`; `MANIFEST` published but no `INDEX-STATE.json`). The crash hook
itself (`fail_after_publish`) is in `zig/src/cli_test.zig`.

Finding the binary as `test_cli_process.py` does: `$SEARCHD_BINARY`, else one
`zig build --prefix <tmp>`; `SEARCH_SIMPLI_NO_ZIG=1` (CI) skips. All content is
invented."""

import base64
import json
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

TIDE = "# Week 7\n\nThe tide table for the harbour walk.\n"
SPELLING = "# Spelling\n\nlighthouse, island, ferry\n"
SURPRISE = "# Plans\n\nA surprise party at the boathouse.\n"


def b64(text: str) -> str:
    return base64.b64encode(text.encode("utf-8")).decode("ascii")


def add(root_id: str, path: str, text: str, **extra) -> dict:
    return {"op": "add", "root_id": root_id, "path": path, "content_base64": b64(text), **extra}


def two_roots() -> dict:
    """Two host roots and an empty third; one file of `home` needs `adults`."""
    return {
        "roots": [{"root_id": "school", "label": "School", "kind": "host"},
                  {"root_id": "home", "label": "Home", "kind": "host"},
                  {"root_id": "attic", "label": "Attic", "kind": "host"}],
        "changes": [add("school", "tide-table.md", TIDE),
                    add("school", "spelling-list.md", SPELLING),
                    add("home", "boathouse-surprise.md", SURPRISE, required_labels=["adults"])],
    }


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


def snapshot(index: Path) -> dict:
    """Every file of the index directory and its bytes."""
    return {p.name: p.read_bytes() for p in sorted(index.iterdir()) if p.is_file()}


class ApplyFilenameIndexTests(unittest.TestCase):
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
        scratch = tempfile.TemporaryDirectory()
        self.addCleanup(scratch.cleanup)
        self.tmp = Path(scratch.name)

    def searchd(self, *args) -> subprocess.CompletedProcess:
        return subprocess.run([str(self.binary), *map(str, args)], capture_output=True, text=True,
                              stdin=subprocess.DEVNULL, timeout=120)

    def changes(self, request: dict, name: str = "changes.json") -> Path:
        path = self.tmp / name
        path.write_text(json.dumps(request), encoding="utf-8")
        return path

    def apply(self, index: Path, request: dict, *flags: str) -> dict:
        done = self.searchd("apply", index, "--changes", self.changes(request), "--json", *flags)
        self.assertEqual(done.returncode, 0, done.stderr)
        return json.loads(done.stdout)

    def serve(self, index: Path, requests: list, *flags: str) -> list:
        """One `searchd serve` process answering `requests` ([method, params]) in order."""
        lines = "".join(json.dumps({"jsonrpc": "2.0", "id": i, "method": m, "params": p}) + "\n"
                        for i, (m, p) in enumerate(requests, 1))
        done = subprocess.run([str(self.binary), "serve", str(index), *flags], input=lines,
                              capture_output=True, text=True, timeout=120)
        self.assertEqual(done.returncode, 0, done.stderr)
        replies = [json.loads(line) for line in done.stdout.splitlines()]
        self.assertEqual(len(replies), len(requests), done.stdout)
        return replies

    def search(self, field: str, query: str) -> list:
        return ["search_knowledge", {"query": query, "top_k": 10, "retrieval_mode": "lexical", "search_field": field}]

    def paths(self, reply: dict) -> list:
        return [r["citation"]["path"] for r in reply["result"]["results"]]

    def assert_channel(self, index: Path, generation: int) -> None:
        status, filename, both, content = self.serve(index, [
            ["index_status", {}], self.search("filename", "tide"), self.search("both", "tide"),
            self.search("content", "harbour")])
        self.assertEqual(status["result"]["generation"], generation)
        self.assertEqual(status["result"]["filename_policy_id"], "filename-field-v1")
        self.assertEqual(self.paths(filename), ["school/tide-table.md"])
        self.assertEqual(filename["result"]["results"][0]["matched_in"], ["filename"])
        self.assertEqual(self.paths(both), ["school/tide-table.md"])
        self.assertEqual(self.paths(content), ["school/tide-table.md"])

    # ---------------------------------------------------------- the cases ---

    def test_fresh_directory_with_the_flag_publishes_the_roots_with_the_channel(self) -> None:
        index = self.tmp / "new" / "index"  # missing, parents too
        report = self.apply(index, two_roots(), "--filename-index")
        self.assertEqual(report["generation"], 1)
        self.assertEqual(report["added"], 3)
        self.assertIn("filenames-1.hybseg", snapshot(index))
        self.assertIn("filename-lexical-1.hyblex", snapshot(index))
        # Exactly the requested roots in their order, the empty one included;
        # no `r-legacy`. `home`'s one file needs `adults`, so it counts only there.
        for flags, home in (((), 0), (("--labels", "adults"), 1)):
            status = self.serve(index, [["index_status", {}]], *flags)[0]["result"]
            self.assertEqual([(r["root_id"], r["files"]) for r in status["roots"]],
                             [("school", 2), ("home", home), ("attic", 0)])
        self.assert_channel(index, 1)
        # The CLI's own filename and both queries answer too.
        for field in ("filename", "both"):
            done = self.searchd("query", index, "spelling", "--search-field", field, "--json")
            self.assertEqual(done.returncode, 0, done.stderr)
            self.assertEqual([r["citation"]["path"] for r in json.loads(done.stdout)["results"]],
                             ["school/spelling-list.md"])

    def test_fresh_directory_without_the_flag_stays_plain(self) -> None:
        index = self.tmp / "plain"
        self.assertEqual(self.apply(index, two_roots())["generation"], 1)
        self.assertFalse(any(name.startswith("filename") for name in snapshot(index)))
        status = self.serve(index, [["index_status", {}]])[0]["result"]
        self.assertNotIn("filename_policy_id", status)
        done = self.searchd("query", index, "tide", "--search-field", "filename")
        self.assertEqual(done.returncode, 1)
        self.assertIn("FilenameIndexUnavailable", done.stderr)

    def test_only_empty_roots(self) -> None:
        index = self.tmp / "empty"
        request = {"roots": [{"root_id": "attic", "kind": "host"}, {"root_id": "shed", "kind": "host"}], "changes": []}
        report = self.apply(index, request, "--filename-index")
        self.assertEqual((report["generation"], report["documents"]), (1, 0))
        status, filename, both = self.serve(index, [["index_status", {}], self.search("filename", "tide"),
                                                    self.search("both", "tide")])
        self.assertEqual([(r["root_id"], r["files"]) for r in status["result"]["roots"]], [("attic", 0), ("shed", 0)])
        self.assertEqual(status["result"]["filename_policy_id"], "filename-field-v1")
        self.assertEqual(self.paths(filename), [])
        self.assertEqual(self.paths(both), [])
        # The empty index takes files later, the channel kept, with or without the flag.
        self.apply(index, {"changes": [add("attic", "tide-table.md", TIDE)]})
        self.assertEqual(self.paths(self.serve(index, [self.search("filename", "tide")])[0]), ["attic/tide-table.md"])

    def test_a_hidden_label_file_is_neither_searched_nor_named(self) -> None:
        index = self.tmp / "labels"
        self.apply(index, two_roots(), "--filename-index")
        asks = [self.search("filename", "boathouse surprise"), self.search("both", "boathouse surprise"),
                self.search("content", "boathouse surprise"), ["list_files", {}],
                ["find", {"query": "boathouse"}]]
        for flags in ((), ("--labels", "kids")):
            filename, both, content, listed, found = self.serve(index, asks, *flags)
            for reply in (filename, both, content):
                self.assertEqual(self.paths(reply), [], (flags, reply))
            self.assertNotIn("boathouse", json.dumps(listed["result"]))
            self.assertEqual(found["result"]["hits"], [])
        filename, both, content, listed, found = self.serve(index, asks, "--labels", "adults")
        for reply in (filename, both, content):
            self.assertEqual(self.paths(reply), ["home/boathouse-surprise.md"])

    def test_repeat_and_the_flag_given_twice(self) -> None:
        index = self.tmp / "repeat"
        self.assertEqual(self.apply(index, two_roots(), "--filename-index", "--filename-index")["generation"], 1)
        again = self.apply(index, two_roots(), "--filename-index")
        self.assertEqual((again["generation"], again["unchanged"], again["added"]), (2, 3, 0))
        self.assert_channel(index, 2)
        # Text output of the same repeat.
        done = self.searchd("apply", index, "--changes", self.changes(two_roots()), "--filename-index")
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertTrue(done.stdout.startswith("applied: generation=3 added=0 "), done.stdout)

    def test_existing_index_with_the_channel_takes_the_flag_as_without_it(self) -> None:
        with_flag, without = self.tmp / "with", self.tmp / "without"
        for index in (with_flag, without):
            self.apply(index, two_roots(), "--filename-index")
        change = {"changes": [add("school", "tide-table.md", TIDE + "\nFerry times, edited.\n")]}
        flagged = self.apply(with_flag, change, "--filename-index")
        plain = self.apply(without, change)
        self.assertEqual(flagged, plain)
        self.assertEqual((flagged["generation"], flagged["changed"]), (2, 1))
        self.assert_channel(with_flag, 2)
        # A channel index under analyzer-v1 (only `index` makes one): `apply`
        # (always analyzer-v2) refuses it with or without the flag, the same way.
        folder, v1 = self.tmp / "folder", self.tmp / "v1"
        folder.mkdir()
        (folder / "tide-table.md").write_text(TIDE, encoding="utf-8")
        self.assertEqual(self.searchd("index", folder, "--out", v1, "--analyzer", "v1", "--filename-index").returncode, 0)
        before = snapshot(v1)
        refusals = [self.searchd("apply", v1, "--changes", self.changes(change), *flags)
                    for flags in (("--filename-index",), ())]
        self.assertEqual([(r.returncode, r.stdout, r.stderr.splitlines()[:1]) for r in refusals][0],
                         [(r.returncode, r.stdout, r.stderr.splitlines()[:1]) for r in refusals][1])
        self.assertEqual(refusals[0].returncode, 1)
        self.assertIn("AnalyzerMismatch", refusals[0].stderr)
        self.assertEqual(snapshot(v1), before)

    def test_existing_index_without_the_channel_is_refused_and_untouched(self) -> None:
        index = self.tmp / "plain-index"
        self.apply(index, two_roots())
        before = snapshot(index)
        asked_before = self.searchd("find", index, "tide", "--json")
        change = {"changes": [add("school", "new-notes.md", "# Notes\n\nnew words\n")]}
        for extra in ((), ("--json",), ("--expect-generation", "1")):
            done = self.searchd("apply", index, "--changes", self.changes(change), "--filename-index", *extra)
            self.assertEqual(done.returncode, 2, done.stderr)
            self.assertEqual(done.stdout, "")
            self.assertEqual(len(done.stderr.splitlines()), 1, done.stderr)
            self.assertIn("--filename-index", done.stderr)
            self.assertIn("has no file-name channel", done.stderr)
            self.assertEqual(snapshot(index), before)
        status = self.serve(index, [["index_status", {}]])[0]["result"]
        self.assertEqual(status["generation"], 1)
        self.assertNotIn("filename_policy_id", status)
        self.assertEqual(self.searchd("find", index, "tide", "--json").stdout, asked_before.stdout)
        # Without the flag the same change still applies.
        self.assertEqual(self.apply(index, change)["generation"], 2)

    def test_the_flag_is_on_apply_only(self) -> None:
        index = self.tmp / "only"
        self.apply(index, two_roots(), "--filename-index")
        for args in (("find", index, "tide"), ("roots", index), ("list-files", index), ("query", index, "tide"),
                     ("evidence", index, "tide"), ("outline", index, "school", "tide-table.md"),
                     ("read-span", index, "school", "tide-table.md", "1", "1"), ("serve", index), ("mcp", index)):
            done = self.searchd(*args, "--filename-index")
            self.assertEqual(done.returncode, 2, (args, done.stderr))
            self.assertIn("unknown flag", done.stderr)
        # `index --filename-index` is unchanged.
        folder = self.tmp / "folder"
        folder.mkdir()
        (folder / "tide-table.md").write_text(TIDE, encoding="utf-8")
        done = self.searchd("index", folder, "--out", self.tmp / "walked", "--filename-index")
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertIn("filenames-1.hybseg", snapshot(self.tmp / "walked"))

    # ------------------------------------------------------ crash points ---

    def test_crash_before_the_manifest_leaves_no_index_and_the_retry_is_complete(self) -> None:
        """Sections written, the `MANIFEST` rename never happened: the
        directory is no index; the same one-step command publishes a complete
        generation with the channel, numbered above the leftovers."""
        source, crashed = self.tmp / "source", self.tmp / "crashed"
        self.apply(source, two_roots(), "--filename-index")
        crashed.mkdir()
        for name, data in snapshot(source).items():
            if name not in ("MANIFEST", "INDEX-STATE.json"):
                (crashed / name).write_bytes(data)
        done = self.searchd("roots", crashed)
        self.assertEqual(done.returncode, 1)  # no index
        report = self.apply(crashed, two_roots(), "--filename-index")
        self.assertEqual((report["generation"], report["added"]), (2, 3))
        self.assert_channel(crashed, 2)

    def test_crash_after_the_manifest_is_the_complete_first_generation(self) -> None:
        """`MANIFEST` published, the `INDEX-STATE.json` pointer never written:
        generation 1 with the channel answers, and the next apply, with or
        without the flag, keeps the channel."""
        for flags in (("--filename-index",), ()):
            index = self.tmp / ("after" + "".join(flags))
            self.apply(index, two_roots(), "--filename-index")
            (index / "INDEX-STATE.json").unlink()
            self.assert_channel(index, 1)
            retry = self.apply(index, two_roots(), *flags)
            self.assertEqual((retry["generation"], retry["unchanged"]), (2, 3))
            self.assert_channel(index, 2)


if __name__ == "__main__":
    unittest.main()
