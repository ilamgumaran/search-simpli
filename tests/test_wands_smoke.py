import csv
import importlib.util
import json
import tempfile
import unittest
from pathlib import Path


_SCRIPT = Path(__file__).resolve().parents[1] / "scripts" / "prepare_wands_smoke.py"
_SPEC = importlib.util.spec_from_file_location("prepare_wands_smoke", _SCRIPT)
wands = importlib.util.module_from_spec(_SPEC)
_SPEC.loader.exec_module(wands)


def _write_tsv(path, fieldnames, rows):
    with path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames, delimiter="\t")
        writer.writeheader()
        writer.writerows(rows)


class WandsSmokePreparationTests(unittest.TestCase):
    def test_sample_is_deterministic_and_retains_every_selected_positive(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            dataset = root / "dataset"
            dataset.mkdir()
            _write_tsv(
                dataset / "product.csv",
                [
                    "product_id", "product_name", "product_class", "category hierarchy",
                    "product_description", "product_features",
                ],
                [
                    {"product_id": str(i), "product_name": f"product {i}",
                     "product_class": "class", "category hierarchy": "category",
                     "product_description": f"description {i}", "product_features": "x:y"}
                    for i in range(5)
                ],
            )
            _write_tsv(
                dataset / "query.csv",
                ["query_id", "query", "query_class"],
                [
                    {"query_id": "0", "query": "first", "query_class": "a"},
                    {"query_id": "1", "query": "second", "query_class": "b"},
                    {"query_id": "2", "query": "third", "query_class": "c"},
                ],
            )
            _write_tsv(
                dataset / "label.csv",
                ["id", "query_id", "product_id", "label"],
                [
                    {"id": "0", "query_id": "0", "product_id": "0", "label": "Exact"},
                    {"id": "1", "query_id": "0", "product_id": "1", "label": "Partial"},
                    {"id": "2", "query_id": "0", "product_id": "4", "label": "Irrelevant"},
                    {"id": "3", "query_id": "1", "product_id": "2", "label": "Exact"},
                    {"id": "4", "query_id": "2", "product_id": "3", "label": "Exact"},
                ],
            )
            first, second = root / "first", root / "second"
            first_manifest = wands.prepare_wands_sample(
                dataset, first, max_products=3, max_queries=3, seed="fixed"
            )
            second_manifest = wands.prepare_wands_sample(
                dataset, second, max_products=3, max_queries=3, seed="fixed"
            )

            self.assertEqual(first_manifest, second_manifest)
            self.assertEqual(
                (first / "judgments.json").read_text(),
                (second / "judgments.json").read_text(),
            )
            suite = json.loads((first / "judgments.json").read_text())
            corpus_names = {path.name for path in (first / "corpus").iterdir()}
            for query in suite["queries"]:
                for judgment in query["relevant"]:
                    self.assertIn(judgment["path"], corpus_names)
                    self.assertIn(judgment["grade"], {1, 2})
            self.assertEqual(first_manifest["selected"]["products"], 3)


if __name__ == "__main__":
    unittest.main()
