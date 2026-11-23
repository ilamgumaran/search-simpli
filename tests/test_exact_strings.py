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

`ScanAcceptanceTests` (added with the engine) runs `searchd scan` over the folder and
over an index of it.
All content is invented."""

import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(ROOT / "scripts"))

import exact_string_questions as questions_mod  # noqa: E402
import gen_text_search_corpus as corpus_mod  # noqa: E402

sys.path.insert(0, str(ROOT / "tests"))
from test_folder_surfaces import build_searchd  # noqa: E402

NO_ZIG = os.environ.get("SEARCH_SIMPLI_NO_ZIG") == "1"

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


@unittest.skipIf(NO_ZIG, "SEARCH_SIMPLI_NO_ZIG=1: this environment deliberately has no Zig (CI)")
class ScanAcceptanceTests(unittest.TestCase):
    """`searchd scan` answers every frozen question: its lines in order, `case_applied`, and for a
    literal question its offsets; over an index of the folder and over the folder itself, paged to the
    end with `max_hits_per_file` 1000 and no file capped."""

    @classmethod
    def setUpClass(cls):
        cls.scratch_dir = tempfile.TemporaryDirectory()
        scratch = Path(cls.scratch_dir.name)
        cls.binary = build_searchd(scratch)
        cls.folder = scratch / "folder"
        for path, data in corpus_mod.build_corpus().items():
            target = cls.folder / path
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(data)
        cls.index = scratch / "index"
        subprocess.run([str(cls.binary), "index", str(cls.folder), "--out", str(cls.index)], check=True,
                       capture_output=True, stdin=subprocess.DEVNULL, timeout=300)
        cls.data = json.loads(FIXTURE.read_text(encoding="utf-8"))

    @classmethod
    def tearDownClass(cls):
        cls.scratch_dir.cleanup()

    def answer(self, where, request):
        hits, cursor, first, capped = [], None, None, 0
        while True:
            args = [str(self.binary), "scan", *where, request["pattern"], "--json", "--case", request["case"],
                    "--page-size", "100", "--max-per-file", "1000", "--time-ms", "30000"]
            args += (["--regex"] if request["mode"] == "regex" else []) + (["--word"] if request["whole_word"] else [])
            args += ["--cursor", cursor] if cursor else []
            done = subprocess.run(args, capture_output=True, stdin=subprocess.DEVNULL, timeout=120)
            self.assertEqual(done.returncode, 0, done.stderr)
            page = json.loads(done.stdout)
            first = first or page
            hits += page["hits"]
            capped += page["files_capped"]
            cursor = page["next_cursor"]
            if cursor is None:
                return first, hits, capped

    def test_every_question_over_the_index_and_the_folder(self):
        answered = 0
        for where in ((str(self.index),), ("--folder", str(self.folder))):
            for q in self.data["questions"]:
                first, hits, capped = self.answer(where, q["request"])
                label = f"{q['id']} {where[0]}"
                self.assertEqual([f"{h['path']}:{h['line']}" for h in hits], q["expect"]["lines"], label)
                self.assertEqual(first["case_applied"], q["expect"]["case_applied"], label)
                self.assertEqual(capped, 0, label)
                self.assertEqual(first["stopped"], "none", label)
                for key, spans in q["expect"].get("offsets", {}).items():
                    hit = next(h for h in hits if f"{h['path']}:{h['line']}" == key)
                    self.assertEqual(hit["match_offsets"], spans, f"{label} {key}")
                answered += 1
        self.assertEqual(answered, 128)


if __name__ == "__main__":
    unittest.main()
