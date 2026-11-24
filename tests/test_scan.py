"""S6-T24: `scan` (CAP-25, docs/decisions/0006-pattern-search.md, docs/scan.md).

- `ReferenceTests`: the Python reference (`src/search_platform/scan.py`) alone: the rulings O-1 (`_` is not a
  word character), O-2 (`\\d` is Nd), O-8 (`\\t` accepted, `\\n` and `\\xHH` refused), smart case, the
  empty-match warning, and the index and folder sources giving the same hits.
- `EngineAgreementTests`: the reference against `searchd scan --folder --json` over a seeded generated folder
  (Tamil, combining marks, the fold's special letters, digits of several scripts, CRLF, a BOM) with a fixed
  list of patterns and seeded random literals taken from its lines. The stated divergence (docs/scan.md, "Known
  differences"; rework 1, ruling 6) is a class, `scan.offsets_may_differ`: on those patterns only the hit lines
  and the counts are compared, and the test checks that the class's examples still diverge (so a fix is noticed).
- `GrepAgreementTests`: literal and ASCII-case-insensitive scans against `grep -n -F` on an ASCII folder,
  with the exclusions recorded in `GREP_EXCLUSIONS`.
- `IndexAndFolderTests`: `searchd scan <index>` and `searchd scan --folder <folder>` over the same files give
  the same pages; the plain output, exit codes and refusals of the command line.
- `BudgetTests`: rework 1's rulings 1-3 and 5 through the command line and `searchd serve`: nested empty repeats
  at `--time-ms 1` (a `status` call queued behind), the listing of `a(.*b)?` linear in the line, a literal that
  stops on time inside a 10 MiB file, the refusal naming its cause.
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
import time
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO))
sys.path.insert(0, str(REPO / "tests"))

from src.search_platform import core, scan  # noqa: E402
from test_folder_surfaces import ROOT_IDS, Rpc, build_searchd, fixture_request  # noqa: E402

NO_ZIG = os.environ.get("SEARCH_SIMPLI_NO_ZIG") == "1"
SEED = 2024_11_23

# The stated divergence (docs/scan.md, "Known differences from the Python reference"): a regex holding a repeat
# with no upper bound, or one above 1, whose body can match the empty string (`scan.offsets_may_differ`). The
# engine and the reference agree on which lines match and on every count, and may differ on `match_offsets` and
# so on where a cut `text` ends (the cap of 16 matches a line). Examples: the first is checked to still differ
# on its line; the other two are the verifier's (S6-T24 Verdict, finding 6), from its generated folder.
DIVERGENT_EXAMPLES = (
    ("(|a)*", "aa"),
    ("b [a-cßa-c]{1,3}|$.(?:s(?:ßé{0,2}|[ka]?.{0,2}|^)?İ)*|[ckk].{2}((?:1|Bé){0,2}(?:\\ds{1,3}){1,}|٣{0,2}|.*)+", None),
    ("(|_.{1,3}(.{0,2}[^0-9a-ck] |(1B7){0,2}|.$$))+|é$|.", None),
)

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
    ("x*", "regex"), ("x*\\w?", "regex"), ("\\b", "regex"),
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


def comparable(answer: dict, lines_only: bool = False) -> object:
    if "refused" in answer:
        return answer["refused"]
    if lines_only:
        hits = [(h["root_id"], h["path"], h["line"], h["before"], h["after"]) for h in answer["hits"]]
    else:
        hits = [(h["root_id"], h["path"], h["line"], h["text"], h["text_truncated"], h["matches_truncated"],
                 h["match_offsets"], h["before"], h["after"]) for h in answer["hits"]]
    return {"hits": hits,
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

    def test_the_fold_tables_exceptions_ruling_7(self) -> None:
        # The schema and docs/scan.md name them: the code points that simple case folding changes (their lowercase
        # is one other code point) but whose full folding is longer, so the one-to-one table leaves them alone.
        exceptions = [cp for cp in range(0x110000) if len(chr(cp).casefold()) > 1
                      and len(chr(cp).lower()) == 1 and chr(cp).lower() != chr(cp)]
        expected = [0x1E9E, *range(0x1F88, 0x1F90), *range(0x1F98, 0x1FA0), *range(0x1FA8, 0x1FB0), 0x1FBC, 0x1FCC, 0x1FFC]
        self.assertEqual(exceptions, expected)
        for cp in expected:
            self.assertEqual(scan.fold(cp), cp, hex(cp))
        self.assertEqual(scan.match_line(scan.compile_pattern("ᾈ", case="insensitive"), "ᾀ ᾈ", 3)[1], [[2, 3]])

    def test_empty_match_warns_and_lists_no_offsets(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            Path(tmp, "a.txt").write_text("one\n\ntwo\n", encoding="utf-8")
            answer = scan.scan_folder(Path(tmp), {"pattern": "x?", "mode": "regex"})
        self.assertEqual([h["line"] for h in answer["hits"]], [1, 2, 3])
        self.assertEqual([h["match_offsets"] for h in answer["hits"]], [[], [], []])
        self.assertEqual(answer["warnings"], [{"code": "pattern_matches_empty", "message": scan.EMPTY_MATCH_MESSAGE}])

    def test_rework_2_ruling_4_empty_matches_do_not_count_and_the_cut_is_flagged(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            Path(tmp, "a.txt").write_text("b" * 17 + "\n" + "a" * 20 + "\n" + " ".join("w%x" % i for i in range(20)) + "\n",
                                          encoding="utf-8")
            empty = scan.scan_folder(Path(tmp), {"pattern": "x*", "mode": "regex"})
            ones = scan.scan_folder(Path(tmp), {"pattern": "x*a?", "mode": "regex"})
            words = scan.scan_folder(Path(tmp), {"pattern": "\\w+", "mode": "regex"})
            literal = scan.scan_folder(Path(tmp), {"pattern": "a"})
        # x* over 17 code points: the whole line, no offsets, nothing cut.
        first = empty["hits"][0]
        self.assertEqual((first["text"], first["text_truncated"], first["matches_truncated"], first["match_offsets"]),
                         ("b" * 17, False, False, []))
        # Empty matches between the non-empty ones do not count: 16 listed, cut at the 17th, flagged.
        second = ones["hits"][1]
        self.assertEqual((second["text"], second["text_truncated"], second["matches_truncated"]), ("a" * 16, True, True))
        self.assertEqual(second["match_offsets"], [[i, i + 1] for i in range(16)])
        third = words["hits"][2]
        self.assertEqual((len(third["match_offsets"]), third["text_truncated"], third["matches_truncated"]), (16, True, True))
        # Literal mode lists every match: never cut by count.
        self.assertEqual([(h["line"], h["matches_truncated"], len(h["match_offsets"])) for h in literal["hits"]][0], (2, False, 20))

    def test_rework_2_ruling_1_the_cursor_counts_files_before_the_scope(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            for name in ("a.md", "b.txt", "c.md", "d.txt", "e.txt"):
                Path(tmp, name).write_text("tide\ntide\n", encoding="utf-8")
            pages, cursor = [], None
            while True:
                page = scan.scan_folder(Path(tmp), {"pattern": "tide", "name_glob": "*.txt", "page_size": 3, "cursor": cursor})
                pages.append([(h["path"], h["line"]) for h in page["hits"]])
                cursor = page["next_cursor"]
                if cursor is None:
                    break
                pages[-1].append(cursor.split(":", 2)[2])
        # b.txt is file 1 and d.txt file 3 of the five, whatever the glob keeps.
        self.assertEqual(pages, [[("b.txt", 1), ("b.txt", 2), ("d.txt", 1), "3:2:1"],
                                 [("d.txt", 2), ("e.txt", 1), ("e.txt", 2), "4:3:2"], []])

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
            if params.get("name_glob"):
                args += ["--glob", params["name_glob"]]
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
        cases += [{"pattern": pattern, "mode": "regex"} for pattern, _line in DIVERGENT_EXAMPLES]
        hits = refusals = lines_only = 0
        for params in cases:
            divergent = params.get("mode") == "regex" and scan.offsets_may_differ(params["pattern"])
            lines_only += divergent
            engine, reference = self.engine_all(params), self.reference(params)
            self.assertEqual(comparable(engine, divergent), comparable(reference, divergent), json.dumps(params, ensure_ascii=False))
            refusals += "refused" in engine
            hits += len(engine.get("hits", []))
        print(f"S6-T24 agreement: {len(cases)} cases ({lines_only} in the stated divergence, lines and counts only), "
              f"{refusals} refused alike, {hits} hit lines identical", file=sys.stderr)
        self.assertGreaterEqual(lines_only, 3)
        self.assertGreater(hits, 1000)
        self.assertGreater(refusals, 10)

    def test_rework_2_ruling_1_pages_and_cursors_agree_under_a_glob(self) -> None:
        def pages(page_of) -> list:
            out, cursor = [], None
            while True:
                page = page_of(cursor)
                tail = page["next_cursor"].split(":", 2)[2] if page["next_cursor"] else None
                out.append(([(h["path"], h["line"], h["match_offsets"]) for h in page["hits"]], tail))
                cursor = page["next_cursor"]
                if cursor is None:
                    return out

        def engine(cursor):
            args = [str(self.binary), "scan", "--folder", str(self.folder), "\\d", "--regex", "--json", "--page-size", "3",
                    "--glob", "n0?.txt", "--time-ms", "30000"]
            done = subprocess.run(args + (["--cursor", cursor] if cursor else []), capture_output=True,
                                  stdin=subprocess.DEVNULL, timeout=60)
            self.assertEqual(done.returncode, 0, done.stderr)
            return json.loads(done.stdout)

        def reference(cursor):
            return scan.scan_folder(self.folder, {"pattern": "\\d", "mode": "regex", "page_size": 3, "name_glob": "n0?.txt",
                                                  "time_budget_ms": 30_000, "cursor": cursor})

        by_engine, by_reference = pages(engine), pages(reference)
        self.assertEqual(by_engine, by_reference)
        self.assertGreater(len(by_engine), 3)

    def test_known_divergences_still_diverge(self) -> None:
        for pattern, _line in DIVERGENT_EXAMPLES:
            self.assertTrue(scan.offsets_may_differ(pattern), pattern)
        for pattern in ("a*", "(ab)+", "x?", "(a?){1}", "(a?){0,1}", "(?:a|b)*c", "\\d+", "(a|)", "a{2,}", "(?:\\b\\b)*x"):
            self.assertFalse(scan.offsets_may_differ(pattern), pattern)
        for pattern in ("(a?)*", "(|a)+", "(?:a?\\b)*x", "(?:a*){2}", "(x|y?){3,}"):
            self.assertTrue(scan.offsets_may_differ(pattern), pattern)
        pattern, line = DIVERGENT_EXAMPLES[0]
        with tempfile.TemporaryDirectory() as tmp:
            Path(tmp, "a.txt").write_text(line + "\n", encoding="utf-8")
            reference = scan.scan_folder(Path(tmp), {"pattern": pattern, "mode": "regex"})
            done = subprocess.run([str(self.binary), "scan", "--folder", tmp, pattern, "--regex", "--json"],
                                  capture_output=True, stdin=subprocess.DEVNULL, timeout=60)
            engine = json.loads(done.stdout)
        self.assertEqual(reference["hits"][0]["match_offsets"], [[0, 1], [1, 2]])
        self.assertEqual(engine["hits"][0]["match_offsets"], [[0, 2]])


    def test_the_fold_tables_exceptions_in_the_engine_ruling_7(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            Path(tmp, "a.txt").write_text("ᾀ ᾈ\nß ss ẞ\nk K \u212a\n", encoding="utf-8")
            got = {}
            for pattern in ("ᾈ", "ẞ", "k"):
                done = subprocess.run([str(self.binary), "scan", "--folder", tmp, pattern, "--case", "insensitive", "--json"],
                                      capture_output=True, stdin=subprocess.DEVNULL, timeout=60)
                got[pattern] = [(h["line"], h["match_offsets"]) for h in json.loads(done.stdout)["hits"]]
        self.assertEqual(got, {"ᾈ": [(1, [[2, 3]])], "ẞ": [(2, [[5, 6]])], "k": [(3, [[0, 1], [2, 3], [4, 5]])]})


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


def nest(depth: int) -> str:
    """The verifier's pattern (probe_compile_hang.py): two empty groups under `depth` repeats of {255}."""
    body = "(?:)(?:)"
    for _ in range(depth):
        body = "(?:" + body + "){255}"
    return body


