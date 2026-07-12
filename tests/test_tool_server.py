import io
import json
import tempfile
import unittest
from pathlib import Path

from src.search_platform.core import build_index
from src.search_platform.tool_server import KnowledgeTools, serve


class KnowledgeToolsTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        root = Path(self.temporary.name)
        (root / "guides").mkdir()
        (root / "notes").mkdir()
        (root / "guides" / "hybrid.md").write_text(
            "Hybrid retrieval combines lexical and semantic results with rank fusion.", encoding="utf-8"
        )
        (root / "notes" / "agent.md").write_text(
            "An agent should cite retrieved evidence and acknowledge missing context.", encoding="utf-8"
        )
        self.tools = KnowledgeTools(build_index(root, vector_mode="none"))

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def request(self, method: str, params: dict, request_id: int = 1) -> dict:
        return self.tools.handle({"jsonrpc": "2.0", "id": request_id, "method": method, "params": params})

    def test_search_and_authoritative_read(self) -> None:
        search_response = self.request(
            "search_knowledge", {"query": "hybrid rank fusion", "path_prefix": "guides/", "top_k": 1}
        )
        result = search_response["result"]["results"][0]
        self.assertEqual(result["citation"]["path"], "guides/hybrid.md")

        read_response = self.request("read_chunk", {"chunk_id": result["chunk_id"]}, request_id=2)
        self.assertEqual(read_response["result"]["content"], result["content"])
        self.assertEqual(read_response["result"]["citation"], result["citation"])

    def test_source_listing_and_status(self) -> None:
        sources = self.request("list_sources", {"path_prefix": "notes/"})["result"]
        self.assertEqual(sources, {"sources": [{"path": "notes/agent.md", "chunks": 1}], "count": 1})

        status = self.request("index_status", {})["result"]
        self.assertTrue(status["ready"])
        self.assertEqual(status["files"], 2)
        self.assertEqual(status["chunks"], 2)

    def test_errors_are_structured_and_do_not_expose_filesystem_reads(self) -> None:
        missing = self.request("read_chunk", {"chunk_id": "missing"})
        self.assertEqual(missing["error"]["code"], -32004)
        self.assertEqual(missing["error"]["data"], {"chunk_id": "missing"})

        unknown = self.request("read_file", {"path": "/etc/passwd"})
        self.assertEqual(unknown["error"]["code"], -32601)

        search_private = self.request("search_knowledge", {"query": "agent evidence", "path_prefix": "notes/"})
        private_chunk = search_private["result"]["results"][0]["chunk_id"]
        scoped_read = self.request("read_chunk", {"chunk_id": private_chunk, "path_prefix": "guides/"})
        self.assertEqual(scoped_read["error"]["code"], -32004)

        invalid = self.request("search_knowledge", {"query": "search", "top_k": 0})
        self.assertEqual(invalid["error"]["code"], -32602)

        invalid_mode = self.request("search_knowledge", {"query": "search", "retrieval_mode": []})
        self.assertEqual(invalid_mode["error"]["code"], -32602)

        invalid_candidates = self.request(
            "search_knowledge", {"query": "search", "top_k": 2, "candidate_k": 1}
        )
        self.assertEqual(invalid_candidates["error"]["code"], -32602)

    def test_json_lines_server_recovers_after_parse_error(self) -> None:
        requests = "not-json\n" + json.dumps(
            {"jsonrpc": "2.0", "id": 9, "method": "index_status", "params": {}}
        ) + "\n"
        output = io.StringIO()
        serve(self.tools, io.StringIO(requests), output)
        responses = [json.loads(line) for line in output.getvalue().splitlines()]
        self.assertEqual(responses[0]["error"]["code"], -32700)
        self.assertEqual(responses[1]["id"], 9)
        self.assertTrue(responses[1]["result"]["ready"])


if __name__ == "__main__":
    unittest.main()
