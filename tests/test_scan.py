"""S6-T24: `scan` (CAP-25, docs/decisions/0006-pattern-search.md, docs/scan.md).

- `ReferenceTests`: the Python reference (`src/search_platform/scan.py`) alone: the rulings O-1 (`_` is not a
  word character), O-2 (`\\d` is Nd), O-8 (`\\t` accepted, `\\n` and `\\xHH` refused), smart case, the
  empty-match warning, and the index and folder sources giving the same hits.
- `EngineAgreementTests`: the reference against `searchd scan --folder --json` over a seeded generated folder
  (Tamil, combining marks, the fold's special letters, digits of several scripts, CRLF, a BOM) with a fixed
  list of patterns and seeded random literals taken from its lines. One divergence is recorded, with its
  reason, in `KNOWN_DIVERGENCES`, and the test checks that it still diverges (so a fix is noticed).
- `GrepAgreementTests`: literal and ASCII-case-insensitive scans against `grep -n -F` on an ASCII folder,
  with the exclusions recorded in `GREP_EXCLUSIONS`.
- `IndexAndFolderTests`: `searchd scan <index>` and `searchd scan --folder <folder>` over the same files give
  the same pages; the plain output, exit codes and refusals of the command line.
- `RpcSurfaceTests`: `scan` over `searchd serve`: field messages, an unknown field, the labelled root
  hidden without labels, request labels taken by a server without `--labels` and refused by one with them.

`SEARCH_SIMPLI_NO_ZIG=1` (CI) skips the classes that run `searchd`.
"""

from __future__ import annotations

import json
import os
import random
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO))
sys.path.insert(0, str(REPO / "tests"))

from src.search_platform import core, scan  # noqa: E402
from test_folder_surfaces import ROOT_IDS, Rpc, build_searchd, fixture_request  # noqa: E402

NO_ZIG = os.environ.get("SEARCH_SIMPLI_NO_ZIG") == "1"
SEED = 2024_11_23

# Patterns on which the engine and the reference are known to differ, with the reason. Each is excluded from
# the agreement check and checked to still differ on its line.
KNOWN_DIVERGENCES = {
    "(|a)*": ("aa", "an empty alternative first inside a repeat: Python's `re` lists [0,1],[1,2] (it retries the "
                    "repeat after an empty iteration), the engine's Pike VM lists [0,2] (an empty iteration ends "
                    "the repeat, then the next match starts at the same place and takes `a` twice)"),
}

# What `grep -n -F` and `scan` count differently, and how the grep folder avoids it.
GREP_EXCLUSIONS = (
    "line breaks other than LF (CR, VT, FF, NEL, LS, PS end a line for scan, not for grep): the folder has LF only",
    "a leading BOM (not part of line 1 for scan): no file starts with one",
    "whole_word and \\b (grep's word characters include `_`; scan's do not, ruling O-1): not compared",
    "case-insensitive matching beyond ASCII (grep's depends on the locale): ASCII text only",
    "lines over 512 bytes (scan cuts `text`, not the match decision): lines are short",
)

PIECES = (
    "the", "tide", "pool", "TS-0142", "ts-0142", "142.50", "42,5", "tide_pool", "snake_case", "x", "ab", "ba",
    "café", "CAFÉ", "café", "naïve", "ß", "SS", "ẞ", "İstanbul", "ıi", "ſ", "K", "K", "Ω", "Ω",
    "Σίσυφος", "ΣΙΣΥΦΟΣ", "ǅ", "ǆ", "தமிழ்", "பள்ளி", "௧௨௩", "٣٤", "²", "Ⅻ", "a‍b", "\t", "  ", " ",
    "!", "(", ")", "[", "]", "-", "_", "$", "日本語", "123", "0", "Z",
)

