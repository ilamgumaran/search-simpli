"""S5-T3: misspelling tolerance (`fuzzy-v1`) in the Python reference.

A query term that no chunk in scope holds and no visible file's title field holds,
all Latin script and at least 5 code points long, is also searched as at most 3
dictionary words within an optimal-string-alignment distance of 1 (5 code points)
or 2 (6 or more) that share its first code point. They score as one word: one
shared document frequency (the largest of theirs), the best member per chunk,
weighted 1.0 at distance 1 and 0.5 at distance 2 (docs/tasks/S5-T3.md ruling 2)."""

import functools
import math
import os
import random
import subprocess
import sys
import tempfile
import unittest
from collections import Counter
from pathlib import Path
from unittest import mock

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO))

from src.search_platform.core import (  # noqa: E402
    FUZZY_POLICY_ID, _bm25_scores, _fuzzy_groups, _fuzzy_latin, _osa_within, build_index, fuzzy_expansions, search,
)
import relevance_smoke  # noqa: E402
from relevance_smoke import run_j2_pack  # noqa: E402

sys.path.insert(0, str(REPO / "scripts"))
import j2_run  # noqa: E402
try:  # `unittest discover -s tests` (CI) or `unittest tests.test_fuzzy`
    from test_title_field import searchd_binary  # noqa: E402
except ImportError:
    from tests.test_title_field import searchd_binary  # noqa: E402


def osa_full(a: str, b: str) -> int:
    """The whole OSA table, unbanded, for comparison."""
    d = [[0] * (len(b) + 1) for _ in range(len(a) + 1)]
    for i in range(len(a) + 1):
        d[i][0] = i
    for j in range(len(b) + 1):
        d[0][j] = j
    for i in range(1, len(a) + 1):
        for j in range(1, len(b) + 1):
            cost = 0 if a[i - 1] == b[j - 1] else 1
            d[i][j] = min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + cost)
            if i > 1 and j > 1 and a[i - 1] == b[j - 2] and a[i - 2] == b[j - 1]:
                d[i][j] = min(d[i][j], d[i - 2][j - 2] + 1)
    return d[len(a)][len(b)]


def write(root: Path, files: dict[str, str]) -> None:
    for path, text in files.items():
        target = root / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(text, encoding="utf-8")


class DistanceTests(unittest.TestCase):
    PAIRS = [
        ("dinosuar", "dinosaur", 1),        # adjacent swap
        ("libary", "library", 1),           # deletion
        ("volcanoe", "volcano", 1),         # insertion
        ("sciense", "science", 1),          # substitution
        ("dinosoar", "dinosaur", 2),        # two substitutions
        ("fractoins", "fraction", 2),       # a swap and a deletion
        ("ca", "abc", 3),                   # OSA, not unrestricted Damerau (which gives 2)
        ("naïve", "naive", 1),              # an accented pair, on code points
        ("frühling", "fruhling", 1),
        ("கடைக்கு", "கடலுக்கு", 2),          # Tamil: measured on code points, never expanded
    ]

    def test_pairs_and_the_band_equal_the_whole_table(self):
        for a, b, want in self.PAIRS:
            self.assertEqual(osa_full(a, b), want, (a, b))
            for k in range(0, 4):
                got = _osa_within(a, b, k)
                self.assertEqual(got, want if want <= k else None, (a, b, k))

    def test_the_band_and_the_early_stop_agree_with_the_table_on_random_words(self):
        rng = random.Random(5)
        alphabet = "abcde"
        for _ in range(3000):
            a = "".join(rng.choice(alphabet) for _ in range(rng.randint(0, 8)))
            b = "".join(rng.choice(alphabet) for _ in range(rng.randint(0, 8)))
            full = osa_full(a, b)
            for k in (1, 2):
                self.assertEqual(_osa_within(a, b, k), full if full <= k else None, (a, b, k))


