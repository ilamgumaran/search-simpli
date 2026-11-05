"""S3-T5: `skills/folder-knowledge/example_loop.py` as a test over the fixture.

The stub model follows SKILL.md against a real `searchd serve`. Every `[n]` in
every answer must map to a hit or span that a tool actually returned; the
newt question must get the skill's exact negative sentence; `apply_changes`
is never called; and the skill document carries the sentences the loop uses.
`SEARCH_SIMPLI_NO_ZIG=1` skips the process tests."""

import importlib.util
import json
import os
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO))
sys.path.insert(0, str(REPO / "tests"))
SKILL = REPO / "skills" / "folder-knowledge"

from test_folder_surfaces import build_searchd  # noqa: E402

spec = importlib.util.spec_from_file_location("example_loop", SKILL / "example_loop.py")
loop = importlib.util.module_from_spec(spec)
sys.modules["example_loop"] = loop
spec.loader.exec_module(loop)


def returned_hit_lines(log: list, root_id: str, path: str):
    """Every (start, end) a tool returned for this file."""
    for method, params, result in log:
        if method == "find":
            for hit in result["hits"]:
                if (hit["root_id"], hit["path"]) == (root_id, path):
                    yield hit["start_line"], hit["end_line"]
        elif method == "search_knowledge":
            for item in result["results"]:
                if item["citation"]["path"] == f"{root_id}/{path}":
                    yield item["citation"]["start_line"], item["citation"]["end_line"]
        elif method == "read_span" and (result["request"]["root_id"], result["request"]["path"]) == (root_id, path):
            yield result["start_line"], result["end_line"]
        elif method == "outline" and (result["request"]["root_id"], result["request"]["path"]) == (root_id, path):
            yield 1, result["lines"]


class SkillDocumentTests(unittest.TestCase):
    def test_skill_carries_the_required_sentences(self) -> None:
        text = (SKILL / "SKILL.md").read_text(encoding="utf-8")
        self.assertTrue(text.startswith("---\nname: folder-knowledge\n"))
        self.assertIn("> " + loop.NEGATIVE, text)
        self.assertIn(loop.CAVEAT.split(" cover")[0], text)
        for needle in ("exact_match", "null", "pending_files", "truncated", "never call", "apply_changes", "root/path › section · lines",
                       "[n]", "index_status", "find", "search_knowledge", "read_span", "read_chunk"):
            self.assertIn(needle.lower(), text.lower(), needle)
        for tool in ("search_knowledge", "read_chunk", "list_sources", "index_status", "find", "outline", "read_span", "list_files", "apply_changes"):
            self.assertIn(f"`{tool}`", text, tool)

    def test_skill_names_the_filename_field(self) -> None:
        """S4-T5: a later edit must not drop the file-name option from the skill."""
        text = (SKILL / "SKILL.md").read_text(encoding="utf-8")
        for needle in ("search_field", "matched_in", "basename", "match_sections", "retrieval_mode: lexical",
                       "search_field: filename", "`filename`", "`both`", "navigation, not evidence", "--filename-index"):
            self.assertIn(needle, text, needle)
        schema = json.loads((REPO / "contracts" / "tools" / "search_knowledge.request.schema.json").read_text(encoding="utf-8"))
        self.assertEqual(schema["properties"]["search_field"]["enum"], ["content", "filename", "both"])

    def test_the_loop_cannot_call_apply_changes(self) -> None:
        self.assertNotIn("apply_changes", loop.READ_TOOLS)
        tools = loop.Tools.__new__(loop.Tools)
        with self.assertRaises(PermissionError):
            tools.call("apply_changes", changes=[])


