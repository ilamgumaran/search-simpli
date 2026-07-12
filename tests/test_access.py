import tempfile
import unittest
from pathlib import Path

from src.search_platform.access import (
    required_labels_for_path,
    validate_access_rules,
)
from src.search_platform.core import build_index, search
from src.search_platform.interchange import build_interchange
from src.search_platform.tool_server import KnowledgeTools


def rules() -> list[dict]:
    return validate_access_rules(
        {
            "version": 1,
            "rules": [
                {"path_prefix": "private/", "required_labels": ["tenant:acme"]},
                {"path_prefix": "private/engineering/", "required_labels": ["group:engineering"]},
            ],
        }
    )


def indexed_fixture(root: Path) -> dict:
    (root / "public").mkdir()
    (root / "private" / "general").mkdir(parents=True)
    (root / "private" / "engineering").mkdir(parents=True)
    (root / "public" / "guide.md").write_text(
        "A public launch guide describes ordinary preparation.", encoding="utf-8"
    )
    (root / "private" / "general" / "plan.md").write_text(
        "The confidential launch plan contains tenant details.", encoding="utf-8"
    )
    (root / "private" / "engineering" / "design.md").write_text(
        "The restricted engine design contains a secret mechanism.", encoding="utf-8"
    )
    return build_index(root, vector_mode="hash", access_rules=rules())


class AccessTests(unittest.TestCase):
    def test_matching_rules_union_all_required_labels(self) -> None:
        self.assertEqual(required_labels_for_path("public/guide.md", rules()), [])
        self.assertEqual(
            required_labels_for_path("private/engineering/design.md", rules()),
            ["group:engineering", "tenant:acme"],
        )

    def test_lexical_and_vector_search_filter_before_results(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            index = indexed_fixture(Path(temporary))
            anonymous_lexical = search(index, "confidential", retrieval_mode="lexical")
            anonymous_vector = search(index, "secret mechanism", retrieval_mode="vector")
            tenant = search(
                index,
                "confidential",
                retrieval_mode="lexical",
                principal_labels=["tenant:acme"],
            )
            engineer = search(
                index,
                "secret mechanism",
                retrieval_mode="hybrid",
                principal_labels=["tenant:acme", "group:engineering"],
            )

        self.assertEqual(anonymous_lexical, [])
        self.assertTrue(all(result["citation"]["path"].startswith("public/") for result in anonymous_vector))
        self.assertEqual(tenant[0]["citation"]["path"], "private/general/plan.md")
        self.assertEqual(engineer[0]["citation"]["path"], "private/engineering/design.md")

    def test_authoritative_read_and_source_listing_use_same_principal(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            index = indexed_fixture(Path(temporary))
            private = next(
                chunk for chunk in index["chunks"] if chunk["path"] == "private/general/plan.md"
            )
            anonymous = KnowledgeTools(index)
            tenant = KnowledgeTools(index, principal_labels=["tenant:acme"])
            denied = anonymous.handle(
                {"jsonrpc": "2.0", "id": 1, "method": "read_chunk", "params": {"chunk_id": private["id"]}}
            )
            allowed = tenant.handle(
                {"jsonrpc": "2.0", "id": 2, "method": "read_chunk", "params": {"chunk_id": private["id"]}}
            )
            anonymous_sources = anonymous.call("list_sources", {})
            tenant_sources = tenant.call("list_sources", {})

        self.assertEqual(denied["error"]["code"], -32004)
        self.assertEqual(allowed["result"]["citation"]["path"], "private/general/plan.md")
        self.assertEqual([item["path"] for item in anonymous_sources["sources"]], ["public/guide.md"])
        self.assertIn("private/general/plan.md", [item["path"] for item in tenant_sources["sources"]])
        self.assertNotIn("private/engineering/design.md", [item["path"] for item in tenant_sources["sources"]])

    def test_interchange_carries_canonical_required_labels(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            index = indexed_fixture(Path(temporary))
            payload = build_interchange(index)
        engineering = next(
            document
            for document in payload["documents"]
            if document["path"] == "private/engineering/design.md"
        )
        self.assertEqual(
            engineering["required_labels"], ["group:engineering", "tenant:acme"]
        )


if __name__ == "__main__":
    unittest.main()
