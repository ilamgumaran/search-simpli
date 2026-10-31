"""S3-T5: `contracts/tools/*.schema.json` against RECORDED REAL responses.

The responses come from the real `searchd` over the family-folder fixture:
the CLI's `--json` (`query`, `find`, `outline`, `read-span`, `list-files`,
`roots`, `apply`) and the RPC server (`serve`) for every method including
`index_status`, `read_chunk`, `list_sources` and `apply_changes`. Each is
validated with the repository's own validator (`schema_check`), and a plant
(an extra field, a missing field, an out-of-range value) must fail it.

`SEARCH_SIMPLI_NO_ZIG=1` skips the recorded-response tests (CI has no Zig);
the schema-shape and validator tests still run."""

import copy
import json
import os
import shutil
import sys
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO))
sys.path.insert(0, str(REPO / "tests"))

from src.search_platform.schema_check import (  # noqa: E402
    SchemaError, UnsupportedKeyword, check, check_schema, load_tool_schema, validate,
)
from test_folder_surfaces import ROOT_IDS, Rpc, build_searchd, fixture_request  # noqa: E402

TOOLS = ("search_knowledge", "read_chunk", "list_sources", "index_status", "find",
         "outline", "read_span", "list_files", "apply_changes")
TOOLS_DIR = REPO / "contracts" / "tools"
NO_ZIG = os.environ.get("SEARCH_SIMPLI_NO_ZIG") == "1"


def objects(schema: object, path: str = "$"):
    """Every sub-schema that describes an object, with its path."""
    if isinstance(schema, dict):
        if schema.get("type") == "object" or (isinstance(schema.get("type"), list) and "object" in schema["type"]):
            yield path, schema
        for key, value in schema.items():
            yield from objects(value, f"{path}.{key}")
    elif isinstance(schema, list):
        for index, value in enumerate(schema):
            yield from objects(value, f"{path}[{index}]")


