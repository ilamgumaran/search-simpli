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
                  "verbform-heldout": 14, "verbform-cross": 6, "precision-control": 8,
                  "misspelling-short": 12, "misspelling-opening": 25}
# The S5-T8 re-ruling, item 3: misspelling-opening is the verifier's rows as they were
# run, and the verifier wrote no negative for it.
NO_NEGATIVES = {"misspelling-opening"}
# S5-T8 ruling 1: two negative sets of at least 15, at least 30 in all.
NEGATIVE_SET_MINIMUMS = {"negatives-tuning": 15, "negatives-heldout": 15}
NEGATIVE_KINDS = {"stop-name", "near-word", "near-topic", "cross-form", "tamil", "accent", "half-held"}
LUCENE_STOP_WORDS = {"a", "an", "and", "are", "as", "at", "be", "but", "by", "for", "if", "in", "into", "is", "it",
                     "no", "not", "of", "on", "or", "such", "that", "the", "their", "then", "there", "these", "they",
                     "this", "to", "was", "will", "with"}


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
            if name in NO_NEGATIVES:
                continue
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

    def test_s5t8_negative_sets(self):
        """S5-T8 ruling 1: at least 30 new negatives in two sets of at least 15, each
        set covering every kind; no new negative's word but a stop word reuses an
        earlier slice's query word."""
        queries = self.judgments["queries"]
        for name, minimum in NEGATIVE_SET_MINIMUMS.items():
            held = [q for q in queries if q["slice"] == name]
            self.assertGreaterEqual(len(held), minimum, name)
            self.assertTrue(all(q.get("negative") and q["mode"] == "knowledge" for q in held), name)
            self.assertEqual({q["kind"] for q in held}, NEGATIVE_KINDS, name)
        self.assertGreaterEqual(sum(1 for q in queries if q["slice"] in NEGATIVE_SET_MINIMUMS), 30)
        for q in queries:
            if q["slice"] in NEGATIVE_SET_MINIMUMS or q["slice"] in ("verbform-cross", "precision-control"):
                self.assertTrue(any(c["check"].startswith("new words") for c in q["checks"]), q["id"])

    def test_s5t8_graded_slices(self):
        """S5-T8 ruling 1: R05's opposing hop/hope and evening/even rows judged on both
        sides, answers in at least six files; precision-control holds stop-word
        titles, near spellings and verb forms."""
        queries = self.judgments["queries"]
        cross = [q for q in queries if q["slice"] == "verbform-cross"]
        files = {(r["root_id"], r["path"]) for q in cross for r in q["expected"] if r["grade"] == 2}
        self.assertGreaterEqual(len(files), 6)
        typed = {c["typed"]: c["cross"] for q in cross for c in q["checks"] if "cross" in c}
        self.assertTrue({"hops", "hoping"} <= set(typed))
        self.assertTrue({"evenings", "even"} <= set(typed))
        for q in cross:
            self.assertIn(0, [r["grade"] for r in q["expected"]], q["id"])
        kinds = {}
        for q in queries:
            if q["slice"] == "precision-control":
                kinds[q["kind"]] = kinds.get(q["kind"], 0) + 1
        self.assertEqual(set(kinds), {"stop-title", "near", "verb"})
        self.assertGreaterEqual(sum(kinds.values()), 8)

    def test_s5t8_measure_inputs(self):
        """The measure of what misleads (README): Lucene's 33 stop words and `my`;
        every verb form judged same or cross."""
        self.assertEqual(set(self.judgments["stop_words"]), LUCENE_STOP_WORDS | {"my"})
        self.assertEqual(len(self.judgments["stop_words"]), 34)
        verdicts = {v for forms in self.judgments["verb_form_judgments"].values() for v in forms.values()}
        self.assertEqual(verdicts, {"same", "cross"})

    def test_s5t8_short_typo_slice(self):
        """S5-T8 Phase 1c (ruling 3 of the Phase 1 rulings): at least 12 typed words of 6
        and 7 code points, Levenshtein 2 from the meant word, at least 5 a swapped
        adjacent pair, the rest a dropped and an added letter or two wrong letters; at
        least 3 negatives of a correctly spelt 6 or 7 code point word with a near word."""
        queries = self.judgments["queries"]
        short = [q for q in queries if q["slice"] == "misspelling-short"]
        self.assertGreaterEqual(len(short), 12)
        facts = [next(c for c in q["checks"] if "levenshtein" in c) for q in short]
        self.assertTrue(all(c["levenshtein"] == 2 for c in facts))
        self.assertEqual({c["typed_code_points"] for c in facts}, {6, 7})
        self.assertGreaterEqual(sum(1 for q in short if q["kind"] == "swap" and q["transposition"]), 5)
        self.assertLessEqual({q["kind"] for q in short}, {"swap", "drop and add", "two wrong letters"})
        self.assertTrue(all(q["kind"] != "swap" or c["distance"] == 1 for q, c in zip(short, facts)))
        negatives = [q for q in queries if q["slice"] == "negatives-short"]
        self.assertGreaterEqual(len(negatives), 3)
        for q in negatives:
            self.assertEqual((q["kind"], q["negative_of"]), ("near-word", "misspelling-short"), q["id"])
            self.assertIn(len(q["query"]), (6, 7), q["id"])
            self.assertTrue(next(c for c in q["checks"] if "near" in c)["near"], q["id"])
        for q in short + negatives:
            self.assertTrue(any(c["check"].startswith("new words") for c in q["checks"]), q["id"])

    def test_s5t8_opening_typo_slice(self):
        """The S5-T8 re-ruling, item 3: the verifier's 25 typed words of 6 and 7 code
        points, two edits from the meant word with no fixture word one edit away; 16
        keep the first letter and miss the second, 9 miss the first; each answer row is
        a whole file holding the meant word, and every such file is one."""
        opening = [q for q in self.judgments["queries"] if q["slice"] == "misspelling-opening"]
        self.assertEqual(len(opening), 25)
        facts = [next(c for c in q["checks"] if "typed" in c) for q in opening]
        self.assertTrue(all(c["distance"] == 2 and c["typed_code_points"] in (6, 7) for c in facts))
        self.assertEqual(sum(1 for q in opening if q["kind"] == "second letter"), 16)
        self.assertEqual(sum(1 for q in opening if q["kind"] == "first letter"), 9)
        for q, c in zip(opening, facts):
            self.assertIn(c["typed"], q["query"].split(), q["id"])
            if q["kind"] == "second letter":
                self.assertEqual(c["typed"][0], c["meant"][0], q["id"])
                self.assertNotEqual(c["typed"][1], c["meant"][1], q["id"])
            else:
                self.assertNotEqual(c["typed"][0], c["meant"][0], q["id"])
            self.assertTrue(all(r["grade"] == 2 and r["start_line"] == 1 for r in q["expected"]), q["id"])
            self.assertFalse(q.get("negative"), q["id"])

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

    def broken_because(self, qid: str, reason: str, **change) -> None:
        spec = copy.deepcopy(self.specs[qid])
        spec.update(change)
        with self.assertRaises(SystemExit) as caught:
            self.generator.build_query(self.corpus, spec)
        self.assertIn(reason, str(caught.exception))

    def test_s5t8_query_must_not_reuse_an_earlier_word(self):
        self.broken_because("nh02", "earlier slice", query="my puppy")

    def test_s5t8_cross_form_must_be_held_and_judged(self):
        self.broken("nh11", cross=("canned", "cans"))
        self.broken("x05", cross=("tapping", "tapped", "tape"))

    def test_s5t8_stop_title_needs_the_stop_word_in_the_name(self):
        self.broken("pc04", query="our flowers")

    def test_s5t8_near_negative_needs_a_neighbour(self):
        self.broken("nt05", query="hiking")

    def test_s5t8_short_typo_must_be_two_levenshtein_edits_of_6_or_7(self):
        self.broken_because("ms01", "Levenshtein", query="centra", typo=("centra", "centre", False))
        self.broken_because("ms10", "6 or 7 code points", query="dokterrs", typo=("dokterrs", "doctor", False))
        self.broken_because("ms09", "declared drop and add", kind="drop and add")

    def test_s5t8_opening_typo_must_be_two_edits_with_no_one_edit_route(self):
        self.broken_because("mo02", "distance", query="rhymin words", typo=("rhymin", "rhyming"))
        self.broken_because("mo04", "declared first letter", kind="first letter")
        self.broken_because("mo17", "the answer files", rows=[("home/household.md", "*", 2, "not the plumber")])
        self.broken_because("mo25", "one edit from", query="plastac cast", typo=("plastac", "plaster"))

    def test_s5t8_every_reachable_verb_form_is_judged(self):
        judgments = self.generator.queries.VERB_FORM_JUDGMENTS
        saved = judgments.pop("goat")
        try:
            with self.assertRaises(SystemExit) as caught:
                self.generator.build_judgments(self.corpus)
        finally:
            judgments["goat"] = saved
        self.assertIn("goat->goats", str(caught.exception))

    def test_s5t8_files_must_keep_out_of_earlier_query_words(self):
        files = dict(self.generator.build_files())
        files["home/clover.md"] += "\nOne dinosaur bone in the hutch.\n".encode("utf-8")
        problems = self.generator.s5t8_file_hygiene(self.generator.Corpus(files))
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