# The stated constant (docs/scan.md, "Time") is measured by a script outside the default run
# (`scripts/prototypes/s6t24/rework2/bound_probe.py`): NFR-19 allows no wall-clock threshold in a test (rework 2,
# ruling 3). These tests check what a page does at a budget it cannot meet (stopped, cursor, refusal) and print
# the time it took; the only timing they assert is a ratio (the slope of ruling 2).


@unittest.skipIf(NO_ZIG, "SEARCH_SIMPLI_NO_ZIG=1: this environment deliberately has no Zig (CI)")
class BudgetTests(unittest.TestCase):
    """S6-T24 rework 1, rulings 1-3 and 5, through `searchd scan` and `searchd serve` (the test build)."""

    @classmethod
    def setUpClass(cls) -> None:
        cls.scratch_dir = tempfile.TemporaryDirectory()
        cls.scratch = Path(cls.scratch_dir.name)
        cls.binary = build_searchd(cls.scratch)
        cls.small = cls.scratch / "small"
        cls.small.mkdir()
        (cls.small / "a.txt").write_text("tide pool\nharbour 12\n", encoding="utf-8")
        cls.index = cls.scratch / "small-index"
        subprocess.run([str(cls.binary), "index", str(cls.small), "--out", str(cls.index)], check=True,
                       capture_output=True, stdin=subprocess.DEVNULL, timeout=120)

    @classmethod
    def tearDownClass(cls) -> None:
        cls.scratch_dir.cleanup()

    def timed(self, *args: str, limit: float = 120.0) -> tuple[float, subprocess.CompletedProcess]:
        """The fastest of three runs, in ms, and the last run's result."""
        best, done = float("inf"), None
        for _ in range(3):
            start = time.monotonic()
            done = subprocess.run([str(self.binary), *args], capture_output=True, stdin=subprocess.DEVNULL, timeout=limit)
            best = min(best, (time.monotonic() - start) * 1000)
        return best, done

    def baseline_ms(self, folder: Path) -> float:
        """The same command with a pattern that costs nothing: process start, the walk and the file's read."""
        return self.timed("scan", "--folder", str(folder), "zq", "--json", "--case", "sensitive", "--time-ms", "30000")[0]

    def test_ruling_1_nested_empty_repeats_cost_nothing(self) -> None:
        base = self.baseline_ms(self.small)
        for depth in (4, 5):
            pattern = nest(depth)
            took, done = self.timed("scan", "--folder", str(self.small), pattern, "--regex", "--json", "--time-ms", "1")
            self.assertEqual(done.returncode, 0, done.stderr)
            print(f"S6-T24 ruling 1: {len(pattern.encode())}-byte pattern at --time-ms 1: {took:.1f} ms (baseline {base:.1f} ms)", file=sys.stderr)
        self.assertEqual([len(nest(depth).encode()) for depth in (4, 5)], [44, 53])
        # Over `searchd serve`: the scan with time_budget_ms 1 and a status call (`index_status`) queued behind it.
        server = subprocess.Popen([str(self.binary), "serve", str(self.index)], stdin=subprocess.PIPE,
                                  stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            server.stdin.write(json.dumps({"jsonrpc": "2.0", "id": 0, "method": "index_status", "params": {}}) + "\n")
            server.stdin.flush()
            server.stdout.readline()  # the index open, outside the measure
            for depth in (4, 5):
                start = time.monotonic()
                server.stdin.write(json.dumps({"jsonrpc": "2.0", "id": 1, "method": "scan",
                                               "params": {"pattern": nest(depth), "mode": "regex", "time_budget_ms": 1}}) + "\n")
                server.stdin.write(json.dumps({"jsonrpc": "2.0", "id": 2, "method": "index_status", "params": {}}) + "\n")
                server.stdin.flush()
                first = json.loads(server.stdout.readline())
                second = json.loads(server.stdout.readline())
                took = (time.monotonic() - start) * 1000
                self.assertIn("result", first)
                self.assertIn("result", second)
                print(f"S6-T24 ruling 1: serve, depth {depth}: scan and the status behind it answered in {took:.1f} ms", file=sys.stderr)
        finally:
            server.stdin.close()
            server.wait(timeout=60)
            server.stdout.close()
            server.stderr.close()
        # Over the cap of work: refused with the existing message.
        done = subprocess.run([str(self.binary), "scan", "--folder", str(self.small), "(?:a{255}){32}", "--regex"],
                              capture_output=True, text=True, stdin=subprocess.DEVNULL, timeout=60)
        self.assertEqual(done.returncode, 1)
        self.assertIn("the pattern is too large (over 8,192 steps)", done.stderr)

    def test_ruling_2_listing_matches_is_linear(self) -> None:
        times = {}
        for power in (20, 22):
            folder = self.scratch / f"a-{power}"
            folder.mkdir()
            (folder / "x.txt").write_bytes(b"a" * (1 << power) + b"\n")
            base = self.baseline_ms(folder)
            took, done = self.timed("scan", "--folder", str(folder), "a(.*b)?", "--regex", "--case", "sensitive",
                                    "--json", "--time-ms", "30000")
            self.assertEqual(done.returncode, 0, done.stderr)
            answer = json.loads(done.stdout)
            self.assertEqual(answer["stopped"], "none")
            hit = answer["hits"][0]
            # At most 16 matches a line: the 17th cuts the text where it starts.
            self.assertEqual(hit["match_offsets"], [[i, i + 1] for i in range(16)])
            self.assertEqual(hit["text"], "a" * 16)
            self.assertTrue(hit["text_truncated"])
            self.assertTrue(hit["matches_truncated"])
            times[power] = took - base
            print(f"S6-T24 ruling 2: a(.*b)? over 2^{power} a's: {took:.0f} ms (baseline {base:.0f} ms)", file=sys.stderr)
        slope = times[22] / times[20]
        print(f"S6-T24 ruling 2: four times the line, {slope:.2f} times the time", file=sys.stderr)
        self.assertLess(slope, 6.0)
        self.assertGreater(slope, 2.0)
        # At a budget the line cannot meet: refused honestly (one line, nothing completed), within the constant.
        folder = self.scratch / "a-22"
        base = self.baseline_ms(folder)
        took, done = self.timed("scan", "--folder", str(folder), "a(.*b)?", "--regex", "--case", "sensitive", "--time-ms", "5")
        self.assertEqual(done.returncode, 1)
        self.assertIn("line 1 of r-legacy/x.txt outlasts time_budget_ms (5)", done.stderr.decode())
        print(f"S6-T24 ruling 2: refused at --time-ms 5 after {took:.0f} ms (baseline {base:.0f} ms)", file=sys.stderr)

    def test_ruling_3_a_literal_stops_on_time(self) -> None:
        folder = self.scratch / "lit"
        folder.mkdir()
        (folder / "x.txt").write_bytes((b"a" * 4095 + b"\n") * (10 * (1 << 20) // 4096))
        base = self.baseline_ms(self.small)  # process start only: stricter than this folder's walk and read
        for case in ("sensitive", "smart"):
            took, done = self.timed("scan", "--folder", str(folder), "a" * 1023 + "b", "--json", "--case", case, "--time-ms", "1")
            self.assertEqual(done.returncode, 0, done.stderr)
            answer = json.loads(done.stdout)
            print(f"S6-T24 ruling 3: 1,023 a's and b over 10 MiB, case {case}, --time-ms 1: {took:.1f} ms "
                  f"(baseline {base:.1f} ms), stopped {answer['stopped']}", file=sys.stderr)
            self.assertEqual(answer["stopped"], "time")
            self.assertIsNotNone(answer["next_cursor"])

    def test_ruling_5_the_refusal_names_its_cause(self) -> None:
        # The verifier's case: an 8 MiB file whose first line is 5,000 x's, x\d at --time-ms 1. The read used the
        # budget; the first line still gets its 10 ms and completes, so the page progresses.
        folder = self.scratch / "slow"
        folder.mkdir()
        (folder / "a.txt").write_bytes(b"x" * 5000 + b"\n" + b"y\n" * (4 << 20))
        done = subprocess.run([str(self.binary), "scan", "--folder", str(folder), "x\\d", "--regex", "--json", "--time-ms", "1"],
                              capture_output=True, stdin=subprocess.DEVNULL, timeout=120)
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertIn(json.loads(done.stdout)["stopped"], ("time", "none"))
        # A line that cannot finish in the grace either: the message says what the budget went on.
        long = self.scratch / "long"
        long.mkdir()
        (long / "a.txt").write_bytes(b"x" * (8 << 20) + b"\n")
        done = subprocess.run([str(self.binary), "scan", "--folder", str(long), "(x|y)+z", "--regex", "--time-ms", "1"],
                              capture_output=True, text=True, stdin=subprocess.DEVNULL, timeout=120)
        self.assertEqual(done.returncode, 1)
        self.assertRegex(done.stderr, r"time_budget_ms \(1\) ran out reading r-legacy/a\.txt, and line 1 did not finish in the "
                                      r"10 ms after: raise it \(at most 30000\) or narrow the scope|line 1 of r-legacy/a\.txt "
                                      r"outlasts time_budget_ms \(1\)")


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