class SchemaShapeTests(unittest.TestCase):
    def test_eighteen_files_for_nine_tools(self) -> None:
        names = sorted(p.name for p in TOOLS_DIR.glob("*.schema.json"))
        self.assertEqual(names, sorted(f"{t}.{k}.schema.json" for t in TOOLS for k in ("request", "result")))

    def test_every_schema_is_2020_12_closed_and_described(self) -> None:
        for tool in TOOLS:
            for kind in ("request", "result"):
                schema = load_tool_schema(tool, kind)
                where = f"{tool}.{kind}"
                self.assertEqual(schema["$schema"], "https://json-schema.org/draft/2020-12/schema", where)
                self.assertTrue(schema["description"], where)
                self.assertEqual(schema["type"], "object", where)
                for path, sub in objects(schema):
                    if "properties" in sub:
                        self.assertIs(sub.get("additionalProperties"), False, f"{where} {path}")
                        for name, prop in sub["properties"].items():
                            if "$ref" not in prop:
                                self.assertTrue(prop.get("description"), f"{where} {path}.{name} has no description")
                # Every $ref resolves, and the validator understands every keyword.
                validate({}, schema)

    def test_request_schemas_hide_principal_labels_and_vectors(self) -> None:
        for tool in TOOLS:
            text = (TOOLS_DIR / f"{tool}.request.schema.json").read_text(encoding="utf-8")
            self.assertNotIn('"principal_labels"', text, tool)
            self.assertNotIn('"query_vector"', text, tool)

    def test_integer_bounds_match_the_protocol(self) -> None:
        find = load_tool_schema("find", "request")["properties"]["page_size"]
        self.assertEqual((find["minimum"], find["maximum"], find["default"]), (1, 100, 20))
        listing = load_tool_schema("list_files", "request")["properties"]["page_size"]
        self.assertEqual((listing["minimum"], listing["maximum"], listing["default"]), (1, 1000, 100))
        span = load_tool_schema("read_span", "request")["properties"]["context_lines"]
        self.assertEqual((span["minimum"], span["maximum"]), (0, 20))
        top = load_tool_schema("search_knowledge", "request")["properties"]["top_k"]
        self.assertEqual((top["minimum"], top["maximum"]), (1, 100))
        self.assertEqual(load_tool_schema("find", "request")["properties"]["mode"]["enum"], ["words", "phrase", "prefix"])
        self.assertEqual(load_tool_schema("list_files", "request")["properties"]["status"]["enum"], ["indexed", "pending", None])

    def test_requests_accept_documented_calls_and_refuse_the_rest(self) -> None:
        ok = [
            ("search_knowledge", {"query": "band concert", "top_k": 3, "roots": ["school"]}),
            ("read_chunk", {"chunk_id": "c97363d864182e221c37"}),
            ("list_sources", {}), ("list_sources", {"path_prefix": "school/", "roots": None}),
            ("index_status", {}), ("index_status", {"roots": ["home"]}),
            ("find", {"query": "\"count me in\"", "mode": "phrase", "page_size": 5, "cursor": "1:5"}),
            ("outline", {"root_id": "school", "path": "science-notes.md"}),
            ("read_span", {"root_id": "school", "path": "notes.md", "start_line": 31, "end_line": 34, "context_lines": 1}),
            ("list_files", {"status": "pending", "page_size": 1000}),
            ("apply_changes", {"expect_generation": 1, "roots": [{"root_id": "home", "kind": "host"}],
                               "changes": [{"op": "add", "root_id": "home", "path": "a.md", "content_base64": "IyBBCg=="}]}),
        ]
        for tool, params in ok:
            self.assertEqual(validate(params, load_tool_schema(tool, "request")), [], (tool, params))
        bad = [
            ("search_knowledge", {"query": ""}), ("search_knowledge", {"query": "x", "top_k": 101}),
            ("search_knowledge", {"query": "x", "principal_labels": ["adults"]}),
            ("search_knowledge", {"query": "x", "retrieval_mode": "fuzzy"}),
            ("read_chunk", {}), ("find", {"query": "x", "page_size": 101}), ("find", {"query": "x", "page_size": 0}),
            ("find", {"query": "x", "mode": "regex"}), ("find", {"query": "x", "cursor": "abc"}),
            ("find", {"query": "x", "extra": 1}), ("find", {"query": "x", "page_size": True}),
            ("outline", {"root_id": "school"}), ("read_span", {"root_id": "a", "path": "b", "start_line": 0, "end_line": 1}),
            ("read_span", {"root_id": "a", "path": "b", "start_line": 1, "end_line": 2, "context_lines": 21}),
            ("list_files", {"page_size": 1001}), ("list_files", {"status": "gone"}),
            ("apply_changes", {}), ("apply_changes", {"changes": [{"op": "rename", "root_id": "a"}]}),
            ("apply_changes", {"changes": [], "principal_labels": ["x"]}),
        ]
        for tool, params in bad:
            self.assertNotEqual(validate(params, load_tool_schema(tool, "request")), [], (tool, params))


def as_input_schema_style(tool: str, description: str) -> dict:
    return {"name": tool, "description": description, "input_schema": load_tool_schema(tool, "request")}


def as_parameters_style(tool: str, description: str) -> dict:
    return {"type": "function", "function": {"name": tool, "description": description, "parameters": load_tool_schema(tool, "request")}}


def as_mcp_tool(tool: str, description: str) -> dict:
    return {"name": tool, "description": description, "inputSchema": load_tool_schema(tool, "request")}


class ProviderWrappingTests(unittest.TestCase):
    """docs/tool-schemas.md: the same schema, three descriptor shapes, unchanged."""

    def test_three_shapes_carry_the_file_unchanged(self) -> None:
        for tool in TOOLS:
            on_disk = json.loads((TOOLS_DIR / f"{tool}.request.schema.json").read_text(encoding="utf-8"))
            for descriptor in (as_input_schema_style(tool, "d"), as_parameters_style(tool, "d"), as_mcp_tool(tool, "d")):
                embedded = (descriptor.get("input_schema") or descriptor.get("inputSchema")
                            or descriptor["function"]["parameters"])
                self.assertEqual(embedded, on_disk, tool)
                self.assertEqual(json.dumps(embedded, sort_keys=True), json.dumps(on_disk, sort_keys=True))
                self.assertEqual(embedded["type"], "object")  # MCP requires an object schema

    def test_the_document_names_the_three_shapes(self) -> None:
        text = (REPO / "docs" / "tool-schemas.md").read_text(encoding="utf-8")
        for needle in ("input_schema", "parameters", "inputSchema", "own target", "Do not change the schema"):
            self.assertIn(needle, text)

    def test_request_validation_is_the_adapters_gate(self) -> None:
        schema = as_mcp_tool("find", "d")["inputSchema"]
        self.assertEqual(validate({"query": "tide"}, schema), [])
        self.assertNotEqual(validate({"query": "tide", "principal_labels": ["x"]}, schema), [])


