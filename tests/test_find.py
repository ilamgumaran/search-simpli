"""S3-T2: the Python reference's `find` (words, phrase, prefix), mirroring
zig/src/find_fixture_test.zig on small invented folders."""

import sys
import tempfile
import unicodedata
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO))

from src.search_platform.core import ReadError, build_index, tokenize  # noqa: E402
from src.search_platform.find import (  # noqa: E402
    MAX_SNIPPET_CODEPOINTS,
    find,
    find_all,
    index_generation,
    normalize_mapped,
    shared_lines,
    tokenize_positioned,
)


def index_of(files: dict[str, str]) -> dict:
    with tempfile.TemporaryDirectory() as scratch:
        root = Path(scratch)
        for path, text in files.items():
            (root / path).parent.mkdir(parents=True, exist_ok=True)
            (root / path).write_text(text, encoding="utf-8")
        return build_index(root)


class TokenizerTests(unittest.TestCase):
    def test_positioned_tokens_equal_tokenize_and_cover_the_original(self):
        samples = [
            "Zig, search-v2! Café rocks.", "பள்ளி விடுமுறை", "1️⃣ a️b",
            "한글 x", "Ångstrom", "", "the the  the",
            "क्‍ष a‍ b",
        ]
        for text in samples:
            positioned = tokenize_positioned(text)
            self.assertEqual([t for t, _, _ in positioned], tokenize(text), text)
            for term, start, length in positioned:
                self.assertEqual(tokenize(text[start:start + length]), [term], text)
        self.assertEqual(tokenize_positioned("Café, café! x️y"),
                         [("café", 0, 4), ("café", 6, 5), ("xy", 13, 3)])

    def test_normalize_mapped_is_nfc(self):
        for text in ["égalite", "ạ́b", "ொ", "plain", "한"]:
            normalized, starts, ends = normalize_mapped(text)
            self.assertEqual(normalized, unicodedata.normalize("NFC", text))
            self.assertTrue(all(s < e for s, e in zip(starts, ends)))