class TriggerTests(unittest.TestCase):
    DF = Counter({"dinosaur": 3, "dinosaurs": 1, "diner": 2, "café": 1, "pottery": 2, "naive": 1, "frühling": 1})

    def test_length_four_does_not_trigger_and_five_does(self):
        df = Counter({"coat": 2, "coats": 1, "dinner": 1})
        self.assertEqual(_fuzzy_groups(["caot"], df, set()), {})
        # coat (a deletion, df 2) before coats (a substitution, df 1): both at distance 1
        self.assertEqual(_fuzzy_groups(["coatz"], df, set()), {"coatz": (("coat", 1.0), ("coats", 1.0))})

    def test_latin_with_accents_triggers_and_other_scripts_do_not(self):
        self.assertTrue(_fuzzy_latin("fruhling") and _fuzzy_latin("naïve") and _fuzzy_latin("ŧest") and _fuzzy_latin("week9"))
        self.assertFalse(_fuzzy_latin("பழங்கள்") or _fuzzy_latin("caféபழ") or _fuzzy_latin("a÷b") or _fuzzy_latin("ｇｏｇｇｌｅｓ"))
        self.assertEqual(_fuzzy_groups(["fruhling"], self.DF, set()), {"fruhling": (("frühling", 1.0),)})
        df = Counter({"பாடங்கள்": 1, "பழம்": 1})
        self.assertEqual(_fuzzy_groups(["பழங்கள்", "caféபழ"], df, set()), {})

    def test_a_term_held_in_scope_or_by_a_visible_title_does_not_trigger(self):
        self.assertEqual(_fuzzy_groups(["dinosaur"], self.DF, set()), {})
        self.assertEqual(_fuzzy_groups(["health"], Counter({"heath": 1}), {"health"}), {})
        self.assertEqual(_fuzzy_groups(["health"], Counter({"heath": 1}), set()), {"health": (("heath", 1.0),)})


class CandidateTests(unittest.TestCase):
    def test_the_first_code_point_is_kept_and_a_multibyte_first_letter_ranges_alone(self):
        df = Counter({"école": 2, "ecole": 5, "écoles": 1, "fcole": 1})
        self.assertEqual(_fuzzy_groups(["écolz"], df, set()), {"écolz": (("école", 1.0),)})
        self.assertEqual(_fuzzy_groups(["ecolz"], df, set()), {"ecolz": (("ecole", 1.0),)})

    def test_order_distance_then_df_then_bytes_and_three_kept(self):
        df = Counter({"bakes": 1, "baked": 4, "baker": 4, "bakers": 9, "bike": 7, "bakery": 1})
        # bakex (5 code points): distance 1 only; baked/baker (df 4, bytes) then bakes (df 1)
        self.assertEqual(_fuzzy_groups(["bakex"], df, set()),
                         {"bakex": (("baked", 1.0), ("baker", 1.0), ("bakes", 1.0))})
        # bakerx (6): bakers (df 9), baker (4), bakery (1), all at distance 1; bakes and
        # baked (distance 2) are cut by N
        self.assertEqual(_fuzzy_groups(["bakerx"], df, set()),
                         {"bakerx": (("bakers", 1.0), ("baker", 1.0), ("bakery", 1.0))})
        df2 = Counter({"tablet": 1, "tables": 3, "table": 8})
        self.assertEqual(_fuzzy_groups(["tabels"], df2, set()),
                         {"tabels": (("tables", 1.0), ("table", 0.5), ("tablet", 0.5))})

    def test_a_title_only_candidate_orders_at_key_df_one(self):
        df = Counter({"wishes": 1, "wisdom": 3})
        self.assertEqual(_fuzzy_groups(["wislist"], df, {"wishlist", "list"}), {"wislist": (("wishlist", 1.0),)})
        df = Counter({"healthy": 1, "heath": 2})
        self.assertEqual(_fuzzy_groups(["helth"], df, {"health"}), {"helth": (("heath", 1.0), ("health", 1.0))})

    def test_no_candidate_means_no_group(self):
        self.assertEqual(_fuzzy_groups(["zzzzzz"], Counter({"apple": 1}), set()), {})


class ScoringTests(unittest.TestCase):
    def test_no_group_is_the_arithmetic_before_bit_for_bit(self):
        chunks = [{"id": "a", "terms": {"x": 2, "y": 1}, "length": 3}, {"id": "b", "terms": {"y": 4}, "length": 4}]
        self.assertEqual(_bm25_scores(chunks, ["x", "y"], {}), _bm25_scores(chunks, ["x", "y"]))
        self.assertEqual(_bm25_scores(chunks, ["x", "y"], {"zz": (("x", 1.0),)}), _bm25_scores(chunks, ["x", "y"]))

    def test_a_group_scores_its_best_member_at_one_shared_df(self):
        chunks = [{"id": "a", "terms": {"cat": 1}, "length": 5}, {"id": "b", "terms": {"cart": 2}, "length": 5},
                  {"id": "c", "terms": {"cat": 1, "cart": 1}, "length": 5}, {"id": "d", "terms": {"cart": 1}, "length": 3}]
        n, avg = 4, (5 + 5 + 5 + 3) / 4

        def bm25(f, df, dl):
            idf = math.log(1.0 + (n - df + 0.5) / (df + 0.5))
            return idf * (f * 2.2 / (f + 1.2 * (1.0 - 0.75 + 0.75 * dl / avg)))

        got = _bm25_scores(chunks, ["caxt"], {"caxt": (("cart", 1.0), ("cat", 0.5))})
        # the shared df is the larger of cart's (3) and cat's (2)
        self.assertAlmostEqual(got["a"], 0.5 * bm25(1, 3, 5), places=12)
        self.assertAlmostEqual(got["b"], 1.0 * bm25(2, 3, 5), places=12)
        self.assertAlmostEqual(got["d"], 1.0 * bm25(1, 3, 3), places=12)
        # chunk c holds both: the best member, counted once
        self.assertAlmostEqual(got["c"], max(1.0 * bm25(1, 3, 5), 0.5 * bm25(1, 3, 5)), places=12)
        # a weight of 1.0 at distance 1 scores the member exactly as the word itself at the group's df
        self.assertEqual(_bm25_scores(chunks, ["caxt"], {"caxt": (("cart", 1.0),)}),
                         {k: v for k, v in _bm25_scores(chunks, ["cart"]).items()})


