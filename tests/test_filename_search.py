import contextlib
import io
import tempfile
import unittest
from pathlib import Path

from src.search_platform.cli import main as cli_main
from src.search_platform.core import build_index, context_envelope, load_index, save_index, search, tokenize
from src.search_platform.interchange import build_interchange
from src.search_platform.tool_server import KnowledgeTools


class FilenameSearchTests(unittest.TestCase):
    def test_filename_results_are_navigation_hits_with_real_body_anchors(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "café-guide.md").write_text("The evidence is in this body.\n", encoding="utf-8")
            index = build_index(root, filename_index=True)
            result = search(index, "CAFÉ guide", search_field="filename", retrieval_mode="lexical")[0]
            envelope = context_envelope(index, "café", search_field="filename", retrieval_mode="lexical")

        self.assertEqual(index["version"], 2)
        self.assertEqual(result["citation"], {"path": "café-guide.md", "start_line": 1, "end_line": 1})
        self.assertEqual(result["content"], "The evidence is in this body.")
        self.assertEqual(result["matched_in"], ["filename"])
        self.assertEqual(result["basename"], "café-guide.md")
        self.assertEqual(result["ranking"]["filename"]["rank"], 1)
        self.assertEqual(envelope["retrieval"]["search_field"], "filename")
        self.assertTrue(envelope["answer_policy"]["filename_matches_are_navigation"])

    def test_default_schema_stays_legacy_and_body_only_fails_closed(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "guide.md").write_text("filename query token", encoding="utf-8")
            old = build_index(root)
            optin = build_index(root, filename_index=True)
        legacy = search(old, "filename", retrieval_mode="lexical")[0]
        self.assertEqual(set(legacy), {"chunk_id", "citation", "content", "score", "ranking"})
        with self.assertRaisesRegex(ValueError, "FilenameIndexUnavailable.*--filename-index"):
            search(old, "guide", search_field="filename", retrieval_mode="lexical")
        with self.assertRaisesRegex(ValueError, "retrieval_mode='lexical'"):
            search(optin, "guide", search_field="filename")

    def test_index_status_reports_policy_only_for_filename_enabled_indexes(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "guide.md").write_text("visible body", encoding="utf-8")
            old = build_index(root)
            optin = build_index(root, filename_index=True)
            request = {"jsonrpc": "2.0", "id": "status", "method": "index_status", "params": {}}
            old_status = KnowledgeTools(old).handle(request)["result"]
            optin_status = KnowledgeTools(optin).handle(request)["result"]

        self.assertNotIn("filename_policy_id", old_status)
        self.assertEqual(optin_status["filename_policy_id"], "filename-field-v1")
        self.assertNotIn("filename_count", optin_status)

    def test_incremental_mismatch_and_refresh_rebuild_filename_records(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            target = root / "alpha.md"
            target.write_text("first passage", encoding="utf-8")
            first = build_index(root, filename_index=True)
            with self.assertRaisesRegex(ValueError, "filename-index setting.*clean rebuild"):
                build_index(root, previous_index=first)
            target.rename(root / "beta.md")
            refreshed = build_index(root, filename_index=True, previous_index=first)
            matches = search(refreshed, "beta", search_field="filename", retrieval_mode="lexical")

        self.assertEqual([match["citation"]["path"] for match in matches], ["beta.md"])
        self.assertEqual(refreshed["filename_index"]["records"][0]["path"], "beta.md")

    def test_cli_rejects_filename_mode_toggle_at_existing_output_path(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "corpus"
            root.mkdir()
            (root / "guide.md").write_text("visible body", encoding="utf-8")
            output = Path(temporary) / "index.json"
            save_index(build_index(root), output)

            with contextlib.redirect_stderr(io.StringIO()):
                enable_status = cli_main(["index", str(root), "--out", str(output), "--filename-index"])
            self.assertEqual(enable_status, 2)
            self.assertEqual(load_index(output)["version"], 1)

            save_index(build_index(root, filename_index=True), output)
            with contextlib.redirect_stderr(io.StringIO()):
                disable_status = cli_main(["index", str(root), "--out", str(output)])
            self.assertEqual(disable_status, 2)
            self.assertEqual(load_index(output)["version"], 2)


    def test_v2_load_checks_filename_anchor_integrity(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "corpus"
            root.mkdir()
            (root / "guide.md").write_text("visible body", encoding="utf-8")
            index = build_index(root, filename_index=True)
            saved = Path(temporary) / "index.json"
            save_index(index, saved)
            loaded = load_index(saved)
            loaded["filename_index"]["records"][0]["anchor_id"] = "not-a-body-anchor"
            save_index(loaded, saved)
            with self.assertRaisesRegex(ValueError, "does not match its body anchor"):
                load_index(saved)

    def test_v2_load_rejects_missing_body_backed_catalog_record(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "corpus"
            root.mkdir()
            (root / "alpha.md").write_text("first body", encoding="utf-8")
            (root / "beta.md").write_text("second body", encoding="utf-8")
            index = build_index(root, filename_index=True)
            saved = Path(temporary) / "index.json"
            index["filename_index"]["records"].pop()
            save_index(index, saved)
            with self.assertRaisesRegex(ValueError, "catalog is missing body-backed paths"):
                load_index(saved)

    def test_authorization_prefix_and_hidden_files_do_not_affect_filename_results(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "public").mkdir()
            (root / "private").mkdir()
            (root / ".hidden").mkdir()
            (root / "public" / "needle.md").write_text("public body", encoding="utf-8")
            (root / "private" / "needle.md").write_text("secret body", encoding="utf-8")
            (root / ".hidden" / "needle.md").write_text("hidden body", encoding="utf-8")
            secured = build_index(root, filename_index=True, access_rules=[{"path_prefix": "private/", "required_labels": ["staff"]}])
            public_only = build_index(root, filename_index=True)
            secured_payload = context_envelope(secured, "needle", retrieval_mode="lexical", search_field="filename")
            plain_payload = context_envelope(public_only, "needle", retrieval_mode="lexical", search_field="filename", path_prefix="public/")
            secured_scoped = context_envelope(secured, "needle", retrieval_mode="lexical", search_field="filename", path_prefix="public/")

        self.assertEqual([r["citation"]["path"] for r in secured_payload["results"]], ["public/needle.md"])
        self.assertEqual(secured_scoped, plain_payload)

    def test_both_fuses_per_file_ranks_and_ties_use_path_order(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "a-alpha.md").write_text("needle body", encoding="utf-8")
            (root / "b-alpha.md").write_text("other body", encoding="utf-8")
            index = build_index(root, filename_index=True)
            filename = search(index, "alpha", retrieval_mode="lexical", search_field="filename")
            both = search(index, "needle alpha", retrieval_mode="lexical", search_field="both")

        self.assertEqual([r["citation"]["path"] for r in filename], ["a-alpha.md", "b-alpha.md"])
        self.assertEqual([r["citation"]["path"] for r in both], ["a-alpha.md", "b-alpha.md"])
        hit = both[0]
        self.assertEqual(hit["matched_in"], ["content", "filename"])
        self.assertAlmostEqual(hit["score"], 1 / 61 + 1 / 61)

    def test_both_cites_the_best_matching_chunk_for_a_multichunk_file(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            body = "\n".join([*(f"ordinary passage line {line}" for line in range(1, 90)), "needleonly appears here"])
            (root / "generic.md").write_text(body, encoding="utf-8")
            index = build_index(root, filename_index=True)
            hit = search(index, "needleonly", retrieval_mode="lexical", search_field="both")[0]
            chunks = {chunk["id"]: chunk for chunk in index["chunks"]}

        matching_chunks = [chunk for chunk in index["chunks"] if "needleonly" in chunk["terms"]]
        self.assertEqual(hit["chunk_id"], matching_chunks[0]["id"])
        self.assertGreater(hit["citation"]["start_line"], 1)
        self.assertEqual(hit["content"], chunks[hit["chunk_id"]]["text"])

    def test_filename_only_score_is_file_bm25(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "alpha.md").write_text("first body", encoding="utf-8")
            (root / "alpha-alpha.md").write_text("second body", encoding="utf-8")
            index = build_index(root, filename_index=True)
            results = search(index, "alpha", retrieval_mode="lexical", search_field="filename")

        self.assertGreater(results[0]["score"], results[1]["score"])
        for result in results:
            self.assertEqual(result["score"], result["ranking"]["filename"]["score"])
            self.assertGreater(result["score"], 1 / 61)

    def test_filename_analyzer_uses_simple_casefold_without_expanding_characters(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "Straße.md").write_text("body", encoding="utf-8")
            (root / "ﬁ.md").write_text("body", encoding="utf-8")
            (root / "İ.md").write_text("body", encoding="utf-8")
            index = build_index(root, filename_index=True)

            def paths(query: str) -> list[str]:
                return [item["citation"]["path"] for item in search(
                    index, query, retrieval_mode="lexical", search_field="filename"
                )]

        self.assertEqual(paths("strasse"), [])
        self.assertEqual(paths("STRAẞE"), ["Straße.md"])
        self.assertEqual(paths("fi"), [])
        self.assertEqual(paths("ﬁ"), ["ﬁ.md"])
        self.assertEqual(paths("i"), [])
        self.assertEqual(paths("İ"), ["İ.md"])
        self.assertEqual(tokenize("Straße"), ["strasse"])

    def test_export_v2_includes_policy_but_not_python_filename_postings(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "guide.md").write_text("visible evidence", encoding="utf-8")
            index = build_index(root, filename_index=True)
            payload = build_interchange(index)

        self.assertEqual(payload["format_version"], 2)
        self.assertEqual(payload["filename_policy_id"], "filename-field-v1")
        self.assertNotIn("filename_index", payload)


if __name__ == "__main__":
    unittest.main()