@unittest.skipIf(os.environ.get("SEARCH_SIMPLI_NO_ZIG") == "1", "SEARCH_SIMPLI_NO_ZIG=1: this environment deliberately has no Zig (CI)")
class LoopOverTheFixtureTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.scratch_dir = tempfile.TemporaryDirectory()
        scratch = Path(cls.scratch_dir.name)
        binary = build_searchd(scratch)
        index = scratch / "index"
        loop.build_fixture_index(str(binary), index)
        cls.results, tools = loop.run_all(str(binary), index)
        cls.log = tools.log
        tools.close()
        cls.by_id = {r["id"]: r for r in cls.results}

    @classmethod
    def tearDownClass(cls) -> None:
        cls.scratch_dir.cleanup()

    def test_ten_questions_are_answered(self) -> None:
        self.assertEqual([r["id"] for r in self.results], [f"uc007-{n:02d}" for n in range(1, 11)])

    def test_every_marker_maps_to_a_returned_passage(self) -> None:
        for item in self.results:
            body = item["answer"].split("\n")
            used = {int(n) for line in body if not re.match(r"^\[\d+\] ", line) for n in re.findall(r"\[(\d+)\]", line)}
            listed = {int(m.group(1)) for line in body if (m := re.match(r"^\[(\d+)\] ", line))}
            self.assertEqual(used, listed, item["id"])
            self.assertEqual(listed, set(range(1, len(item["sources"]) + 1)), item["id"])
            if item["id"] == "uc007-08":
                self.assertEqual(used, set())
            else:
                self.assertTrue(used, item["id"])
            for number, source in enumerate(item["sources"], 1):
                spans = list(returned_hit_lines(self.log, source["root_id"], source["path"]))
                self.assertTrue(any(a <= source["start_line"] and source["end_line"] <= b for a, b in spans),
                                (item["id"], number, source, spans))
                self.assertRegex(item["answer"], rf"(?m)^\[{number}\] {re.escape(source['root_id'] + '/' + source['path'])}")

    def test_quotes_are_substrings_of_returned_text(self) -> None:
        texts = []
        for method, _, result in self.log:
            if method == "read_span":
                texts.append(" ".join(result["text"].split()))
            elif method in ("read_chunk",):
                texts.append(" ".join(result["content"].split()))
        blob = "\n".join(texts)
        for item in self.results:
            for quote in re.findall(r"“([^”]+)”", item["answer"]):
                self.assertIn(" ".join(quote.split()), blob, (item["id"], quote))

    def test_a_citation_that_was_never_returned_is_caught(self) -> None:
        spans = list(returned_hit_lines(self.log, "school", "notes.md"))
        self.assertTrue(spans)
        self.assertFalse(any(a <= 4000 <= b for a, b in spans))
        self.assertEqual(list(returned_hit_lines(self.log, "school", "no-such-file.md")), [])

    def test_the_newt_question_gets_the_negative_sentence(self) -> None:
        newt = self.by_id["uc007-08"]
        self.assertEqual(newt["answer"], loop.NEGATIVE)
        self.assertEqual(newt["sources"], [])
        others = [r["answer"] for r in self.results if r["id"] != "uc007-08"]
        self.assertTrue(all(loop.NEGATIVE not in a for a in others))
        self.assertNotIn("nothing about", newt["answer"].lower())

    def test_the_answers_are_the_expected_ones(self) -> None:
        self.assertIn("school/notes.md › Class notes › Week 7 › Spelling · lines 27–29", self.by_id["uc007-06"]["answer"])
        self.assertIn("Friday 6", self.by_id["uc007-07"]["answer"])
        self.assertIn("exact phrase", self.by_id["uc007-02"]["answer"])
        self.assertNotIn("exact phrase", self.by_id["uc007-01"]["answer"])  # exact_match was null for words
        self.assertIn("4. Tip it out", self.by_id["uc007-10"]["answer"])
        self.assertIn("home/recipes/bread.md › Weekend bread › Method · line 20", self.by_id["uc007-10"]["answer"])

    def test_no_write_and_every_tool_call_is_valid(self) -> None:
        from src.search_platform.schema_check import load_tool_schema, validate
        self.assertTrue(self.log)
        for method, params, result in self.log:
            self.assertNotEqual(method, "apply_changes")
            self.assertEqual(validate(params, load_tool_schema(method, "request")), [], (method, params))
            self.assertEqual(validate(result, load_tool_schema(method, "result")), [], method)

    def test_the_caveat_appears_when_files_are_pending(self) -> None:
        import json
        import subprocess
        scratch = Path(self.scratch_dir.name)
        binary = build_searchd(scratch)
        index = scratch / "pending-index"
        loop.build_fixture_index(str(binary), index)
        request = {"changes": [{"op": "pending", "root_id": "home", "path": "later.md", "size": 90}]}
        file = scratch / "pending.json"
        file.write_text(json.dumps(request), encoding="utf-8")
        done = subprocess.run([str(binary), "apply", str(index), "--changes", str(file)], capture_output=True, text=True)
        self.assertEqual(done.returncode, 0, done.stderr)
        tools = loop.Tools(str(binary), index)
        try:
            answer = loop.Loop(tools).run({"kind": "empty", "query": "newts"}).render()
        finally:
            tools.close()
        self.assertEqual(answer, loop.NEGATIVE + "\n" + loop.CAVEAT)


