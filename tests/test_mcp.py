"""S3-T6: `searchd mcp`, the MCP server (`docs/tasks/S3-T6.md` rulings 1 to 3;
`docs/mcp-server.md`), through the real binary and the standard-library
client `tests/mcp_client.py`.

The index is the family-folder fixture as three host roots plus the
labelled `private` root (`test_folder_surfaces.fixture_request`, invented
content). Covered: the conformance sequence; revision negotiation and the
lifecycle; the three tool modes (`--baseline`, default, `--allow-write`) and
their descriptors (the S3-T5 schemas verbatim); every structured result
against its result schema; parity with `searchd serve` for every fixture
judgment and for one request per tool without optional fields (the
canonical JSON in `structuredContent` and in the text block equals the RPC
`result`, byte for byte, 100% of cases; a refusal's error object equals the
RPC error object); the scope from the command line only (forged
`principal_labels`/`query_vector` refused, hidden = absent); resources
(pagination, whole-file reads through `read_span`'s limits); writes
(`--allow-write`, confined to `--roots`); framing (malformed, batch, blank,
over-long lines; notifications unanswered); usage errors.

`SEARCH_SIMPLI_NO_ZIG=1` (CI) skips, as the other surface tests do."""

from __future__ import annotations

import base64
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from mcp_client import (  # noqa: E402
    BASELINE_TOOLS, PROTOCOL_VERSION, READ_TOOLS, UTF8_BOM, McpClient, resource_text_matches_size, run_conformance,
    structured, tool_error,
)
from src.search_platform.schema_check import load_tool_schema, validate  # noqa: E402
from test_folder_surfaces import PACK, Rpc, build_searchd, fixture_request  # noqa: E402

NO_ZIG = os.environ.get("SEARCH_SIMPLI_NO_ZIG") == "1"
TOOLS_DIR = Path(__file__).resolve().parents[1] / "contracts" / "tools"


def schema_file(name: str, kind: str) -> dict:
    return json.loads((TOOLS_DIR / f"{name}.{kind}.schema.json").read_text(encoding="utf-8"))


class ResourceSizeComparisonTests(unittest.TestCase):
    """S3-T8: the conformance client's length check is BOM-aware (needs no Zig)."""

    def test_bom_file_of_the_fixture(self) -> None:
        data = (PACK / "home" / "bom-checklist.md").read_bytes()
        self.assertTrue(data.startswith(UTF8_BOM))
        text = data.removeprefix(UTF8_BOM).decode("utf-8")
        # The server's `size` counts the BOM; its text does not: the strict comparison fails here.
        self.assertNotEqual(len(text.encode("utf-8")), len(data))
        self.assertTrue(resource_text_matches_size(text, len(data)))

    def test_a_file_without_a_bom_and_wrong_sizes(self) -> None:
        data = (PACK / "home" / "birthday-plans.md").read_bytes()
        self.assertFalse(data.startswith(UTF8_BOM))
        text = data.decode("utf-8")
        self.assertTrue(resource_text_matches_size(text, len(data)))
        self.assertFalse(resource_text_matches_size(text, len(data) + 1))
        self.assertFalse(resource_text_matches_size(text, len(data) - 1))
        self.assertFalse(resource_text_matches_size(text, len(data) + 4))


