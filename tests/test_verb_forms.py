"""S5-T5: R, the verb-form rule of fold-groups-v2 (`verb_forms.py`), and its groups in
the reference (`core._query_groups`; docs/fold-groups-v2.md); S5-T8: fold-groups-v3's
eligible forms (docs/fold-groups-v3.md). Invented content only."""

import sys
import tempfile
import unittest
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "src"))

from search_platform import verb_forms as r  # noqa: E402
from search_platform.core import (FOLD_POLICY_ID, VERB_FORM_HELD_WEIGHT, _query_groups,  # noqa: E402
                                  build_index, fold_groups, search)


def write(root: Path, files: dict) -> None:
    for path, text in files.items():
        target = root / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(text, encoding="utf-8")


class RuleTests(unittest.TestCase):
    def test_bases(self):
        self.assertEqual(r.bases("hopping"), ["hopping", "hopp", "hoppe", "hop"])
        self.assertEqual(r.bases("hoped"), ["hoped", "hop", "hope"])
        self.assertEqual(r.bases("tidied"), ["tidied", "tidi", "tidie", "tidy"])
        self.assertEqual(r.bases("paints"), ["paint"])  # S first
        self.assertEqual(r.bases("Painting"), ["painting", "paint", "painte"])  # F first
        self.assertEqual(r.bases("café"), ["cafe"])  # A first
        self.assertEqual(r.bases("løve"), ["love"])

    def test_the_remainder_needs_three_letters_and_a_vowel(self):
        self.assertEqual(r.bases("sing"), ["sing"])     # s
        self.assertEqual(r.bases("feed"), ["feed"])     # fe
        self.assertEqual(r.bases("string"), ["string"])  # str: no vowel
        self.assertIn("fly", r.bases("flying"))          # y counts in a remainder
        self.assertEqual(r.bases("tied"), ["tied"])     # -ied needs five letters

    def test_undoubling_keeps_l_s_z(self):
        self.assertEqual(r.bases("fizzing"), ["fizzing", "fizz", "fizze"])
        self.assertEqual(r.bases("missed"), ["missed", "miss", "misse"])
        self.assertEqual(r.bases("rolled"), ["rolled", "roll", "rolle"])
        self.assertIn("plan", r.bases("planned"))

    def test_relatives(self):
        self.assertEqual(r.relatives("hop"), ["hop", "hops", "hopes", "hoped", "hoping", "hopped", "hopping"])
        self.assertEqual(r.relatives("dance"), ["dance", "dances", "dancees", "danceed", "danceing", "danced",
                                                "dancing"])
        self.assertEqual(r.relatives("tidy"), ["tidy", "tidys", "tidyes", "tidyed", "tidying", "tidies", "tidied"])

    def test_off(self):
        for term in ("aaa", "a" * 50, "ab1d", "x²", "½", "பாடல்கள்"):
            self.assertEqual(r.bases(term), [], term)
            self.assertEqual(r.forms(term), [], term)
        self.assertTrue(r.bases("a" * 49))

    def test_forms_leave_the_term_out_and_count_lookups(self):
        forms = r.forms("hopping")
        self.assertNotIn("hopping", forms)
        self.assertEqual(len(forms), len(set(forms)))
        self.assertLessEqual(len(forms), 19)


class EligibleTests(unittest.TestCase):
    """S5-T8 (fold-groups-v3): R's forms less those of another word."""

    def test_the_doubling_shape(self):
        for b in ("hop", "tap", "car", "bit", "bus", "whiz", "ship"):
            self.assertTrue(r.doubling_shape(b), b)
        for b in ("box", "row", "play", "visit", "oil", "even", "at", "hope", "quiz"):
            self.assertFalse(r.doubling_shape(b), b)

    def test_rule_i_a_doubling_base_loses_its_undoubled_forms(self):
        forms = r.eligible_forms("hopping")
        for gone in ("hoped", "hoping", "hopes"):
            self.assertIn(gone, r.forms("hopping"))
            self.assertNotIn(gone, forms)
        self.assertIn("hops", forms)
        self.assertIn("hopped", forms)
        # -es stays after s, x, z, ch or sh.
        self.assertIn("whizes", r.eligible_forms("whiz"))
        self.assertNotIn("whized", r.eligible_forms("whiz"))
        self.assertNotIn("hopes", r.eligible_forms("hop" + "s"))

    def test_rule_ii_the_remainder_of_a_single_letter_ending_is_left_out(self):
        self.assertNotIn("hop", r.eligible_forms("hoping"))
        self.assertIn("hope", r.eligible_forms("hoping"))
        self.assertNotIn("car", r.eligible_forms("caring"))
        self.assertIn("care", r.eligible_forms("caring"))
        self.assertIn("visit", r.eligible_forms("visiting"))

    def test_eligible_forms_are_a_subset_of_r_without_repeats(self):
        # A subset, not R's order: a left-out base (hop of hoping) moves the forms it
        # shared with a later base (hopes, hoped) to that base's place.
        for term in ("hopping", "hoping", "tapping", "taping", "dancing", "tidied", "evening", "Painting", "x²"):
            forms, kept = r.forms(term), r.eligible_forms(term)
            self.assertLessEqual(set(kept), set(forms), term)
            self.assertEqual(len(kept), len(set(kept)), term)
            self.assertNotIn(term, kept, term)  # the term as typed, as R leaves it out
        self.assertEqual(r.eligible_forms("hoping"), ["hopings", "hopinges", "hopinged", "hopinging", "hope",
                                                      "hopes", "hopees", "hopeed", "hopeing", "hoped"])


