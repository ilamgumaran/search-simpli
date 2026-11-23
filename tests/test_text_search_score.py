"""S6-T22: the text-search judged set (plan step H1): its corpus, its judgments and its scorer.

The judgments are checked, not asserted (the task's ruling 2): every committed
line range is read back from a freshly generated folder, with a line splitter
written here and not the generator's, and must hold its key words; every
`absent_from_corpus` and `absent_from_files` word is looked for as a token of
the repository analyzer. Rework 1 adds: the 129 questions of version 1 keep
their wording (a digest), the answers judged after the Verdict stay judged (a
question that loses one fails), `single_source` is recomputed here, stale
copies are checked like answers, and the files of version 1 keep their bytes.
Rework 2 adds: a digest per question freezes all 181 (wording, both forms,
files, parts, ranges, alternatives, stale copies, checks), every stale copy
disagrees with the answer and says in its text that it is a draft or
superseded, and a scripted search finds no other file stating a different value
for a judged key fact beyond a reviewed list.
The scorer's arithmetic is tested on hand-made
answers; one end-to-end run through the real `searchd` (found as
`test_direct_search.py` finds it; `SEARCH_SIMPLI_NO_ZIG=1` skips) checks that
direct search and an index agree and that the output is deterministic and holds
no absolute path. All content is invented."""

import hashlib
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
         "filename", "about", "file-content", "no-answer",
         "tamil-latin", "synonym", "table", "current-copy", "where-is-it"]

# The corpus of version 1 (264 files): its files keep their bytes in rework 1.
V1_CORPUS_SHA256 = "d2bf0314a2769cb78d9077dbe196a1c53216e8393b0c150a6781badae0e94e26"
# Rework 2 changes three of them on purpose (CHANGED_IN_REWORK_2); the other 261 keep their bytes.
V1_UNCHANGED_SHA256 = "f5a8bc17e3c8c8b8143b4c8ba3093449378bda6a2c8a804f4050c821f2a48287"
CHANGED_IN_REWORK_2 = {
    "archive/committee-2025.md": "7ec25643fe28e6f0c6f8b9d7a28e9344a751c4efaf736787ac3ca084f6023e02",
    "archive/house-notes-2024.md": "5947c390a036b4af369d0b2702b5fd4b3dabccfedb10743b39787aacf72b11f3",
    "inbox/note-08.txt": "709846f58e4d38e5ca0e65150959e0205ea20b535a2ae2a9452dcc906cc18e65",
}
DIGESTS = ROOT / "fixtures" / "text-search" / "question-digests.json"

# What the scripted contradiction search (questions_mod.contradictions) returns
# today, each read by eye: none states a different value for the same fact.
REVIEWED_NON_CONTRADICTIONS = {
    ("about-11", "toolshare/docs/treasurer.md", 8): "a hardware invoice, not the electricity bill",
    ("name-12", "toolshare/docs/treasurer.md", 8): "a hardware invoice, not the electricity bill",
    ("word-02", "home/recipes/flatbread.md", 3): "another recipe's flour and water",
    ("word-13", "school/trip-letter-castle.md", 1): "another school trip",
    ("word-13", "school/trip-letter-castle.md", 5): "another school trip, on another day",
}
# sha256 of the sorted [id, question] pairs of version 1's 129 questions
# (judgments sha256 078a85fb..., commit 0cd6f5f): no question's wording changes.
V1_QUESTIONS_SHA256 = "cd90ba207bb0f250daa923fc618dd57f801c9208ba01884fd8bb7b97152f40dd"

# Answers judged in rework 1 beside an answer judged before (the Verdict's
# findings 1, 2 and 5, and the files H2 will make readable). Each question must
# keep every one of these files among its judged answers.
JUDGED_ANSWERS = {
    "word-06": {"paati/pongal-samayal.md", "paati/naatkaatti-2027.md"},
    "spell-10": {"toolshare/data/inventory.yaml", "toolshare/data/loans-2026.csv"},
    "number-02": {"toolshare/data/inventory.yaml", "toolshare/docs/repairs.md", "toolshare/data/loans-2026.csv"},
    "number-06": {"home/lists/useful-numbers.txt", "home/contacts.tsv"},
    "span-08": {"home/house/boiler.md", "inbox/boiler-service-2026-03-14.txt", "home/lists/useful-numbers.txt",
                "home/contacts.tsv"},
    "pair-01": {"home/house/boiler.md", "inbox/boiler-service-2026-03-14.txt"},
    "word-13": {"school/trip-letter-wetlands.md", "school/calendar-autumn.md"},
    "word-14": {"home/trips/cornwall-2026.md", "home/trips/directions-to-gull-cottage.txt"},
    "word-15": {"home/lists/useful-numbers.txt", "home/house/jobs-autumn.md", "home/contacts.tsv",
                "home/money/receipts-note.md", "home/money/house-costs-2026.csv"},
    "name-01": {"inbox/boiler-service-2026-03-14.txt", "home/house/boiler.md"},
    "about-05": {"toolshare/data/inventory.yaml", "toolshare/data/loans-2026.csv"},
    "about-09": {"toolshare/site/index.html", "toolshare/site/join.html", "toolshare/site/styles.css",
                 "toolshare/site/sitemap.xml"},
}


