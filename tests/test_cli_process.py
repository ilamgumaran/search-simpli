"""S1-T8 criterion 3 pin: run the real `searchd` binary and read its exit
statuses, so a usage error (2), a failure of the work (1) and `--help` (stdout,
0) cannot drift together. Zig unit tests cannot see `main.zig`'s exit paths.

Finding the binary: `$SEARCHD_BINARY` if set; otherwise one `zig build
--prefix <tmp>` (Debug) of `zig/`, which needs `zig` on PATH (the env file
puts it there). The test fails, not skips, if neither is available, with one
exception: `SEARCH_SIMPLI_NO_ZIG=1`, which the CI workflow sets because its runner
deliberately has no Zig. Only that explicit opt-out skips; nothing implicit does."""

import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


class CliProcessTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        if os.environ.get("SEARCH_SIMPLI_NO_ZIG") == "1":
            raise unittest.SkipTest(
                "SEARCH_SIMPLI_NO_ZIG=1: this environment deliberately has no Zig (CI); "
                "run locally with the pinned toolchain"
            )
        cls.scratch = tempfile.TemporaryDirectory()
        override = os.environ.get("SEARCHD_BINARY")
        if override:
            cls.binary = Path(override)
        else:
            if shutil.which("zig") is None:
                raise AssertionError("zig is not on PATH and SEARCHD_BINARY is not set")
            prefix = Path(cls.scratch.name) / "prefix"
            built = subprocess.run(
                ["zig", "build", "--prefix", str(prefix)],
                cwd=ROOT / "zig", capture_output=True, text=True,
            )
            if built.returncode != 0:
                raise AssertionError("zig build failed:\n" + built.stderr)
            cls.binary = prefix / "bin" / "searchd"
        if not cls.binary.is_file():
            raise AssertionError(f"no searchd binary at {cls.binary}")

    @classmethod
    def tearDownClass(cls) -> None:
        cls.scratch.cleanup()

    def run_searchd(self, *args: str) -> subprocess.CompletedProcess:
        return subprocess.run(
            [str(self.binary), *args], capture_output=True, text=True,
            stdin=subprocess.DEVNULL, timeout=60,
        )

    def test_usage_error_exits_2_with_exactly_one_stderr_line(self) -> None:
        result = self.run_searchd("frobnicate")
        self.assertEqual(result.returncode, 2)
        self.assertEqual(result.stdout, "")
        self.assertEqual(len(result.stderr.splitlines()), 1, result.stderr)

    def test_invalid_value_exits_2_before_any_work(self) -> None:
        out = Path(self.scratch.name) / "generation-zero-out"
        folder = Path(self.scratch.name) / "docs"
        folder.mkdir(exist_ok=True)
        (folder / "a.md").write_text("hello\n", encoding="utf-8")
        result = self.run_searchd("index", str(folder), "--out", str(out), "--generation", "0")
        self.assertEqual(result.returncode, 2)
        self.assertEqual(result.stdout, "")
        self.assertEqual(len(result.stderr.splitlines()), 1, result.stderr)
        self.assertFalse(out.exists(), "a usage error must not create --out")
        bench = self.run_searchd("benchmark", "1", "0", "1", "vector")
        self.assertEqual(bench.returncode, 2)
        self.assertEqual(len(bench.stderr.splitlines()), 1, bench.stderr)

    def test_work_failure_exits_1_not_2(self) -> None:
        missing = Path(self.scratch.name) / "no-such-snapshot"
        for command in ("query", "evidence"):
            result = self.run_searchd(command, str(missing), "x")
            self.assertEqual(result.returncode, 1, (command, result.stderr))
            self.assertEqual(result.stdout, "")
            self.assertIn("FileNotFound", result.stderr)

    def test_help_prints_to_stdout_and_exits_0(self) -> None:
        for flag in ("--help", "-h"):
            result = self.run_searchd(flag)
            self.assertEqual(result.returncode, 0, flag)
            self.assertIn("Commands:", result.stdout)
            self.assertEqual(result.stderr, "", flag)

    def test_unreadable_file_is_counted_not_a_failure_and_help_says_so(self) -> None:
        folder = Path(self.scratch.name) / "unreadable-docs"
        folder.mkdir(exist_ok=True)
        (folder / "a.md").write_text("hello\n", encoding="utf-8")
        locked = folder / "b.md"
        locked.write_text("secret\n", encoding="utf-8")
        locked.chmod(0)
        try:
            try:
                locked.read_bytes()
                self.skipTest("cannot make a file unreadable here (running as root?)")
            except PermissionError:
                pass
            result = self.run_searchd("index", str(folder), "--out", str(Path(self.scratch.name) / "unreadable-out"))
        finally:
            locked.chmod(0o644)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("unreadable=1", result.stdout)
        # The usage text must say what the binary does, not the opposite.
        text = self.run_searchd("--help").stdout.replace("\n", " ")
        self.assertNotIn("an unreadable file)", text)
        self.assertIn("An unreadable file inside the folder does not fail `index`: it exits 0 and counts the file in `unreadable`", " ".join(text.split()))

    def test_bare_invocation_prints_usage_to_stderr_and_exits_2(self) -> None:
        result = self.run_searchd()
        self.assertEqual(result.returncode, 2)
        self.assertEqual(result.stdout, "")
        self.assertIn("Commands:", result.stderr)

    def test_invalid_utf8_query_exits_2_with_one_line_and_serve_reports_an_error(self) -> None:
        """S2-T11: a query text that is not UTF-8 is a usage error, on both analyzers."""
        folder = Path(self.scratch.name) / "utf8-docs"
        folder.mkdir(exist_ok=True)
        (folder / "a.md").write_text("hybrid retrieval ranks documents\n", encoding="utf-8")
        for analyzer in ("v1", "v2"):
            snapshot = Path(self.scratch.name) / f"utf8-{analyzer}"
            built = self.run_searchd("index", str(folder), "--out", str(snapshot), "--analyzer", analyzer)
            self.assertEqual(built.returncode, 0, built.stderr)
            for command in ("query", "evidence"):
                for raw in (b"caf\xff", b"\x80", b"hybrid \xfe\xff"):
                    result = subprocess.run(
                        [str(self.binary), command, str(snapshot), raw],
                        capture_output=True, stdin=subprocess.DEVNULL, timeout=20,
                    )
                    self.assertEqual(result.returncode, 2, (analyzer, command, raw, result.stderr))
                    self.assertEqual(result.stdout, b"")
                    self.assertEqual(len(result.stderr.splitlines()), 1, result.stderr)
                    self.assertIn(b"not valid UTF-8", result.stderr)
            # serve: the JSON-RPC line is an error, never a result, and the server stays up.
            requests = (
                b'{"jsonrpc":"2.0","id":1,"method":"search_knowledge","params":{"query":"caf\xff"}}\n'
                b'{"jsonrpc":"2.0","id":2,"method":"search_knowledge","params":{"query":"caf\\udc00"}}\n'
                b'{"jsonrpc":"2.0","id":3,"method":"search_knowledge","params":{"query":"hybrid","retrieval_mode":"lexical"}}\n'
            )
            served = subprocess.run(
                [str(self.binary), "serve", str(snapshot)], input=requests,
                capture_output=True, timeout=20,
            )
            lines = served.stdout.splitlines()
            self.assertEqual(len(lines), 3, served.stdout)
            self.assertIn(b'"error"', lines[0])
            self.assertIn(b'"error"', lines[1])
            self.assertIn(b'"result"', lines[2])

    def test_lost_manifest_numbers_above_what_is_on_disk(self) -> None:
        """S2-T14: only generation 2 on disk and no MANIFEST -> the update
        publishes generation 3 (never 1), recovered=missing_manifest, and
        keep_generations 1 prunes generation 2 after the new MANIFEST."""
        import json

        base = Path(self.scratch.name) / "lost-manifest"
        folder = base / "docs"
        out = base / "out"
        folder.mkdir(parents=True)
        (folder / "a.md").write_text("alpha evidence about recovery\n", encoding="utf-8")

        def index(*extra: str) -> dict:
            result = self.run_searchd("index", str(folder), "--out", str(out), "--analyzer", "v2", *extra)
            self.assertEqual(result.returncode, 0, result.stderr)
            return json.loads(result.stdout) if extra else {}

        index()
        index("--update")
        (out / "MANIFEST").unlink()
        for name in ("documents-1.hybseg", "lexical-1.hyblex"):
            (out / name).unlink()
        report = index("--update")
        self.assertEqual(report["generation"], 3, f"expected 3, found {report['generation']}")
        self.assertEqual(report.get("recovered"), "missing_manifest")
        self.assertTrue((out / "documents-2.hybseg").exists())  # superseded, kept without the option

        (out / "MANIFEST").unlink()
        report = index("--update", "--keep-generations", "1")
        self.assertEqual(report["generation"], 4, f"expected 4, found {report['generation']}")
        self.assertEqual(sorted(p.name for p in out.glob("documents-*")), ["documents-4.hybseg"])

        # import-json: the payload names the generation; above the leftovers it
        # publishes and keep 1 prunes them.
        (out / "MANIFEST").unlink()
        payload = base / "p.json"
        payload.write_text(json.dumps({
            "format_version": 1, "generation": 5, "analyzer_id": "ascii-alnum-v1",
            "embedding_model_id": "none", "documents": [],
        }), encoding="utf-8")
        imported = self.run_searchd("import-json", str(out), str(payload), "--keep-generations", "1")
        self.assertEqual(imported.returncode, 0, imported.stderr)
        self.assertEqual(sorted(p.name for p in out.glob("documents-*")), ["documents-5.hybseg"])


if __name__ == "__main__":
    unittest.main()