class GroupTests(unittest.TestCase):
    def test_policy(self):
        self.assertEqual(FOLD_POLICY_ID, "fold-groups-v3")

    def test_a_word_no_file_holds_takes_its_forms_at_one_and_no_fuzzy(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            write(root, {"a.md": "We went dancing on Friday.", "b.md": "A dandelion clock."})
            chunks = build_index(root)["chunks"]
            self.assertEqual(_query_groups(chunks, chunks, ["danced"], (), fold="FAST"),
                             {"danced": (("dancing", 1.0),)})
            # fold off: fuzzy-v1 alone, as before
            self.assertNotIn(("dancing", 1.0), _query_groups(chunks, chunks, ["danced"], (), fold="").get("danced", ()))

    def test_a_held_word_takes_a_form_at_half_only_under_its_own_df(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            write(root, {"a.md": "Painting the fence.", "b.md": "Painted the gate.", "c.md": "The painted shed.",
                         "d.md": "Paint pots.", "e.md": "Painting day."})
            chunks = build_index(root)["chunks"]
            # painting df 2: paint (df 1) joins, painted (df 2) joins, both at 0.5
            self.assertEqual(_query_groups(chunks, chunks, ["painting"], (), fold="FAST"),
                             {"painting": (("painting", 1.0), ("painted", VERB_FORM_HELD_WEIGHT),
                                           ("paint", VERB_FORM_HELD_WEIGHT))})
            # paint df 1: painting and painted (df 2) are above it
            self.assertEqual(_query_groups(chunks, chunks, ["paint"], (), fold="FAST"), {})

    def test_the_invariant_a_held_words_group_df_never_rises_through_r(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            words = ["plan", "plans", "planned", "planning", "hop", "hops", "hoped", "hoping", "hopping", "hopped",
                     "tidy", "tidies", "tidied", "tidying", "bake", "baked", "baking", "bakes"]
            files = {}
            for i in range(40):
                files[f"n{i:02d}.md"] = " ".join(words[(i * 7 + j * 3) % len(words)] for j in range(1 + i % 4))
            write(root, files)
            chunks = build_index(root)["chunks"]
            df: Counter = Counter()
            for chunk in chunks:
                df.update(chunk["terms"].keys())
            for word in words:
                if not df[word]:
                    continue
                v1 = _query_groups(chunks, chunks, [word], (), fold="FAST", fuzzy=False)
                for member, weight in v1.get(word, ()):
                    if weight != 1.0:
                        self.assertLessEqual(df[member], df[word], (word, member))

    def test_a_hidden_chunk_s_form_is_not_a_member_and_the_prefix_narrows(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            write(root, {"private/plan.md": "Secret juggling practice.", "public/notes.md": "Rain again.",
                         "other/more.md": "Juggled three balls."})
            rules = [{"path_prefix": "private/", "required_labels": ["tenant:x"]}]
            index = build_index(root, access_rules=rules)
            self.assertEqual(fold_groups(index, "juggle"), {"juggle": ["juggled"]})
            self.assertEqual(fold_groups(index, "juggle", principal_labels=["tenant:x"]),
                             {"juggle": ["juggled", "juggling"]})
            self.assertEqual(fold_groups(index, "juggle", principal_labels=["tenant:x"], path_prefix="public/"), {})
            hits = search(index, "juggle", retrieval_mode="lexical")
            self.assertEqual([h["citation"]["path"] for h in hits], ["other/more.md"])

    def test_a_title_holds_a_form(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            write(root, {"days-out/sledging.md": "Snow on the hill.", "other.md": "Nothing much."})
            index = build_index(root, filename_index=True)
            self.assertEqual(fold_groups(index, "sledged"), {"sledged": ["sledging"]})
            for field in ("content", "both"):
                hits = search(index, "sledged", retrieval_mode="lexical", search_field=field)
                self.assertEqual([h["citation"]["path"] for h in hits], ["days-out/sledging.md"], field)


if __name__ == "__main__":
    unittest.main()
