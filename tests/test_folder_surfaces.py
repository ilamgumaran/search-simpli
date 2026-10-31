"""S3-T4: the folder-knowledge operations on the CLI and the RPC server
(`docs/tasks/S3-T4.md` rulings 3 to 5), through the real `searchd` binary.

The index is the family-folder fixture as three host roots (`home`, `laptop`,
`school`) published by `searchd apply` from `content_base64` changes, plus a
fourth root `private` whose files require the label `adults` (invented
content). Covered: every new CLI subcommand with human and `--json` output
and its exit codes; one RPC request per method with scope, paging, caps and
error cases; `apply_changes` only under `--allow-write`; the server's scope
from the command line; and the CLI `--json` and RPC results byte-identical
for the fixture judgments (the Dart binding's side of that parity is
`bindings/dart/search_simpli/test/parity_test.dart`).

Finding the binary as `test_cli_process.py` does: `$SEARCHD_BINARY`, else one
`zig build --prefix <tmp>`; `SEARCH_SIMPLI_NO_ZIG=1` (CI) skips."""

import base64
import hashlib
import json
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PACK = ROOT / "fixtures" / "family-folder"
ROOT_IDS = ("home", "laptop", "school")
PRIVATE_TEXT = "# Plans\n\nThe tide table hides a surprise party for Grandpa.\n"


def fixture_request() -> dict:
    """The fixture's three roots, every file as content_base64, plus the
    labelled `private` root."""
    request = {"roots": [], "changes": []}
    for root_id in ROOT_IDS:
        request["roots"].append({"root_id": root_id, "label": root_id.title(), "kind": "host"})
        base = PACK / root_id
        for path in sorted(p for p in base.rglob("*") if p.is_file()):
            request["changes"].append({
                "op": "add",
                "root_id": root_id,
                "path": path.relative_to(base).as_posix(),
                "content_base64": base64.b64encode(path.read_bytes()).decode("ascii"),
            })
    request["roots"].append({"root_id": "private", "label": "Private", "kind": "host", "required_labels": ["adults"]})
    request["changes"].append({
        "op": "add", "root_id": "private", "path": "plans.md",
        "content_base64": base64.b64encode(PRIVATE_TEXT.encode()).decode("ascii"),
    })
    return request


def build_searchd(scratch: Path) -> Path:
    override = os.environ.get("SEARCHD_BINARY")
    if override:
        return Path(override)
    if shutil.which("zig") is None:
        raise AssertionError("zig is not on PATH and SEARCHD_BINARY is not set")
    prefix = scratch / "prefix"
    built = subprocess.run(["zig", "build", "--prefix", str(prefix)], cwd=ROOT / "zig", capture_output=True, text=True)
    if built.returncode != 0:
        raise AssertionError("zig build failed:\n" + built.stderr)
    return prefix / "bin" / "searchd"


class Rpc:
    """One `searchd serve` process, one request per line."""

    def __init__(self, binary: Path, index: Path, *flags: str) -> None:
        self.process = subprocess.Popen(
            [str(binary), "serve", str(index), *flags],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
        )
        self.next_id = 0

    def raw(self, method: str, params: dict) -> str:
        self.next_id += 1
        line = json.dumps({"jsonrpc": "2.0", "id": self.next_id, "method": method, "params": params})
        self.process.stdin.write(line + "\n")
        self.process.stdin.flush()
        return self.process.stdout.readline()

    def call(self, method: str, params: dict) -> dict:
        return json.loads(self.raw(method, params))

    def result_text(self, method: str, params: dict) -> str:
        """The `result` member's bytes as the server wrote them."""
        line = self.raw(method, params)
        prefix = '{"jsonrpc":"2.0","id":%d,"result":' % self.next_id
        if not line.startswith(prefix):
            raise AssertionError(f"not a result: {line[:300]}")
        return line[len(prefix):].rstrip("\n")[:-1]

    def close(self) -> None:
        self.process.stdin.close()
        self.process.wait(timeout=30)
        self.process.stdout.close()
        self.process.stderr.close()