PATTERNS = (
    ("\\d+", "regex"), ("\\w+", "regex"), ("\\b\\w{2}\\b", "regex"), ("[A-Z][a-z]+", "regex"),
    ("T[S-T]-\\d{4}", "regex"), ("\\s+$", "regex"), ("^\\W", "regex"), ("(ab|ba)+", "regex"), ("[^\\w\\s]", "regex"),
    ("x?", "regex"), ("ß", "literal"), ("\\bthe\\b", "regex"), ("\\D\\d", "regex"), ("\\S{3,5}", "regex"),
    ("[ά-ώ]+", "regex"), ("த.ி", "regex"), ("\\t", "regex"), ("\\n", "regex"), ("\\x41", "regex"), ("a(", "regex"),
    ("a{256}", "regex"), ("(a", "regex"), ("[z-a]", "regex"), ("a**", "regex"), (".", "regex"), ("^$", "regex"),
    ("\\w_\\w", "regex"), ("_", "literal"), ("snake_case", "literal"), ("K", "literal"), ("k", "literal"),
    ("σ", "literal"), ("STRASSE", "literal"), ("ǆ", "literal"), ("(a|ab)(c|bcd)", "regex"), ("a|", "regex"),
)


def generate_folder(root: Path, seed: int = SEED) -> None:
    rng = random.Random(seed)
    for number in range(12):
        lines = []
        for _ in range(rng.randint(5, 40)):
            lines.append("".join(rng.choice(PIECES) + rng.choice(("", " ", " ", "_", "-")) for _ in range(rng.randint(0, 9))))
        text = "\n".join(lines) + rng.choice(("", "\n"))
        data = text.encode("utf-8")
        if number % 4 == 1:
            data = data.replace(b"\n", b"\r\n")
        if number == 2:
            data = b"\xef\xbb\xbf" + data
        sub = root / ("deep" if number % 3 == 0 else "") / f"n{number:02d}.txt"
        sub.parent.mkdir(parents=True, exist_ok=True)
        sub.write_bytes(data)


def random_literals(root: Path, count: int, seed: int = SEED) -> list[dict]:
    rng = random.Random(seed + 1)
    lines = [line for path in sorted(root.rglob("*.txt")) for line in path.read_bytes().decode("utf-8-sig").splitlines() if line.strip()]
    out = []
    for _ in range(count):
        line = rng.choice(lines)
        start = rng.randrange(len(line))
        piece = line[start:start + rng.randint(1, 6)]
        out.append({"pattern": piece, "case": rng.choice(("sensitive", "insensitive", "smart")),
                    "whole_word": rng.random() < 0.25})
    return out


def reference_all(root: Path, params: dict) -> dict:
    """Every page of the reference's folder scan, joined: the hits and the summed counts."""
    return _join(lambda cursor: scan.scan_folder(root, {**params, "page_size": 100, "max_hits_per_file": 1000,
                                                         "time_budget_ms": 30_000, "cursor": cursor}))


def _join(page_of) -> dict:
    hits, counts, cursor, first = [], {"files_scanned": 0, "files_matched": 0, "files_capped": 0, "bytes_scanned": 0}, None, None
    while True:
        page = page_of(cursor)
        first = first or page
        hits.extend(page["hits"])
        for key in counts:
            counts[key] += page[key]
        cursor = page["next_cursor"]
        if cursor is None:
            break
    return {"hits": hits, **counts, "case_applied": first["case_applied"], "warnings": first["warnings"]}


def comparable(answer: dict) -> object:
    if "refused" in answer:
        return answer["refused"]
    return {"hits": [(h["root_id"], h["path"], h["line"], h["text"], h["text_truncated"], h["match_offsets"],
                      h["before"], h["after"]) for h in answer["hits"]],
            **{key: answer[key] for key in ("files_scanned", "files_matched", "files_capped", "bytes_scanned",
                                            "case_applied", "warnings")}}


