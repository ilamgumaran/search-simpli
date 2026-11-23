"""S6-T24 (plan step H3): the exact-string question set of `scan`, frozen.

`fixtures/text-search/exact-strings.json` is written by
`scripts/exact_string_questions.py` from the judged folder of S6-T22 (its
`corpus_sha256` unchanged) and frozen by a digest per question
(`fixtures/text-search/exact-string-digests.json`), committed before the engine's
`scan` was run against it. Checked here, without the engine:

- the fixture is what the script writes, and every question matches its digest;
- 64 questions, eight of each of the eight kinds;
- the literal answers again by a second method: a byte search per line with a
  splitter written here (`\\n`, `\\r\\n`, `\\r`; the folder holds no other break);
- `grep -rn` (LC_ALL=C) gives the same lines for every question that names grep
  arguments; a question that does not names its reason.

`ScanAcceptanceTests` (added with the engine) runs `searchd scan` over the folder.
All content is invented."""

import json
import shutil
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(ROOT / "scripts"))

import exact_string_questions as questions_mod  # noqa: E402
import gen_text_search_corpus as corpus_mod  # noqa: E402

FIXTURE = ROOT / "fixtures" / "text-search" / "exact-strings.json"
DIGESTS = ROOT / "fixtures" / "text-search" / "exact-string-digests.json"


def split_lines(data: bytes) -> list[bytes]:
    if data.startswith(b"\xef\xbb\xbf"):
        data = data[3:]
    lines = data.replace(b"\r\n", b"\n").replace(b"\r", b"\n").split(b"\n")
    return lines[:-1] if lines and lines[-1] == b"" else lines


class ExactStringSetTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.text = FIXTURE.read_text(encoding="utf-8")
        cls.data = json.loads(cls.text)
        cls.corpus = corpus_mod.build_corpus()

    def test_fixture_is_what_the_script_writes(self):
        self.assertEqual(self.text, questions_mod.render())

    def test_every_question_matches_its_frozen_digest(self):
        frozen = json.loads(DIGESTS.read_text(encoding="utf-8"))
        self.assertEqual(DIGESTS.read_text(encoding="utf-8"), questions_mod.render_digests(self.data))
        now = {q["id"]: questions_mod.question_digest(q) for q in self.data["questions"]}
        self.assertEqual(len(now), 64)
        self.assertEqual(now, frozen["questions"])

    def test_any_edit_to_a_question_changes_its_digest(self):
        by_id = {q["id"]: q for q in self.data["questions"]}
        edits = {
            "pattern": lambda q: q["request"].update(pattern=q["request"]["pattern"] + " "),
            "case": lambda q: q["request"].update(case="sensitive"),
            "a line dropped": lambda q: q["expect"]["lines"].pop(),
            "grep": lambda q: q["grep"].update(args=["-F", "-i"]),
        }
        for name, edit in edits.items():
            q = json.loads(json.dumps(by_id["num-04"]))
            before = questions_mod.question_digest(q)
            edit(q)
            self.assertNotEqual(before, questions_mod.question_digest(q), name)

    def test_eight_kinds_of_eight(self):
        kinds = {}
        for q in self.data["questions"]:
            kinds.setdefault(q["kind"], []).append(q["id"])
        self.assertEqual(sorted(kinds), sorted(questions_mod.KINDS))
        self.assertEqual({k: len(v) for k, v in kinds.items()}, {k: 8 for k in questions_mod.KINDS})
        self.assertEqual(self.data["corpus"]["corpus_sha256"], corpus_mod.corpus_digest(self.corpus))
        # every no-answer question has no line; every other kind has questions with answers
        for q in self.data["questions"]:
            if q["kind"] == "no-answer":
                self.assertEqual(q["expect"]["lines"], [], q["id"])
        self.assertGreater(sum(1 for q in self.data["questions"] if q["expect"]["lines"]), 50)

    def test_literal_answers_by_a_byte_search(self):
        """Sensitive literals: the lines holding the pattern's bytes; insensitive ASCII ones by bytes.lower()."""
        checked = 0
        for q in self.data["questions"]:
            request = q["request"]
            if request["mode"] != "literal" or request["whole_word"]:
                continue
            needle = request["pattern"].encode("utf-8")
            insensitive = q["expect"]["case_applied"] == "insensitive"
            if insensitive and not needle.isascii():
                needle_ok = needle == needle.lower()  # Tamil has no case: the fold is the identity on it
                self.assertTrue(needle_ok, q["id"])
                insensitive = False
            found = []
            for path in sorted(self.corpus):
                for number, line in enumerate(split_lines(self.corpus[path]), 1):
                    hay = line.lower() if insensitive else line
                    if (needle.lower() if insensitive else needle) in hay:
                        found.append(f"{path}:{number}")
            self.assertEqual(found, q["expect"]["lines"], q["id"])
            # offsets: each span's text is the pattern (up to case)
            for key, spans in q["expect"]["offsets"].items():
                path, number = key.rsplit(":", 1)
                line = split_lines(self.corpus[path])[int(number) - 1].decode("utf-8")
                for start, end in spans:
                    got = line[start:end]
                    self.assertEqual(got.lower() if insensitive else got,
                                     request["pattern"].lower() if insensitive else request["pattern"], q["id"])
            checked += 1
        self.assertGreaterEqual(checked, 30)

    def test_grep_agrees_or_the_question_says_why_not(self):
        grep = shutil.which("grep")
        if grep is None:
            self.skipTest("no grep on PATH")
        reasons = [q["id"] for q in self.data["questions"] if "args" not in q["grep"]]
        for q in self.data["questions"]:
            if "args" not in q["grep"]:
                self.assertTrue(q["grep"]["reason"], q["id"])
        self.assertEqual(len(reasons), 6, reasons)
        self.assertEqual(questions_mod.grep_disagreements(self.data, grep), [])


if __name__ == "__main__":
    unittest.main()