@unittest.skipIf(os.environ.get("SEARCH_SIMPLI_NO_ZIG") == "1", "SEARCH_SIMPLI_NO_ZIG=1: this environment deliberately has no Zig (CI)")
class FilenameQuestionTests(unittest.TestCase):
    """S4-T5: a question that names a file by a word found only in its name.

    `geography` is in the name of `geography-coast.md` in the `school` folder and nowhere in its
    text (nor in any other file of the `school` folder, the one indexed here). The stub follows the skill's
    step 2: `search_knowledge` with `search_field: filename` and
    `retrieval_mode: lexical` over an index built with `--filename-index`; the
    result is navigation only, so it reads `outline` and `read_span` and cites
    the file by name (no lines) plus the lines it actually read."""

    @classmethod
    def setUpClass(cls) -> None:
        cls.scratch_dir = tempfile.TemporaryDirectory()
        scratch = Path(cls.scratch_dir.name)
        cls.binary = build_searchd(scratch)
        cls.index = scratch / "index"
        # The CLI has the flag: `searchd index <folder> --out <dir> --filename-index`.
        done = subprocess.run([str(cls.binary), "index", str(loop.PACK / "school"), "--out", str(cls.index), "--filename-index"],
                              capture_output=True, text=True)
        assert done.returncode == 0, done.stderr
        plain = scratch / "plain-index"
        done = subprocess.run([str(cls.binary), "index", str(loop.PACK / "school"), "--out", str(plain)], capture_output=True, text=True)
        assert done.returncode == 0, done.stderr
        cls.plain = plain

    @classmethod
    def tearDownClass(cls) -> None:
        cls.scratch_dir.cleanup()

    def answer(self, tools) -> tuple[str, dict]:
        status = tools.call("index_status")
        self.assertEqual(status.get("filename_policy_id"), "filename-field-v1")
        found = tools.call("search_knowledge", query="geography", search_field="filename", retrieval_mode="lexical", top_k=3)
        self.assertEqual(found["retrieval"]["search_field"], "filename")
        top = found["results"][0]
        self.assertEqual(top["matched_in"], ["filename"])
        self.assertEqual(top["basename"], "geography-coast.md")
        self.assertTrue(top["match_sections"]["filename"]["matched"])
        self.assertFalse(top["match_sections"]["content"]["matched"])
        self.assertTrue(found["answer_policy"]["filename_matches_are_navigation"])
        # Navigation, not evidence: name the file, then read it before quoting.
        root_id = top["root_id"]
        path = top["citation"]["path"]
        if path.startswith(root_id + "/"):
            path = path[len(root_id) + 1:]
        self.assertEqual(path, "geography-coast.md")
        outline = tools.call("outline", root_id=root_id, path=path)
        tides = next(h for h in outline["headings"] if h["text"] == "Tides")
        span = tools.call("read_span", root_id=root_id, path=path, start_line=tides["line"] + 1, end_line=tides["line"] + 3)
        quote = " ".join(span["text"].split()).split(". ")[0] + "."
        section = loop.section_for(outline["headings"], tides["line"])
        arrow = " \u203a "
        text = (f"The file named for geography is {root_id}/{path}; only its name matched, so I read it. "
                f"It says: \u201c{quote}\u201d [1]\n"
                f"[1] {root_id}/{path} \u203a {arrow.join(section)} \u00b7 lines {span['start_line']}\u2013{span['end_line']}")
        return text, {"root_id": root_id, "path": path, "span": span, "outline": outline}

    def test_a_word_only_in_the_name_is_answered_through_filename_search(self) -> None:
        tools = loop.Tools(str(self.binary), self.index)
        try:
            text, seen = self.answer(tools)
            log = tools.log
        finally:
            tools.close()
        methods = [m for m, _, _ in log]
        self.assertEqual(methods[:2], ["index_status", "search_knowledge"])
        self.assertLess(methods.index("search_knowledge"), methods.index("outline"))
        self.assertLess(methods.index("outline"), methods.index("read_span"))
        self.assertNotIn("apply_changes", methods)
        search_params = log[1][1]
        self.assertEqual(search_params["search_field"], "filename")
        self.assertEqual(search_params["retrieval_mode"], "lexical")
        # find does not see file names: the word is a miss there and in the text search.
        tools = loop.Tools(str(self.binary), self.index)
        try:
            self.assertEqual(tools.call("find", query="geography", page_size=5)["hits"], [])
            self.assertEqual(tools.call("search_knowledge", query="geography", retrieval_mode="lexical", top_k=3)["results"], [])
        finally:
            tools.close()
        # The citation is the file and lines that read_span returned, none invented.
        span = seen["span"]
        self.assertIn("\u201cThe sea comes in and goes out twice a day.\u201d [1]", text)
        self.assertIn(" ".join(span["text"].split()).split(". ")[0], " ".join(span["text"].split()))
        self.assertIn(f"[1] {seen['root_id']}/geography-coast.md \u203a The coast project \u203a Tides \u00b7 lines {span['start_line']}\u2013{span['end_line']}", text)
        lines = (loop.PACK / "school" / seen["path"]).read_text(encoding="utf-8").splitlines()
        self.assertEqual(len(lines), seen["outline"]["lines"])
        self.assertTrue(1 <= span["start_line"] <= span["end_line"] <= len(lines))
        self.assertIn("The sea comes in and goes out twice a day.", " ".join(lines[span["start_line"] - 1:span["end_line"]]))
        for number in re.findall(r"lines (\d+)\u2013(\d+)", text):
            self.assertEqual((int(number[0]), int(number[1])), (span["start_line"], span["end_line"]))

    def test_an_index_without_the_channel_refuses_filename_search(self) -> None:
        tools = loop.Tools(str(self.binary), self.plain)
        try:
            self.assertNotIn("filename_policy_id", tools.call("index_status"))
            with self.assertRaises(RuntimeError) as caught:
                tools.call("search_knowledge", query="geography", search_field="filename", retrieval_mode="lexical")
            self.assertIn("--filename-index", str(caught.exception))
            # the text still answers
            self.assertTrue(tools.call("search_knowledge", query="tide table", retrieval_mode="lexical")["results"])
        finally:
            tools.close()


if __name__ == "__main__":
    unittest.main()
