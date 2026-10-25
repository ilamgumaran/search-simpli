"""Exercise the filename field through real CLI and JSON-RPC processes.

The only skip is the explicit Python-only CI opt-out. Otherwise a missing Zig
toolchain or broken native build fails, as in test_cli_process.py.
"""

import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
FIXTURES = ROOT / "fixtures" / "filename-search"
CASES = json.loads((FIXTURES / "cases.json").read_text(encoding="utf-8"))
GOLDEN = json.loads((FIXTURES / "legacy-content-golden.json").read_text(encoding="utf-8"))


class FilenameCliTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if os.environ.get("SEARCH_SIMPLI_NO_ZIG") == "1":
            raise unittest.SkipTest("SEARCH_SIMPLI_NO_ZIG=1: native CLI deliberately unavailable")
        cls.binary_dir = tempfile.TemporaryDirectory()
        override = os.environ.get("SEARCHD_BINARY")
        if override:
            cls.binary = Path(override).resolve()
        else:
            if shutil.which("zig") is None:
                raise AssertionError("zig is not on PATH and SEARCHD_BINARY is not set")
            prefix = Path(cls.binary_dir.name) / "prefix"
            built = subprocess.run(
                ["zig", "build", "-j2", "--prefix", str(prefix)],
                cwd=ROOT / "zig", capture_output=True, text=True, timeout=180,
            )
            if built.returncode:
                raise AssertionError("zig build failed:\n" + built.stderr)
            cls.binary = prefix / "bin" / "searchd"
        if not cls.binary.is_file():
            raise AssertionError(f"no searchd binary at {cls.binary}")

    @classmethod
    def tearDownClass(cls):
        cls.binary_dir.cleanup()

    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory()
        self.addCleanup(self.scratch.cleanup)
        self.tmp = Path(self.scratch.name)

    def run_cli(self, *args):
        return subprocess.run(
            [str(self.binary), *map(str, args)], cwd=ROOT,
            capture_output=True, text=True, stdin=subprocess.DEVNULL, timeout=60,
        )

    def good_cli(self, *args):
        result = self.run_cli(*args)
        self.assertEqual(result.returncode, 0, (args, result.stderr, result.stdout))
        return result.stdout

    def index_fixtures(self, *, filename_index):
        output = self.tmp / ("with-filename" if filename_index else "body-only")
        args = ["index", FIXTURES / "corpus", "--out", output]
        if filename_index:
            args.append("--filename-index")
        self.good_cli(*args)
        return output

    def assert_real_span(self, result, root):
        path = result["citation"]["path"]
        source = (root / path).resolve()
        self.assertTrue(source.is_relative_to(root.resolve()), path)
        lines = source.read_text(encoding="utf-8").splitlines()
        first = result["citation"]["start_line"]
        last = result["citation"]["end_line"]
        self.assertGreaterEqual(first, 1)
        self.assertGreaterEqual(last, first)
        self.assertLessEqual(last, len(lines))
        self.assertEqual(result["content"], "\n".join(lines[first - 1:last]))
        self.assertTrue(result["chunk_id"])

    def rpc(self, snapshot, requests):
        input_text = "".join(json.dumps(request, ensure_ascii=False) + "\n" for request in requests)
        served = subprocess.run(
            [str(self.binary), "serve", str(snapshot)], input=input_text,
            cwd=ROOT, capture_output=True, text=True, timeout=60,
        )
        self.assertEqual(served.returncode, 0, served.stderr)
        try:
            replies = [json.loads(line) for line in served.stdout.splitlines()]
        except json.JSONDecodeError as exc:
            raise AssertionError(f"invalid JSON-RPC response: {served.stdout!r}") from exc
        self.assertEqual(len(replies), len(requests), served.stdout)
        return replies

    def test_six_frozen_filename_cases_have_real_navigation_passages(self):
        snapshot = self.index_fixtures(filename_index=True)
        for case in CASES["cases"]:
            with self.subTest(case=case["path"]):
                source = FIXTURES / "corpus" / case["path"]
                self.assertEqual(hashlib.sha256(source.read_bytes()).hexdigest(), case["sha256"])
                response = json.loads(self.good_cli(
                    "evidence", snapshot, case["query"], "--search-field", "filename"
                ))
                self.assertEqual(response["retrieval"]["search_field"], "filename")
                self.assertEqual(response["retrieval"]["filename_policy_id"], "filename-field-v1")
                self.assertTrue(response["answer_policy"]["filename_matches_are_navigation"])
                self.assertTrue(response["results"], response)
                hit = response["results"][0]
                self.assertEqual(hit["citation"]["path"], case["expected_top1"])
                self.assertEqual(hit["basename"], case["path"].split("/")[-1])
                self.assertEqual(hit["matched_in"], ["filename"])
                self.assertEqual(hit["ranking"]["filename"]["rank"], 1)
                self.assertIsNone(hit["ranking"]["lexical"]["rank"])
                self.assert_real_span(hit, FIXTURES / "corpus")
        for query in CASES["negative_queries"]:
            with self.subTest(negative=query):
                response = json.loads(self.good_cli(
                    "evidence", snapshot, query, "--search-field", "filename"
                ))
                self.assertEqual(response["results"], [])
        combined = json.loads(self.good_cli(
            "evidence", snapshot, "annual observation", "--search-field", "both"
        ))
        self.assertEqual(combined["retrieval"]["search_field"], "both")
        self.assertEqual(combined["results"][0]["citation"]["path"], "Annual_Budget_2026.md")
        self.assertEqual(combined["results"][0]["matched_in"], ["content", "filename"])
        self.assert_real_span(combined["results"][0], FIXTURES / "corpus")

    def test_default_content_bytes_and_frozen_golden_on_both_snapshots(self):
        body_only = self.index_fixtures(filename_index=False)
        enabled = self.index_fixtures(filename_index=True)
        for entry in GOLDEN["queries"].values():
            query = entry["query"]
            with self.subTest(query=query):
                old = self.good_cli("query", body_only, query, "--json", "--top-k", "10")
                new = self.good_cli("query", enabled, query, "--json", "--top-k", "10")
                self.assertEqual(new, old, "opt-in indexing changed default content bytes")
                self.assertEqual(
                    new,
                    self.good_cli("query", enabled, query, "--json", "--top-k", "10", "--search-field", "content"),
                )
                payload = json.loads(new)
                self.assertEqual(payload["analyzer_id"], entry["analyzer_id"])
                self.assertEqual(payload["results"], entry["results"])
                self.assertNotIn("search_field", payload)
                self.assertNotIn("filename_policy_id", payload)
                self.assertEqual(
                    self.good_cli("evidence", body_only, query),
                    self.good_cli("evidence", enabled, query),
                )

    def test_unavailable_field_and_rpc_mode_validation(self):
        body_only = self.index_fixtures(filename_index=False)
        enabled = self.index_fixtures(filename_index=True)
        missing = self.run_cli("evidence", body_only, "annual budget", "--search-field", "filename")
        self.assertEqual(missing.returncode, 1, missing.stderr)
        self.assertIn("FilenameIndexUnavailable", missing.stderr)
        self.assertIn("--filename-index", missing.stderr)
        requests = [
            {"jsonrpc": "2.0", "id": 1, "method": "index_status", "params": {}},
            {"jsonrpc": "2.0", "id": 2, "method": "search_knowledge", "params": {
                "query": "annual budget", "search_field": "filename"}},
            {"jsonrpc": "2.0", "id": 3, "method": "search_knowledge", "params": {
                "query": "annual budget", "search_field": "both", "retrieval_mode": "hybrid"}},
            {"jsonrpc": "2.0", "id": 4, "method": "search_knowledge", "params": {
                "query": "annual budget", "search_field": "filename", "retrieval_mode": "lexical"}},
        ]
        old = self.rpc(body_only, requests)
        new = self.rpc(enabled, requests)
        self.assertNotIn("filename_policy_id", old[0]["result"])
        self.assertEqual(new[0]["result"]["filename_policy_id"], "filename-field-v1")
        for response in (old, new):
            self.assertEqual(response[1]["error"]["code"], -32602)
            self.assertEqual(response[2]["error"]["code"], -32602)
        self.assertEqual(old[3]["error"]["code"], -32004)
        self.assertIn("--filename-index", old[3]["error"]["message"])
        self.assertEqual(new[3]["result"]["results"][0]["matched_in"], ["filename"])

    def test_python_v2_export_import_answers_filename_query(self):
        py_index = self.tmp / "python-index.json"
        interchange = self.tmp / "interchange.json"
        snapshot = self.tmp / "imported"
        self.good_python("search.py", "index", FIXTURES / "corpus", "--filename-index", "--out", py_index)
        self.good_python("export_zig.py", py_index, "--out", interchange, "--analyzer", "analyzer-v2")
        exported = json.loads(interchange.read_text(encoding="utf-8"))
        self.assertEqual(exported["format_version"], 2)
        self.assertEqual(exported["filename_policy_id"], "filename-field-v1")
        self.assertNotIn("filename_index", exported)
        self.good_cli("import-json", snapshot, interchange)
        for case in CASES["cases"]:
            with self.subTest(case=case["path"]):
                response = json.loads(self.good_cli(
                    "evidence", snapshot, case["query"], "--search-field", "filename"
                ))
                self.assertEqual(response["results"][0]["citation"]["path"], case["path"])
                self.assert_real_span(response["results"][0], FIXTURES / "corpus")

    def test_unsupported_hidden_and_empty_files_have_no_filename_hit(self):
        docs = self.tmp / "docs"
        docs.mkdir()
        (docs / "Valid_Note.md").write_text("A cited passage.\n", encoding="utf-8")
        (docs / "Invoice.pdf").write_bytes(b"not extracted")
        (docs / "Blank_File.md").write_text("", encoding="utf-8")
        hidden = docs / ".hidden"
        hidden.mkdir()
        (hidden / "Secret_Plan.md").write_text("private passage\n", encoding="utf-8")
        snapshot = self.tmp / "snapshot"
        self.good_cli("index", docs, "--out", snapshot, "--filename-index")
        for query in ("invoice", "blank", "secret"):
            with self.subTest(query=query):
                response = json.loads(self.good_cli(
                    "evidence", snapshot, query, "--search-field", "filename"
                ))
                self.assertEqual(response["results"], [])

    def good_python(self, script, *args):
        result = subprocess.run(
            [sys.executable, str(ROOT / script), *map(str, args)], cwd=ROOT,
            capture_output=True, text=True, timeout=60,
        )
        self.assertEqual(result.returncode, 0, (script, result.stderr, result.stdout))
        return result.stdout

    def test_incremental_refresh_and_separate_directory_migration(self):
        docs = self.tmp / "docs"
        docs.mkdir()
        (docs / "Old_Marker.md").write_text("unique old content\n", encoding="utf-8")
        (docs / "Removed_File.md").write_text("unrelated body\n", encoding="utf-8")
        snapshot = self.tmp / "snapshot"
        self.good_cli("index", docs, "--out", snapshot, "--filename-index")
        wrong_mode = self.run_cli("index", docs, "--out", snapshot)
        self.assertEqual(wrong_mode.returncode, 1, wrong_mode.stderr)
        self.assertIn("FilenameMigrationRequiresNewDirectory", wrong_mode.stderr)
        wrong_analyzer = self.run_cli("index", docs, "--out", snapshot, "--filename-index", "--analyzer", "v1")
        self.assertEqual(wrong_analyzer.returncode, 1, wrong_analyzer.stderr)
        self.assertIn("FilenameMigrationRequiresNewDirectory", wrong_analyzer.stderr)
        body_only = self.tmp / "body-only"
        self.good_cli("index", docs, "--out", body_only)
        enable_in_place = self.run_cli("index", docs, "--out", body_only, "--filename-index")
        self.assertEqual(enable_in_place.returncode, 1, enable_in_place.stderr)
        self.assertIn("FilenameMigrationRequiresNewDirectory", enable_in_place.stderr)
        (docs / "Old_Marker.md").rename(docs / "New_Marker.md")
        (docs / "New_Marker.md").write_text("unique new content\n", encoding="utf-8")
        (docs / "Removed_File.md").unlink()
        self.good_cli("index", docs, "--out", snapshot, "--update", "--filename-index")
        changed_content = json.loads(self.good_cli("evidence", snapshot, "unique new content"))
        self.assertEqual(changed_content["evidence"][0]["path"], "New_Marker.md")
        self.assertNotIn("unique old content", changed_content["evidence"][0]["content"])
        for query, expected in (("new marker", "New_Marker.md"), ("old", None), ("removed", None)):
            with self.subTest(query=query):
                response = json.loads(self.good_cli(
                    "evidence", snapshot, query, "--search-field", "filename"
                ))
                paths = [hit["citation"]["path"] for hit in response["results"]]
                if expected:
                    self.assertEqual(paths[0], expected)
                    self.assert_real_span(response["results"][0], docs)
                else:
                    self.assertEqual(paths, [])


if __name__ == "__main__":
    unittest.main()
