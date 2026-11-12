"""S5-T7 (review R03): `content` under a path prefix scores as the engine does.

BM25's count, average length and document frequencies are the chunks the caller
may see (roots and labels); the path prefix narrows the candidates only
(`Engine.queryTraced`, S3-T3; S5-T2 ruling 2; S5-T3 ruling 8). A grouped term
(fuzzy-v1, fold-groups-v2) takes the largest of its held members' document
frequencies over the same chunks. A label-hidden chunk is neither a candidate nor
counted. `filename` and `both` keep their own prefix-scoped statistics
(`_search_filename_fields`, `filename_field.scoreQuery`): those cases are guards.

The fixture is invented: two roots, `notes` (visible) and `attic` (label
`adults`); the prefix `notes/pond/` holds three files, `notes/meadow/` five more
visible ones outside it. Scores are compared with the tolerance the engine's
grouped and title goldens use against the reference (`zig/src/fuzzy_test.zig`,
`zig/src/title_field_test.zig`): |engine - reference| <= 1e-4 * max(1, |reference|)."""

from __future__ import annotations

import base64
import json
import math
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO))

from src.search_platform.core import build_index, fold_groups, fuzzy_expansions, search, tokenize  # noqa: E402

sys.path.insert(0, str(REPO / "scripts"))
import j2_run  # noqa: E402
try:  # `unittest discover -s tests` (CI) or `unittest tests.test_prefix_statistics`
    from test_title_field import searchd_binary  # noqa: E402
except ImportError:
    from tests.test_title_field import searchd_binary  # noqa: E402

FILES = {
    "notes/pond/lily.md": "The heron waits by the lily pads. Frogs croak at dusk.\n",
    "notes/pond/reeds.md": "A heron nest sits in the reeds near the frog spawn, and newts swim below the heron.\n",
    "notes/pond/newt.md": "Stepping stones cross the water. A frog sat on one stone all morning.\n",
    "notes/meadow/one.md": "The heron flew over the meadow. A newt hid under a log.\n",
    "notes/meadow/two.md": "Cows graze in the long grass all summer long while the bees hum in the clover.\n",
    "notes/meadow/three.md": "A newt and another newt crossed the lane after rain.\n",
    "notes/meadow/four.md": "Frogs and frogs and more frogs sang in the ditch.\n",
    "notes/meadow/five.md": "The hedge holds blackbirds, wrens and a robin.\n",
    "attic/box/one.md": "heron heron heron frog frog newts newts\n",
    "attic/box/two.md": "heron frogs newts newt\n",
    "attic/box/three.md": "An old heron print hangs above a frog lamp.\n",
}
ROOTS = ("notes", "attic")
HIDDEN_ROOT, LABEL = "attic", "adults"
RULES = [{"path_prefix": "attic/", "required_labels": [LABEL]}]
PREFIX = "notes/pond/"
TOLERANCE = 1e-4

# (query, path prefix, principal labels, the query's groups, the measured order).
# Every group member here weighs 1.0 (key-mates, or fuzzy-v1 at distance 1).
CONTENT_CASES = [
    ("heron", PREFIX, (), {}, ["notes/pond/reeds.md", "notes/pond/lily.md"]),
    # The prefix-narrowed statistics put reeds.md first here; the engine's, lily.md.
    ("heron frog", PREFIX, (), {"frog": ["frog", "frogs"]},
     ["notes/pond/lily.md", "notes/pond/reeds.md", "notes/pond/newt.md"]),
    ("herron", PREFIX, (), {"herron": ["heron"]}, ["notes/pond/reeds.md", "notes/pond/lily.md"]),
    ("frogz", PREFIX, (), {"frogz": ["frog", "frogs"]},
     ["notes/pond/lily.md", "notes/pond/newt.md", "notes/pond/reeds.md"]),
    ("frogs", PREFIX, (), {"frogs": ["frogs", "frog"]},
     ["notes/pond/lily.md", "notes/pond/newt.md", "notes/pond/reeds.md"]),
    # `newt` is a title word under the prefix (notes/pond/newt.md) that only chunks
    # outside it hold in their bodies: it adds nothing to the group's df.
    ("newts", PREFIX, (), {"newts": ["newts", "newt"]}, ["notes/pond/newt.md", "notes/pond/reeds.md"]),
    ("heron", PREFIX, (LABEL,), {}, ["notes/pond/reeds.md", "notes/pond/lily.md"]),
    ("frogs", PREFIX, (LABEL,), {"frogs": ["frogs", "frog"]},
     ["notes/pond/lily.md", "notes/pond/newt.md", "notes/pond/reeds.md"]),
    ("heron", "attic/", (), {}, []),
    ("heron", "attic/", (LABEL,), {}, ["attic/box/one.md", "attic/box/two.md", "attic/box/three.md"]),
    ("heron", None, (), {}, ["notes/pond/reeds.md", "notes/pond/lily.md", "notes/meadow/one.md"]),
    ("frogs", None, (), {"frogs": ["frogs", "frog"]},
     ["notes/meadow/four.md", "notes/pond/lily.md", "notes/pond/newt.md", "notes/pond/reeds.md"]),
]
# `both` and `filename` under the prefix: their own prefix-scoped statistics, unchanged.
GUARD_CASES = [
    ("heron frog", PREFIX, (), "both"),
    ("newts", PREFIX, (), "both"),
    ("frogs", PREFIX, (LABEL,), "both"),
    ("reeds", PREFIX, (), "filename"),
    ("newt lily", PREFIX, (), "filename"),
]


