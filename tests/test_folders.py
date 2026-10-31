"""S3-T3: the Python reference for roots, apply_changes and visible-scope statistics."""

import base64
import hashlib
import json
import os
import tempfile
import unittest
from pathlib import Path

from src.search_platform.core import ReadError
from src.search_platform.folders import (
    MAX_CHANGES,
    ApplyError,
    FolderIndex,
    add_change,
    strict_base64,
)

ROOTS = [{"root_id": "home", "label": "Home", "kind": "host"},
         {"root_id": "school", "label": "School", "kind": "icloud"}]


def sha(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def public_changes() -> list[dict]:
    return [
        add_change("home", "chores.md", "# Chores\n\nWash the dishes and feed the cat.\nThe dishes go on the rack.\n"),
        add_change("home", "garden.md", "# Garden\n\nWater the beans after school.\n"),
        add_change("home", "empty.txt", ""),
        add_change("school", "menu.md", "# Lunch\n\nSoup and dishes of rice on Monday.\n"),
    ]


def hidden_changes() -> list[dict]:
    return [
        add_change("home", "money/budget.md", "# Budget\n\nThe salary pays for dishes and the mortgage.\nSalary day is Friday.\n",
                   required_labels=["adults"]),
        add_change("home", "money/notes.txt", "salary review and dishes\n", required_labels=["adults"]),
        add_change("home", "money/blank.txt", "", required_labels=["adults"]),
    ]


def payload(index: FolderIndex, scope: dict, chunk_ids: list[str]) -> str:
    out = {}
    for query in ("dishes", "salary", "salary dishes cat", "friday", "mortgage review"):
        out[f"search {query}"] = index.search(query, top_k=10, **scope)
    out["read_chunk"] = [index.read_chunk(i, **scope) for i in chunk_ids]
    out["list_sources"] = index.list_sources(**scope)
    out["list_files"] = index.list_files(**scope)
    out["index_status"] = index.index_status(**scope)
    spans = []
    for root_id, path in (("home", "money/budget.md"), ("home", "money/blank.txt"), ("home", "never.md"),
                          ("home", "chores.md"), ("vault", "x.md")):
        try:
            spans.append(index.read_span(root_id, path, 1, 2, **scope))
        except ReadError as exc:
            spans.append([exc.code, str(exc)])
    out["read_span"] = spans
    return json.dumps(out, sort_keys=True)


class FolderIndexTests(unittest.TestCase):
    def test_hidden_domain_is_indistinguishable_from_absent(self) -> None:
        with_hidden, without = FolderIndex(), FolderIndex()
        with_hidden.apply_changes({"roots": ROOTS, "changes": public_changes() + hidden_changes()})
        without.apply_changes({"roots": ROOTS, "changes": public_changes()})
        hidden_ids = [c["id"] for c in with_hidden.visible_chunks(principal_labels=["adults"])
                      if c["required_labels"]] + ["0123456789abcdef0123"]
        self.assertGreaterEqual(len(hidden_ids), 3)
        for scope in ({}, {"principal_labels": ["kids"]}, {"roots": ["home"]}):
            self.assertEqual(payload(with_hidden, scope, hidden_ids), payload(without, scope, hidden_ids))
        adults = {"principal_labels": ["adults"]}
        self.assertNotEqual(payload(with_hidden, adults, hidden_ids), payload(without, adults, hidden_ids))

    def test_roots_together_apart_and_removed(self) -> None:
        index = FolderIndex()
        index.apply_changes({"roots": ROOTS, "changes": [
            add_change("school", "tides.md", "# Tides\n\nThe tide table for the coast trip.\n"),
            add_change("home", "trips/seaside.md", "# Seaside\n\nCheck the tide table before the walk.\n"),
        ]})
        self.assertEqual({r["root_id"] for r in index.search("tide")}, {"home", "school"})
        self.assertEqual([r["root_id"] for r in index.search("tide", roots=["school"])], ["school"])
        alone = FolderIndex()
        alone.apply_changes({"roots": ROOTS, "changes": [
            add_change("school", "tides.md", "# Tides\n\nThe tide table for the coast trip.\n")]})
        self.assertEqual(index.search("tide table", roots=["school"]), alone.search("tide table"))
        report = index.apply_changes({"changes": [{"op": "remove_root", "root_id": "school"}]})
        self.assertEqual(report["roots_removed"], 1)
        self.assertEqual([r["root_id"] for r in index.index_status()["roots"]], ["home"])
        self.assertNotIn("coast", {t for c in index.visible_chunks() for t in c["terms"]})

    def test_each_operation_in_one_call(self) -> None:
        index = FolderIndex()
        roots = [{"root_id": "home", "label": "Home", "kind": "host"}]
        self.assertEqual(index.apply_changes({"roots": roots, "changes": [
            add_change("home", "recipes/soup.md", "# Soup\n\nLentils and carrots.\n")]})["added"], 1)
        text = "# Soup\n\nLentils, carrots and leeks.\n"
        report = index.apply_changes({"changes": [dict(add_change("home", "recipes/soup.md", text), op="change", sha256=sha(text))]})
        self.assertEqual(report["changed"], 1)
        report = index.apply_changes({"changes": [{"op": "move", "root_id": "home", "path": "recipes/soup-v2.md",
                                                   "moved_from": "recipes/soup.md"}]})
        self.assertEqual((report["moved"], report["added"], report["removed"]), (1, 0, 0))
        self.assertEqual([r["path"] for r in index.search("leeks")], ["recipes/soup-v2.md"])
        report = index.apply_changes({"changes": [{"op": "pending", "root_id": "home", "path": "recipes/soup-v2.md", "size": 5000}]})
        self.assertEqual(report["pending"], 1)
        self.assertEqual(index.search("leeks"), [])
        self.assertEqual(index.index_status()["pending_paths"], [{"root_id": "home", "path": "recipes/soup-v2.md"}])
        report = index.apply_changes({"changes": [add_change("home", "recipes/soup-v2.md", "barley soup\n")]})
        self.assertEqual((report["added"], report["pending"]), (1, 0))
        self.assertEqual(index.apply_changes({"changes": [{"op": "remove", "root_id": "home", "path": "recipes/soup-v2.md"}]})["removed"], 1)
        self.assertEqual(index.apply_changes({"changes": [{"op": "remove_root", "root_id": "home"}]})["roots_removed"], 1)
        self.assertEqual(index.generation, 7)

    def test_rejections_change_nothing(self) -> None:
        index = FolderIndex()
        index.apply_changes({"roots": ROOTS, "changes": [add_change("home", "a.md", "alpha\n")]})
        before = (index.generation, json.dumps(index.list_files()))
        bad = [
            {"principal_labels": ["adults"], "changes": []},
            {"changes": [dict(add_change("home", "b.md", "x"), principal_labels=["adults"])]},
            {"changes": [add_change("home", "../b.md", "x")]},
            {"changes": [add_change("home", "a\u0000b.md", "x")]},
            {"changes": [add_change("home", "/b.md", "x")]},
            {"changes": [{"op": "add", "root_id": "home", "path": "b.md", "content_base64": "eB=="}]},
            {"changes": [{"op": "add", "root_id": "home", "path": "b.md"}]},
            {"changes": [{"op": "rename", "root_id": "home", "path": "b.md"}]},
            {"changes": [{"op": "remove", "root_id": "vault", "path": "b.md"}]},
            {"expect_generation": 0, "changes": []},
            {"changes": [{"op": "remove", "root_id": "home", "path": f"f{i}.md"} for i in range(MAX_CHANGES + 1)]},
        ]
        codes = []
        for request in bad:
            with self.assertRaises(ApplyError) as caught:
                index.apply_changes(request)
            codes.append(caught.exception.code)
            self.assertEqual((index.generation, json.dumps(index.list_files())), before)
        self.assertEqual(codes[-1], "capacity")
        with self.assertRaises(ApplyError) as caught:
            index.apply_changes({"expect_generation": 0, "changes": [{"op": "nope"}]})
        self.assertEqual(str(caught.exception), "stale: generation is 1")
        with self.assertRaises(ApplyError) as caught:
            index.apply_changes({"changes": [add_change("home", "b.md", "0123456789"), add_change("home", "c.md", "0123456789")]},
                                max_total_bytes=15)
        self.assertEqual(caught.exception.code, "capacity")

    def test_files_are_confined_to_their_local_root(self) -> None:
        with tempfile.TemporaryDirectory() as scratch:
            base = Path(scratch).resolve()
            (base / "desk" / "notes").mkdir(parents=True)
            (base / "elsewhere").mkdir()
            (base / "desk" / "notes" / "words.txt").write_text("spelling words\n", encoding="utf-8")
            (base / "elsewhere" / "secret.txt").write_text("outside\n", encoding="utf-8")
            os.symlink("../elsewhere/secret.txt", base / "desk" / "link.txt")
            roots = [{"root_id": "desk", "kind": "local", "path": str(base / "desk")}]
            index = FolderIndex()
            good = {"op": "add", "root_id": "desk", "path": "lists/words.txt",
                    "file": str(base / "desk" / "notes" / "words.txt"), "sha256": sha("spelling words\n")}
            self.assertEqual(index.apply_changes({"roots": roots, "changes": [good]}, allow_file_reads=True)["added"], 1)
            for file in (base / "elsewhere" / "secret.txt", base / "desk" / "link.txt"):
                change = dict(good, path="s.txt", file=str(file), sha256=sha("outside\n"))
                with self.assertRaises(ApplyError):
                    index.apply_changes({"roots": roots, "changes": [change]}, allow_file_reads=True)
            with self.assertRaises(ApplyError):
                index.apply_changes({"roots": roots, "changes": [good]})
            self.assertEqual(index.generation, 1)

    def test_hash_mismatch_conflicts_and_ambiguous_moves(self) -> None:
        index = FolderIndex()
        same = "# Same\n\nidentical words\n"
        index.apply_changes({"roots": ROOTS, "changes": [add_change("home", "x.md", same), add_change("home", "y.md", same),
                                                         add_change("home", "keep.md", "kept\n")]})
        report = index.apply_changes({"changes": [
            dict(add_change("home", "bad.md", "real\n"), sha256=sha("other\n")),
            {"op": "remove", "root_id": "home", "path": "y.md"},
            {"op": "remove", "root_id": "home", "path": "x.md"},
            add_change("home", "z.md", same),
            add_change("home", "dup.md", "one\n"),
            add_change("home", "dup.md", "two\n"),
        ]})
        self.assertEqual(report["rejected"], [{"root_id": "home", "path": "bad.md", "reason": "hash_mismatch"}])
        self.assertEqual(report["conflicts"], [{"root_id": "home", "path": "dup.md", "replaced": "add", "by": "add"}])
        self.assertEqual((report["moved"], report["removed"], report["added"], report["unchanged"]), (1, 1, 1, 1))
        self.assertEqual(report["ambiguous_moves"][0]["pairs"], [{"from": "x.md", "to": "z.md"}])
        self.assertEqual(report["ambiguous_moves"][0]["from"], ["x.md", "y.md"])

    def test_pending_and_truncated_over_the_visible_scope(self) -> None:
        index = FolderIndex()
        index.apply_changes({"roots": ROOTS, "changes": [
            add_change("home", "notes.md", "canal walk\n"),
            {"op": "pending", "root_id": "home", "path": "later.md", "size": 10},
            {"op": "pending", "root_id": "home", "path": "secret.md", "required_labels": ["adults"]},
        ]})
        self.assertEqual(index.index_status()["pending"], 1)
        self.assertEqual(index.index_status(principal_labels=["adults"])["pending"], 2)
        index.apply_changes({"changes": [add_change("home", "big.md", "0123456789" * 3, required_labels=["adults"])]},
                            max_file_bytes=10)
        self.assertFalse(index.index_status()["truncated"])
        self.assertTrue(index.index_status(principal_labels=["adults"])["truncated"])
        index.apply_changes({"changes": [add_change("home", "big.md", "small", required_labels=["adults"])]})
        self.assertFalse(index.index_status(principal_labels=["adults"])["truncated"])

    def test_strict_base64(self) -> None:
        self.assertEqual(strict_base64(base64.b64encode(b"x").decode()), b"x")
        for text in ("eA=", "eB==", "e A=", "eA==\n", "@@@@"):
            self.assertIsNone(strict_base64(text))


if __name__ == "__main__":
    unittest.main()
