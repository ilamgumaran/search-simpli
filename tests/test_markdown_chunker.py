"""S3-T1: md-section-v1, outline and read_span in the Python reference.

The golden (`fixtures/chunk-golden-md.json`) is what `zig/src/chunker_md_test.zig`
holds the Zig port to; these tests hold the Python reference to the same file,
to the frozen family-folder judgments, and to the line-window-v1 golden that
must not move.
"""

import hashlib
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO))

from src.search_platform import core  # noqa: E402

PACK = REPO / "fixtures" / "family-folder"


class MarkdownChunkerGoldenTest(unittest.TestCase):
    def test_golden_regenerates_byte_for_byte(self):
        produced = subprocess.run(
            [sys.executable, "scripts/gen_chunk_golden_md.py"], cwd=REPO, check=True,
            capture_output=True,
        ).stdout
        self.assertEqual(produced, (REPO / "fixtures" / "chunk-golden-md.json").read_bytes())

    def test_markdown_fixture_regenerates_byte_for_byte(self):
        with tempfile.TemporaryDirectory() as scratch:
            copy = Path(scratch)
            (copy / "fixtures").mkdir()
            subprocess.run([sys.executable, str(REPO / "scripts" / "gen_markdown_fixture.py")],
                           cwd=copy, check=True)
            for path in sorted((REPO / "fixtures" / "markdown").iterdir()):
                self.assertEqual((copy / "fixtures" / "markdown" / path.name).read_bytes(),
                                 path.read_bytes(), path.name)

    def test_line_window_golden_is_unchanged(self):
        produced = subprocess.run(
            [sys.executable, "scripts/gen_chunk_golden.py"], cwd=REPO, check=True,
            capture_output=True,
        ).stdout
        self.assertEqual(produced, (REPO / "fixtures" / "chunk-golden.json").read_bytes())

    def test_dispatch_by_extension(self):
        self.assertEqual(core.chunker_for_path("a/b.md"), core.MD_CHUNKER_ID)
        self.assertEqual(core.chunker_for_path("README.MD"), core.MD_CHUNKER_ID)
        self.assertEqual(core.chunker_for_path("notes.markdown"), core.MD_CHUNKER_ID)
        self.assertEqual(core.chunker_for_path("notes.txt"), core.CHUNKER_ID)
        self.assertEqual(core.chunker_for_path(".md"), core.CHUNKER_ID)

    def test_sections_never_cross_and_fences_stay_whole(self):
        text = (REPO / "fixtures" / "markdown" / "fences.md").read_text(encoding="utf-8")
        lines = text.splitlines()
        heads = {h["line"] for h in core.markdown_outline(text)["headings"]}
        for start, end, _, path, heading in core._md_section_chunks(text):
            inner = {line for line in heads if start < line <= end}
            self.assertEqual(inner, set(), (start, end))
            self.assertLessEqual(heading, start)
        # The fence that fits max_chars after "Overlap into fence" is in one chunk whole.
        open_line = next(i + 1 for i, line in enumerate(lines) if line.startswith("tally 1:")) - 1
        close_line = open_line + 7
        holders = [(s, e) for s, e, *_ in core._md_section_chunks(text) if s <= open_line and close_line <= e]
        self.assertTrue(holders)

    def test_front_matter_is_not_body(self):
        text = (PACK / "laptop" / "photosynthesis-draft.md").read_text(encoding="utf-8")
        outline = core.markdown_outline(text)
        last = outline["front_matter"]["end_line"]
        for start, *_ in core._md_section_chunks(text):
            self.assertGreater(start, last)


class FamilyFolderReadOperationsTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.judgments = json.loads((PACK / "judgments.json").read_text(encoding="utf-8"))

    def test_outline_judgments_are_exact(self):
        for case in self.judgments["outline"]:
            data = (PACK / case["root_id"] / case["path"]).read_bytes()
            want = {key: case[key] for key in ("front_matter", "headings", "lines", "chunker")}
            self.assertEqual(core.outline_bytes(case["path"], data), want, case["id"])

    def test_read_span_judgments_are_byte_exact(self):
        for case in self.judgments["read_span"]:
            data = (PACK / case["root_id"] / case["path"]).read_bytes()
            got = core.read_span_bytes(data, case["start_line"], case["end_line"], case["context_lines"])
            self.assertEqual(got["sha256"], case["sha256"], case["id"])
            self.assertEqual(len(got["text"].encode("utf-8")), case["byte_length"], case["id"])
            self.assertTrue(got["byte_exact"])

    def test_read_span_through_an_index_and_its_refusals(self):
        index = core.build_index(PACK / "home")
        crlf = core.read_span(index, "crlf-shopping.md", 3, 8, 1)
        self.assertIn("\r\n", crlf["text"])
        self.assertTrue(crlf["context_before"].endswith("\r\n"))
        with self.assertRaises(core.ReadError) as raised:
            core.read_span(index, "missing.md", 1, 1)
        self.assertEqual(raised.exception.code, "not_found")
        with self.assertRaises(core.ReadError) as raised:
            core.read_span(index, "crlf-shopping.md", 1, 1, 21)
        self.assertEqual(raised.exception.code, "invalid_argument")
        many = ("x\n" * 1000).encode()
        core.read_span_bytes(many, 21, 380, 20)
        with self.assertRaises(core.ReadError) as raised:
            core.read_span_bytes(many, 21, 381, 20)
        self.assertEqual(raised.exception.code, "capacity")

    def test_stale_file_is_refused(self):
        with tempfile.TemporaryDirectory() as scratch:
            root = Path(scratch)
            (root / "a.md").write_text("# A\nalpha\n", encoding="utf-8")
            index = core.build_index(root)
            self.assertEqual(core.read_span(index, "a.md", 2, 2)["text"], "alpha\n")
            (root / "a.md").write_text("# A\nbeta\n", encoding="utf-8")
            with self.assertRaises(core.ReadError) as raised:
                core.read_span(index, "a.md", 2, 2)
            self.assertEqual(raised.exception.code, "not_found")
            self.assertIn("stale", str(raised.exception))

    def test_chunk_section_paths_match_the_judged_spans(self):
        index = core.build_index(PACK / "school")
        judged = [item for sc in self.judgments["scenarios"] for item in sc.get("expected", [])
                  if sc["kind"] == "answer" and item["root_id"] == "school"]
        self.assertTrue(judged)
        for item in judged:
            holders = [c for c in index["chunks"] if c["path"] == item["path"]
                       and c["start_line"] <= item["start_line"] and item["end_line"] <= c["end_line"]]
            self.assertTrue(holders, item)
            for chunk in holders:
                self.assertEqual(chunk["section_path"], item["section_path"], item)
                self.assertEqual(chunk["chunker"], core.MD_CHUNKER_ID)

    def test_line_starts_cover_every_terminator(self):
        data = "a\r\nb\rc\nd\x0be\x0cf\x1cg\x85h i j".encode("utf-8")
        self.assertEqual(core.line_starts(data), [0, 3, 5, 7, 9, 11, 13, 16, 20, 24, 25])
        self.assertEqual(core.line_starts(b"\xef\xbb\xbfx\n\ny"), [3, 5, 6, 7])
        self.assertEqual(core.line_starts(b""), [0])
        whole = b"".join(core.read_span_bytes(data, n, n)["text"].encode() for n in range(1, 11))
        self.assertEqual(whole, data)
        self.assertEqual(hashlib.sha256(whole).hexdigest(), hashlib.sha256(data).hexdigest())


if __name__ == "__main__":
    unittest.main()