def missing_answers(data) -> list:
    by_id = {q["id"]: q for q in data["questions"]}
    out = []
    for qid, paths in JUDGED_ANSWERS.items():
        judged = {r["path"] for p in by_id[qid]["parts"] for r in p["ranges"]}
        out += [f"{qid}: {path}" for path in sorted(paths - judged)]
    return out


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

    def test_the_files_of_version_1_keep_their_bytes(self):
        added = set(corpus_mod.ADDED_IN_REWORK_1)
        self.assertTrue(added <= set(self.corpus))
        v1 = {p: b for p, b in self.corpus.items() if p not in added}
        self.assertEqual(len(v1), 264)
        self.assertEqual(set(corpus_mod.CHANGED_IN_REWORK_2), set(CHANGED_IN_REWORK_2))
        unchanged = {p: b for p, b in v1.items() if p not in CHANGED_IN_REWORK_2}
        self.assertEqual(corpus_mod.corpus_digest(unchanged), V1_UNCHANGED_SHA256)
        for path, digest in CHANGED_IN_REWORK_2.items():
            self.assertEqual(hashlib.sha256(self.corpus[path]).hexdigest(), digest, path)

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
        no_answer = next(i for i, q in enumerate(bad["questions"]) if q["kind"] == "no-answer")
        bad["questions"][no_answer]["files"] = ["home/TODO"]
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
                for path in {part["ranges"][0]["path"] for part in q["parts"]}:
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
                paths = {p["ranges"][0]["path"] for p in q["parts"]}
                self.assertEqual(len(paths), 1, q["id"])  # one file; later ranges are alternatives
            if q["kind"] == "two-files":
                self.assertEqual(len(q["parts"]), 2, q["id"])
                first, second = ({r["path"] for r in p["ranges"]} for p in q["parts"])
                self.assertFalse(first & second, q["id"])

    # ---------------------------------------------------------------- rework 1

    def test_version_1_questions_keep_their_wording(self):
        old = sorted([q.get("was", q["id"]), q["question"]] for q in self.data["questions"] if "added" not in q)
        self.assertEqual(len(old), 129)
        digest = hashlib.sha256(json.dumps(old, ensure_ascii=False).encode("utf-8")).hexdigest()
        self.assertEqual(digest, V1_QUESTIONS_SHA256)
        for q in self.data["questions"]:
            if "was" in q:
                self.assertNotIn("added", q, q["id"])

    def test_every_question_carries_both_forms(self):
        for q in self.data["questions"]:
            self.assertTrue(q["question"].strip() and q["query"].strip(), q["id"])

    def test_the_judged_answers_stay_judged(self):
        self.assertEqual(missing_answers(self.data), [])

    def test_removing_one_of_two_judged_answers_fails(self):
        for qid in ("word-06", "number-06", "about-09"):
            bad = json.loads(json.dumps(self.data))
            q = next(q for q in bad["questions"] if q["id"] == qid)
            for part in q["parts"]:
                if len(part["ranges"]) > 1:
                    part["ranges"].pop()
                    break
            else:
                q["parts"].pop()
            self.assertTrue(missing_answers(bad), qid)

    def test_no_query_borrows_a_word_from_its_answer(self):
        """A query word the typed question lacks (no common 4-letter start) is not in the answer's lines."""
        def stems(text):
            return {tok[:4] for tok in tokenize(text)}

        for q in self.data["questions"]:
            if re.search("[஀-௿]", q["question"] + q["query"]):
                continue  # Tamil tokens split at vowel signs; read by eye (the verifier's query-shape.txt)
            typed = stems(q["question"])
            added = [tok for tok in tokenize(q["query"]) if tok[:4] not in typed]
            for part in q["parts"]:
                for r in part["ranges"]:
                    lines = own_lines(self.corpus[r["path"]])[r["start_line"] - 1:r["end_line"]]
                    toks = set(tokenize("\n".join(lines)))
                    for tok in added:
                        self.assertNotIn(tok, toks, f"{q['id']}: {tok} in {r['path']}")

    def test_single_source_is_what_the_readable_files_say(self):
        readable = [p for p in sorted(self.corpus)
                    if "." in p.rsplit("/", 1)[-1]
                    and p[p.rindex("."):].lower() in questions_mod.READABLE_EXTENSIONS]
        holders = {}
        seen = set()
        for path in readable:
            if self.corpus[path] in seen:
                continue
            seen.add(self.corpus[path])
            for tok in set(tokenize(self.corpus[path].decode("utf-8"))):
                holders.setdefault(tok, set()).add(path)
        marked = 0
        for q in self.data["questions"]:
            counts = [len(holders[tok]) for tok in tokenize(q["query"]) if tok in holders]
            expected = bool(q["files"]) and bool(counts) and min(counts) == 1
            self.assertEqual(q["single_source"], expected, q["id"])
            marked += expected
        self.assertGreater(marked, 20)

    def test_every_question_matches_its_frozen_digest(self):
        """All 181 are frozen: a change to any is made on purpose, with --freeze (docs/text-search-score.md)."""
        frozen = json.loads(DIGESTS.read_text(encoding="utf-8"))
        self.assertEqual(DIGESTS.read_text(encoding="utf-8"), questions_mod.render_digests(self.data))
        now = {q["id"]: questions_mod.question_digest(q) for q in self.data["questions"]}
        self.assertEqual(len(now), 181)
        self.assertEqual(now, frozen["questions"])

    def test_any_edit_to_a_question_changes_its_digest(self):
        by_id = {q["id"]: q for q in self.data["questions"]}
        edits = {
            "syn-05 reworded": lambda q: q.update(question=q["question"] + " please"),
            "syn-05 query": lambda q: q.update(query=q["query"] + " please"),
            "syn-08 alternative dropped": lambda q: q["parts"][0]["ranges"].pop(),
            "word-06 range moved": lambda q: q["parts"][0]["ranges"][0].update(end_line=99),
            "word-05 stale dropped": lambda q: q.pop("stale"),
            "spell-01 check dropped": lambda q: q.pop("checks"),
            "pair-04 kind": lambda q: q.update(kind="word"),
        }
        for name, edit in edits.items():
            q = json.loads(json.dumps(by_id[name.split()[0]]))
            before = questions_mod.question_digest(q)
            edit(q)
            self.assertNotEqual(questions_mod.question_digest(q), before, name)

    def test_readable_now_is_every_part_in_a_readable_file(self):
        for q in self.data["questions"]:
            expected = bool(q["files"]) and all(
                any(questions_mod.readable(r["path"]) for r in part["ranges"]) for part in q["parts"])
            self.assertEqual(q["readable_now"], expected, q["id"])
        self.assertEqual(sum(q["readable_now"] for q in self.data["questions"]), 146)

    def test_a_stale_copy_disagrees_and_says_it_is_old(self):
        """Stale: a key of the copy is not in the answer files, or a key of the answer is not in the copy.
        The copy's own text says draft or superseded; the answer files say neither (finding 5)."""
        def says_old(path):
            text = self.corpus[path].decode("utf-8").casefold()
            return "draft" in text or "superseded" in text

        marked = 0
        for q in self.data["questions"]:
            answers = fold(" ".join(self.corpus[p].decode("utf-8") for p in q["files"]))
            answer_keys = [k for part in q["parts"] for k in part["ranges"][0]["keys"]]
            for r in q.get("stale", []):
                copy = fold(self.corpus[r["path"]].decode("utf-8"))
                disagrees = (any(fold(k) not in answers for k in r["keys"])
                             or any(fold(k) not in copy for k in answer_keys))
                self.assertTrue(disagrees, f"{q['id']}: {r['path']} agrees with the answer")
                self.assertTrue(says_old(r["path"]), f"{q['id']}: {r['path']}")
                marked += 1
            if q.get("stale"):
                for path in q["files"]:
                    self.assertFalse(says_old(path), f"{q['id']}: {path}")
        self.assertEqual(marked, 23)  # stale ranges, over 22 questions
        syn02 = next(q for q in self.data["questions"] if q["id"] == "syn-02")
        self.assertNotIn("stale", syn02)  # its 2024 copy agrees: an alternative
        self.assertIn("archive/house-notes-2024.md", syn02["files"])

    def test_no_other_file_states_a_different_value_for_a_judged_fact(self):
        found = questions_mod.contradictions(self.corpus, self.data["questions"])
        self.assertEqual(set(found), set(REVIEWED_NON_CONTRADICTIONS), found)

    def test_the_contradiction_search_finds_planted_clashes(self):
        old = dict(self.corpus)
        old["inbox/note-08.txt"] = b"Wilf can do the Saturday desk on the 21st.\n"  # before rework 2
        self.assertIn(("table-09", "inbox/note-08.txt", 1), questions_mod.contradictions(old, self.data["questions"]))
        planted = dict(self.corpus)
        planted["inbox/note-99.txt"] = b"The refundable deposit for power tools is 30 pounds now.\n"
        self.assertIn(("word-05", "inbox/note-99.txt", 1),
                      questions_mod.contradictions(planted, self.data["questions"]))
        unmarked = json.loads(json.dumps(self.data["questions"]))
        for q in unmarked:
            q.pop("stale", None)
        found = questions_mod.contradictions(self.corpus, unmarked)
        for qid, path in (("word-05", "archive/lending-rules-2024.md"), ("pair-01", "archive/boiler-2025.md"),
                          ("span-08", "archive/boiler-2025.md"), ("span-10", "school/calendar-autumn-draft.md"),
                          ("span-03", "archive/committee-2025.md")):
            self.assertTrue(any(k[:2] == (qid, path) for k in found), (qid, path))

    def test_stale_copies_hold_their_keys_and_are_not_answers(self):
        stale_questions = 0
        for q in self.data["questions"]:
            if q["kind"] == "current-copy":
                self.assertTrue(q.get("stale"), q["id"])
            for r in q.get("stale", []):
                self.assertNotIn(r["path"], q["files"], q["id"])
                lines = own_lines(self.corpus[r["path"]])
                text = fold("\n".join(lines[r["start_line"] - 1:r["end_line"]]))
                for key in r["keys"]:
                    self.assertIn(fold(key), text, q["id"])
                stale_questions += 1
        self.assertGreaterEqual(stale_questions, 22)

    def test_the_new_kinds_are_of_their_shape(self):
        tamil = re.compile("[஀-௿]")
        for q in self.data["questions"]:
            first = [p["ranges"][0] for p in q["parts"]]
            if q["kind"] == "tamil-latin":
                self.assertFalse(tamil.search(q["question"] + q["query"]), q["id"])
                for r in first:
                    lines = own_lines(self.corpus[r["path"]])
                    self.assertTrue(tamil.search("\n".join(lines[r["start_line"] - 1:r["end_line"]])), q["id"])
            if q["kind"] == "table":
                for r in first:
                    line = own_lines(self.corpus[r["path"]])[r["start_line"] - 1]
                    self.assertTrue(line.startswith("|") or "," in line or "\t" in line or ":" in line, q["id"])
            if q["kind"] in ("synonym", "where-is-it"):
                self.assertTrue(q.get("checks"), q["id"])
            if q["kind"] in KINDS[11:]:
                self.assertTrue("added" in q or "was" in q, q["id"])


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

    def test_tightness_judged_share_first_passage_and_budget(self):
        # a.md lines 4-6 returned; the range 5-6 holds lines 5 and 6 (newlines counted)
        got = [passage("a.md", 4, 6, "four\nfive\nsix"), passage("a.md", 20, 20, "z" * 9)]
        row = scorer.score_question(self.Q, got, 100)
        self.assertEqual(row["judged_share"], round((5 + 4 + 10) / (5 + 5 + 4 + 10), 4))
        self.assertTrue(row["complete"])
        self.assertFalse(row["first_passage"])  # part 2 (line 20) is in a.md's second passage
        self.assertTrue(row["complete_within"])
        row = scorer.score_question(self.Q, got, scorer.BUDGET_BYTES + 1)
        self.assertFalse(row["complete_within"])
        self.assertTrue(scorer.score_question(self.Q, got, scorer.BUDGET_BYTES)["complete_within"])  # <=, not <
        one = dict(self.Q, parts=self.Q["parts"][:1])
        self.assertTrue(scorer.score_question(one, got, 1)["first_passage"])
        # an a.md passage before the one holding 5-6: complete, not in the first passage
        got = [passage("a.md", 1, 2, "a\nb"), passage("a.md", 5, 6, "e\nf")]
        row = scorer.score_question(one, got, 1)
        self.assertTrue(row["complete"])
        self.assertFalse(row["first_passage"])
        # the alternative b.md, first in its file, counts
        self.assertTrue(scorer.score_question(one, [passage("a.md", 1, 2), passage("b.md", 1, 3)], 1)["first_passage"])
        self.assertEqual(scorer.score_question(self.Q, [], 1)["judged_share"], None)

    def test_judged_share_follows_the_file_when_content_skips_a_blank_start_line(self):
        """The engine sometimes starts a passage on a blank line its content skips (the Verdict's finding 7)."""
        q = {"id": "b", "kind": "word", "files": ["a.md"],
             "parts": [{"ranges": [{"path": "a.md", "start_line": 3, "end_line": 3, "keys": ["k"]}]}]}
        file_lines = {"a.md": ["one", "", "  three", "four"]}
        got = [passage("a.md", 2, 4, "three\nfour")]       # starts at the blank line 2, leading spaces trimmed
        self.assertEqual(scorer.first_line_offset(got[0], file_lines), 1)
        aligned = scorer.score_question(q, got, 1, file_lines)
        self.assertEqual(aligned["judged_share"], round(6 / 11, 4))  # "three\n" is line 3
        unaligned = scorer.score_question(q, got, 1)
        self.assertEqual(unaligned["judged_share"], round(5 / 11, 4))  # without the file: "four\n" taken as line 3
        self.assertEqual(scorer.first_line_offset(passage("a.md", 3, 4, "three\nfour"), file_lines), 0)
        self.assertEqual(scorer.first_line_offset(passage("a.md", 1, 2, "absent"), file_lines), 0)

    def test_a_stale_copy_ranked_first_is_counted(self):
        q = {"id": "s", "kind": "current-copy", "files": ["new.md"], "single_source": False,
             "parts": [{"ranges": [{"path": "new.md", "start_line": 1, "end_line": 1, "keys": ["k"]}]}],
             "stale": [{"path": "old.md", "start_line": 1, "end_line": 1, "keys": ["k"]}]}
        row = scorer.score_question(q, [passage("old.md", 1, 1), passage("new.md", 1, 1)], 1)
        self.assertEqual((row["stale_rank"], row["file_rank"], row["stale_first"], row["complete"]), (1, 2, True, True))
        row = scorer.score_question(q, [passage("new.md", 1, 1), passage("old.md", 1, 1)], 1)
        self.assertFalse(row["stale_first"])
        agg = scorer.aggregate([row], set())
        self.assertEqual(agg["stale_first"], {"hits": 0, "of": 1, "share": 0.0})

    def test_totals_with_and_without_single_source(self):
        one = dict(self.Q, id="one", single_source=True)
        two = dict(self.Q, id="two", single_source=False)
        rows = [scorer.score_question(one, [passage("a.md", 1, 30)], 1), scorer.score_question(two, [], 1)]
        summary = scorer.summarize(rows, ["two-passages"], set())
        self.assertEqual(summary["total"]["complete"]["hits"], 1)
        self.assertEqual(summary["total_without_single_source"]["questions"], 1)
        self.assertEqual(summary["total_without_single_source"]["complete"]["hits"], 0)

    def test_the_readable_now_total(self):
        now = dict(self.Q, id="now", single_source=False, readable_now=True)
        later = dict(self.Q, id="later", single_source=False, readable_now=False)
        rows = [scorer.score_question(now, [], 1), scorer.score_question(later, [passage("a.md", 1, 30)], 1)]
        summary = scorer.summarize(rows, ["two-passages"], set())
        self.assertEqual(summary["total"]["complete"]["hits"], 1)
        self.assertEqual(summary["total_readable_now"]["questions"], 1)
        self.assertEqual(summary["total_readable_now"]["complete"]["hits"], 0)

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
                for form in ("typed", "query"):
                    agree = out["direct_equals_index"][f"{field}/{form}"]
                    self.assertEqual(agree["identical"], agree["of"], (field, form))
            # S6-T23 (text-sniff-v1): every file of the folder is text, so the
            # engine reads all of them, the CSV, TSV, .log and extensionless files
            # too. The judgments' fixed `readable_now` list (S6-T22) still names
            # the files of the 19 extensions; it is not the engine's set any more.
            unread = out["corpus"]["files_not_read"]
            self.assertEqual(unread, [])
            corpus = corpus_mod.build_corpus()
            self.assertIn("inbox/NOTES", corpus)
            self.assertFalse(questions_mod.readable("inbox/NOTES"))
            self.assertEqual(scorer.markdown(out, KINDS).count("| **total** (with an answer)"), 4)
            self.assertEqual(scorer.markdown(out, KINDS).count("| **total without single-source**"), 4)
            self.assertEqual(scorer.markdown(out, KINDS).count("| **total readable now**"), 4)
            self.assertIn("first passage (ranking)", scorer.markdown(out, KINDS))


if __name__ == "__main__":
    unittest.main()