def write(root: Path, files: dict[str, str]) -> None:
    for path, text in files.items():
        target = root / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(text, encoding="utf-8")


def close(got: float, want: float) -> bool:
    return abs(got - want) <= TOLERANCE * max(1.0, abs(want))


def visible(chunk: dict, labels: tuple[str, ...]) -> bool:
    return set(chunk.get("required_labels", [])) <= set(labels)


def oracle(index: dict, query: str, prefix: str | None, labels: tuple[str, ...], groups: dict[str, list[str]],
           *, narrowed: bool = False) -> dict[str, float]:
    """BM25 per candidate chunk id, written out here (k1 1.2, b 0.75): statistics over
    the visible chunks, or over the candidates when `narrowed` (the reading before
    S5-T7, and still `both`'s). A group's df is its largest held member's."""
    seen = [chunk for chunk in index["chunks"] if visible(chunk, labels)]
    candidates = [chunk for chunk in seen if prefix is None or chunk["path"].startswith(prefix)]
    population = candidates if narrowed else seen
    n = len(population)
    average = sum(chunk["length"] for chunk in population) / n

    def df(term: str) -> int:
        return sum(1 for chunk in population if term in chunk["terms"])

    def part(frequency: int, document_frequency: int, length: int) -> float:
        idf = math.log(1.0 + (n - document_frequency + 0.5) / (document_frequency + 0.5))
        return idf * (frequency * 2.2 / (frequency + 1.2 * (0.25 + 0.75 * length / average)))

    held = {term for chunk in candidates for term in chunk["terms"]}
    out = {}
    for chunk in candidates:
        total = 0.0
        for term in sorted(set(tokenize(query))):
            members = groups.get(term, [term])
            shared = max((df(m) for m in members if m in held), default=0)
            found = [part(chunk["terms"][m], shared, chunk["length"]) for m in members if chunk["terms"].get(m)]
            if found:
                total += max(found)
        if total > 0.0:
            out[chunk["id"]] = total
    return out


def reference_hits(index: dict, query: str, prefix: str | None, labels: tuple[str, ...], field: str) -> list[dict]:
    hits = search(index, query, top_k=20, retrieval_mode="lexical", path_prefix=prefix, principal_labels=labels,
                  search_field=field, title_root_ids=ROOTS)
    return [{"path": h["citation"]["path"], "lines": (h["citation"]["start_line"], h["citation"]["end_line"]),
             "score": h["ranking"]["lexical"]["score"] if field == "content" else h["score"],
             "title": (h["ranking"].get("title") or {}).get("score"), "chunk_id": h["chunk_id"]} for h in hits]


class ReferenceRuleTests(unittest.TestCase):
    """The reference alone (CI's Python job runs these)."""

    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory()
        folder = Path(cls.temporary.name)
        write(folder, FILES)
        cls.index = build_index(folder, access_rules=RULES, filename_index=True)

    @classmethod
    def tearDownClass(cls):
        cls.temporary.cleanup()

    def test_the_fixture_groups(self):
        for query, prefix, labels, groups, _ in CONTENT_CASES:
            got = dict(fold_groups(self.index, query, path_prefix=prefix, principal_labels=labels, title_root_ids=ROOTS))
            got.update(fuzzy_expansions(self.index, query, path_prefix=prefix, principal_labels=labels,
                                        title_root_ids=ROOTS))
            self.assertEqual(got, groups, (query, prefix, labels))

    def test_the_prefix_narrows_the_candidates_and_a_hidden_chunk_is_never_one(self):
        for query, prefix, labels, _, order in CONTENT_CASES:
            hits = reference_hits(self.index, query, prefix, labels, "content")
            self.assertEqual([h["path"] for h in hits], order, (query, prefix, labels))
            for hit in hits:
                self.assertTrue(prefix is None or hit["path"].startswith(prefix), hit)
                self.assertTrue(LABEL in labels or not hit["path"].startswith(HIDDEN_ROOT + "/"), hit)

    def test_content_scores_over_the_visible_chunks(self):
        compared = 0
        for query, prefix, labels, groups, _ in CONTENT_CASES:
            want = oracle(self.index, query, prefix, labels, groups)
            for hit in reference_hits(self.index, query, prefix, labels, "content"):
                if hit["title"] is not None:
                    continue  # the title part is S5-T2's, over the visible files already
                self.assertAlmostEqual(hit["score"], want[hit["chunk_id"]], places=12, msg=(query, prefix, labels, hit))
                compared += 1
        self.assertGreaterEqual(compared, 25)

    def test_the_fixture_tells_the_two_readings_apart(self):
        # Under the prefix the narrowed statistics differ from the visible ones by more
        # than the tolerance on every case with a candidate: a score comparison sees
        # the old reading.
        for query, prefix, labels, groups, order in CONTENT_CASES:
            if prefix is None or not order:
                continue
            wide = oracle(self.index, query, prefix, labels, groups)
            narrow = oracle(self.index, query, prefix, labels, groups, narrowed=True)
            self.assertTrue(any(not close(narrow[c], wide[c]) for c in wide), (query, prefix, labels))

    def test_both_keeps_its_prefix_scoped_body_statistics(self):
        for query, prefix, labels, field in GUARD_CASES:
            if field != "both":
                continue
            groups = dict(fold_groups(self.index, query, path_prefix=prefix, principal_labels=labels,
                                      search_field="both", title_root_ids=ROOTS))
            groups.update(fuzzy_expansions(self.index, query, path_prefix=prefix, principal_labels=labels,
                                           search_field="both", title_root_ids=ROOTS))
            narrow = oracle(self.index, query, prefix, labels, groups, narrowed=True)
            hits = [h for h in reference_hits(self.index, query, prefix, labels, "both") if h["title"] is None]
            self.assertTrue(hits, query)
            for hit in hits:
                self.assertAlmostEqual(hit["score"], narrow[hit["chunk_id"]], places=12, msg=(query, hit))