class ValidatorTests(unittest.TestCase):
    def test_keywords(self) -> None:
        schema = {"type": "object", "additionalProperties": False, "required": ["a"], "properties": {
            "a": {"type": "integer", "minimum": 1, "maximum": 3},
            "b": {"type": ["string", "null"], "pattern": "^x"},
            "c": {"enum": ["p", "q", None]},
            "d": {"type": "array", "items": {"$ref": "#/$defs/s"}, "maxItems": 2, "uniqueItems": True},
            "e": {"const": True},
            "f": {"type": "number"}},
            "$defs": {"s": {"type": "string", "minLength": 1}}}
        good = {"a": 2, "b": None, "c": None, "d": ["x"], "e": True, "f": 1}
        self.assertEqual(validate(good, schema), [])
        for change in ({"a": 0}, {"a": 4}, {"a": 1.5}, {"a": True}, {"b": "y"}, {"b": 3}, {"c": "r"}, {"d": ["x", "x"]},
                       {"d": [""]}, {"d": ["a", "b", "c"]}, {"d": [1]}, {"e": 1}, {"f": "1"}, {"zzz": 1}):
            self.assertNotEqual(validate({**good, **change}, schema), [], change)
        self.assertNotEqual(validate({k: v for k, v in good.items() if k != "a"}, schema), [])
        self.assertTrue(validate([], schema))

    def test_unknown_keyword_is_loud(self) -> None:
        with self.assertRaises(UnsupportedKeyword):
            validate(1, {"oneOf": []})
        with self.assertRaises(SchemaError):
            check({"a": 1}, {"type": "object", "additionalProperties": False})

    def test_unknown_keyword_off_the_instance_path_is_loud(self) -> None:
        # S3-T5 Verdict finding 2: `oneOf` under a property the instance does
        # not carry, in `$defs`, under `items` and `additionalProperties`.
        request = load_tool_schema("find", "request")
        planted = json.loads(json.dumps(request))
        planted["properties"]["page_size"]["oneOf"] = [{"type": "integer"}]
        self.assertEqual(validate({"query": "tide"}, request), [])
        with self.assertRaises(UnsupportedKeyword):
            validate({"query": "tide"}, planted)
        for schema in ({"$defs": {"x": {"format": "date"}}},
                       {"type": "array", "items": {"anyOf": []}},
                       {"type": "object", "additionalProperties": {"if": {}}},
                       {"type": "object", "properties": {"a": {"type": "decimal"}}},
                       {"$ref": "https://example.invalid/x.json"}):
            with self.assertRaises(UnsupportedKeyword, msg=json.dumps(schema)):
                check_schema(schema)
        for name in TOOLS:
            for kind in ("request", "result"):
                check_schema(load_tool_schema(name, kind))


