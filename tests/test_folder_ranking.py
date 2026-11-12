"""S5-T9 (review R04): the folder lifecycle helper ranks as the reference does.

`FolderIndex.search` hands its authorized snapshot to `core.search`; this file
holds it to that, and to the engine, across a lifecycle. The same invented
folder goes three ways: `FolderIndex.apply_changes` (the helper), `build_index`
over the files of each state (`core.search`, the reference), and `searchd apply`
(the engine, `$SEARCHD_BINARY`: the ReleaseSmall build in the task's runs). The
states are the start, an update, a rename and a delete; the cases a title
question, a misspelt word, a verb form, a plural, and the scope (a file behind
the label `adults`, with and without the label, and one root named).

Same hits (root-qualified path and lines) in the same order, and scores within
the tolerance the engine's grouped and title goldens use against the reference
(`zig/src/fuzzy_test.zig`, `zig/src/title_field_test.zig`; S5-T7):
|engine - reference| <= 1e-4 * max(1, |reference|). The helper's `score` is the
reference's `ranking.lexical.score` (BM25 plus the title part a chunk received)."""

from __future__ import annotations

import base64
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO))

from src.search_platform.core import build_index, search, tokenize  # noqa: E402
from src.search_platform.folders import FolderIndex, add_change  # noqa: E402

sys.path.insert(0, str(REPO / "scripts"))
import j2_run  # noqa: E402
try:  # `unittest discover -s tests` (CI) or `unittest tests.test_folder_ranking`
    from test_title_field import searchd_binary  # noqa: E402
except ImportError:
    from tests.test_title_field import searchd_binary  # noqa: E402

ROOTS = ("garden", "kitchen")
LABEL = "adults"
HIDDEN = {"garden/money/seed-costs.md"}
RULES = [{"path_prefix": "garden/money/", "required_labels": [LABEL]}]
TOLERANCE = 1e-4
TOP_K = 10

START = {
    "garden/seed-packets.md": "# Seed packets\n\nThe tin holds bean and pea seeds for spring.\n"
                              "Write the sowing date on each one.\n",
    "garden/beds/north.md": "# North bed\n\nThe carrots grow beside the onions.\n"
                            "Water the carrots every evening in dry weeks.\n",
    "garden/beds/south.md": "# South bed\n\nA cucumber vine climbs the fence.\n"
                            "We planted three cucumber plants in May, and one onion.\n",
    "garden/tools.txt": "The spade and the rake hang in the shed.\nOil the shears before winter.\n",
    "garden/money/seed-costs.md": "# Seed costs\n\nSeed packets cost more this spring.\n"
                                  "The cucumber seeds were the dearest; onions were cheap.\n",
    "kitchen/recipes/soup.md": "# Soup\n\nPeel two carrots and one onion.\nSimmer the pot for twenty minutes.\n",
    "kitchen/shopping.txt": "Buy onions, a cucumber and fresh bread from the market stall.\n"
                            "The bakery opens early on Saturday, the cucumber stall at noon.\n",
    "kitchen/notes.md": "# Notes\n\nThe small seed tray on the sill is for herbs.\nBasil and mint, planting in April.\n",
}

# (state, the changes that reach it): each applied after the one before.
STEPS = [
    ("start", []),
    ("update", [("change", "garden/beds/north.md",
                 "# North bed\n\nThe leeks grow beside the onions now.\nA cucumber frame stands at the end.\n")]),
    ("rename", [("move", "kitchen/recipes/carrot-soup.md", "kitchen/recipes/soup.md")]),
    ("delete", [("remove", "garden/beds/south.md", None)]),
]

# (name, query, roots, principal labels)
CASES = [
    ("title", "seed packets", None, ()),
    ("title, after the rename", "carrot soup", None, ()),
    ("misspelt", "cucumbr", None, ()),
    ("verb form", "planting", None, ()),
    ("plural", "onion", None, ()),
    ("scope, label not held", "seed cucumber", None, ()),
    ("scope, label held", "seed cucumber", None, (LABEL,)),
    ("scope, one root", "seed cucumber", ("kitchen",), (LABEL,)),
]


def states() -> list[tuple[str, list[tuple], dict[str, str]]]:
    """(state, its changes, the files after them)."""
    files = dict(START)
    out = []
    for name, changes in STEPS:
        for op, path, extra in changes:
            if op == "change":
                files[path] = extra
            elif op == "move":
                files[path] = files.pop(extra)
            else:
                del files[path]
        out.append((name, changes, dict(sorted(files.items()))))
    return out


