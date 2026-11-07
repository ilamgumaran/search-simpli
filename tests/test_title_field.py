"""S5-T2: the title field (`title-field-v1`) in the Python reference.

A file's root-relative folder names and stem, tokenized with analyzer-v2, scored
with BM25 over the visible files times coverage, times the weight 2.5; added to the
file's best body chunk (or its first chunk) under `content`, and merged per file
under `both`."""

import sys
import tempfile
import unicodedata
import unittest
from collections import Counter
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO))

from src.search_platform.core import (  # noqa: E402
    TITLE_WEIGHT, _bm25_scores, _title_scores, _title_tokens, build_index, search, tokenize,
)
from relevance_smoke import run_j2_pack  # noqa: E402

ROOTS = ("school", "home", "laptop")


def write(root: Path, files: dict[str, str]) -> None:
    for path, text in files.items():
        target = root / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(text, encoding="utf-8")


class TokenTests(unittest.TestCase):
    def test_folders_then_stem_and_the_root_id_is_never_a_word(self):
        self.assertEqual(_title_tokens("school/swimming-lessons/autumn-term.md", ROOTS),
                         ("swimming", "lessons", "autumn", "term"))
        # P5: the root id kept as a folder word would put "school" first.
        self.assertNotIn("school", _title_tokens("school/notes/uniform.md", ROOTS))

    def test_legacy_and_unrooted_paths_are_taken_whole(self):
        self.assertEqual(_title_tokens("school/x.md", ("r-legacy",)), ("school", "x"))
        self.assertEqual(_title_tokens("elsewhere/x.md", ROOTS), ("elsewhere", "x"))
        self.assertEqual(_title_tokens("schoolbag/x.md", ROOTS), ("schoolbag", "x"))

    def test_the_stem_is_python_path_stem(self):
        self.assertEqual(_title_tokens("notes.v2.md", ()), ("notes", "v2"))
        self.assertEqual(_title_tokens(".hidden", ()), ("hidden",))
        self.assertEqual(_title_tokens("a/.profile.md", ()), ("a", "profile"))
        self.assertEqual(_title_tokens("README", ()), ("readme",))

    def test_tamil_full_width_and_accents(self):
        nfc = unicodedata.normalize("NFC", "home/tamil/பாட்டி-கடிதங்கள்.md")
        nfd = unicodedata.normalize("NFD", nfc)
        self.assertEqual(_title_tokens(nfc, ROOTS), ("tamil", "பாட்டி", "கடிதங்கள்"))
        self.assertEqual(_title_tokens(nfd, ROOTS), _title_tokens(nfc, ROOTS))
        self.assertEqual(_title_tokens("home/Ｒｅｃｉｐｅｓ/Crêpes-Été.md", ROOTS), ("ｒｅｃｉｐｅｓ", "crêpes", "été"))
        # the simple fold: ß and the ﬁ ligature do not expand
        self.assertEqual(_title_tokens("Straße/ﬁle.md", ()), ("straße", "ﬁle"))


class ScoreTests(unittest.TestCase):
    def chunks(self, paths, labels=None):
        return [{"id": f"c{i}", "path": p, "required_labels": (labels or {}).get(p, [])} for i, p in enumerate(paths)]

    def test_bm25_times_coverage_times_weight(self):
        paths = ["art-club/a.md", "b/club.md", "c/d.md"]
        got = _title_scores(self.chunks(paths), "art club", (), 2.5)
        docs = [{"id": p, "terms": Counter(_title_tokens(p, ())), "length": len(_title_tokens(p, ()))} for p in paths]
        bm25 = _bm25_scores(docs, ["art", "club"])
        self.assertEqual(set(got), {"art-club/a.md", "b/club.md"})
        self.assertEqual(got["art-club/a.md"], 2.5 * (bm25["art-club/a.md"] * 1.0))
        self.assertEqual(got["b/club.md"], 2.5 * (bm25["b/club.md"] * 0.5))
        self.assertEqual(_title_scores(self.chunks(paths), "art club", (), 0.0), {})

    def test_statistics_are_over_the_files_given(self):
        # P4: statistics over every file instead of the visible scope change N, the
        # average length and the df.
        wide = _title_scores(self.chunks(["x/club.md", "y/club.md", "z/other.md"]), "club", (), 2.5)
        narrow = _title_scores(self.chunks(["x/club.md", "z/other.md"]), "club", (), 2.5)
        self.assertNotEqual(wide["x/club.md"], narrow["x/club.md"])