@unittest.skipIf(os.environ.get("SEARCH_SIMPLI_NO_ZIG") == "1", "SEARCH_SIMPLI_NO_ZIG=1: no searchd")
class SearchdConformanceTests(unittest.TestCase):
    """`searchd` (`$SEARCHD_BINARY`, the ReleaseSmall build in the task's runs)
    against the reference: the same hits in the same order, raw scores within the
    tolerance."""

    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory()
        scratch = Path(cls.temporary.name)
        folder = scratch / "folder"
        write(folder, FILES)
        cls.index = build_index(folder, access_rules=RULES, filename_index=True)
        binary = searchd_binary(scratch)
        request = {"roots": [], "changes": []}
        for root in ROOTS:
            entry = {"root_id": root, "label": root, "kind": "host"}
            if root == HIDDEN_ROOT:
                entry["required_labels"] = [LABEL]
            request["roots"].append(entry)
        for path, text in FILES.items():
            root, rest = path.split("/", 1)
            request["changes"].append({"op": "add", "root_id": root, "path": rest,
                                       "content_base64": base64.b64encode(text.encode("utf-8")).decode("ascii")})
        (scratch / "empty").mkdir()
        (scratch / "changes.json").write_text(json.dumps(request), encoding="utf-8")
        for cmd in ([str(binary), "index", str(scratch / "empty"), "--out", str(scratch / "idx"), "--filename-index"],
                    [str(binary), "apply", str(scratch / "idx"), "--changes", str(scratch / "changes.json")]):
            done = subprocess.run(cmd, capture_output=True, text=True, timeout=300)
            if done.returncode != 0:
                raise AssertionError(f"{cmd[1]} failed:\n{done.stdout}\n{done.stderr}")
        cls.serve = j2_run.Serve(binary, scratch / "idx")

    @classmethod
    def tearDownClass(cls):
        cls.serve.close()
        cls.temporary.cleanup()

    def searchd_hits(self, query: str, prefix: str | None, labels: tuple[str, ...], field: str) -> list[dict]:
        params = {"query": query, "top_k": 20, "retrieval_mode": "lexical", "principal_labels": list(labels),
                  "search_field": field}
        if prefix is not None:
            params["path_prefix"] = prefix
        result = self.serve.call("search_knowledge", params)
        return [{"path": r["citation"]["path"], "lines": (r["citation"]["start_line"], r["citation"]["end_line"]),
                 "score": r["ranking"]["lexical"]["score"] if field == "content" else r["score"]}
                for r in result["results"]]

    def compare(self, query: str, prefix: str | None, labels: tuple[str, ...], field: str) -> int:
        native = self.searchd_hits(query, prefix, labels, field)
        reference = reference_hits(self.index, query, prefix, labels, field)
        case = (query, prefix, labels, field)
        self.assertEqual([(h["path"], h["lines"]) for h in native], [(h["path"], h["lines"]) for h in reference], case)
        for got, want in zip(native, reference):
            self.assertTrue(close(got["score"], want["score"]), (case, got, want))
        return len(native)

    def test_content_ranks_and_raw_scores_agree(self):
        compared = sum(self.compare(query, prefix, labels, "content") for query, prefix, labels, _, _ in CONTENT_CASES)
        self.assertGreaterEqual(compared, 30)

    def test_both_and_filename_under_the_prefix_still_agree(self):
        for query, prefix, labels, field in GUARD_CASES:
            self.assertGreaterEqual(self.compare(query, prefix, labels, field), 1, (query, field))


if __name__ == "__main__":
    unittest.main()