class SearchTests(unittest.TestCase):
    def test_a_misspelt_word_finds_the_right_word_and_a_spelt_word_is_untouched(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            write(root, {"dino.md": "# Dinosaur\n\nThe dinosaur bones.\n", "dog.md": "# Dog\n\nChew bones for the dog.\n",
                         "rain.md": "Rain all day."})
            index = build_index(root)
            hits = search(index, "dinosuar", retrieval_mode="lexical")
            self.assertEqual(hits[0]["citation"]["path"], "dino.md")
            self.assertEqual(search(index, "dinosuar", retrieval_mode="lexical", fuzzy=False), [])
            self.assertEqual(fuzzy_expansions(index, "dinosuar bones"), {"dinosuar": ["dinosaur"]})
            for query in ("dinosaur bones", "rain", "dog bones"):
                self.assertEqual(search(index, query, retrieval_mode="lexical"),
                                 search(index, query, retrieval_mode="lexical", fuzzy=False), query)

    def test_privacy_a_word_only_a_hidden_chunk_holds_is_neither_used_nor_reported(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            write(root, {"private/plan.md": "The surprise party plan.", "public/notes.md": "Wren was surprised.",
                         "public/other.md": "Cake at noon."})
            rules = [{"path_prefix": "private/", "required_labels": ["tenant:x"]}]
            index = build_index(root, access_rules=rules)
            # surprise (distance 1) is held only by a chunk the principal cannot see
            self.assertEqual(fuzzy_expansions(index, "surprize"), {"surprize": ["surprised"]})
            hits = search(index, "surprize", retrieval_mode="lexical")
            self.assertEqual([h["citation"]["path"] for h in hits], ["public/notes.md"])
            self.assertEqual(fuzzy_expansions(index, "surprize", principal_labels=["tenant:x"]),
                             {"surprize": ["surprise", "surprised"]})
            # a path prefix narrows the scope: what only another folder holds is no candidate
            self.assertEqual(fuzzy_expansions(index, "surprize", principal_labels=["tenant:x"], path_prefix="public/"),
                             {"surprize": ["surprised"]})

    def test_a_word_only_a_visible_title_holds_guards_and_is_a_candidate(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            write(root, {"health/doctor-visits.md": "Wren: ear check.", "other.md": "Nothing much."})
            index = build_index(root, filename_index=True)
            self.assertEqual(fuzzy_expansions(index, "health"), {})
            self.assertEqual(fuzzy_expansions(index, "helth"), {"helth": ["health"]})
            for field in ("content", "both"):
                hits = search(index, "helth", retrieval_mode="lexical", search_field=field)
                self.assertEqual([h["citation"]["path"] for h in hits], ["health/doctor-visits.md"], field)
            self.assertEqual(search(index, "helth", retrieval_mode="lexical", search_field="filename"), [])

    def test_the_policy_id(self):
        self.assertEqual(FUZZY_POLICY_ID, "fuzzy-v1")


# Ruling 8 (S5-T3 Phase 2): a path prefix narrows membership, not statistics.
# baker is held by four chunks, one of them under kitchen/b/; bakes, baked and
# bakel by two each, all under it. The whole-scope key df keeps baker (4),
# baked, bakel and cuts bakes by bytes, so kitchen/b/three.md (bakes alone) is
# not found; a prefix-narrowed df would keep baked, bakel, bakes and find it.
PREFIX_FILES = {
    "kitchen/a/one.md": "baker", "kitchen/a/two.md": "baker", "kitchen/a/three.md": "baker",
    "kitchen/b/one.md": "baker bakes baked bakel", "kitchen/b/two.md": "baked bakel", "kitchen/b/three.md": "bakes",
}


class PrefixRuleTests(unittest.TestCase):
    def test_the_reference_keeps_whole_scope_key_df_and_holds_candidates_under_the_prefix(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            write(root, PREFIX_FILES)
            index = build_index(root)
            self.assertEqual(fuzzy_expansions(index, "bakex", path_prefix="kitchen/b/"),
                             {"bakex": ["baker", "baked", "bakel"]})
            hits = search(index, "bakex", retrieval_mode="lexical", path_prefix="kitchen/b/")
            self.assertEqual(sorted(h["citation"]["path"] for h in hits), ["kitchen/b/one.md", "kitchen/b/two.md"])

    @unittest.skipIf(os.environ.get("SEARCH_SIMPLI_NO_ZIG") == "1", "SEARCH_SIMPLI_NO_ZIG=1: no searchd")
    def test_searchd_and_the_reference_agree_on_a_prefixed_query(self):
        with tempfile.TemporaryDirectory() as temporary:
            scratch = Path(temporary)
            folder = scratch / "folder"
            write(folder, PREFIX_FILES)
            binary = searchd_binary(scratch)
            done = subprocess.run([str(binary), "index", str(folder), "--out", str(scratch / "idx")],
                                  capture_output=True, text=True, timeout=300)
            self.assertEqual(done.returncode, 0, done.stderr)
            serve = j2_run.Serve(binary, scratch / "idx")
            try:
                # `searchd index FOLDER` writes one legacy root, whose record
                # paths carry no root id.
                rpc = serve.call("search_knowledge", {"query": "bakex", "top_k": 10, "retrieval_mode": "lexical",
                                                      "path_prefix": "kitchen/b/"})
            finally:
                serve.close()
            # search_knowledge over JSON-RPC carries no warnings (the C ABI's
            # ss_query does: fuzzy_test.zig); the hits and their scores say which
            # reading was taken: kitchen/b/three.md (bakes alone) is not found.
            self.assertEqual(sorted(r["citation"]["path"] for r in rpc["results"]),
                             ["kitchen/b/one.md", "kitchen/b/two.md"])
            reference = search(build_index(folder), "bakex", retrieval_mode="lexical", path_prefix="kitchen/b/")
            # The same hits in the same order. The scores differ by the reference's
            # prefix-narrowed BM25 statistics, a difference older than S5-T3 (a plain
            # prefixed "bakes" differs the same way), so only the order is compared.
            self.assertEqual([r["citation"]["path"] for r in rpc["results"]],
                             [r["citation"]["path"] for r in reference])


class J2Tests(unittest.TestCase):
    """Ruling 6 and ruling 7 through the reference."""

    @classmethod
    def setUpClass(cls):
        # S5-T3's bars, as measured before fold-groups-v1 (S5-T4): fold off.
        cls.runs = run_j2_pack(fold="")["runs"]
        with mock.patch.object(relevance_smoke, "search", functools.partial(relevance_smoke.search, fuzzy=False)):
            cls.before = run_j2_pack(fold="")["runs"]

    def test_the_bars(self):
        bars = {"content": (0.438, 0.55), "both": (0.438, 0.50)}
        for variant, (s1, mrr) in bars.items():
            run = self.runs[variant]
            self.assertGreaterEqual(run["slices"]["misspelling"]["success_at_1"], s1, variant)
            self.assertGreaterEqual(run["slices"]["misspelling"]["mrr_at_10"], mrr, variant)
            self.assertEqual(run["slices"]["control"]["success_at_1"], 1.0, variant)
            for name in ("title", "title-heldout", "tamil"):
                ids = [q for q, r in run["queries"].items() if r["slice"] == name]
                self.assertEqual({q: run["queries"][q]["first_grade2_rank"] for q in ids},
                                 {q: self.before[variant]["queries"][q]["first_grade2_rank"] for q in ids}, (variant, name))

    def test_the_heldout_slice(self):
        self.assertGreaterEqual(self.runs["content"]["slices"]["misspelling-heldout"]["success_at_1"], 0.40)
        for variant in ("content", "both"):
            for q, r in self.before[variant]["queries"].items():
                if r["slice"] == "misspelling-heldout" and r["first_grade2_rank"] == 1:
                    self.assertEqual(self.runs[variant]["queries"][q]["first_grade2_rank"], 1, (variant, q))


if __name__ == "__main__":
    unittest.main()
