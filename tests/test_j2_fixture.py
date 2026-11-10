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
                  "title": 10, "phrase": 8, "title-heldout": 6, "misspelling-heldout": 10,
                  "morphology-heldout": 12, "accent-heldout": 10, "tamil-heldout": 10,
                  "verbform-heldout": 14}


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

    def test_heldout_title_slice(self):
        """S5-T2 ruling 5 on the plan: at least two folder-only and two stem-only rows."""
        held = [q for q in self.judgments["queries"] if q["slice"] == "title-heldout"]
        where = [next(c["where"] for c in q["checks"] if "where" in c) for q in held]
        self.assertGreaterEqual(sum(1 for w in where if set(w.values()) == {"folder"}), 2)
        self.assertGreaterEqual(sum(1 for w in where if set(w.values()) == {"stem"}), 2)
        for q in held:
            self.assertTrue(any(c["check"].startswith("held out") for c in q["checks"]), q["id"])

    def test_heldout_misspelling_slice(self):
        """S5-T3 ruling 7 of its plan: at least two adjacent swaps, two deletions, one
        insertion and one substitution; two distance-2 typos of words of 8 or more code
        points; one word only a file or folder name holds; one common word (in 8 or more
        files); one 4-code-point word; all knowledge rows, none reusing m01-m16's words."""
        held = [q for q in self.judgments["queries"] if q["slice"] == "misspelling-heldout"]
        facts = [next(c for c in q["checks"] if "edit" in c) for q in held]
        count = lambda test: sum(1 for c in facts if test(c))  # noqa: E731
        for kind, minimum in (("swap", 2), ("deletion", 2), ("insertion", 1), ("substitution", 1)):
            self.assertGreaterEqual(count(lambda c: c["edit"] == kind and c["distance"] == 1), minimum, kind)
        self.assertGreaterEqual(count(lambda c: c["edit"] == "two edits" and c["distance"] == 2
                                      and c["meant_code_points"] >= 8), 2)
        self.assertGreaterEqual(count(lambda c: c["where"] == "name" and c["meant_df"] == 0), 1)
        self.assertGreaterEqual(count(lambda c: c["meant_df"] >= 8), 1)
        self.assertGreaterEqual(count(lambda c: c["meant_code_points"] == 4), 1)
        mwords = {w for q in self.judgments["queries"] if q["slice"] == "misspelling"
                  for c in q["checks"] if "typed" in c for w in (c["typed"], c["meant"])}
        for q, c in zip(held, facts):
            self.assertEqual(q["mode"], "knowledge", q["id"])
            self.assertFalse({c["typed"], c["meant"]} & mwords, q["id"])
            self.assertTrue(any(k["check"].startswith("held out") for k in q["checks"]), q["id"])
    def kinds(self, name: str, field: str) -> dict[str, int]:
        held = [q for q in self.judgments["queries"] if q["slice"] == name]
        out: dict[str, int] = {}
        for q in held:
            out[q.get(field)] = out.get(q.get(field), 0) + 1
            self.assertEqual(q["mode"], "knowledge", q["id"])
            self.assertTrue(any(c["check"].startswith("held out") for c in q["checks"]), q["id"])
        return out

    def test_heldout_morphology_slice(self):
        """S5-T4 ruling 11 of its plan: two -ies, two -ches, two -oes, three keep
        guards, three -ing/-ed rows, one title-only row; both directions."""
        kinds = self.kinds("morphology-heldout", "kind")
        for kind, minimum in (("-ies", 2), ("-ches", 2), ("-oes", 2), ("keep", 3), ("-ing/-ed", 3), ("title", 1)):
            self.assertGreaterEqual(kinds.get(kind, 0), minimum, kind)
        held = [q for q in self.judgments["queries"] if q["slice"] == "morphology-heldout"]
        directions = {c.get("direction") for q in held for c in q["checks"]}
        self.assertTrue({"query plural", "query singular"} <= directions)
        for q in held:
            if q["kind"] == "keep":
                self.assertTrue(any(c["check"].startswith("keep guard") for c in q["checks"]), q["id"])

    def test_heldout_accent_slice(self):
        """S5-T4 ruling 11 of its plan: four short words, two compatibility forms, the
        sharp s, a table letter, a merge guard; plain and accented queries."""
        kinds = self.kinds("accent-heldout", "kind")
        for kind, minimum in (("short", 4), ("nfkc", 2), ("sharp-s", 1), ("table", 1), ("merge-guard", 1)):
            self.assertGreaterEqual(kinds.get(kind, 0), minimum, kind)
        held = [q for q in self.judgments["queries"] if q["slice"] == "accent-heldout"]
        directions = {c.get("direction") for q in held for c in q["checks"]}
        self.assertTrue({"plain query", "accented query"} <= directions)
        for q in held:
            if q["kind"] == "short":
                fact = next(c for c in q["checks"] if "query_code_points" in c)
                self.assertLessEqual(fact["query_code_points"], 4, q["id"])

    def test_heldout_tamil_slice(self):
        """S5-T4 ruling 11 of its plan: ten rule rows over the seven suffixes and three
        guards of three kinds, on words in none of J2's Tamil rows."""
        rules = self.kinds("tamil-heldout", "rule")
        rules.pop(None, None)
        self.assertGreaterEqual(sum(rules.values()), 10)
        self.assertEqual(set(rules), {"ங்கள்", "கள்", "த்தில்", "த்தின்", "க்கு", "யில்", "யின்"})
        guards = self.kinds("tamil-heldout", "tamil_guard")
        guards.pop(None, None)
        self.assertEqual(set(guards), {"accusative", "-வு noun", "keep-list pronoun"})

    def test_heldout_verbform_slice(self):
        """S5-T5 ruling 4: eight verb rows over both directions of each ending pair,
        with the doubled consonant, the dropped e and -ied each exercised; four
        guards whose look-alike sits in the distractor; two rows whose typed word a
        file holds elsewhere; every row in the three new files."""
        kinds = self.kinds("verbform-heldout", "kind")
        for kind, minimum in (("verb", 8), ("guard", 4), ("held", 2)):
            self.assertGreaterEqual(kinds.get(kind, 0), minimum, kind)
        held = [q for q in self.judgments["queries"] if q["slice"] == "verbform-heldout"]
        directions = {q.get("direction") for q in held if q["kind"] == "verb"}
        self.assertEqual(directions, {"-ing->-ed", "-ed->-ing", "base->-ing", "-ing->base", "base->-ed", "-ed->base"})
        features = {q.get("feature") for q in held if q["kind"] == "verb"}
        self.assertTrue({"doubled", "dropped e", "-ied"} <= features)
        new = {"home/family-log.md", "laptop/notes/weekend-jobs.md", "school/year2-blog.md"}
        for q in held:
            self.assertTrue(all(f"{r['root_id']}/{r['path']}" in new for r in q["expected"]), q["id"])
            lead = {"verb": "verb form", "guard": "guard", "held": "held"}[q["kind"]]
            self.assertTrue(any(c["check"].startswith(lead) for c in q["checks"]), q["id"])


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

    def test_heldout_row_must_not_reuse_a_title_slice_word(self):
        self.broken("th02", query="house homework", name=[("house", "stem")])

    def test_heldout_misspelling_must_not_reuse_a_misspelling_slice_word(self):
        self.broken("mh05", query="wifi libary", typo=("libary", "library", False))

    def test_heldout_misspelling_edit_must_be_true_to_the_typo(self):
        self.broken("mh07", edit="deletion")

    def test_heldout_name_word_must_be_absent_from_every_body(self):
        self.broken("mh01", name=True)

    def test_heldout_morphology_must_not_reuse_a_morphology_slice_word(self):
        self.broken("o02", slice="morphology-heldout", kind="-s")

    def test_keep_guard_needs_the_merged_form_in_the_distractor(self):
        self.broken("oh08", guard=("glasses", "glas"))

    def test_merge_guard_needs_the_other_word_in_the_distractor(self):
        self.broken("ah11", guard=("méla", "mella"))

    def test_heldout_tamil_rule_must_end_the_form(self):
        self.broken("tah01", rule="க்கு")

    def test_heldout_tamil_must_not_reuse_a_tamil_row_word(self):
        self.broken("t01", slice="tamil-heldout", rule="கள்")

    def test_verbform_query_form_present_in_the_answer_fails(self):
        self.broken("vh02", query="wobbling", forms=[("wobbling", "wobbling")])

    def test_verbform_direction_must_be_true_to_the_forms(self):
        self.broken("vh02", direction="-ing->-ed")

    def test_verbform_feature_must_be_true_to_the_forms(self):
        self.broken("vh09", feature="doubled")

    def test_verbform_guard_needs_the_lookalike_in_the_distractor(self):
        self.broken("vg1", guard=("herring", "herr"))

    def test_verbform_held_row_needs_the_typed_word_in_a_distractor(self):
        rows = [r for r in self.specs["vt1"]["rows"] if "Winter notices" not in r[1]]
        self.broken("vt1", rows=rows)

    def test_verbform_row_must_not_reuse_a_morphology_word(self):
        self.broken("vh09", query="knead dough teeth")

    def test_verbform_files_must_keep_out_of_earlier_query_words(self):
        files = dict(self.generator.build_files())
        files["home/family-log.md"] += "\nGran found one dinosaur bone.\n".encode("utf-8")
        problems = self.generator.new_file_hygiene(self.generator.Corpus(files))
        self.assertTrue(any("dinosaur" in p for p in problems), problems)

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
