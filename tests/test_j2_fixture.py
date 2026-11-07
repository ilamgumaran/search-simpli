"""S5-T1: the J2 judged fixture matches its generator byte for byte, holds the
inventory the task asks for, and its judgments keep every ruled check."""

import copy
import hashlib
import importlib.util
import json
import re
import sys
import tempfile
import unittest
import unicodedata
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO))

PACK = REPO / "fixtures" / "j2"
ROOTS = ("school", "home", "laptop")
BOM = b"\xef\xbb\xbf"
SLICE_MINIMUMS = {"control": 20, "misspelling": 15, "morphology": 12, "accent": 6, "tamil": 10,
                  "title": 10, "phrase": 8}


def pack_files() -> dict[str, bytes]:
    out = {}
    for root in ROOTS:
        for path in sorted((PACK / root).rglob("*")):
            if path.is_file():
                out[path.relative_to(PACK).as_posix()] = path.read_bytes()
    return out


def load_generator():
    spec = importlib.util.spec_from_file_location("j2_generate", PACK / "generate.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class DeterminismTests(unittest.TestCase):
    def test_regenerates_byte_for_byte(self):
        generator = load_generator()
        with tempfile.TemporaryDirectory() as scratch:
            out = Path(scratch)
            generator.write_tree(out)
            fresh = {p.relative_to(out).as_posix(): p.read_bytes() for p in sorted(out.rglob("*")) if p.is_file()}
        committed = {**pack_files(),
                     "judgments.json": (PACK / "judgments.json").read_bytes(),
                     "README.md": (PACK / "README.md").read_bytes()}
        self.assertEqual(sorted(fresh), sorted(committed))
        for name in committed:
            self.assertEqual(fresh[name], committed[name], f"{name} differs from a fresh generation (P4)")


class InventoryTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.files = pack_files()
        cls.judgments = json.loads((PACK / "judgments.json").read_text(encoding="utf-8"))

    def test_counts(self):
        self.assertEqual(self.judgments["roots"], list(ROOTS))
        self.assertGreaterEqual(len(self.files), 60)
        for root in ROOTS:
            self.assertTrue(any(p.startswith(root + "/") for p in self.files), root)
        self.assertEqual(len(self.judgments["files"]), len(self.files))
        for item in self.judgments["files"]:
            data = self.files[f"{item['root_id']}/{item['path']}"]
            self.assertEqual(item["sha256"], hashlib.sha256(data).hexdigest())
            self.assertEqual(item["bytes"], len(data))

    def test_special_files(self):
        f = self.files
        for path in ("school/trip-permission-museum.md", "home/shopping-list.md"):
            self.assertGreater(f[path].count(b"\r\n"), 0, path)
            self.assertEqual(f[path].count(b"\n"), f[path].count(b"\r\n"), path)
        self.assertEqual([p for p, d in f.items() if d.startswith(BOM)], ["school/class-rules.md"])
        self.assertEqual(sum(1 for d in f.values() if b"\r\n" in d), 2)
        self.assertFalse(f["school/pe-kit.txt"].endswith(b"\n"))
        self.assertEqual(f["school/pe-kit.txt"].count(b"\n"), 0)
        self.assertEqual(f["school/empty-notes.txt"], b"")
        self.assertIn("Noël".encode(), f["school/newsletter-autumn.md"])
        self.assertIn("ﬁ".encode(), f["school/letters/letter-home-oct.txt"])
        self.assertIn("１２".encode(), f["school/notes-from-phone.txt"])
        lines = {p: d.count(b"\n") for p, d in f.items()}
        self.assertGreaterEqual(max(lines.values()), 390)
        self.assertLessEqual(max(lines.values()), 420)
        for root in ROOTS:
            self.assertTrue(any(p.startswith(root + "/") and re.search("[஀-௿]", d.decode("utf-8"))
                                for p, d in f.items()), f"no Tamil file in {root}")
        tamil_name = [p for p in f if re.search("[஀-௿]", p)]
        self.assertEqual(tamil_name, ["home/tamil/பாட்டி-கடிதங்கள்.md"])
        self.assertEqual(unicodedata.normalize("NFC", tamil_name[0]), unicodedata.normalize("NFD", tamil_name[0]))

    def test_slices(self):
        queries = self.judgments["queries"]
        ids = [q["id"] for q in queries]
        self.assertEqual(len(ids), len(set(ids)))
        for name, minimum in SLICE_MINIMUMS.items():
            self.assertGreaterEqual(sum(1 for q in queries if q["slice"] == name), minimum, name)
            self.assertGreaterEqual(sum(1 for q in queries if q.get("negative_of") == name), 2, f"negatives of {name}")
        self.assertGreaterEqual(sum(1 for q in queries if q.get("transposition")), 5)
        self.assertGreaterEqual(sum(1 for q in queries if q.get("only_form")), 3)
        self.assertEqual(sum(1 for q in queries if q.get("guard") == "inflectional"), 2)
        self.assertEqual([q["id"] for q in queries if q.get("reversed")], ["p07"])
        self.assertTrue(any(q["slice"] == "title" and q["checks"][-1]["where"] and
                            all(w == "folder" for w in q["checks"][-1]["where"].values()) for q in queries))

    def test_rows(self):
        lines = {f"{f['root_id']}/{f['path']}": f["lines"] for f in self.judgments["files"]}
        modes = {"knowledge", "find:words", "find:phrase", "find:prefix"}
        for q in self.judgments["queries"]:
            self.assertIn(q["mode"], modes, q["id"])
            self.assertTrue(q["checks"], q["id"])
            grades = [row["grade"] for row in q["expected"]]
            self.assertTrue(set(grades) <= {0, 1, 2}, q["id"])
            if q.get("negative"):
                self.assertEqual(max(grades), 0, q["id"])
            else:
                self.assertIn(2, grades, q["id"])
            for row in q["expected"]:
                path = f"{row['root_id']}/{row['path']}"
                self.assertIn(path, lines, q["id"])
                self.assertTrue(1 <= row["start_line"] <= row["end_line"] <= lines[path], (q["id"], row))


class CheckTests(unittest.TestCase):
    """The generator stops when a ruled check no longer holds: each miss stays real."""

    @classmethod
    def setUpClass(cls):
        cls.generator = load_generator()
        cls.corpus = cls.generator.Corpus(cls.generator.build_files())
        cls.specs = {spec["id"]: spec for spec in cls.generator.queries.QUERIES}

    def broken(self, qid: str, **change) -> None:
        spec = copy.deepcopy(self.specs[qid])
        spec.update(change)
        with self.assertRaises(SystemExit):
            self.generator.build_query(self.corpus, spec)

    def test_committed_judgments_hold(self):
        judgments = self.generator.build_judgments(self.corpus)
        self.assertEqual(judgments, json.loads((PACK / "judgments.json").read_text(encoding="utf-8")))

    def test_misspelt_word_in_a_file_fails(self):
        self.broken("m01", query="dinosaur bones", typo=("dinosaur", "dinosaur", False))

    def test_transposition_flag_must_be_true_to_the_typo(self):
        self.broken("m04", typo=("fractoins", "fractions", False))

    def test_form_present_in_the_answer_fails(self):
        self.broken("o01", query="dinosaur teeth", forms=[("dinosaur", "dinosaur")])

    def test_accent_form_present_in_the_answer_fails(self):
        self.broken("a01", query="café menu", fold=("café", "café"))

    def test_tamil_guard_needs_the_homograph_in_the_distractor(self):
        self.broken("g1", guard=("காலை", "நாள்"))

    def test_title_word_must_sit_where_declared(self):
        self.broken("ti06", name=[("swimming", "stem"), ("lessons", "folder")])

    def test_phrase_distractor_must_hold_the_words_apart(self):
        self.broken("p01", adjacent=1, apart=0)

    def test_negative_needs_a_word_in_the_corpus(self):
        self.broken("tn2", query="கடற்கரை")

    def test_grade_two_and_grade_zero_never_share_a_chunk(self):
        spec = self.specs["c12"]
        rows = list(spec["rows"]) + [("laptop/school-run-rota.md", "=Wednesday pickup", 0, "same chunk")]
        self.broken("c12", rows=rows)


if __name__ == "__main__":
    unittest.main()
