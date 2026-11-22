"""S6-T22: the text-search judged set (plan step H1): its corpus, its judgments and its scorer.

The judgments are checked, not asserted (the task's ruling 2): every committed
line range is read back from a freshly generated folder, with a line splitter
written here and not the generator's, and must hold its key words; every
`absent_from_corpus` and `absent_from_files` word is looked for as a token of
the repository analyzer. The scorer's arithmetic is tested on hand-made
answers; one end-to-end run through the real `searchd` (found as
`test_direct_search.py` finds it; `SEARCH_SIMPLI_NO_ZIG=1` skips) checks that
direct search and an index agree and that the output is deterministic and holds
no absolute path. All content is invented."""

import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import unicodedata
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(ROOT / "scripts"))

import gen_text_search_corpus as corpus_mod  # noqa: E402
import text_search_questions as questions_mod  # noqa: E402
import text_search_score as scorer  # noqa: E402
from src.search_platform.core import tokenize  # noqa: E402

JUDGMENTS = ROOT / "fixtures" / "text-search" / "judgments.json"
KINDS = ["word", "word-form", "misspelt", "phrase", "number", "two-passages", "two-files",
         "filename", "about", "file-content", "no-answer"]


def load():
    return json.loads(JUDGMENTS.read_text(encoding="utf-8"))


def own_lines(data: bytes) -> list:
    """1-based lines, split here independently of the generator."""
    text = data.decode("utf-8")
    lines = re.split(r"\r?\n", text)
    if lines and lines[-1] == "":
        lines.pop()
    return lines


def fold(text: str) -> str:
    return unicodedata.normalize("NFC", text).casefold()


class CorpusTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.corpus = corpus_mod.build_corpus()
        cls.data = load()

    def test_deterministic_and_the_judged_one(self):
        again = corpus_mod.build_corpus()
        self.assertEqual(self.corpus, again)
        self.assertEqual(corpus_mod.corpus_digest(self.corpus), self.data["corpus"]["corpus_sha256"])
        self.assertEqual(len(self.corpus), self.data["corpus"]["files"])
        self.assertEqual(sum(map(len, self.corpus.values())), self.data["corpus"]["bytes"])

    def test_a_few_hundred_files_of_the_shapes_the_brief_names(self):
        paths = list(self.corpus)
        self.assertGreaterEqual(len(paths), 200)
        self.assertLessEqual(len(paths), 999)
        names = [p.rsplit("/", 1)[-1] for p in paths]
        for ext in (".md", ".txt", ".csv", ".tsv", ".json", ".yaml", ".html", ".py", ".js", ".log"):
            self.assertTrue(any(n.endswith(ext) for n in names), ext)
        self.assertGreaterEqual(sum(1 for n in names if "." not in n), 3, "files with no extension")
        lengths = {p: len(own_lines(v)) for p, v in self.corpus.items()}
        self.assertGreater(max(lengths.values()), 1000, "a long file")
        self.assertGreaterEqual(sum(1 for n in lengths.values() if n == 1), 10, "one-line files")
        text = "".join(v.decode("utf-8") for v in self.corpus.values())
        self.assertTrue(re.search("[஀-௿]", text), "Tamil script")
        self.assertTrue(any(b"\r\n" in v for v in self.corpus.values()), "a CRLF file")
        values = list(self.corpus.values())
        self.assertLess(len(set(values)), len(values), "an exact duplicate")
        self.assertTrue(any(re.search("[஀-௿]", p) for p in paths), "a Tamil file name")

    def test_write_corpus_writes_every_file_and_refuses_a_full_folder(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / "c"
            written = corpus_mod.write_corpus(out)
            on_disk = {str(p.relative_to(out)): p.read_bytes() for p in out.rglob("*") if p.is_file()}
            self.assertEqual(on_disk, written)
            with self.assertRaises(SystemExit):
                corpus_mod.write_corpus(out)


class JudgmentTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.corpus = corpus_mod.build_corpus()
        cls.data = load()

    def test_file_is_what_the_questions_script_writes(self):
        self.assertEqual(JUDGMENTS.read_text(encoding="utf-8"), questions_mod.render())

    def test_shape(self):
        self.assertEqual(scorer.validate_judgments(self.data), [])
        self.assertEqual(list(self.data["kinds"]), KINDS)
        qs = self.data["questions"]
        self.assertGreaterEqual(len(qs), 120)
        for kind in KINDS:
            self.assertGreaterEqual(sum(1 for q in qs if q["kind"] == kind), 8, kind)

    def test_validator_finds_planted_faults(self):
        bad = json.loads(json.dumps(self.data))
        bad["questions"][0]["files"] = []
        bad["questions"][1]["parts"][0]["ranges"][0]["start_line"] = 0
        bad["questions"][-1]["files"] = ["home/TODO"]
        bad["kinds"]["word"]["questions"] = 99
        problems = scorer.validate_judgments(bad)
        self.assertEqual(len(problems), 5, problems)

    def test_every_range_exists_and_holds_its_keys(self):
        checked = 0
        for q in self.data["questions"]:
            for part in q["parts"]:
                for r in part["ranges"]:
                    self.assertIn(r["path"], self.corpus, q["id"])
                    lines = own_lines(self.corpus[r["path"]])
                    self.assertLessEqual(r["end_line"], len(lines), q["id"])
                    text = fold("\n".join(lines[r["start_line"] - 1:r["end_line"]]))
                    for key in r["keys"]:
                        self.assertIn(fold(key), text, f"{q['id']}: {r['path']} {r['start_line']}-{r['end_line']}")
                    checked += 1
        self.assertGreater(checked, 150)

    def test_absent_words_are_absent(self):
        corpus_tokens = set()
        file_tokens = {}
        for path, data in self.corpus.items():
            toks = set(tokenize(data.decode("utf-8")))
            file_tokens[path] = toks
            corpus_tokens |= toks
        for q in self.data["questions"]:
            checks = q.get("checks", {})
            for word in checks.get("absent_from_corpus", []):
                for tok in tokenize(word):
                    self.assertFalse(tok in corpus_tokens, f"{q['id']}: {word}")
            for word in checks.get("absent_from_files", []):
                for path in q["files"]:
                    for tok in tokenize(word):
                        self.assertFalse(tok in file_tokens[path], f"{q['id']}: {word} in {path}")

    def test_every_misspelt_filename_and_no_answer_question_has_its_check(self):
        for q in self.data["questions"]:
            checks = q.get("checks", {})
            if q["kind"] in ("misspelt", "no-answer"):
                self.assertTrue(checks.get("absent_from_corpus"), q["id"])
            if q["kind"] in ("word-form", "filename"):
                self.assertTrue(checks.get("absent_from_files"), q["id"])

    def test_two_passage_and_two_file_questions_have_two_parts_of_the_right_shape(self):
        for q in self.data["questions"]:
            if q["kind"] == "two-passages":
                self.assertEqual(len(q["parts"]), 2, q["id"])
                paths = {r["path"] for p in q["parts"] for r in p["ranges"]} - {"archive/sourdough-copy.md"}
                self.assertEqual(len(paths), 1, q["id"])  # one file (its exact copy aside)
            if q["kind"] == "two-files":
                self.assertEqual(len(q["parts"]), 2, q["id"])
                first, second = ({r["path"] for r in p["ranges"]} for p in q["parts"])
                self.assertFalse(first & second, q["id"])


def passage(path, start, end, content="x"):
    return {"path": path, "start_line": start, "end_line": end, "content": content}


class ScoringTests(unittest.TestCase):
    Q = {"id": "t", "kind": "two-passages", "files": ["a.md", "b.md"],
         "parts": [{"ranges": [{"path": "a.md", "start_line": 5, "end_line": 6, "keys": ["k"]},
                               {"path": "b.md", "start_line": 2, "end_line": 2, "keys": ["k"]}]},
                   {"ranges": [{"path": "a.md", "start_line": 20, "end_line": 20, "keys": ["k"]}]}]}

    def test_a_range_counts_only_when_a_passage_holds_it_whole(self):
        r = {"path": "a.md", "start_line": 5, "end_line": 6}
        self.assertTrue(scorer.holds(passage("a.md", 5, 6), r))
        self.assertTrue(scorer.holds(passage("a.md", 1, 9), r))
        self.assertFalse(scorer.holds(passage("a.md", 6, 9), r))
        self.assertFalse(scorer.holds(passage("a.md", 1, 5), r))
        self.assertFalse(scorer.holds(passage("c.md", 1, 9), r))

    def test_ranks_count_distinct_files_and_passages(self):
        got = [passage("c.md", 1, 3), passage("c.md", 4, 8), passage("a.md", 1, 4), passage("a.md", 5, 9),
               passage("a.md", 18, 22, "é")]
        row = scorer.score_question(self.Q, got, 123)
        self.assertEqual(row["file_rank"], 2)       # c.md, then a.md
        self.assertEqual(row["passage_rank"], 4)    # the fourth passage holds 5-6
        self.assertTrue(row["complete"])
        self.assertEqual(row["passage_bytes"], 4 + 2)
        self.assertEqual(row["evidence_bytes"], 123)

    def test_an_alternative_satisfies_a_part_and_a_missing_part_is_incomplete(self):
        row = scorer.score_question(self.Q, [passage("b.md", 1, 3)], 1)
        self.assertEqual((row["file_rank"], row["passage_rank"], row["parts_found"], row["complete"]), (1, 1, 1, False))
        row = scorer.score_question(self.Q, [], 1)
        self.assertEqual((row["file_rank"], row["passage_rank"], row["complete"]), (None, None, False))

    def test_no_answer_rows_and_aggregates(self):
        q = {"id": "n", "kind": "no-answer", "files": [], "parts": []}
        rows = [scorer.score_question(q, [], 10), scorer.score_question(dict(q, id="m"), [passage("a.md", 1, 1)], 30)]
        agg = scorer.aggregate(rows, set())
        self.assertEqual(agg["returned_something"], {"hits": 1, "of": 2, "share": 0.5})
        self.assertEqual(agg["evidence_bytes_mean"], 20.0)
        rows = [scorer.score_question(self.Q, [passage("a.md", 5, 6)], 1), scorer.score_question(self.Q, [], 1)]
        agg = scorer.aggregate(rows, {"t"})
        self.assertEqual(agg["file@1"]["hits"], 1)
        self.assertEqual(agg["complete"]["hits"], 0)
        self.assertEqual(agg["not_read"]["hits"], 2)

    def test_both_envelopes_parse(self):
        tool = {"results": [{"citation": {"path": "a.md", "start_line": 1, "end_line": 2}, "content": "x"}]}
        old = {"evidence": [{"path": "a.md", "start_line": 1, "end_line": 2, "content": "x"}]}
        self.assertEqual(scorer.passages_of(tool), scorer.passages_of(old))
        with self.assertRaises(ValueError):
            scorer.passages_of({})


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


class EndToEndTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if os.environ.get("SEARCH_SIMPLI_NO_ZIG") == "1":
            raise unittest.SkipTest("SEARCH_SIMPLI_NO_ZIG=1: this environment deliberately has no Zig (CI)")
        cls.binary_dir = tempfile.TemporaryDirectory()
        cls.binary = build_searchd(Path(cls.binary_dir.name))

    @classmethod
    def tearDownClass(cls):
        cls.binary_dir.cleanup()

    def test_a_sample_scores_deterministically_and_direct_equals_index(self):
        sample = {q["id"] for q in load()["questions"][::6]}
        results = []
        with tempfile.TemporaryDirectory() as tmp:
            for name in ("one", "two"):
                scratch = Path(tmp) / name
                out = scorer.score(self.binary, JUDGMENTS, scratch, 10, ["both", "content"], None,
                                   questions_filter=lambda q: q["id"] in sample)
                text = json.dumps(out, ensure_ascii=False)
                self.assertNotIn(str(scratch), text)
                self.assertNotIn(tmp, text)
                results.append(text)
            self.assertEqual(results[0], results[1])
            out = json.loads(results[0])
            self.assertEqual(out["judgments"]["questions"], len(sample))
            for field in ("both", "content"):
                agree = out["direct_equals_index"][field]
                self.assertEqual(agree["identical"], agree["of"], field)
            # The engine reads none of the CSV, TSV, .log or extensionless files today.
            unread = out["corpus"]["files_not_read"]
            self.assertIn("home/money/budget-2026.csv", unread)
            self.assertIn("inbox/NOTES", unread)
            self.assertEqual(scorer.markdown(out, KINDS).count("| **total**"), 2)


if __name__ == "__main__":
    unittest.main()