class SearchTests(unittest.TestCase):
    def test_a_title_only_file_is_returned_through_its_first_chunk(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            write(root, {"health/doctor.md": "# Doctor\n\n" + "\n".join(f"line {i} ear check" for i in range(200)),
                         "other.md": "nothing here about the folder"})
            index = build_index(root)
            hits = search(index, "health", retrieval_mode="lexical")
            first = min((c for c in index["chunks"] if c["path"] == "health/doctor.md"),
                        key=lambda c: (c["start_line"], c["end_line"], c["id"]))
        self.assertEqual([h["citation"]["path"] for h in hits], ["health/doctor.md"])
        self.assertEqual(hits[0]["chunk_id"], first["id"])
        # no body chunk holds "health": the lexical score is the title part alone
        self.assertEqual(hits[0]["ranking"]["lexical"]["score"],
                         _title_scores(index["chunks"], "health", (), TITLE_WEIGHT)["health/doctor.md"])

    def test_the_title_part_goes_on_the_best_body_chunk_only(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            lines = [f"filler line {i}" for i in range(120)]
            lines[100] = "kite kite kite string"
            lines[5] = "kite once"
            write(root, {"kite/plans.md": "\n".join(lines), "b.md": "kite in a story"})
            index = build_index(root)
            plain = search(index, "kite", retrieval_mode="lexical", top_k=10, title_weight=0)
            titled = search(index, "kite", retrieval_mode="lexical", top_k=10)
        plain_scores = {h["chunk_id"]: h["ranking"]["lexical"]["score"] for h in plain}
        changed = {h["chunk_id"] for h in titled if h["ranking"]["lexical"]["score"] != plain_scores[h["chunk_id"]]}
        best = max((h for h in plain if h["citation"]["path"] == "kite/plans.md"),
                   key=lambda h: (h["ranking"]["lexical"]["score"], [-ord(c) for c in h["chunk_id"]]))
        self.assertEqual(changed, {best["chunk_id"]})
        self.assertEqual(titled[0]["chunk_id"], best["chunk_id"])

    def test_weight_zero_is_the_ranking_before_s5_t2(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            write(root, {"maths/homework.md": "fractions and shapes homework", "log.md": "homework homework maths"})
            index = build_index(root, filename_index=True)
            chunks = index["chunks"]
            raw = _bm25_scores(chunks, tokenize("maths homework"))
            want = [c for c, _ in sorted(raw.items(), key=lambda item: (-item[1], item[0]))]
            got = [h["chunk_id"] for h in search(index, "maths homework", retrieval_mode="lexical", title_weight=0)]
            titled = search(index, "maths homework", retrieval_mode="lexical")
        self.assertEqual(got, want)
        self.assertEqual(titled[0]["citation"]["path"], "maths/homework.md")

    def test_labels_narrow_the_statistics_and_a_path_prefix_does_not(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            write(root, {"private/club.md": "a", "public/club.md": "b", "public/other.md": "c"})
            rules = [{"path_prefix": "private/", "required_labels": ["tenant:x"]}]
            index = build_index(root, access_rules=rules)

            def title_score(**kw):
                hit = search(index, "club", retrieval_mode="lexical", top_k=5, **kw)
                return {h["citation"]["path"]: h["ranking"]["lexical"]["score"] for h in hit}

            anonymous = title_score()
            held = title_score(principal_labels=["tenant:x"])
            prefixed = title_score(principal_labels=["tenant:x"], path_prefix="public/")
        self.assertEqual(set(anonymous), {"public/club.md"})
        self.assertNotEqual(anonymous["public/club.md"], held["public/club.md"])
        self.assertEqual(prefixed["public/club.md"], held["public/club.md"])


class BothTests(unittest.TestCase):
    def test_one_result_per_file_merged_by_score(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            write(root, {"pe-kit.txt": "pe kit thursday", "notes.md": "swimming kit tuesday: goggles, towel"})
            index = build_index(root, filename_index=True)
            hits = search(index, "swimming kit tuesday", retrieval_mode="lexical", search_field="both")
        paths = [h["citation"]["path"] for h in hits]
        self.assertEqual(len(paths), len(set(paths)))
        self.assertEqual(paths[0], "notes.md")
        self.assertEqual(hits, sorted(hits, key=lambda h: (-h["score"], h["citation"]["path"].encode())))


class J2Tests(unittest.TestCase):
    """Ruling 6 of S5-T2 (and orchestrator ruling 5 on the plan) through the reference."""

    @classmethod
    def setUpClass(cls):
        cls.runs = run_j2_pack()["runs"]

    def test_title_bars(self):
        content, both = self.runs["content"]["slices"], self.runs["both"]["slices"]
        self.assertGreaterEqual(content["title"]["success_at_1"], 0.818)
        self.assertGreaterEqual(content["title"]["mrr_at_10"], 0.90)
        self.assertGreaterEqual(both["title"]["success_at_1"], 0.818)
        self.assertGreaterEqual(content["title-heldout"]["success_at_1"], 0.667)

    def test_control_keeps_rank_one_in_both_variants(self):
        for variant in ("content", "both"):
            lost = [q for q, r in self.runs[variant]["queries"].items()
                    if r["slice"] == "control" and r["first_grade2_rank"] != 1]
            self.assertEqual(lost, [], variant)


if __name__ == "__main__":
    unittest.main()