def split(path: str) -> tuple[str, str]:
    root, rest = path.split("/", 1)
    return root, rest


def labels_of(path: str) -> list[str]:
    return [LABEL] if path in HIDDEN else []


def request(changes: list[tuple], first: bool) -> dict:
    """The apply_changes request of one step (the helper's and the engine's)."""
    body: dict = {"changes": []}
    if first:
        body["roots"] = [{"root_id": root, "label": root, "kind": "host"} for root in ROOTS]
        for path, text in START.items():
            root, rest = split(path)
            body["changes"].append(add_change(root, rest, text, required_labels=labels_of(path))
                                   if path in HIDDEN else add_change(root, rest, text))
        return body
    for op, path, extra in changes:
        root, rest = split(path)
        if op == "change":
            body["changes"].append(dict(add_change(root, rest, extra), op="change"))
        elif op == "move":
            body["changes"].append({"op": "move", "root_id": root, "path": rest, "moved_from": split(extra)[1]})
        else:
            body["changes"].append({"op": "remove", "root_id": root, "path": rest})
    return body


def close(got: float, want: float) -> bool:
    return abs(got - want) <= TOLERANCE * max(1.0, abs(want))


def helper_hits(index: FolderIndex, query: str, roots, labels) -> list[tuple]:
    return [(f"{h['root_id']}/{h['path']}", h["start_line"], h["end_line"], h["score"])
            for h in index.search(query, roots=None if roots is None else list(roots),
                                  principal_labels=labels, top_k=TOP_K)]


def reference_hits(files: dict[str, str], query: str, roots, labels) -> list[tuple]:
    """`core.search` over an index of the state's files of the roots named."""
    with tempfile.TemporaryDirectory() as scratch:
        folder = Path(scratch)
        for path, text in files.items():
            if roots is None or split(path)[0] in roots:
                (folder / path).parent.mkdir(parents=True, exist_ok=True)
                (folder / path).write_text(text, encoding="utf-8")
        index = build_index(folder, access_rules=RULES)
    return [(h["citation"]["path"], h["citation"]["start_line"], h["citation"]["end_line"],
             h["ranking"]["lexical"]["score"])
            for h in search(index, query, top_k=TOP_K, retrieval_mode="lexical", principal_labels=labels,
                            title_root_ids=ROOTS)]


class Lifecycle:
    """The helper fed through the steps, one state at a time."""

    def __init__(self) -> None:
        self.index = FolderIndex()
        self.first = True

    def apply(self, changes: list[tuple]) -> dict:
        report = self.index.apply_changes(request(changes, self.first))
        self.first = False
        return report