class ReferenceTests(unittest.TestCase):
    def test_underscore_is_not_a_word_character_ruling_o1(self) -> None:
        compiled = scan.compile_pattern("\\w+", "regex")
        self.assertEqual(scan.match_line(compiled, "tide_pool", 9), (True, [[0, 4], [5, 9]]))
        word = scan.compile_pattern("tide", "literal", whole_word=True)
        self.assertTrue(scan.match_line(word, "tide_pool", 9)[0])  # `_` is a boundary
        self.assertFalse(scan.match_line(word, "tidepool", 8)[0])
        # Marks Mn and Mc and ZWJ are word characters: the Tamil word is one match.
        self.assertEqual(scan.match_line(compiled, "தமிழ் x", 7)[1], [[0, 5], [6, 7]])

    def test_digit_is_nd_ruling_o2(self) -> None:
        digits = scan.compile_pattern("\\d+", "regex")
        self.assertEqual(scan.match_line(digits, "௧௨௩ ٣٤ ² Ⅻ 7", 12)[1], [[0, 3], [4, 6], [11, 12]])

    def test_escapes_ruling_o8(self) -> None:
        self.assertTrue(scan.match_line(scan.compile_pattern("a\\tb", "regex"), "a\tb", 3)[0])
        for pattern, reason in (("a\\n", "pattern not supported at byte 1: \\n cannot match: a line holds no line break"),
                                ("\\x41", "pattern not supported at byte 0: \\x escapes are not supported")):
            with self.assertRaises(scan.ScanError) as caught:
                scan.compile_pattern(pattern, "regex")
            self.assertEqual(caught.exception.code, "invalid_argument")
            self.assertIn(reason.split(": ", 1)[0], str(caught.exception))

    def test_smart_case(self) -> None:
        self.assertEqual(scan.compile_pattern("tide").case_applied, "insensitive")
        self.assertEqual(scan.compile_pattern("Tide").case_applied, "sensitive")
        self.assertEqual(scan.compile_pattern("\\d", "regex").case_applied, "insensitive")
        self.assertEqual(scan.compile_pattern("Σ").case_applied, "sensitive")
        # The fold is one code point to one: ẞ's fold is "ss" (two), so ẞ does not change, is insensitive,
        # and matches neither ß nor ss (docs/scan.md).
        self.assertEqual(scan.compile_pattern("ẞ").case_applied, "insensitive")
        self.assertEqual(scan.match_line(scan.compile_pattern("ẞ"), "ß ss ẞ", 6)[1], [[5, 6]])

    def test_empty_match_warns_and_lists_no_offsets(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            Path(tmp, "a.txt").write_text("one\n\ntwo\n", encoding="utf-8")
            answer = scan.scan_folder(Path(tmp), {"pattern": "x?", "mode": "regex"})
        self.assertEqual([h["line"] for h in answer["hits"]], [1, 2, 3])
        self.assertEqual([h["match_offsets"] for h in answer["hits"]], [[], [], []])
        self.assertEqual(answer["warnings"], [{"code": "pattern_matches_empty", "message": scan.EMPTY_MATCH_MESSAGE}])

    def test_index_and_folder_give_the_same_hits(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "folder"
            generate_folder(root)
            index = core.build_index(root)
            for params in ({"pattern": "tide"}, {"pattern": "\\d+", "mode": "regex", "context_lines": 2}):
                by_index = _join(lambda cursor: scan.scan(index, {**params, "page_size": 7, "cursor": cursor}))
                by_folder = _join(lambda cursor: scan.scan_folder(root, {**params, "page_size": 7, "cursor": cursor}))
                self.assertEqual(comparable(by_index), comparable(by_folder))
                self.assertGreater(len(by_folder["hits"]), 7)

    def test_a_cursor_from_another_request_is_refused(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            Path(tmp, "a.txt").write_text("tide\ntide\n", encoding="utf-8")
            page = scan.scan_folder(Path(tmp), {"pattern": "tide", "page_size": 1})
            with self.assertRaises(scan.ScanError) as caught:
                scan.scan_folder(Path(tmp), {"pattern": "pool", "cursor": page["next_cursor"]})
            self.assertEqual(str(caught.exception), "cursor does not belong to this request")


@unittest.skipIf(NO_ZIG, "SEARCH_SIMPLI_NO_ZIG=1: this environment deliberately has no Zig (CI)")
class EngineAgreementTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.scratch_dir = tempfile.TemporaryDirectory()
        cls.scratch = Path(cls.scratch_dir.name)
        cls.binary = build_searchd(cls.scratch)
        cls.folder = cls.scratch / "folder"
        generate_folder(cls.folder)

    @classmethod
    def tearDownClass(cls) -> None:
        cls.scratch_dir.cleanup()

    def engine_all(self, params: dict) -> dict:
        def page_of(cursor):
            args = [str(self.binary), "scan", "--folder", str(self.folder), params["pattern"], "--json",
                    "--page-size", "100", "--max-per-file", "1000", "--time-ms", "30000"]
            if params.get("mode") == "regex":
                args.append("--regex")
            if params.get("case"):
                args += ["--case", params["case"]]
            if params.get("whole_word"):
                args.append("--word")
            if params.get("context_lines"):
                args += ["--context", str(params["context_lines"])]
            if cursor:
                args += ["--cursor", cursor]
            done = subprocess.run(args, capture_output=True, stdin=subprocess.DEVNULL, timeout=120)
            if done.returncode != 0:
                raise scan.ScanError("invalid_argument", done.stderr.decode("utf-8").strip().split(": ", 2)[-1])
            return json.loads(done.stdout)
        try:
            return _join(page_of)
        except scan.ScanError as error:
            return {"refused": str(error)}

    def reference(self, params: dict) -> dict:
        try:
            return reference_all(self.folder, params)
        except scan.ScanError as error:
            return {"refused": str(error)}

    def test_fixed_patterns_and_seeded_literals_agree(self) -> None:
        cases = [{"pattern": p, "mode": m, "case": c} for p, m in PATTERNS for c in ("sensitive", "insensitive", "smart")]
        cases += [{"pattern": "tide", "whole_word": True, "context_lines": 2}, {"pattern": "\\w+", "mode": "regex", "whole_word": True}]
        cases += random_literals(self.folder, 60)
        hits = refusals = 0
        for params in cases:
            if params["pattern"] in KNOWN_DIVERGENCES:
                continue
            engine, reference = self.engine_all(params), self.reference(params)
            self.assertEqual(comparable(engine), comparable(reference), json.dumps(params, ensure_ascii=False))
            refusals += "refused" in engine
            hits += len(engine.get("hits", []))
        print(f"S6-T24 agreement: {len(cases)} cases, {refusals} refused alike, {hits} hit lines identical", file=sys.stderr)
        self.assertGreater(hits, 1000)
        self.assertGreater(refusals, 10)

    def test_known_divergences_still_diverge(self) -> None:
        for pattern, (line, _reason) in KNOWN_DIVERGENCES.items():
            with tempfile.TemporaryDirectory() as tmp:
                Path(tmp, "a.txt").write_text(line + "\n", encoding="utf-8")
                reference = scan.scan_folder(Path(tmp), {"pattern": pattern, "mode": "regex"})
                done = subprocess.run([str(self.binary), "scan", "--folder", tmp, pattern, "--regex", "--json"],
                                      capture_output=True, stdin=subprocess.DEVNULL, timeout=60)
                engine = json.loads(done.stdout)
            self.assertEqual(reference["hits"][0]["match_offsets"], [[0, 1], [1, 2]])
            self.assertEqual(engine["hits"][0]["match_offsets"], [[0, 2]])


@unittest.skipIf(shutil.which("grep") is None, "no grep")
class GrepAgreementTests(unittest.TestCase):
    def test_literal_lines_match_grep(self) -> None:
        rng = random.Random(SEED + 2)
        words = ("tide", "pool", "TS-0142", "142.50", "the", "Tide", "a", "ab", "x.y", "[x]", "$", "*", "-")
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            for number in range(6):
                lines = [" ".join(rng.choice(words) for _ in range(rng.randint(0, 8))) for _ in range(rng.randint(10, 60))]
                (root / f"g{number}.txt").write_text("\n".join(lines) + "\n", encoding="ascii")
            compared = 0
            for pattern in words:
                for case in ("sensitive", "insensitive"):
                    answer = reference_all(root, {"pattern": pattern, "case": case})
                    ours = sorted((h["path"], h["line"]) for h in answer["hits"])
                    flags = ["-n", "-F"] + (["-i"] if case == "insensitive" else [])
                    theirs = []
                    for path in sorted(root.glob("*.txt")):
                        done = subprocess.run(["grep", *flags, "-e", pattern, str(path)], capture_output=True, text=True,
                                              env={**os.environ, "LC_ALL": "C"})
                        theirs += [(path.name, int(line.split(":", 1)[0])) for line in done.stdout.splitlines()]
                    self.assertEqual(ours, sorted(theirs), (pattern, case))
                    compared += len(ours)
            self.assertGreater(compared, 300)
        self.assertEqual(len(GREP_EXCLUSIONS), 5)


@unittest.skipIf(NO_ZIG, "SEARCH_SIMPLI_NO_ZIG=1: this environment deliberately has no Zig (CI)")
class IndexAndFolderTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.scratch_dir = tempfile.TemporaryDirectory()
        cls.scratch = Path(cls.scratch_dir.name)
        cls.binary = build_searchd(cls.scratch)
        cls.folder = cls.scratch / "folder"
        generate_folder(cls.folder)
        cls.index = cls.scratch / "index"
        cls.run_searchd("index", str(cls.folder), "--out", str(cls.index))

    @classmethod
    def tearDownClass(cls) -> None:
        cls.scratch_dir.cleanup()

    @classmethod
    def run_searchd(cls, *args: str, code: int = 0) -> subprocess.CompletedProcess:
        done = subprocess.run([str(cls.binary), *args], capture_output=True, text=True, stdin=subprocess.DEVNULL, timeout=120)
        if done.returncode != code:
            raise AssertionError(f"{args}: exit {done.returncode}, expected {code}\n{done.stderr}")
        return done

    def pages(self, *where: str, pattern: str, extra: tuple = ()) -> list[list]:
        out, cursor = [], None
        while True:
            args = ["scan", *where, pattern, "--json", "--page-size", "7", *extra] + (["--cursor", cursor] if cursor else [])
            page = json.loads(self.run_searchd(*args).stdout)
            out.append([(h["root_id"], h["path"], h["line"], h["text"], h["match_offsets"], h["before"], h["after"])
                        for h in page["hits"]])
            cursor = page["next_cursor"]
            if cursor is None:
                return out

    def test_index_and_folder_pages_are_the_same(self) -> None:
        for pattern, extra in (("tide", ()), ("\\d+", ("--regex", "--context", "1")), ("ß", ("--case", "insensitive"))):
            by_index = self.pages(str(self.index), pattern=pattern, extra=extra)
            by_folder = self.pages("--folder", str(self.folder), pattern=pattern, extra=extra)
            self.assertEqual(by_index, by_folder, pattern)
            self.assertGreater(len(by_index), 1, pattern)

    def test_plain_output_and_exit_codes(self) -> None:
        done = self.run_searchd("scan", "--folder", str(self.folder), "TS-0142", "--case", "sensitive")
        reference = reference_all(self.folder, {"pattern": "TS-0142", "case": "sensitive"})
        lines = done.stdout.splitlines()
        expected = [f"{h['path']}:{h['line']}:{h['text']}" for h in reference["hits"]][:20]
        self.assertEqual(lines, expected)
        self.assertGreater(len(lines), 1)
        paged = self.run_searchd("scan", "--folder", str(self.folder), "TS-0142", "--case", "sensitive", "--page-size", "1")
        self.assertIn("next page: --cursor f", paged.stderr)
        context = self.run_searchd("scan", "--folder", str(self.folder), "TS-0142", "--context", "1", "--page-size", "2").stdout
        self.assertIn("\n--\n", context)
        self.assertRegex(context, r"(?m)^[^:\n]+-\d+-")
        self.assertIn("missing argument", self.run_searchd("scan", "--folder", str(self.folder), code=2).stderr)
        self.assertIn("expected a whole number 1-100",
                      self.run_searchd("scan", str(self.index), "x", "--page-size", "101", code=2).stderr)
        self.assertIn("pattern not supported at byte 1: ",
                      self.run_searchd("scan", str(self.index), "a(", "--regex", code=1).stderr)
        self.assertIn("--max-file-bytes", self.run_searchd("scan", str(self.index), "x", "--max-file-bytes", "10", code=2).stderr)
        small = json.loads(self.run_searchd("scan", "--folder", str(self.folder), "x", "--max-file-bytes", "10", "--json").stdout)
        self.assertEqual(small["not_scanned"]["too_large"], 12)
        self.assertTrue(small["truncated"])

    def test_a_folder_cursor_sees_an_added_file_ruling_o4(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            Path(tmp, "a.txt").write_text("tide\ntide\n", encoding="utf-8")
            first = json.loads(self.run_searchd("scan", "--folder", tmp, "tide", "--json", "--page-size", "1").stdout)
            Path(tmp, "b.txt").write_text("tide\n", encoding="utf-8")
            done = self.run_searchd("scan", "--folder", tmp, "tide", "--json", "--cursor", first["next_cursor"], code=1)
            self.assertIn("stale cursor", done.stderr)


@unittest.skipIf(NO_ZIG, "SEARCH_SIMPLI_NO_ZIG=1: this environment deliberately has no Zig (CI)")
class RpcSurfaceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.scratch_dir = tempfile.TemporaryDirectory()
        cls.scratch = Path(cls.scratch_dir.name)
        cls.binary = build_searchd(cls.scratch)
        changes = cls.scratch / "changes.json"
        changes.write_text(json.dumps(fixture_request()), encoding="utf-8")
        cls.index = cls.scratch / "index"
        subprocess.run([str(cls.binary), "apply", str(cls.index), "--changes", str(changes)], check=True,
                       capture_output=True, stdin=subprocess.DEVNULL, timeout=120)

    @classmethod
    def tearDownClass(cls) -> None:
        cls.scratch_dir.cleanup()

    def test_field_messages(self) -> None:
        rpc = Rpc(self.binary, self.index)
        try:
            for params, message in (
                ({"pattern": "tide", "bogus": 1}, "unknown field \"bogus\""),
                ({}, "pattern is required"),
                ({"pattern": ""}, "pattern must be 1..1024 bytes"),
                ({"pattern": "x", "mode": "glob"}, "mode must be literal or regex"),
                ({"pattern": "x", "case": "upper"}, "case must be sensitive, insensitive or smart"),
                ({"pattern": "x", "page_size": 101}, "page_size must be 1..100"),
                ({"pattern": "x", "context_lines": 21}, "context_lines must be 0..20"),
                ({"pattern": "x", "max_hits_per_file": 1001}, "max_hits_per_file must be 1..1000"),
                ({"pattern": "x", "time_budget_ms": 30001}, "time_budget_ms must be 1..30000"),
                ({"pattern": "x", "cursor": "nope"}, "malformed cursor"),
            ):
                error = rpc.call("scan", params).get("error")
                self.assertIsNotNone(error, params)
                self.assertIn(message, error["message"], params)
        finally:
            rpc.close()

    def test_labelled_root_is_hidden_without_labels(self) -> None:
        plain = Rpc(self.binary, self.index)
        labelled = Rpc(self.binary, self.index, "--labels", "adults")
        try:
            hidden = plain.call("scan", {"pattern": "surprise party"})["result"]
            seen = labelled.call("scan", {"pattern": "surprise party"})["result"]
            # A server without --labels takes the host's labels from the request (as every RPC method);
            # a server with --labels refuses them.
            raw = plain.call("scan", {"pattern": "surprise party", "principal_labels": ["adults"]})["result"]
            forged = labelled.call("scan", {"pattern": "surprise party", "principal_labels": ["adults"]})
        finally:
            plain.close()
            labelled.close()
        self.assertEqual(hidden["hits"], [])
        self.assertNotIn("private", hidden["scope"]["roots"])
        self.assertEqual([h["root_id"] for h in seen["hits"]], ["private"])
        self.assertEqual(raw["hits"], seen["hits"])
        self.assertIn("principal_labels", forged["error"]["message"])
        self.assertEqual(hidden["files_scanned"], seen["files_scanned"] - 1)
        self.assertEqual(sorted(ROOT_IDS), sorted(r for r in hidden["scope"]["roots"]))


if __name__ == "__main__":
    unittest.main()