@unittest.skipIf(NO_ZIG, "SEARCH_SIMPLI_NO_ZIG=1: this environment deliberately has no Zig (CI)")
class RecordedResponseTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.scratch_dir = tempfile.TemporaryDirectory()
        cls.scratch = Path(cls.scratch_dir.name)
        cls.binary = build_searchd(cls.scratch)
        changes = cls.scratch / "changes.json"
        changes.write_text(json.dumps(fixture_request()), encoding="utf-8")
        cls.index = cls.scratch / "index"
        cls.apply_report = cls.cli("apply", str(cls.index), "--changes", str(changes))
        cls.rpc = Rpc(cls.binary, cls.index, "--roots", ",".join(ROOT_IDS))
        cls.recorded: list[tuple[str, dict, dict]] = []  # (tool, params, result)

    @classmethod
    def tearDownClass(cls) -> None:
        cls.rpc.close()
        cls.scratch_dir.cleanup()

    @classmethod
    def cli(cls, *args: str) -> dict:
        import subprocess
        done = subprocess.run([str(cls.binary), *args, "--json"], capture_output=True, text=True, stdin=subprocess.DEVNULL, timeout=120)
        if done.returncode != 0:
            raise AssertionError(done.stderr)
        return json.loads(done.stdout)

    def rpc_ok(self, tool: str, params: dict) -> dict:
        self.assertEqual(validate(params, load_tool_schema(tool, "request")), [], (tool, params))
        response = self.rpc.call(tool, params)
        self.assertIn("result", response, response)
        self.recorded.append((tool, params, response["result"]))
        return response["result"]

    def assert_valid(self, tool: str, result: dict) -> None:
        self.assertEqual(validate(result, load_tool_schema(tool, "result")), [], tool)

    def test_search_knowledge_read_chunk_list_sources(self) -> None:
        found = self.rpc_ok("search_knowledge", {"query": "band concert", "top_k": 3})
        self.assert_valid("search_knowledge", found)
        self.assertTrue(found["results"])
        chunk = self.rpc_ok("read_chunk", {"chunk_id": found["results"][0]["chunk_id"]})
        self.assert_valid("read_chunk", chunk)
        self.assert_valid("list_sources", self.rpc_ok("list_sources", {}))
        self.assert_valid("list_sources", self.rpc_ok("list_sources", {"path_prefix": "school/", "roots": ["school"]}))
        empty = self.rpc_ok("search_knowledge", {"query": "newt"})
        self.assertEqual(empty["results"], [])
        self.assert_valid("search_knowledge", empty)

    def test_index_status(self) -> None:
        status = self.rpc_ok("index_status", {})
        self.assert_valid("index_status", status)
        self.assertEqual(status["pending"], 0)
        self.assert_valid("index_status", self.rpc_ok("index_status", {"roots": ["school"]}))

    def test_find_every_mode_cli_and_rpc(self) -> None:
        for params in ({"query": "tide table"}, {"query": "\"count me in\"", "page_size": 2},
                       {"query": "photosyn*", "mode": "prefix"}, {"query": "newt"},
                       {"query": "\"zzz qqq\"", "mode": "phrase"}, {"query": "tide", "roots": ["school"], "path_prefix": "geo"}):
            result = self.rpc_ok("find", params)
            self.assert_valid("find", result)
        words = self.rpc_ok("find", {"query": "tide"})
        self.assertIsNone(words["exact_match"])
        phrase_miss = self.rpc_ok("find", {"query": "\"zzz qqq\""})
        self.assertIs(phrase_miss["exact_match"], False)
        self.assertTrue(phrase_miss["empty"])
        page = self.rpc_ok("find", {"query": "tide", "page_size": 1})
        self.assertIsNotNone(page["next_cursor"])
        self.assert_valid("find", self.rpc_ok("find", {"query": "tide", "page_size": 1, "cursor": page["next_cursor"]}))
        cli = self.cli("find", str(self.index), "\"count me in\"", "--page-size", "1")
        self.assert_valid("find", cli)

    def test_outline_read_span_list_files_roots(self) -> None:
        outline = self.rpc_ok("outline", {"root_id": "school", "path": "science-notes.md"})
        self.assert_valid("outline", outline)
        self.assertIsInstance(outline["front_matter"], dict)
        plain = self.rpc_ok("outline", {"root_id": "school", "path": "contacts.txt"})
        self.assert_valid("outline", plain)
        self.assertIsNone(plain["front_matter"])
        self.assert_valid("outline", self.cli("outline", str(self.index), "school", "science-notes.md"))
        span = self.rpc_ok("read_span", {"root_id": "school", "path": "notes.md", "start_line": 31, "end_line": 34, "context_lines": 1})
        self.assert_valid("read_span", span)
        clamped = self.rpc_ok("read_span", {"root_id": "school", "path": "notes.md", "start_line": 30, "end_line": 9999})
        self.assertEqual(clamped["warnings"][0]["code"], "end_line_clamped")
        self.assert_valid("read_span", clamped)
        self.assert_valid("read_span", self.cli("read-span", str(self.index), "school", "notes.md", "31", "34", "--context", "2"))
        listing = self.rpc_ok("list_files", {"page_size": 3})
        self.assert_valid("list_files", listing)
        self.assert_valid("list_files", self.rpc_ok("list_files", {"root_id": "home", "path_prefix": "trips/", "status": "indexed"}))
        self.assert_valid("list_files", self.cli("list-files", str(self.index), "--page-size", "2"))
        # `roots` has no tool of its own; its result is the envelope plus the roots,
        # checked here against the shared shape of index_status's `roots` member.
        roots = self.cli("roots", str(self.index))
        status_roots = load_tool_schema("index_status", "result")["$defs"]["root_info"]
        for item in roots["roots"]:
            self.assertEqual(validate(item, status_roots), [])

    def test_apply_changes_report_and_pending(self) -> None:
        self.assert_valid("apply_changes", self.apply_report)
        scratch = self.scratch / "writable"
        shutil.copytree(self.index, scratch)
        server = Rpc(self.binary, scratch, "--roots", ",".join(ROOT_IDS), "--allow-write")
        try:
            changes = {"expect_generation": 1, "changes": [
                {"op": "pending", "root_id": "home", "path": "not-yet.md", "size": 120},
                {"op": "add", "root_id": "home", "path": "extra.md", "content_base64": "IyBFeHRyYQoKQSBsaW5lLgo="},
                {"op": "add", "root_id": "home", "path": "extra.md", "content_base64": "IyBFeHRyYQoKQSBsaW5lLgo="},
                {"op": "add", "root_id": "home", "path": "bad.md", "sha256": "0" * 64, "content_base64": "IyBFeHRyYQo="}]}
            self.assertEqual(validate(changes, load_tool_schema("apply_changes", "request")), [])
            reply = server.call("apply_changes", changes)
            self.assertIn("result", reply, reply)
            report = reply["result"]
            self.assert_valid("apply_changes", report)
            self.assertEqual(report["pending"], 1)
            self.assertTrue(report["rejected"])
            self.assertTrue(report["conflicts"])
            # Pending files show in index_status, list_files and find.
            status = server.call("index_status", {})["result"]
            self.assert_valid("index_status", status)
            self.assertEqual(status["pending"], 1)
            self.assertEqual(status["pending_paths"], [{"root_id": "home", "path": "not-yet.md"}])
            files = server.call("list_files", {"status": "pending"})["result"]
            self.assert_valid("list_files", files)
            self.assertEqual(files["files"][0]["status"], "pending")
            found = server.call("find", {"query": "tide"})["result"]
            self.assert_valid("find", found)
            self.assertEqual(found["pending_files"], 1)
        finally:
            server.close()

    def test_a_response_with_an_extra_field_fails_every_schema(self) -> None:
        self.test_search_knowledge_read_chunk_list_sources()
        self.test_index_status()
        self.test_find_every_mode_cli_and_rpc()
        self.test_outline_read_span_list_files_roots()
        seen = {tool for tool, _, _ in self.recorded}
        self.assertEqual(seen, set(TOOLS) - {"apply_changes"})
        for tool, _, result in self.recorded:
            schema = load_tool_schema(tool, "result")
            self.assertEqual(validate(result, schema), [])
            planted = copy.deepcopy(result)
            planted["surprise"] = 1
            self.assertIn("unexpected field 'surprise'", " ".join(validate(planted, schema)), tool)
            missing = copy.deepcopy(result)
            first = next(iter(missing))
            del missing[first]
            self.assertNotEqual(validate(missing, schema), [], (tool, first))
        # Nested plants: a hit, a file entry, a heading, the scope.
        find = next(r for t, _, r in self.recorded if t == "find" and r["hits"])
        schema = load_tool_schema("find", "result")
        for target in (lambda r: r["hits"][0], lambda r: r["files"][0], lambda r: r["scope"], lambda r: r["coverage"], lambda r: r["request"]):
            planted = copy.deepcopy(find)
            target(planted)["surprise"] = 1
            self.assertNotEqual(validate(planted, schema), [])
        planted = copy.deepcopy(find)
        planted["hits"][0]["start_line"] = "3"
        self.assertNotEqual(validate(planted, schema), [])
        # The apply report too.
        planted = copy.deepcopy(self.apply_report)
        planted["surprise"] = 1
        self.assertNotEqual(validate(planted, load_tool_schema("apply_changes", "result")), [])


if __name__ == "__main__":
    unittest.main()
