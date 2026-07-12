import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from src.search_platform.access import validate_access_rules
from src.search_platform.core import build_index
from src.search_platform.providers import ProviderMismatch


class CountingProvider:
    def __init__(self, model_id: str = "counting-neural-v1") -> None:
        self.document_batches: list[list[str]] = []
        self._metadata = {
            "model_id": model_id,
            "model_family": "counting-test",
            "type": "neural",
            "dimensions": 2,
            "normalization": "l2",
            "semantic": True,
            "provider": {"type": "test"},
        }

    @property
    def metadata(self) -> dict:
        return dict(self._metadata)

    def embed_documents(self, texts: list[str]) -> list[list[float]]:
        self.document_batches.append(list(texts))
        return [[float(len(text) or 1), 1.0] for text in texts]

    def embed_queries(self, texts: list[str]) -> list[list[float]]:
        return [[1.0, 1.0] for _ in texts]


class IncrementalIndexTests(unittest.TestCase):
    def test_neural_reuses_unchanged_and_embeds_only_changed_and_added_chunks(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "a.md").write_text("unchanged evidence", encoding="utf-8")
            (root / "b.md").write_text("old content", encoding="utf-8")
            (root / "c.md").write_text("to be deleted", encoding="utf-8")
            first_provider = CountingProvider()
            first = build_index(root, vector_mode="neural", embedding_provider=first_provider)
            unchanged_id = next(chunk["id"] for chunk in first["chunks"] if chunk["path"] == "a.md")

            (root / "b.md").write_text("new changed content", encoding="utf-8")
            (root / "c.md").unlink()
            (root / "d.md").write_text("newly added content", encoding="utf-8")
            second_provider = CountingProvider()
            second = build_index(
                root,
                vector_mode="neural",
                embedding_provider=second_provider,
                previous_index=first,
            )

        report = second["stats"]["incremental"]
        self.assertEqual(report["reused_files"], 1)
        self.assertEqual(report["reused_chunks"], 1)
        self.assertEqual(report["changed_files"], 1)
        self.assertEqual(report["added_files"], 1)
        self.assertEqual(report["deleted_files"], 1)
        self.assertEqual(report["embedded_chunks"], 2)
        self.assertEqual(len(second_provider.document_batches), 1)
        self.assertEqual(len(second_provider.document_batches[0]), 2)
        self.assertEqual(
            next(chunk["id"] for chunk in second["chunks"] if chunk["path"] == "a.md"),
            unchanged_id,
        )
        self.assertNotIn("c.md", [chunk["path"] for chunk in second["chunks"]])

    def test_no_change_and_acl_change_reuse_all_neural_vectors(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "private").mkdir()
            (root / "private" / "one.md").write_text("stable private content", encoding="utf-8")
            first = build_index(root, vector_mode="neural", embedding_provider=CountingProvider())
            rules = validate_access_rules(
                {
                    "version": 1,
                    "rules": [
                        {"path_prefix": "private/", "required_labels": ["tenant:acme"]}
                    ],
                }
            )
            second_provider = CountingProvider()
            second = build_index(
                root,
                vector_mode="neural",
                embedding_provider=second_provider,
                access_rules=rules,
                previous_index=first,
            )

        report = second["stats"]["incremental"]
        self.assertFalse(report["corpus_changed"])
        self.assertEqual(report["reused_files"], 1)
        self.assertEqual(report["relabeled_chunks"], 1)
        self.assertEqual(report["embedded_chunks"], 0)
        self.assertEqual(second_provider.document_batches, [])
        self.assertEqual(second["chunks"][0]["required_labels"], ["tenant:acme"])

    def test_incremental_compatibility_is_fail_closed(self) -> None:
        with tempfile.TemporaryDirectory() as temporary, tempfile.TemporaryDirectory() as other:
            root = Path(temporary)
            (root / "one.md").write_text("stable content", encoding="utf-8")
            first = build_index(root, vector_mode="neural", embedding_provider=CountingProvider())
            with self.assertRaisesRegex(ProviderMismatch, "does not match"):
                build_index(
                    root,
                    vector_mode="neural",
                    embedding_provider=CountingProvider("different-model"),
                    previous_index=first,
                )
            with self.assertRaisesRegex(ValueError, "root does not match"):
                build_index(Path(other), vector_mode="neural", embedding_provider=CountingProvider(), previous_index=first)
            without_hashes = dict(first)
            without_hashes.pop("source_files")
            with self.assertRaisesRegex(ValueError, "no source-file hash"):
                build_index(
                    root,
                    vector_mode="neural",
                    embedding_provider=CountingProvider(),
                    previous_index=without_hashes,
                )
            wrong_chunker = dict(first)
            wrong_chunker["chunking"] = {**first["chunking"], "max_chars": 999}
            with self.assertRaisesRegex(ValueError, "chunker contract"):
                build_index(
                    root,
                    vector_mode="neural",
                    embedding_provider=CountingProvider(),
                    previous_index=wrong_chunker,
                )

    def test_transient_read_failure_retains_previous_chunks_as_stale(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "one.md"
            source.write_text("evidence that should remain available", encoding="utf-8")
            first = build_index(root, vector_mode="none")
            original_read_bytes = Path.read_bytes

            def fail_selected(path: Path) -> bytes:
                if path.name == source.name:
                    raise OSError("temporary read failure")
                return original_read_bytes(path)

            with patch.object(Path, "read_bytes", fail_selected):
                second = build_index(root, vector_mode="none", previous_index=first)

        report = second["stats"]["incremental"]
        self.assertEqual(report["stale_files"], 1)
        self.assertEqual(report["reused_chunks"], 1)
        self.assertEqual(second["chunks"][0]["id"], first["chunks"][0]["id"])
        self.assertIn("temporary read failure", second["stats"]["skipped"][0]["reason"])

    def test_ppmi_reuses_unchanged_model_but_retrains_after_corpus_change(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "one.md").write_text("car road vehicle", encoding="utf-8")
            (root / "two.md").write_text("automobile road wheels", encoding="utf-8")
            first = build_index(root, vector_mode="cooccurrence")
            unchanged = build_index(root, vector_mode="cooccurrence", previous_index=first)
            (root / "two.md").write_text("physician clinic patient", encoding="utf-8")
            changed = build_index(root, vector_mode="cooccurrence", previous_index=unchanged)

        self.assertEqual(unchanged["embedding"]["model_id"], first["embedding"]["model_id"])
        self.assertEqual(unchanged["stats"]["incremental"]["embedded_chunks"], 0)
        self.assertNotEqual(changed["embedding"]["model_id"], first["embedding"]["model_id"])
        self.assertEqual(
            changed["stats"]["incremental"]["embedded_chunks"],
            changed["stats"]["chunks"],
        )


if __name__ == "__main__":
    unittest.main()