def overlaps(hit: dict, expected: dict) -> bool:
    return (hit["root_id"] == expected["root_id"] and hit["path"] == expected["path"]
            and hit["start_line"] <= expected["end_line"] and expected["start_line"] <= hit["end_line"])


class FolderSurfaceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        if os.environ.get("SEARCH_SIMPLI_NO_ZIG") == "1":
            raise unittest.SkipTest("SEARCH_SIMPLI_NO_ZIG=1: this environment deliberately has no Zig (CI)")
        cls.scratch_dir = tempfile.TemporaryDirectory()
        cls.scratch = Path(cls.scratch_dir.name)
        cls.binary = build_searchd(cls.scratch)
        cls.judgments = json.loads((PACK / "judgments.json").read_text(encoding="utf-8"))
        cls.request_file = cls.scratch / "changes.json"
        cls.request_file.write_text(json.dumps(fixture_request()), encoding="utf-8")
        cls.index = cls.scratch / "index"
        applied = cls.run_searchd("apply", str(cls.index), "--changes", str(cls.request_file), "--json")
        if applied.returncode != 0:
            raise AssertionError(applied.stderr)
        cls.report = json.loads(applied.stdout)

    @classmethod
    def tearDownClass(cls) -> None:
        cls.scratch_dir.cleanup()

    @classmethod
    def run_searchd(cls, *args: str) -> subprocess.CompletedProcess:
        return subprocess.run([str(cls.binary), *args], capture_output=True, text=True, stdin=subprocess.DEVNULL, timeout=120)

    def cli_json(self, *args: str) -> dict:
        result = self.run_searchd(*args, "--json")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stderr, "")
        return json.loads(result.stdout)

    def expect_failure(self, result: subprocess.CompletedProcess, status: int, needle: str) -> None:
        self.assertEqual(result.returncode, status, result.stdout + result.stderr)
        self.assertEqual(result.stdout, "")
        self.assertEqual(len(result.stderr.splitlines()), 1, result.stderr)
        self.assertIn(needle, result.stderr)

    # ------------------------------------------------------------- CLI ---

    def test_apply_report_counts_the_fixture(self) -> None:
        self.assertEqual(self.report["generation"], 1)
        self.assertEqual(self.report["added"], 43)
        self.assertEqual(self.report["rejected"], [])

    def test_cli_find_pages_every_phrase_and_prefix_judgment_completely(self) -> None:
        for case in self.judgments["phrase"] + self.judgments["prefix"]:
            hits, cursor = [], None
            while True:
                args = ["find", str(self.index), case["query"], "--mode", case["mode"], "--page-size", "2", "--roots", "home,laptop,school"]
                if cursor:
                    args += ["--cursor", cursor]
                page = self.cli_json(*args)
                self.assertLessEqual(len(page["hits"]), 2)
                self.assertEqual(page["empty"], not page["hits"])
                hits += page["hits"]
                cursor = page["next_cursor"]
                if cursor is None:
                    break
            self.assertEqual(len(hits), sum(f["hits"] for f in page["files"]), case["id"])
            expected = [e for e in case["expected"] if e not in case.get("expected_engine_miss", [])]
            for item in expected:
                self.assertTrue(any(overlaps(h, item) for h in hits), (case["id"], item))
            for hit in hits:
                self.assertTrue(any(overlaps(hit, e) for e in case["expected"]), (case["id"], hit))
            if case["mode"] == "phrase":
                self.assertEqual(page["exact_match"], bool(hits))

    def test_cli_find_human_output_and_scope(self) -> None:
        result = self.run_searchd("find", str(self.index), '"count me in"')
        self.assertEqual(result.returncode, 0, result.stderr)
        lines = result.stdout.splitlines()
        self.assertTrue(lines[0].startswith('find: "count me in" (mode phrase, generation 1): 3 hits in 3 files'), lines[0])
        self.assertTrue(lines[1].startswith("1. "), lines[1])
        # The CLI's scope holds no label: the labelled root is invisible.
        tide = self.cli_json("find", str(self.index), "tide table")
        self.assertNotIn("private", [h["root_id"] for h in tide["hits"]])
        self.assertEqual(tide["scope"]["roots"], ["home", "laptop", "school"])
        narrowed = self.cli_json("find", str(self.index), "tide table", "--roots", "school")
        self.assertEqual({h["root_id"] for h in narrowed["hits"]}, {"school"})
        self.assertEqual(narrowed["request"]["roots"], ["school"])

    def test_cli_outline_matches_every_outline_judgment(self) -> None:
        for case in self.judgments["outline"]:
            got = self.cli_json("outline", str(self.index), case["root_id"], case["path"])
            if "front_matter" in case:
                self.assertEqual(got["front_matter"], case["front_matter"], case["id"])
            self.assertEqual(got["headings"], case["headings"], case["id"])
            if "lines" in case:
                self.assertEqual(got["lines"], case["lines"], case["id"])
        human = self.run_searchd("outline", str(self.index), "school", "science-notes.md")
        self.assertEqual(human.returncode, 0)
        self.assertIn("  ## How plants make food (lines 12-33)", human.stdout)

    def test_cli_read_span_is_byte_exact_for_every_judgment(self) -> None:
        for case in self.judgments["read_span"]:
            got = self.cli_json("read-span", str(self.index), case["root_id"], case["path"],
                                str(case["start_line"]), str(case["end_line"]), "--context", str(case["context_lines"]))
            text = got["text"].encode("utf-8")
            self.assertEqual(len(text), case["byte_length"], case["id"])
            self.assertEqual(hashlib.sha256(text).hexdigest(), case["sha256"], case["id"])
            self.assertEqual(got["sha256"], case["sha256"], case["id"])
        # Human output is the bytes themselves, context included.
        raw = subprocess.run([str(self.binary), "read-span", str(self.index), "home", "crlf-shopping.md", "3", "4"],
                             capture_output=True, timeout=60)
        self.assertEqual(raw.returncode, 0)
        source = (PACK / "home" / "crlf-shopping.md").read_bytes()
        self.assertIn(b"\r\n", raw.stdout)
        self.assertEqual(raw.stdout, b"".join(source.splitlines(keepends=True)[2:4]))

    def test_cli_read_span_refusals_exit_1_with_one_line(self) -> None:
        self.expect_failure(self.run_searchd("read-span", str(self.index), "laptop", "big-log.txt", "1", "401"), 1, "SS_ERR_CAPACITY")
        self.expect_failure(self.run_searchd("read-span", str(self.index), "school", "nope.md", "1", "1"), 1, "SS_ERR_NOT_FOUND")
        # A hidden file reads exactly like an absent one.
        hidden = self.run_searchd("read-span", str(self.index), "private", "plans.md", "1", "1")
        absent = self.run_searchd("read-span", str(self.index), "private", "absent.md", "1", "1")
        self.assertEqual(hidden.stderr.replace("plans.md", "X"), absent.stderr.replace("absent.md", "X"))
        self.expect_failure(self.run_searchd("read-span", str(self.index), "school", "notes.md", "9", "3"), 2, "must be at least <start>")
        self.expect_failure(self.run_searchd("read-span", str(self.index), "school", "notes.md", "1", "2", "--context", "21"), 2, "--context")

    def test_cli_list_files_pages_and_filters(self) -> None:
        everything = self.cli_json("list-files", str(self.index), "--page-size", "1000")
        self.assertEqual(everything["total"], 42)
        self.assertNotIn("private", {f["root_id"] for f in everything["files"]})
        pages, cursor = [], None
        while True:
            args = ["list-files", str(self.index), "--page-size", "10"]
            if cursor:
                args += ["--cursor", cursor]
            page = self.cli_json(*args)
            pages += page["files"]
            cursor = page["next_cursor"]
            if cursor is None:
                break
        self.assertEqual(pages, everything["files"])
        recipes = self.cli_json("list-files", str(self.index), "--root", "home", "--prefix", "recipes/")
        self.assertTrue(recipes["files"])
        self.assertTrue(all(f["path"].startswith("recipes/") and f["root_id"] == "home" for f in recipes["files"]))
        big = next(f for f in everything["files"] if f["path"] == "big-log.txt")
        self.assertEqual(big["size"], (PACK / "laptop" / "big-log.txt").stat().st_size)
        self.assertIsNone(big["mtime_ms"])
        self.expect_failure(self.run_searchd("list-files", str(self.index), "--cursor", "9:0"), 1, "stale cursor")
        self.expect_failure(self.run_searchd("list-files", str(self.index), "--status", "gone"), 2, "--status")

    def test_cli_roots_and_usage_errors(self) -> None:
        roots = self.cli_json("roots", str(self.index))
        self.assertEqual([r["root_id"] for r in roots["roots"]], ["home", "laptop", "school"])
        human = self.run_searchd("roots", str(self.index))
        self.assertEqual(human.stdout.splitlines()[0], "home  Home  host  files=16 documents=48 pending=0")
        for args, needle in (
            (("find", str(self.index), "x", "--mode", "fuzzy"), "--mode"),
            (("find", str(self.index), "x", "--page-size", "0"), "--page-size"),
            (("find", str(self.index), "x", "--page-size", "101"), "--page-size"),
            (("find", str(self.index), "x", "--roots", "a,,b"), "--roots"),
            (("apply", str(self.index)), "--changes"),
            (("outline", str(self.index), "school"), "<path>"),
            (("roots", str(self.index), "--bogus"), "unknown flag for roots"),
        ):
            self.expect_failure(self.run_searchd(*args), 2, needle)
        self.expect_failure(self.run_searchd("find", str(self.index), "tide* table"), 1, "SS_ERR_INVALID_ARGUMENT: only the last token may end in *")
        # A missing index fails the work as `query` always has (exit 1; a
        # Debug build adds its error trace to stderr).
        missing = self.run_searchd("roots", str(self.scratch / "missing"))
        self.assertEqual(missing.returncode, 1)
        self.assertIn("FileNotFound", missing.stderr)

    def test_cli_apply_checks_the_generation_and_reports(self) -> None:
        index = self.scratch / "apply-copy"
        shutil.copytree(self.index, index)
        change = self.scratch / "one-change.json"
        change.write_text(json.dumps({"changes": [{"op": "remove", "root_id": "home", "path": "bills.txt"}]}), encoding="utf-8")
        self.expect_failure(self.run_searchd("apply", str(index), "--changes", str(change), "--expect-generation", "7"), 1, "stale: generation is 1")
        done = self.run_searchd("apply", str(index), "--changes", str(change), "--expect-generation", "1")
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertTrue(done.stdout.startswith("applied: generation=2 added=0 changed=0 removed=1"), done.stdout)
        file_change = self.scratch / "file-change.json"
        file_change.write_text(json.dumps({
            "roots": [{"root_id": "desk", "kind": "local", "path": str(PACK / "school")}],
            "changes": [{"op": "add", "root_id": "desk", "path": "notes.md", "file": str(PACK / "school" / "notes.md"),
                         "sha256": hashlib.sha256((PACK / "school" / "notes.md").read_bytes()).hexdigest()}],
        }), encoding="utf-8")
        self.expect_failure(self.run_searchd("apply", str(index), "--changes", str(file_change)), 1, "file reads are not enabled")
        allowed = self.run_searchd("apply", str(index), "--changes", str(file_change), "--allow-file-reads", "--json")
        self.assertEqual(allowed.returncode, 0, allowed.stderr)
        self.assertEqual(json.loads(allowed.stdout)["added"], 1)

    # ------------------------------------------------------------- RPC ---

    def test_rpc_methods_with_scope_paging_caps_and_errors(self) -> None:
        rpc = Rpc(self.binary, self.index, "--roots", "school,laptop,private")
        try:
            page = rpc.call("find", {"query": "tide table", "page_size": 1})["result"]
            self.assertEqual(page["scope"]["roots"], ["laptop", "school"])
            self.assertEqual(len(page["hits"]), 1)
            second = rpc.call("find", {"query": "tide table", "page_size": 1, "cursor": page["next_cursor"]})["result"]
            self.assertNotEqual(second["hits"][0]["chunk_id"], page["hits"][0]["chunk_id"])
            # A request may narrow the server's roots, never widen them.
            widened = rpc.call("find", {"query": "tide table", "roots": ["home", "school"]})["result"]
            self.assertEqual({h["root_id"] for h in widened["hits"]}, {"school"})
            outline = rpc.call("outline", {"root_id": "school", "path": "science-notes.md"})["result"]
            self.assertEqual(outline["lines"], 74)
            span = rpc.call("read_span", {"root_id": "laptop", "path": "big-log.txt", "start_line": 1, "end_line": 400})["result"]
            self.assertEqual(span["end_line"], 400)
            over = rpc.call("read_span", {"root_id": "laptop", "path": "big-log.txt", "start_line": 21, "end_line": 381, "context_lines": 20})
            self.assertEqual(over["error"]["code"], -32005)
            outside = rpc.call("read_span", {"root_id": "home", "path": "bills.txt", "start_line": 1, "end_line": 1})
            self.assertEqual(outside["error"], {"code": -32004, "message": "not indexed or not retained: home/bills.txt"})
            files = rpc.call("list_files", {"page_size": 5})["result"]
            self.assertEqual(files["total"], 26)
            self.assertEqual(files["next_cursor"], "1:5")
            stale = rpc.call("list_files", {"cursor": "2:5"})
            self.assertEqual(stale["error"], {"code": -32602, "message": "Invalid params: stale cursor"})
            roots = rpc.call("roots", {})["result"]
            self.assertEqual([r["root_id"] for r in roots["roots"]], ["laptop", "school"])
            status = rpc.call("index_status", {})["result"]
            self.assertEqual([r["root_id"] for r in status["roots"]], ["laptop", "school"])
            self.assertEqual(status["files"], 26)
            self.assertEqual(status["documents"], sum(r["documents"] for r in status["roots"]))
            self.assertTrue(status["has_source"] and status["has_positions"])
            for method, params in (
                ("find", {"query": "x", "bogus": 1}),
                ("outline", {"root_id": "school"}),
                ("read_span", {"root_id": "school", "path": "notes.md", "start_line": "1", "end_line": 2}),
                ("list_files", {"status": "gone"}),
                ("roots", {"roots": "school"}),
                ("find", {"query": "x", "page_size": 0}),
                ("index_status", {"extra": True}),
            ):
                self.assertEqual(rpc.call(method, params)["error"]["code"], -32602, (method, params))
            self.assertEqual(rpc.call("apply_changes", {"changes": []})["error"]["code"], -32601)
            knowledge = rpc.call("search_knowledge", {"query": "tide table", "retrieval_mode": "lexical", "top_k": 10})["result"]
            self.assertTrue(all(not r["citation"]["path"].startswith("home/") for r in knowledge["results"]))
        finally:
            rpc.close()

    def test_rpc_labels_come_from_the_command_line(self) -> None:
        raw = Rpc(self.binary, self.index)
        labelled = Rpc(self.binary, self.index, "--labels", "adults")
        try:
            # Without --labels the raw service keeps request labels, bounded as before.
            self.assertNotIn("private", [r["root_id"] for r in raw.call("roots", {})["result"]["roots"]])
            self.assertIn("private", [r["root_id"] for r in raw.call("roots", {"principal_labels": ["adults"]})["result"]["roots"]])
            self.assertEqual(raw.call("roots", {"principal_labels": ["a", "a"]})["error"]["code"], -32602)
            self.assertEqual(raw.call("search_knowledge", {"query": "x", "retrieval_mode": "lexical", "principal_labels": ["a"] * 65})["error"]["code"], -32602)
            self.assertEqual(raw.call("index_status", {})["result"]["files"], 42)
            # With --labels: the label is the server's; a request may not state one.
            self.assertIn("private", [h["root_id"] for h in labelled.call("find", {"query": "surprise party"})["result"]["hits"]])
            refused = labelled.call("find", {"query": "x", "principal_labels": ["adults"]})
            self.assertEqual(refused["error"]["code"], -32602)
            self.assertIn("principal_labels", refused["error"]["message"])
            self.assertEqual(labelled.call("search_knowledge", {"query": "x", "retrieval_mode": "lexical", "principal_labels": []})["error"]["code"], -32602)
            self.assertEqual(labelled.call("index_status", {})["result"]["files"], 43)
            hidden_id = labelled.call("find", {"query": "surprise party"})["result"]["hits"][0]["chunk_id"]
            self.assertEqual(raw.call("read_chunk", {"chunk_id": hidden_id})["error"]["code"], -32004)
            self.assertEqual(labelled.call("read_chunk", {"chunk_id": hidden_id})["result"]["chunk_id"], hidden_id)
        finally:
            raw.close()
            labelled.close()

    def test_rpc_apply_changes_only_with_allow_write_and_reads_see_it(self) -> None:
        index = self.scratch / "rpc-write"
        shutil.copytree(self.index, index)
        rpc = Rpc(self.binary, index, "--allow-write")
        try:
            before = rpc.call("roots", {})["result"]
            stale = rpc.call("apply_changes", {"expect_generation": 9, "changes": []})
            self.assertEqual(stale["error"], {"code": -32602, "message": "Invalid params: stale: generation is 1"})
            forged = rpc.call("apply_changes", {"changes": [], "principal_labels": ["adults"]})
            self.assertEqual(forged["error"]["code"], -32602)
            done = rpc.call("apply_changes", {"expect_generation": 1, "changes": [{"op": "remove", "root_id": "home", "path": "bills.txt"}]})["result"]
            self.assertEqual((done["generation"], done["removed"]), (2, 1))
            after = rpc.call("roots", {})["result"]
            self.assertEqual(after["generation"], 2)
            self.assertEqual(after["roots"][0]["files"], before["roots"][0]["files"] - 1)
            gone = rpc.call("read_span", {"root_id": "home", "path": "bills.txt", "start_line": 1, "end_line": 1})
            self.assertEqual(gone["error"]["code"], -32004)
        finally:
            rpc.close()

    # ---------------------------------------------------------- parity ---

    def test_cli_json_and_rpc_results_are_byte_identical_for_the_judgments(self) -> None:
        rpc = Rpc(self.binary, self.index)
        try:
            compared = 0
            for case in self.judgments["phrase"] + self.judgments["prefix"]:
                cli = self.run_searchd("find", str(self.index), case["query"], "--mode", case["mode"], "--page-size", "100", "--json")
                rpc_text = rpc.result_text("find", {"query": case["query"], "mode": case["mode"], "page_size": 100})
                self.assertEqual(cli.stdout.rstrip("\n"), rpc_text, case["id"])
                compared += 1
            for case in self.judgments["outline"]:
                cli = self.run_searchd("outline", str(self.index), case["root_id"], case["path"], "--json")
                self.assertEqual(cli.stdout.rstrip("\n"), rpc.result_text("outline", {"root_id": case["root_id"], "path": case["path"]}), case["id"])
                compared += 1
            for case in self.judgments["read_span"]:
                cli = self.run_searchd("read-span", str(self.index), case["root_id"], case["path"], str(case["start_line"]),
                                       str(case["end_line"]), "--context", str(case["context_lines"]), "--json")
                rpc_text = rpc.result_text("read_span", {k: case[k] for k in ("root_id", "path", "start_line", "end_line", "context_lines")})
                self.assertEqual(cli.stdout.rstrip("\n"), rpc_text, case["id"])
                compared += 1
            cli = self.run_searchd("list-files", str(self.index), "--json")
            self.assertEqual(cli.stdout.rstrip("\n"), rpc.result_text("list_files", {}))
            cli = self.run_searchd("roots", str(self.index), "--json")
            self.assertEqual(cli.stdout.rstrip("\n"), rpc.result_text("roots", {}))
            self.assertEqual(compared, 23)
        finally:
            rpc.close()


if __name__ == "__main__":
    unittest.main()