class HelperAgainstReferenceTests(unittest.TestCase):
    """The helper against `core.search` (CI's Python job runs these)."""

    def assert_same(self, got: list[tuple], want: list[tuple], case) -> None:
        self.assertEqual([g[:3] for g in got], [w[:3] for w in want], case)
        for g, w in zip(got, want):
            self.assertTrue(close(g[3], w[3]), (case, g, w))

    def test_every_case_in_every_state(self):
        lifecycle = Lifecycle()
        compared = 0
        for state, changes, files in states():
            report = lifecycle.apply(changes)
            if state == "rename":
                self.assertEqual(report["moved"], 1)
            for name, query, roots, labels in CASES:
                want = reference_hits(files, query, roots, labels)
                self.assert_same(helper_hits(lifecycle.index, query, roots, labels), want, (state, name))
                # No two hits tie within the tolerance: every order compared is the
                # ranker's, not a tie-break (chunk id here, document index in the engine).
                for higher, lower in zip(want, want[1:]):
                    self.assertFalse(close(lower[3], higher[3]), (state, name, higher, lower))
                compared += len(want)
        self.assertGreaterEqual(compared, 90)

    def test_the_cases_exercise_what_they_name(self):
        # Pinned on the start state so a fixture edit cannot empty a case silently.
        lifecycle = Lifecycle()
        lifecycle.apply([])
        index = lifecycle.index

        def paths(query, roots=None, labels=()):
            return [h[0] for h in helper_hits(index, query, roots, labels)]

        # The title part puts the file named for the words first, over a body that holds both.
        self.assertEqual(paths("seed packets")[0], "garden/seed-packets.md")
        # A misspelling no chunk holds reaches the word (fuzzy-v1).
        self.assertIn("kitchen/shopping.txt", paths("cucumbr"))
        # `planting` reaches `planted` (fold-groups-v2's verb forms) besides itself.
        self.assertIn("garden/beds/south.md", paths("planting"))
        # `onion` reaches `onions` (the plural key).
        self.assertIn("garden/beds/north.md", paths("onion"))
        # The hidden file only with the label; one root named keeps to it.
        self.assertNotIn("garden/money/seed-costs.md", paths("seed cucumber"))
        self.assertIn("garden/money/seed-costs.md", paths("seed cucumber", labels=(LABEL,)))
        self.assertTrue(all(p.startswith("kitchen/") for p in paths("seed cucumber", ("kitchen",), (LABEL,))))

    def test_a_hidden_file_is_indistinguishable_from_an_absent_one(self):
        with_hidden, without = FolderIndex(), FolderIndex()
        with_hidden.apply_changes(request([], True))
        body = request([], True)
        body["changes"] = [c for c in body["changes"] if f"{c['root_id']}/{c['path']}" not in HIDDEN]
        without.apply_changes(body)
        for _, query, roots, _ in CASES:
            self.assertEqual(helper_hits(with_hidden, query, roots, ()), helper_hits(without, query, roots, ()), query)

    def test_conjunctive_keeps_the_chunks_holding_every_word_in_rank_order(self):
        lifecycle = Lifecycle()
        lifecycle.apply([])
        index = lifecycle.index
        ranked = index.search("seed cucumber", top_k=100, principal_labels=[LABEL])
        both = index.search("seed cucumber", top_k=100, principal_labels=[LABEL], conjunctive=True)
        self.assertEqual(both, [h for h in ranked if {"seed", "cucumber"} <= set(tokenize(h["content"]))])
        self.assertTrue(0 < len(both) < len(ranked), (both, ranked))
        self.assertEqual(index.search("seed cucumber", top_k=1, principal_labels=[LABEL], conjunctive=True), both[:1])
        self.assertEqual(index.search("seed packets", top_k=0), [])


@unittest.skipIf(os.environ.get("SEARCH_SIMPLI_NO_ZIG") == "1", "SEARCH_SIMPLI_NO_ZIG=1: no searchd")
class HelperAgainstEngineTests(unittest.TestCase):
    """The helper against `searchd` fed the same steps: the same hits in the same
    order, raw `ranking.lexical.score` within the tolerance."""

    def test_every_case_in_every_state(self):
        with tempfile.TemporaryDirectory() as temporary:
            scratch = Path(temporary)
            binary = searchd_binary(scratch)
            (scratch / "empty").mkdir()
            done = subprocess.run([str(binary), "index", str(scratch / "empty"), "--out", str(scratch / "idx")],
                                  capture_output=True, text=True, timeout=300)
            self.assertEqual(done.returncode, 0, done.stderr)
            lifecycle = Lifecycle()
            compared = 0
            for step, (state, changes, _) in enumerate(states()):
                body = request(changes, step == 0)
                lifecycle.apply(changes)
                changes_file = scratch / f"changes-{step}.json"
                changes_file.write_text(json.dumps(body), encoding="utf-8")
                done = subprocess.run([str(binary), "apply", str(scratch / "idx"), "--changes", str(changes_file)],
                                      capture_output=True, text=True, timeout=300)
                self.assertEqual(done.returncode, 0, (state, done.stdout, done.stderr))
                serve = j2_run.Serve(binary, scratch / "idx")
                try:
                    for name, query, roots, labels in CASES:
                        params = {"query": query, "top_k": TOP_K, "retrieval_mode": "lexical",
                                  "principal_labels": list(labels), "search_field": "content"}
                        if roots is not None:
                            params["roots"] = list(roots)
                        result = serve.call("search_knowledge", params)
                        native = [(r["citation"]["path"], r["citation"]["start_line"], r["citation"]["end_line"],
                                   r["ranking"]["lexical"]["score"]) for r in result["results"]]
                        mine = helper_hits(lifecycle.index, query, roots, labels)
                        case = (state, name)
                        self.assertEqual([m[:3] for m in mine], [n[:3] for n in native], case)
                        for m, n in zip(mine, native):
                            self.assertTrue(close(n[3], m[3]), (case, m, n))
                        compared += len(native)
                finally:
                    serve.close()
            self.assertGreaterEqual(compared, 90)


if __name__ == "__main__":
    unittest.main()
