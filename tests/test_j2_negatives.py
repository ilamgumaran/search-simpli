"""S5-T8: the measure of what misleads (scripts/j2_negatives.py) labels a hit by the
first of real, cross, near, stop that one of its matches has."""

import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO))


def load():
    spec = importlib.util.spec_from_file_location("j2_negatives", REPO / "scripts" / "j2_negatives.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class LabelTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.n = load()
        cls.stop = {"the", "my", "of"}
        cls.verdicts = {"hating": {"hat": "cross", "hates": "same"}}

    def label(self, held, terms, groups=None):
        return self.n.label(set(held), terms, groups or {}, self.stop, self.verdicts)[0]

    def test_stop_word_alone(self):
        self.assertEqual(self.label({"the", "dog"}, ["the", "dragon"]), "stop")

    def test_real_word_beats_a_stop_word(self):
        self.assertEqual(self.label({"the", "dragon"}, ["the", "dragon"]), "real")

    def test_fold_key_mate_is_real(self):
        self.assertEqual(self.label({"pinata"}, ["piñata"], {"piñata": ["pinata"]}), "real")

    def test_verb_form_by_its_verdict(self):
        groups = {"hating": ["hat", "hats", "hates"]}
        self.assertEqual(self.label({"hat"}, ["hating"], groups), "cross")
        self.assertEqual(self.label({"hat", "hates"}, ["hating"], groups), "real")

    def test_unjudged_verb_form_stops(self):
        with self.assertRaises(SystemExit):
            self.label({"hats"}, ["hating"], {"hating": ["hats"]})

    def test_fuzzy_member_is_near(self):
        self.assertEqual(self.label({"spring"}, ["skiing"], {"skiing": ["spring"]}), "near")

    def test_no_match_is_other(self):
        self.assertEqual(self.label({"dog"}, ["dragon"]), "other")


class MeasureTests(unittest.TestCase):
    def test_measure_over_the_reference(self):
        """The committed fixture through the Python reference: every negative is
        measured, and the S5-T8 sets have their counts."""
        n = load()
        import relevance_smoke as rs
        results = rs.run_j2_pack()
        judgments = n.load_judgments()
        with tempfile.TemporaryDirectory() as scratch:
            index = n.build(judgments, Path(scratch))
            out = n.measure(results, judgments, n.capture(index, judgments), n.hit_words(index, judgments))
        for variant in ("content", "both"):
            sets = out["sets"][variant]
            self.assertEqual(sets["negatives-tuning"]["n"], 17)
            self.assertEqual(sets["negatives-heldout"]["n"], 17)
            for s in sets.values():
                self.assertLessEqual(s["mean_top5"], 5)
                self.assertGreaterEqual(s["misleading_first_share"], 0)
                self.assertLessEqual(s["misleading_first_share"], 1)
            self.assertEqual(len(out["queries"][variant]), sum(s["n"] for s in sets.values()))
        json.dumps(out)


if __name__ == "__main__":
    unittest.main()
