"""S3-T7: the family-folder fixture matches the section 12 inventory and its frozen
judgments are internally consistent and match the files."""

import hashlib
import importlib.util
import json
import re
import sys
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO))

from relevance_smoke import run_pack  # noqa: E402
from src.search_platform.core import _line_chunks, tokenize  # noqa: E402

PACK = REPO / "fixtures" / "family-folder"
ROOTS = ("school", "home", "laptop")
BOM = b"\xef\xbb\xbf"


def pack_files() -> dict[str, bytes]:
    out = {}
    for root in ROOTS:
        for path in sorted((PACK / root).rglob("*")):
            if path.is_file():
                out[path.relative_to(PACK).as_posix()] = path.read_bytes()
    return out


def lines_of(data: bytes) -> list[bytes]:
    """Lines of the original bytes: terminator (\\n or \\r\\n) excluded, BOM dropped."""
    if data.startswith(BOM):
        data = data[len(BOM):]
    parts = data.split(b"\n")
    if parts and parts[-1] == b"":
        parts.pop()
    return [p[:-1] if p.endswith(b"\r") else p for p in parts]


def load_generator():
    spec = importlib.util.spec_from_file_location("family_folder_generate", PACK / "generate.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class InventoryTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.files = pack_files()
        cls.judgments = json.loads((PACK / "judgments.json").read_text(encoding="utf-8"))

    def test_counts(self):
        self.assertEqual(set(self.judgments["roots"]), set(ROOTS))
        for root in ROOTS:
            self.assertTrue(any(p.startswith(root + "/") for p in self.files), root)
        self.assertGreaterEqual(len(self.files), 40)
        markdown = [p for p in self.files if p.endswith(".md")]
        self.assertGreaterEqual(len(markdown), 25)

    def test_special_files(self):
        f = self.files
        big = f["laptop/big-log.txt"]
        self.assertGreater(len(big), 1_000_000)
        self.assertLess(len(big), 2_000_000)
        self.assertEqual(f["home/house-rules.md"], f["laptop/archive/house-rules-old.md"])
        self.assertIn(b"\r\n", f["home/crlf-shopping.md"])
        self.assertEqual(f["home/crlf-shopping.md"].count(b"\n"), f["home/crlf-shopping.md"].count(b"\r\n"))
        self.assertNotIn(b"\r\n", f["home/house-rules.md"])
        self.assertFalse(f["home/no-final-newline.txt"].endswith(b"\n"))
        self.assertGreater(len(f["home/no-final-newline.txt"]), 0)
        self.assertTrue(f["home/bom-checklist.md"].startswith(BOM))
        self.assertEqual(sum(1 for d in f.values() if d.startswith(BOM)), 1)
        self.assertEqual(f["home/empty.txt"], b"")
        tamil = f["home/tamil-notes.md"].decode("utf-8")
        self.assertTrue(re.search("[஀-௿]", tamil))
        self.assertRegex(f["home/repeated-tokens.md"].decode("utf-8").lower(), r"\bthe the\b")

    def test_markdown_structure(self):
        text = {p: d.decode("utf-8-sig").replace("\r\n", "\n") for p, d in self.files.items() if p.endswith(".md")}
        front = [p for p, t in text.items() if t.startswith("---\n")]
        self.assertEqual(len(front), 12)
        for p in front:
            body = t = text[p]
            head = body.split("\n---\n", 1)[0].split("\n")[1:]
            for line in head:
                self.assertRegex(line, r"^[A-Za-z_]+: .+$", p)
        self.assertTrue(any(re.search(r"^### ", t, re.M) for t in text.values()))
        self.assertTrue(any(re.search(r"^[^\n]+\n={3,}$", t, re.M) for t in text.values()))
        self.assertTrue(any(re.search(r"^[^\n]+\n-{3,}$", t, re.M) and not t.startswith("---") for t in text.values()))
        self.assertTrue(any(re.search(r"^- ", t, re.M) for t in text.values()))
        self.assertTrue(any(re.search(r"^1\. ", t, re.M) for t in text.values()))
        self.assertFalse(any(re.search(r"^#### ", t, re.M) for t in text.values()), "depth is 3 at most")

    def test_two_fenced_blocks_one_long(self):
        blocks = []
        for p, d in self.files.items():
            if p.endswith(".md"):
                blocks += re.findall(r"^```[a-z]*\n(.*?)^```$", d.decode("utf-8-sig").replace("\r\n", "\n"), re.S | re.M)
        self.assertEqual(len(blocks), 2)
        self.assertEqual(sorted(len(b) > 1600 for b in blocks), [False, True])

    def test_no_trailing_whitespace_and_no_home_paths(self):
        for p, d in self.files.items():
            if p.endswith(".md"):
                for n, line in enumerate(lines_of(d), 1):
                    self.assertFalse(line.endswith((b" ", b"\t")), f"{p}:{n}")
            self.assertNotIn(b"/Users/", d)
            self.assertNotIn(b"/home/", d)

    def test_newt_is_absent(self):
        for p, d in self.files.items():
            self.assertFalse(any(t.startswith("newt") for t in tokenize(d.decode("utf-8-sig"))), p)


class JudgmentTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.files = pack_files()
        cls.j = json.loads((PACK / "judgments.json").read_text(encoding="utf-8"))
        cls.lines = {p: lines_of(d) for p, d in cls.files.items()}

    def key(self, e):
        return f"{e['root_id']}/{e['path']}"

    def check_range(self, e, ctx):
        k = self.key(e)
        self.assertTrue(k in self.files, f"{ctx}: {k} does not exist")
        self.assertGreaterEqual(e["start_line"], 1, ctx)
        self.assertLessEqual(e["start_line"], e["end_line"], ctx)
        self.assertLessEqual(e["end_line"], len(self.lines[k]), f"{ctx}: {k} has {len(self.lines[k])} lines")

    def test_shape(self):
        j = self.j
        self.assertEqual(j["version"], 2)
        self.assertEqual(len(j["scenarios"]), 13)
        self.assertEqual([s["scenario"] for s in j["scenarios"]], list(range(1, 14)))
        for kind in ("phrase", "prefix", "outline"):
            self.assertEqual(len(j[kind]), 5, kind)
        self.assertEqual(len(j["read_span"]), 8)
        self.assertEqual(sum(1 for c in j["phrase"] if c["expected_engine_miss"]), 1)
        self.assertEqual(self.j["scenarios"][7]["expected_empty"], True)
        self.assertEqual(self.j["scenarios"][7]["expected"], [])

    def test_ranges_reference_existing_files(self):
        j = self.j
        for sc in j["scenarios"]:
            for e in sc.get("expected", []):
                self.check_range(e, sc["id"])
            if "expected_neighbour" in sc:
                self.check_range(sc["expected_neighbour"], sc["id"])
            if sc["kind"] == "summary":
                path = f"{sc['root_id']}/{sc['path']}"
                for s in sc["expected_sections"]:
                    self.assertLessEqual(s["heading_line"], len(self.lines[path]))
                    if s["first_span"]:
                        self.assertLessEqual(s["first_span"]["end_line"], len(self.lines[path]))
            if sc["kind"] in ("outline", "read_span"):
                self.assertTrue(f"{sc['root_id']}/{sc['path']}" in self.files)
            for step in sc.get("steps", []):
                for e in step.get("expect_hits_include", []):
                    self.check_range(e, sc["id"])
                for p in step.get("changes", []):
                    if p["op"] in ("move", "remove"):  # add/pending paths are created by the test that runs the step
                        self.assertIn(f"{p['root_id']}/{p.get('moved_from', p['path'])}", self.files.keys())
        for kind in ("phrase", "prefix"):
            for c in j[kind]:
                for e in c["expected"] + c["expected_engine_miss"]:
                    self.check_range(e, c["id"])
        for c in j["read_span"]:
            self.check_range(c, c["id"])

    def test_sha256_matches_files(self):
        for c in self.j["read_span"]:
            data = self.files[self.key(c)]
            body = data[len(BOM):] if data.startswith(BOM) else data
            # absolute byte offsets of line starts; the span ends at the start of the line
            # after end_line (or end of file), so the last line's own terminator is included
            starts, pos = [], 0
            for raw in body.split(b"\n"):
                starts.append(pos)
                pos += len(raw) + 1
            start = starts[c["start_line"] - 1]
            end = starts[c["end_line"]] if c["end_line"] < len(starts) and starts[c["end_line"]] <= len(body) else len(body)
            chunk = body[start:end]
            self.assertEqual(hashlib.sha256(chunk).hexdigest(), c["sha256"], c["id"])
            self.assertEqual(len(chunk), c["byte_length"], c["id"])
            if not body.endswith(b"\n"):
                continue
            self.assertTrue(chunk.endswith(b"\n"), c["id"])
        no_nl = next(c for c in self.j["read_span"] if c["path"] == "no-final-newline.txt")
        self.assertFalse(self.files["home/no-final-newline.txt"].endswith(b"\n"))
        self.assertEqual(no_nl["end_line"], len(self.lines["home/no-final-newline.txt"]))
        tamil = next(c for c in self.j["read_span"] if c["path"] == "tamil-notes.md")
        text = self.files["home/tamil-notes.md"].decode("utf-8").split("\n")
        self.assertGreater(tamil["byte_length"], len("\n".join(text[tamil["start_line"] - 1:tamil["end_line"]])) + 1)
        fm = next(c for c in self.j["read_span"] if c["id"] == "s6")
        self.assertEqual((fm["start_line"], fm["end_line"]), (1, 5))
        self.assertEqual(self.lines["school/notes.md"][4], b"---")
        indented = next(c for c in self.j["read_span"] if c["id"] == "s7")
        self.assertTrue(self.lines["school/notes.md"][indented["end_line"] - 1].startswith(b"  "))
        crlf = next(c for c in self.j["read_span"] if c["path"] == "crlf-shopping.md")
        data = self.files["home/crlf-shopping.md"]
        self.assertIn(b"\r\n", data.split(b"\n", 2)[2][: crlf["byte_length"] + 4])

    def test_phrase_and_prefix_sets_are_complete(self):
        """Recompute every expected set from the files with an independent scan."""
        toks = {p: [(t, n) for n, l in enumerate(ls, 1) for t in tokenize(l.decode("utf-8"))]
                for p, ls in self.lines.items()}
        for c in self.j["phrase"]:
            want = tokenize(c["query"])
            found = set()
            for p, ts in toks.items():
                for i in range(len(ts) - len(want) + 1):
                    if [t for t, _ in ts[i:i + len(want)]] == want:
                        found.add((p, ts[i][1], ts[i + len(want) - 1][1]))
            expected = {(self.key(e), e["start_line"], e["end_line"]) for e in c["expected"]}
            self.assertEqual(found, expected, c["id"])
        for c in self.j["prefix"]:
            found = {(p, n) for p, ts in toks.items() for t, n in ts if t.startswith(c["prefix"])}
            expected = {(self.key(e), e["start_line"]) for e in c["expected"] + c["expected_engine_miss"]}
            self.assertEqual(found, expected, c["id"])
            self.assertTrue(all(e["start_line"] == e["end_line"] for e in c["expected"]))
            for e in c["expected_engine_miss"]:  # only front-matter lines (line 1 is ---, so lines 2+ up to the closing ---)
                lines = self.lines[self.key(e)]
                closing = lines.index(b"---", 1) + 1
                self.assertTrue(lines[0] == b"---" and 1 < e["start_line"] < closing, c["id"])
            if c["expected_engine_miss"]:
                self.assertIn("front matter", c["expected_engine_miss_reason"])

    def test_known_chunk_local_miss_is_a_real_miss(self):
        miss = next(c for c in self.j["phrase"] if c["expected_engine_miss"])
        want = tokenize(miss["query"])
        path = self.key(miss["expected"][0])
        text = "\n".join(l.decode("utf-8") for l in self.lines[path])
        for _, _, chunk in _line_chunks(text):
            toks = tokenize(chunk)
            self.assertFalse(any(toks[i:i + len(want)] == want for i in range(len(toks))))
        # the other four phrase cases each sit whole inside one chunk
        for c in self.j["phrase"]:
            if c is miss:
                continue
            want = tokenize(c["query"])
            for e in c["expected"]:
                text = "\n".join(l.decode("utf-8") for l in self.lines[self.key(e)])
                self.assertTrue(any(
                    any(t[i:i + len(want)] == want for i in range(len(t)))
                    for t in (tokenize(ch) for _, _, ch in _line_chunks(text))), c["id"])

    def test_outline_headings_are_headings(self):
        for c in self.j["outline"]:
            path = f"{c['root_id']}/{c['path']}"
            lines = [l.decode("utf-8") for l in self.lines[path]]
            self.assertEqual(c["lines"], len(lines))
            for h in c["headings"]:
                text = lines[h["line"] - 1]
                atx = re.match(rf"^#{{{h['level']}}} {re.escape(h['text'])}\s*$", text)
                setext = (text.strip() == h["text"] and h["line"] < len(lines)
                          and re.match(r"^(=+|-+)$", lines[h["line"]]))
                self.assertTrue(atx or setext, f"{path}:{h['line']} {text!r}")
                self.assertLessEqual(h["line"], h["end_line"])
                self.assertLessEqual(h["end_line"], len(lines))
            if c["front_matter"]:
                fm = c["front_matter"]
                self.assertEqual(lines[0], "---")
                self.assertEqual(lines[fm["end_line"] - 1], "---")

    def test_section_paths(self):
        s6 = self.j["scenarios"][5]["expected"][0]
        self.assertEqual(s6["section_path"], ["Class notes", "Week 7", "Spelling"])
        s7 = self.j["scenarios"][6]["expected"][0]
        self.assertEqual(s7["section_path"], ["Class notes", "Week 7", "Dates"])


class GeneratorAndRunnerTests(unittest.TestCase):
    def test_generator_is_deterministic_and_matches_committed_files(self):
        gen = load_generator()
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp)
            gen.write_tree(out)
            for path in [p for p in PACK.rglob("*") if p.is_file()]:
                rel = path.relative_to(PACK)
                if rel.parts[0] in ROOTS or rel.name in ("judgments.json", "README.md"):
                    self.assertEqual((out / rel).read_bytes(), path.read_bytes(), str(rel))
            produced = {p.relative_to(out).as_posix() for p in out.rglob("*") if p.is_file()}
            committed = {p.relative_to(PACK).as_posix() for p in PACK.rglob("*")
                         if p.is_file() and "__pycache__" not in p.parts}
            self.assertEqual(produced - committed, set())

    def test_pack_runner(self):
        report = run_pack("family-folder")
        self.assertTrue(report["gate"]["passed"])
        self.assertGreaterEqual(report["words_recall_at_k"], 0.9)
        self.assertTrue(report["newt_empty"])
        # S3-T2: phrase and prefix run through the Python reference's `find`:
        # 5 + 5 cases plus scenarios 2 and 3, precision and recall 1.00 across
        # all pages, the listed engine misses missed; scenario 10's phrase
        # step runs too. S3-T3: the three lifecycle scenarios run as well, so
        # nothing is skipped.
        self.assertEqual(report["skipped"], {})
        self.assertEqual({k: len(v) for k, v in report["find_cases"].items()}, {"phrase": 6, "prefix": 6})
        for metrics in report["find_metrics"].values():
            self.assertEqual(metrics, {"precision": 1.0, "recall": 1.0, "expected_misses_found": 0})
        self.assertEqual([c["hits"] for c in report["find_cases"]["phrase"]], [3, 1, 0, 1, 2, 3])
        self.assertEqual([c["hits"] for c in report["find_cases"]["prefix"]], [5, 7, 5, 5, 1, 5])
        # S3-T1: outline and read_span run through the Python reference, exactly.
        self.assertNotIn("outline", report["skipped"])
        self.assertNotIn("read_span", report["skipped"])
        # S3-T3: the three lifecycle scenarios run through the reference's apply_changes.
        self.assertEqual(report["exactness"], {"outline": 1.0, "read_span": 1.0, "phrase_neighbour": 1.0, "lifecycle": 1.0})
        self.assertEqual(len(report["exact_cases"]["lifecycle"]), 3)
        self.assertNotIn("scenario lifecycle (S3-T3/T4)", report["skipped"])
        self.assertEqual(len(report["exact_cases"]["read_span"]), 9)  # 8 cases + scenario 5
        self.assertEqual(len(report["exact_cases"]["outline"]), 7)  # 5 cases + scenarios 4 and 9


if __name__ == "__main__":
    unittest.main()
