"""S2-T4: the byte-level stripper behind the bar-(a) comparison."""

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "scripts"))
from strip_report_keys import strip  # noqa: E402

OLD = '{"tool":"search_knowledge","results":[],"answer_policy":{"ground_in_results":true,"cite_path_and_lines":true,"say_when_evidence_is_insufficient":true}}'
NEW_TAIL = ',"warnings":[{"code":"query_term_unmatched","message":"m","term":"x"}],"request":{"analyzer_id":"a","retrieval_mode":"lexical","top_k":1,"candidate_k":2,"path_prefix":null}'


class StripReportKeysTest(unittest.TestCase):
    def test_removes_the_tail_and_leaves_the_old_bytes(self):
        stripped, names = strip(OLD[:-1] + NEW_TAIL + "}")
        self.assertEqual(stripped, OLD)
        self.assertEqual(names, ["warnings", "request"])

    def test_profile_is_last_and_stripped(self):
        profile = ',"profile":{"tokenize_us":1,"score_us":2,"rank_us":3,"serialize_us":4,"matched_chunks":5}'
        stripped, names = strip(OLD[:-1] + NEW_TAIL + profile + "}")
        self.assertEqual(stripped, OLD)
        self.assertEqual(names, ["warnings", "request", "profile"])

    def test_rejects_a_report_without_the_new_keys_or_in_another_order(self):
        with self.assertRaises(ValueError):
            strip(OLD)
        with self.assertRaises(ValueError):
            strip(OLD[:-1] + ',"warnings":[],"profile":{},"request":{}}')


if __name__ == "__main__":
    unittest.main()