class FindTests(unittest.TestCase):
    def test_phrase_repeated_tokens_punctuation_tamil_and_quotes(self):
        index = index_of({
            "a.txt": "the the the\n",
            "b.txt": "the the the the\n",
            "c.txt": "the cat the\n",
            "d.txt": "Yes: count, me... in! And COUNT me IN.\n",
            "e.txt": "பள்ளி விடுமுறை நாளை. விடுமுறை பள்ளி\n",
            "f.txt": "me count in\n",
        })
        repeated = find(index, "the the", mode="phrase", page_size=100)
        self.assertEqual({h["path"]: len(h["match_offsets"]) for h in repeated["hits"]}, {"a.txt": 1, "b.txt": 2})
        punctuated = find(index, '"count -- me, in"', page_size=100)
        self.assertEqual(punctuated["request"]["mode"], "phrase")
        self.assertEqual([h["path"] for h in punctuated["hits"]], ["d.txt"])
        self.assertEqual(punctuated["hits"][0]["match_offsets"], [[5, 20], [26, 37]])
        self.assertTrue(punctuated["exact_match"])
        words = find(index, "count me in", page_size=100)
        self.assertEqual(sorted(h["path"] for h in words["hits"]), ["d.txt", "f.txt"])
        self.assertIsNone(words["exact_match"])
        tamil = find(index, '"பள்ளி விடுமுறை"', page_size=100)
        self.assertEqual(tamil["hits"][0]["match_offsets"], [[0, 14]])
        self.assertEqual(len(find(index, "விடு*")["hits"][0]["match_offsets"]), 2)

    def test_invalid_arguments_and_cursors(self):
        index = index_of({"a.txt": "alpha beta gamma\n", "b.txt": "alpha beta\n", "c.txt": "alpha\n"})
        for query in ["", "   ", "!!! ...", "*", '""', '" "']:
            for mode in ("words", "phrase", "prefix"):
                with self.assertRaises(ReadError) as raised:
                    find(index, query, mode=mode)
                self.assertEqual((raised.exception.code, str(raised.exception)), ("invalid_argument", "empty query"))
        for kwargs in ({"page_size": 0}, {"page_size": 101}, {"mode": "fuzzy"}):
            with self.assertRaises(ReadError):
                find(index, "alpha", **kwargs)
        with self.assertRaisesRegex(ReadError, "only the last token"):
            find(index, "al* beta")
        generation = index_generation(index)
        first = find(index, "alpha", page_size=2)
        self.assertEqual(first["total_hits"], 3)
        self.assertEqual(first["next_cursor"], f"{generation}:2")
        second = find(index, "alpha", page_size=2, cursor=first["next_cursor"])
        self.assertEqual(len(second["hits"]), 1)
        self.assertIsNone(second["next_cursor"])
        with self.assertRaisesRegex(ReadError, "^stale cursor$"):
            find(index, "alpha", cursor=f"{generation + 1}:2")
        for cursor in ["", "1", "1:", ":2", "x:2", "1:-1"]:
            with self.assertRaisesRegex(ReadError, "malformed cursor"):
                find(index, "alpha", cursor=cursor)
        with self.assertRaisesRegex(ReadError, "positions absent") as raised:
            find(index, '"alpha beta"', positions=False)
        self.assertEqual(raised.exception.code, "capacity")

    def test_prefix_expansion_is_visible_only_and_capped(self):
        public = "".join(f"zq{i:04d} " + ("\n" if i % 10 == 9 else "") for i in range(1000))
        index = index_of({"public/terms.txt": public, "hidden/extra.txt": "zq9999 zebra\n"})
        with self.assertRaises(ReadError) as raised:
            find(index, "zq*")
        self.assertEqual(raised.exception.code, "capacity")
        scoped = find(index, "zq*", path_prefix="public/", page_size=100)
        self.assertGreater(scoped["total_hits"], 0)
        self.assertTrue(find(index, "zeb*", path_prefix="public/")["empty"])
        earlier = find(index, "zebra zq99*", page_size=100)
        self.assertEqual([h["path"] for h in earlier["hits"]], ["hidden/extra.txt"])

    def test_ordering_files_and_coverage(self):
        same = "# Notes\n\nlantern festival\n"
        index = index_of({"school/b.md": same, "home/z.md": same, "school/a.md": same, "home/a.md": same})
        answer = find(index, '"lantern festival"', page_size=100, root_ids=["home", "school"])
        self.assertEqual([(h["root_id"], h["path"]) for h in answer["hits"]],
                         [("home", "a.md"), ("home", "z.md"), ("school", "a.md"), ("school", "b.md")])
        self.assertEqual(answer["coverage"], {"files": 4, "sections": 4})
        self.assertEqual(len(answer["files"]), 4)

    def test_overlap_deduplication(self):
        lines = []
        for line in range(40):
            words = {19: "the harbour light is green tonight", 25: "a harbour light again further down"}.get(line, "filler words here")
            lines.append(f"{words:<78}")
        index = index_of({"log.txt": "\n".join(lines) + "\n"})
        self.assertGreaterEqual(len(index["chunks"]), 2)
        self.assertEqual(len(find(index, '"harbour light"', page_size=100)["hits"]), 2)
        only = find(index, '"green tonight"', page_size=100)
        self.assertEqual(len(only["hits"]), 1)
        self.assertEqual(only["deduplicated"], 1)
        self.assertEqual(only["hits"][0]["start_line"], 1)
        self.assertEqual(len(find(index, "green tonight", page_size=100)["hits"]), 1)
        self.assertEqual(len(find(index, "tonig*", page_size=100)["hits"]), 1)
        a, b = sorted(index["chunks"], key=lambda c: c["start_line"])[:2]
        self.assertEqual(shared_lines(a["text"], b["text"], a["end_line"] - b["start_line"] + 1), 3)

    def test_snippet_window_and_offsets(self):
        text = "".join(f"padding{i} " for i in range(30)) + "kestrel " + "".join(f"middle{i} " for i in range(20))
        text += "kestrel osprey kestrel " + "".join(f"tail{i} " for i in range(30))
        index = index_of({"birds.txt": text})
        hit = find(index, "kestrel osprey")["hits"][0]
        self.assertEqual(len(hit["match_offsets"]), 4)
        self.assertIn("kestrel osprey kestrel", hit["snippet"])
        self.assertLessEqual(len(hit["snippet"]), MAX_SNIPPET_CODEPOINTS)
        self.assertEqual(hit["content"][hit["snippet_start"]:hit["snippet_start"] + len(hit["snippet"])], hit["snippet"])
        for start, end in hit["snippet_offsets"]:
            self.assertIn([start + hit["snippet_start"], end + hit["snippet_start"]], hit["match_offsets"])
        for start, end in hit["match_offsets"]:
            self.assertIn(tokenize(hit["content"][start:end])[0], {"kestrel", "osprey"})
        self.assertFalse(hit["snippet"].startswith(" ") or hit["snippet"].endswith(" "))

    def test_find_all_pages_to_the_end(self):
        index = index_of({f"n{i}.txt": "lantern\n" for i in range(7)})
        self.assertEqual(len(find_all(index, "lantern", page_size=2)), 7)


if __name__ == "__main__":
    unittest.main()