@unittest.skipIf(NO_ZIG, "SEARCH_SIMPLI_NO_ZIG=1: this environment deliberately has no Zig (CI)")
class McpServerTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.scratch_dir = tempfile.TemporaryDirectory()
        cls.scratch = Path(cls.scratch_dir.name)
        cls.binary = build_searchd(cls.scratch)
        cls.judgments = json.loads((PACK / "judgments.json").read_text(encoding="utf-8"))
        changes = cls.scratch / "changes.json"
        changes.write_text(json.dumps(fixture_request()), encoding="utf-8")
        cls.index = cls.scratch / "index"
        applied = subprocess.run([str(cls.binary), "apply", str(cls.index), "--changes", str(changes)],
                                 capture_output=True, text=True, timeout=120)
        if applied.returncode != 0:
            raise AssertionError(applied.stderr)

    @classmethod
    def tearDownClass(cls) -> None:
        cls.scratch_dir.cleanup()

    def mcp(self, *flags: str, index: Path | None = None) -> McpClient:
        return McpClient([str(self.binary), "mcp", str(index or self.index), *flags])

    def ready(self, *flags: str, index: Path | None = None) -> McpClient:
        client = self.mcp(*flags, index=index)
        client.initialize()
        return client

    def finish(self, client: McpClient) -> None:
        self.assertEqual(client.close(), 0)
        self.assertEqual(client.protocol_errors, [])

    # ------------------------------------------------------ conformance ---

    def test_the_conformance_client_passes_every_check(self) -> None:
        checks = run_conformance([str(self.binary), "mcp", str(self.index)])
        failed = [f"{c.name}: {c.detail}" for c in checks if not c.ok]
        self.assertEqual(failed, [])
        self.assertGreaterEqual(len(checks), 25)

    def test_revision_negotiation_and_lifecycle(self) -> None:
        for asked in (PROTOCOL_VERSION, "2025-06-18", "1999-01-01"):
            client = self.mcp()
            result = client.result("initialize", {"protocolVersion": asked, "capabilities": {}, "clientInfo": {"name": "t", "version": "1"}})
            self.assertEqual(result["protocolVersion"], PROTOCOL_VERSION, asked)
            self.assertEqual(result["serverInfo"]["name"], "search-simpli")
            self.assertIn("instructions", result)
            again = client.request("initialize", {"protocolVersion": asked})
            self.assertEqual(again["error"]["code"], -32600)
            self.finish(client)
        client = self.mcp()
        self.assertEqual(client.request("ping")["result"], {}, "ping before initialize")
        self.assertEqual(client.request("initialize", {"capabilities": {}})["error"]["code"], -32602)
        self.assertEqual(client.request("resources/list")["error"]["code"], -32600)
        client.initialize()
        self.assertEqual(len(client.list_tools()), 8)
        self.finish(client)

    # ------------------------------------------------------------ tools ---

    def test_three_modes_and_the_descriptors_carry_the_schemas_verbatim(self) -> None:
        cases = ((("--baseline",), BASELINE_TOOLS), ((), READ_TOOLS), (("--allow-write",), READ_TOOLS + ("apply_changes",)))
        for flags, expected in cases:
            client = self.mcp(*flags)
            init = client.initialize()
            tools = client.list_tools()
            self.assertEqual(tuple(t["name"] for t in tools), expected, flags)
            for tool in tools:
                self.assertEqual(tool["inputSchema"], schema_file(tool["name"], "request"), tool["name"])
                self.assertEqual(tool["outputSchema"], schema_file(tool["name"], "result"), tool["name"])
                self.assertTrue(tool["description"])
                self.assertEqual(tool["annotations"]["readOnlyHint"], tool["name"] != "apply_changes")
            if flags == ("--baseline",):
                self.assertNotIn("resources", init["capabilities"])
                for method in ("resources/list", "resources/read", "resources/templates/list"):
                    self.assertEqual(client.request(method, {"uri": "search://school/notes.md"})["error"]["code"], -32601, method)
                refused = client.request("tools/call", {"name": "find", "arguments": {"query": "tide"}})
                self.assertEqual(refused["error"], {"code": -32602, "message": "Unknown tool: find"})
            self.assertEqual(client.request("tools/list", {"cursor": "next"})["error"]["code"], -32602)
            self.finish(client)

    def test_every_structured_result_validates_against_its_result_schema(self) -> None:
        client = self.ready()
        try:
            calls = [
                ("search_knowledge", {"query": "tide table"}),
                ("search_knowledge", {"query": "newts", "retrieval_mode": "lexical"}),
                ("list_sources", {"roots": ["school"]}),
                ("index_status", {}),
                ("find", {"query": "\"count me in\""}),
                ("find", {"query": "photosyn*", "page_size": 2}),
                ("outline", {"root_id": "school", "path": "science-notes.md"}),
                ("read_span", {"root_id": "school", "path": "science-notes.md", "start_line": 40, "end_line": 9999}),
                ("list_files", {"page_size": 5}),
            ]
            found = structured(client.call_tool("find", {"query": "tide"}))
            calls.append(("read_chunk", {"chunk_id": found["hits"][0]["chunk_id"]}))
            for name, arguments in calls:
                value = structured(client.call_tool(name, arguments))
                self.assertEqual(validate(value, load_tool_schema(name, "result")), [], name)
                self.assertEqual(validate(arguments, load_tool_schema(name, "request")), [], name)
        finally:
            self.finish(client)

    def test_search_knowledge_names_root_section_and_completeness(self) -> None:
        client = self.ready()
        try:
            value = structured(client.call_tool("search_knowledge", {"query": "band concert", "retrieval_mode": "lexical", "top_k": 10}))
            self.assertTrue(value["results"])
            for item in value["results"]:
                self.assertTrue(item["citation"]["path"].startswith(item["root_id"] + "/"), item["citation"])
                self.assertIsInstance(item["section_path"], list)
                self.assertEqual(list(item)[:5], ["chunk_id", "citation", "content", "score", "ranking"])
            self.assertTrue(any(item["section_path"] for item in value["results"]))
            self.assertEqual(list(value)[-3:], ["answer_policy", "truncated", "pending_files"])
            self.assertIs(value["truncated"], False)
            self.assertEqual(value["pending_files"], 0)
        finally:
            self.finish(client)

    # ----------------------------------------------------------- parity ---

    def parity_requests(self, client: McpClient) -> list[tuple[str, dict]]:
        """Every fixture judgment as a request, plus a read_chunk per find
        judgment (its first hit) and the listings."""
        requests: list[tuple[str, dict]] = []
        for case in self.judgments["phrase"] + self.judgments["prefix"]:
            requests.append(("find", {"query": case["query"], "mode": case["mode"], "page_size": 100}))
            requests.append(("search_knowledge", {"query": case["query"].rstrip("*"), "retrieval_mode": "lexical", "top_k": 10}))
        for case in self.judgments["scenarios"]:
            if case.get("query"):
                requests.append(("find", {"query": case["query"], "mode": case["mode"], "page_size": 100}))
                requests.append(("search_knowledge", {"query": case["query"].rstrip("*"), "top_k": 10}))
            if case["kind"] in ("outline", "summary"):
                requests.append(("outline", {"root_id": case["root_id"], "path": case["path"]}))
        for case in self.judgments["outline"]:
            requests.append(("outline", {"root_id": case["root_id"], "path": case["path"]}))
        for case in self.judgments["read_span"]:
            requests.append(("read_span", {k: case[k] for k in ("root_id", "path", "start_line", "end_line", "context_lines")}))
        for name, arguments in list(requests):
            if name == "find":
                hits = structured(client.call_tool(name, arguments))["hits"]
                if hits:
                    requests.append(("read_chunk", {"chunk_id": hits[0]["chunk_id"]}))
        requests += [
            ("list_sources", {"path_prefix": "school/"}),
            ("index_status", {"roots": ["home", "laptop"]}),
            ("list_files", {"page_size": 1000}),
            ("list_files", {"root_id": "laptop", "page_size": 3}),
        ]
        return requests

    def assert_parity(self, rpc: Rpc, client: McpClient, name: str, arguments: dict) -> None:
        rpc_line = json.loads(rpc.raw(name, arguments))
        mcp_result = client.call_tool(name, arguments)
        label = f"{name} {json.dumps(arguments)[:120]}"
        if "error" in rpc_line:
            self.assertEqual(tool_error(mcp_result), rpc_line["error"], label)
            return
        rpc_text = json.dumps(rpc_line["result"], ensure_ascii=False, separators=(",", ":"))
        self.assertEqual(structured(mcp_result), rpc_line["result"], label)
        # The text block is the RPC result's own bytes (same producer, ops.zig).
        self.assertEqual(json.loads(mcp_result["content"][0]["text"]), json.loads(rpc_text), label)

    def test_parity_with_the_rpc_server_for_every_fixture_judgment(self) -> None:
        rpc = Rpc(self.binary, self.index)
        client = self.ready()
        try:
            requests = self.parity_requests(client)
            for name, arguments in requests:
                self.assert_parity(rpc, client, name, arguments)
            tools = {name for name, _ in requests}
            self.assertEqual(tools, set(READ_TOOLS))
            self.assertGreaterEqual(len(requests), 60)
            # Byte for byte: the text block equals the RPC `result` member's bytes.
            for name, arguments in requests[:12]:
                self.assertEqual(client.call_tool(name, arguments)["content"][0]["text"], rpc.result_text(name, arguments))
            print(f"\nS3-T6 parity: {len(requests)} requests, MCP structuredContent = RPC result (100%)", file=sys.stderr)
        finally:
            rpc.close()
            self.finish(client)

    def test_parity_with_no_optional_fields_catches_a_changed_default(self) -> None:
        """S3-T4 Verdict finding 1: one request per tool that states nothing
        optional, so a surface that injects a different default is caught."""
        rpc = Rpc(self.binary, self.index)
        client = self.ready()
        try:
            chunk = structured(client.call_tool("find", {"query": "tide"}))["hits"][0]["chunk_id"]
            minimal = [
                ("search_knowledge", {"query": "tide table"}),
                ("read_chunk", {"chunk_id": chunk}),
                ("list_sources", {}),
                ("index_status", {}),
                ("find", {"query": "tide"}),
                ("outline", {"root_id": "school", "path": "science-notes.md"}),
                ("read_span", {"root_id": "school", "path": "science-notes.md", "start_line": 40, "end_line": 41}),
                ("list_files", {}),
            ]
            self.assertEqual({name for name, _ in minimal}, set(READ_TOOLS))
            for name, arguments in minimal:
                self.assertEqual(client.call_tool(name, arguments)["content"][0]["text"], rpc.result_text(name, arguments), name)
            # The same with no `arguments` member at all where nothing is required.
            for name in ("list_sources", "index_status", "list_files"):
                self.assertEqual(client.call_tool(name)["content"][0]["text"], rpc.result_text(name, {}), name)
        finally:
            rpc.close()
            self.finish(client)

    def test_refusals_carry_the_rpc_error_object(self) -> None:
        rpc = Rpc(self.binary, self.index)
        client = self.ready()
        try:
            refused = [
                ("find", {"query": "tide", "bogus": 1}),
                ("find", {"query": ""}),
                ("find", {"query": "tide", "page_size": 101}),
                ("find", {"query": "tide", "cursor": "999:0"}),
                ("search_knowledge", {"query": "tide", "top_k": 0}),
                ("search_knowledge", {}),
                ("read_chunk", {"chunk_id": "no-such-chunk"}),
                ("outline", {"root_id": "private", "path": "plans.md"}),
                ("read_span", {"root_id": "laptop", "path": "big-log.txt", "start_line": 1, "end_line": 401}),
                ("read_span", {"root_id": "school", "path": "notes.md", "start_line": 1}),
                ("list_files", {"status": "done"}),
                ("index_status", {"roots": "school"}),
            ]
            for name, arguments in refused:
                rpc_line = json.loads(rpc.raw(name, arguments))
                self.assertIn("error", rpc_line, name)
                self.assert_parity(rpc, client, name, arguments)
        finally:
            rpc.close()
            self.finish(client)

    # ------------------------------------------------------------ scope ---

    def test_the_scope_comes_from_the_command_line_only(self) -> None:
        plain = self.ready()
        labelled = self.ready("--labels", "adults")
        school = self.ready("--roots", "school")
        try:
            for client in (plain, labelled):
                for name, arguments in (("find", {"query": "tide", "principal_labels": ["adults"]}),
                                        ("search_knowledge", {"query": "tide", "principal_labels": []}),
                                        ("search_knowledge", {"query": "tide", "query_vector": [0.1]}),
                                        ("list_sources", {"principal_labels": ["adults"]})):
                    error = tool_error(client.call_tool(name, arguments))
                    self.assertEqual(error["code"], -32602, name)
            hidden = structured(plain.call_tool("find", {"query": "surprise party"}))
            self.assertEqual(hidden["hits"], [])
            self.assertNotIn("private", hidden["scope"]["roots"])
            seen = structured(labelled.call_tool("find", {"query": "surprise party"}))
            self.assertEqual([h["root_id"] for h in seen["hits"]], ["private"])
            absent = tool_error(plain.call_tool("read_span", {"root_id": "private", "path": "nope.md", "start_line": 1, "end_line": 1}))
            hidden_span = tool_error(plain.call_tool("read_span", {"root_id": "private", "path": "plans.md", "start_line": 1, "end_line": 1}))
            self.assertEqual(absent["code"], hidden_span["code"])
            self.assertEqual(absent["message"].replace("nope.md", "X"), hidden_span["message"].replace("plans.md", "X"))
            status = structured(school.call_tool("index_status", {"roots": ["school", "home"]}))
            self.assertEqual([r["root_id"] for r in status["roots"]], ["school"])
            knowledge = structured(school.call_tool("search_knowledge", {"query": "tide table", "top_k": 20}))
            self.assertTrue(all(item["root_id"] == "school" for item in knowledge["results"]))
        finally:
            for client in (plain, labelled, school):
                self.finish(client)

    # -------------------------------------------------------- resources ---

    def test_resources_read_of_the_bom_file_matches_the_listed_size(self) -> None:
        client = self.ready()
        try:
            listed = client.result("resources/list")
            uri = "search://home/bom-checklist.md"
            entry = next(r for r in listed["resources"] if r["uri"] == uri)
            data = (PACK / "home" / "bom-checklist.md").read_bytes()
            self.assertEqual(entry["size"], len(data))
            text = client.result("resources/read", {"uri": uri})["contents"][0]["text"]
            self.assertFalse(text.startswith("\ufeff"))
            self.assertTrue(resource_text_matches_size(text, entry["size"]))
        finally:
            self.finish(client)

    def test_resources_read_through_read_span_limits(self) -> None:
        client = self.ready()
        try:
            listed = client.result("resources/list")
            resources = {r["uri"]: r for r in listed["resources"]}
            self.assertNotIn("nextCursor", listed)
            self.assertTrue(all(uri.startswith("search://") for uri in resources))
            self.assertFalse(any(uri.startswith("search://private/") for uri in resources))
            for root_id in ("home", "laptop", "school"):
                base = PACK / root_id
                for path in sorted(p for p in base.rglob("*") if p.is_file()):
                    relative = path.relative_to(base).as_posix()
                    uri = "search://" + root_id + "/" + relative.replace(" ", "%20")
                    data = path.read_bytes()
                    response = client.request("resources/read", {"uri": uri})
                    lines = data.count(b"\n") + (0 if data.endswith(b"\n") or not data else 1)
                    if len(data) <= 256 * 1024 and lines <= 400:
                        self.assertIn(uri, resources, uri)
                        self.assertEqual(resources[uri]["size"], len(data), uri)
                        contents = response["result"]["contents"]
                        # read_span's text: the file's bytes, a leading UTF-8 BOM not part of line 1.
                        self.assertEqual(contents[0]["text"].encode("utf-8"), data.removeprefix(b"\xef\xbb\xbf"), uri)
                        self.assertEqual(contents[0]["mimeType"], "text/markdown" if relative.endswith(".md") else "text/plain")
                    else:
                        self.assertEqual(response["error"]["code"], -32005, uri)
                        self.assertIn("400-line or 262144-byte limit", response["error"]["message"])
            hidden = client.request("resources/read", {"uri": "search://private/plans.md"})["error"]
            absent = client.request("resources/read", {"uri": "search://private/none.md"})["error"]
            self.assertEqual((hidden["code"], hidden["message"]), (absent["code"], absent["message"]))
            self.assertEqual(hidden["code"], -32002)
            for bad in ("file:///etc/passwd", "search://school", "search://school/%G0.md", 7):
                self.assertEqual(client.request("resources/read", {"uri": bad})["error"]["code"], -32602, bad)
            self.assertEqual(client.request("resources/list", {"cursor": "nonsense"})["error"]["code"], -32602)
        finally:
            self.finish(client)
        labelled = self.ready("--labels", "adults")
        try:
            text = labelled.result("resources/read", {"uri": "search://private/plans.md"})["contents"][0]["text"]
            self.assertIn("surprise party", text)
        finally:
            self.finish(labelled)

    def test_resources_list_pages_with_an_opaque_cursor(self) -> None:
        index = self.scratch / "many"
        changes = self.scratch / "many.json"
        request = {"roots": [{"root_id": "notes", "kind": "host"}], "changes": [
            {"op": "add", "root_id": "notes", "path": f"day-{n:03}.md",
             "content_base64": base64.b64encode(f"# Day {n}\n\nWalked to the harbour.\n".encode()).decode()}
            for n in range(1, 151)]}
        changes.write_text(json.dumps(request), encoding="utf-8")
        applied = subprocess.run([str(self.binary), "apply", str(index), "--changes", str(changes)], capture_output=True, text=True, timeout=120)
        self.assertEqual(applied.returncode, 0, applied.stderr)
        client = self.ready(index=index)
        try:
            first = client.result("resources/list")
            self.assertEqual(len(first["resources"]), 100)
            second = client.result("resources/list", {"cursor": first["nextCursor"]})
            self.assertEqual(len(second["resources"]), 50)
            self.assertNotIn("nextCursor", second)
            uris = [r["uri"] for r in first["resources"] + second["resources"]]
            self.assertEqual(uris, [f"search://notes/day-{n:03}.md" for n in range(1, 151)])
        finally:
            self.finish(client)

    # ----------------------------------------------------------- writes ---

    def test_writes_need_allow_write_and_stay_inside_the_roots(self) -> None:
        index = self.scratch / "writable"
        changes = self.scratch / "writable.json"
        changes.write_text(json.dumps({"roots": [{"root_id": "school", "kind": "host"}, {"root_id": "home", "kind": "host"}], "changes": [
            {"op": "add", "root_id": "school", "path": "week.md", "content_base64": base64.b64encode(b"# Week\n\nSpelling list.\n").decode()}]}), encoding="utf-8")
        applied = subprocess.run([str(self.binary), "apply", str(index), "--changes", str(changes)], capture_output=True, text=True, timeout=120)
        self.assertEqual(applied.returncode, 0, applied.stderr)
        add = {"expect_generation": 1, "changes": [{"op": "add", "root_id": "school", "path": "trip.md",
                                                   "content_base64": base64.b64encode(b"# Trip\n\nThe museum of kites.\n").decode()}]}
        reader = self.ready(index=index)
        try:
            self.assertEqual(reader.request("tools/call", {"name": "apply_changes", "arguments": add})["error"]["code"], -32602)
        finally:
            self.finish(reader)
        confined = self.ready("--allow-write", "--roots", "school", index=index)
        try:
            outside = {"changes": [{"op": "add", "root_id": "home", "path": "x.md", "content_base64": "eA=="}]}
            self.assertIn("outside the server's --roots", tool_error(confined.call_tool("apply_changes", outside))["message"])
            filed = {"changes": [{"op": "add", "root_id": "school", "path": "f.md", "file": str(changes)}]}
            self.assertEqual(tool_error(confined.call_tool("apply_changes", filed))["code"], -32602)
            report = structured(confined.call_tool("apply_changes", add))
            self.assertEqual(report["generation"], 2)
            self.assertEqual(validate(report, load_tool_schema("apply_changes", "result")), [])
            hits = structured(confined.call_tool("find", {"query": "kites"}))["hits"]
            self.assertEqual([h["path"] for h in hits], ["trip.md"])
            uris = [r["uri"] for r in confined.result("resources/list")["resources"]]
            self.assertIn("search://school/trip.md", uris)
            stale = tool_error(confined.call_tool("apply_changes", add))
            self.assertEqual(stale["code"], -32602)
        finally:
            self.finish(confined)

    # ---------------------------------------------------------- framing ---

    def test_framing_and_notifications(self) -> None:
        client = self.ready()
        try:
            client.send_line("")
            client.send_line("   ")
            client.notify("notifications/initialized")
            client.notify("notifications/unknown", {"x": 1})
            client.send({"jsonrpc": "2.0", "id": 99, "result": {}})
            self.assertEqual(client.request("ping")["result"], {})
            client.send([{"jsonrpc": "2.0", "id": 1, "method": "ping"}])
            batch = client.read_message()
            self.assertEqual((batch["id"], batch["error"]["code"]), (None, -32600))
            client.send({"jsonrpc": "2.0", "id": None, "method": "ping"})
            self.assertEqual(client.read_message()["error"]["code"], -32600)
            client.send({"jsonrpc": "2.0", "id": 5, "method": "tools/call", "params": [1]})
            self.assertEqual(client.read_message()["error"]["code"], -32602)
            client.send_line("x" * (9 * 1024 * 1024))
            too_long = client.read_message()
            self.assertEqual((too_long["id"], too_long["error"]["code"]), (None, -32700))
            client.send_line(json.dumps({"jsonrpc": "2.0", "id": "crlf", "method": "ping"}) + "\r")
            self.assertEqual(client.read_message(), {"jsonrpc": "2.0", "id": "crlf", "result": {}})
            self.assertFalse(client.pending())
        finally:
            self.finish(client)

    def test_usage_errors_and_a_missing_index(self) -> None:
        for flags, needle in ((("--baseline", "--allow-write"), "read-only"),
                              (("--allow-file-reads",), "needs --allow-write"),
                              (("--http", "127.0.0.1:1"), "unknown flag"),
                              (("--roots", ""), "--roots")):
            run = subprocess.run([str(self.binary), "mcp", str(self.index), *flags], capture_output=True, text=True,
                                 stdin=subprocess.DEVNULL, timeout=60)
            self.assertEqual(run.returncode, 2, flags)
            self.assertEqual(run.stdout, "")
            self.assertIn(needle, run.stderr)
        missing = subprocess.run([str(self.binary), "mcp", str(self.scratch / "nowhere")], capture_output=True, text=True,
                                 stdin=subprocess.DEVNULL, timeout=60)
        self.assertEqual(missing.returncode, 1)
        self.assertEqual(missing.stdout, "")
        self.assertEqual(len(missing.stderr.splitlines()), 1, missing.stderr)


if __name__ == "__main__":
    unittest.main()
