"""A minimal Model Context Protocol client over stdio, standard library only
(S3-T6 ruling 2; CAP-19 NFR-14).

It launches an MCP server as a child process, writes one JSON-RPC message
per line to its stdin and reads one per line from its stdout, as MCP's stdio
transport specifies. Every line the server writes must be one complete JSON
object (the server may write nothing else to stdout); `McpClient` records a
violation in `protocol_errors` instead of guessing.

`run_conformance(argv)` runs the conformance sequence against a server
started with `argv` (the read-only default mode) and returns one `Check` per
step: the initialize handshake with the pinned revision, `ping`, a
cancellation of a request that is no longer in flight (nothing to honour;
the next `ping` is still answered), `tools/list`, `tools/call` for every
listed tool, `resources/templates/list`, `resources/list` (every page) and
`resources/read`, a malformed line, an unknown method, and an
`apply_changes` call that the server must refuse because it was not started
with `--allow-write`. The arguments it sends are taken from the server's
own answers (a file from `list_files`, a chunk id from `find`), so it runs
against any index with at least one Markdown file.

Usage (prints one line per check, exit 1 on any failure):

    python3 tests/mcp_client.py <searchd> <index-dir> [extra mcp flags...]
"""

from __future__ import annotations

import json
import queue
import re
import subprocess
import sys
import threading
from dataclasses import dataclass
from typing import Any

PROTOCOL_VERSION = "2025-11-25"
READ_TOOLS = ("search_knowledge", "read_chunk", "list_sources", "index_status",
              "find", "outline", "read_span", "list_files")
BASELINE_TOOLS = READ_TOOLS[:4]


class McpError(RuntimeError):
    pass


class McpClient:
    """One server process; requests are answered in order (the server reads
    one line, answers it, then reads the next)."""

    def __init__(self, argv: list[str], timeout: float = 60.0) -> None:
        self.argv = list(argv)
        self.timeout = timeout
        self.process = subprocess.Popen(
            self.argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            text=True, encoding="utf-8", bufsize=1,
        )
        self.lines: queue.Queue[str | None] = queue.Queue()
        self.protocol_errors: list[str] = []
        self.next_id = 0
        self._reader = threading.Thread(target=self._read, daemon=True)
        self._reader.start()

    def _read(self) -> None:
        assert self.process.stdout is not None
        for line in self.process.stdout:
            self.lines.put(line)
        self.lines.put(None)

    # -------------------------------------------------------------- wire ---

    def send_line(self, line: str) -> None:
        assert self.process.stdin is not None
        self.process.stdin.write(line + "\n")
        self.process.stdin.flush()

    def send(self, message: Any) -> None:
        self.send_line(json.dumps(message, ensure_ascii=False, separators=(",", ":")))

    def read_message(self) -> dict:
        try:
            line = self.lines.get(timeout=self.timeout)
        except queue.Empty as error:
            raise McpError(f"no message from the server within {self.timeout} s") from error
        if line is None:
            raise McpError("the server closed stdout")
        if not line.endswith("\n"):
            self.protocol_errors.append("a message without its newline")
        try:
            message = json.loads(line)
        except json.JSONDecodeError:
            self.protocol_errors.append(f"not JSON on stdout: {line[:200]!r}")
            raise McpError(f"not JSON on stdout: {line[:200]!r}") from None
        if not isinstance(message, dict) or message.get("jsonrpc") != "2.0":
            self.protocol_errors.append(f"not a JSON-RPC 2.0 message: {line[:200]!r}")
        return message

    def pending(self) -> bool:
        """Whether the server wrote something not yet read."""
        return not self.lines.empty()

    # ---------------------------------------------------------- messages ---

    def request(self, method: str, params: dict | None = None) -> dict:
        """The whole response (`result` or `error`) to one request."""
        self.next_id += 1
        message: dict = {"jsonrpc": "2.0", "id": self.next_id, "method": method}
        if params is not None:
            message["params"] = params
        self.send(message)
        response = self.read_message()
        if response.get("id") != self.next_id:
            raise McpError(f"response id {response.get('id')!r} for request {self.next_id}")
        return response

    def result(self, method: str, params: dict | None = None) -> dict:
        response = self.request(method, params)
        if "result" not in response:
            raise McpError(f"{method}: {response.get('error')}")
        return response["result"]

    def notify(self, method: str, params: dict | None = None) -> None:
        message: dict = {"jsonrpc": "2.0", "method": method}
        if params is not None:
            message["params"] = params
        self.send(message)

    def initialize(self, version: str = PROTOCOL_VERSION) -> dict:
        result = self.result("initialize", {
            "protocolVersion": version,
            "capabilities": {},
            "clientInfo": {"name": "search-simpli-conformance", "version": "1"},
        })
        self.notify("notifications/initialized")
        return result

    def call_tool(self, name: str, arguments: dict | None = None) -> dict:
        params: dict = {"name": name}
        if arguments is not None:
            params["arguments"] = arguments
        return self.result("tools/call", params)

    def list_tools(self) -> list[dict]:
        return self.result("tools/list")["tools"]

    def close(self) -> int:
        """Close stdin (the end of the session) and wait for the exit status."""
        if self.process.stdin and not self.process.stdin.closed:
            self.process.stdin.close()
        status = self.process.wait(timeout=self.timeout)
        self._reader.join(timeout=self.timeout)
        rest = []
        while not self.lines.empty():
            line = self.lines.get()
            if line is not None:
                rest.append(line)
        if rest:
            self.protocol_errors.append(f"unread output after the session: {rest[0][:200]!r}")
        if self.process.stdout:
            self.process.stdout.close()
        if self.process.stderr:
            self.stderr = self.process.stderr.read()
            self.process.stderr.close()
        return status

    def __enter__(self) -> "McpClient":
        return self

    def __exit__(self, *_: Any) -> None:
        if self.process.poll() is None:
            self.close()


def structured(result: dict) -> Any:
    """The canonical JSON of a successful `tools/call` result, checked to be
    the same value in `structuredContent` and in the one text block."""
    if result.get("isError"):
        raise McpError(f"tool error: {result['content'][0]['text']}")
    content = result["content"]
    if len(content) != 1 or content[0]["type"] != "text":
        raise McpError("expected exactly one text content block")
    if json.loads(content[0]["text"]) != result["structuredContent"]:
        raise McpError("structuredContent and the text block differ")
    return result["structuredContent"]


def tool_error(result: dict) -> dict:
    """The `{code, message}` object of a refused `tools/call`."""
    if result.get("isError") is not True:
        raise McpError(f"expected isError: {json.dumps(result)[:300]}")
    return json.loads(result["content"][0]["text"])


@dataclass
class Check:
    name: str
    ok: bool
    detail: str = ""


def run_conformance(argv: list[str]) -> list[Check]:
    """The conformance sequence against a default-mode (read-only) server."""
    checks: list[Check] = []

    def check(name: str, ok: bool, detail: Any = "") -> None:
        checks.append(Check(name, bool(ok), str(detail)[:300]))

    with McpClient(argv) as client:
        early = client.request("tools/list")
        check("a request before initialize is refused", early.get("error", {}).get("code") == -32600, early)
        init = client.initialize()
        check("initialize answers the pinned protocol revision", init.get("protocolVersion") == PROTOCOL_VERSION, init.get("protocolVersion"))
        check("initialize names the server and its tools/resources capabilities",
              init.get("serverInfo", {}).get("name") == "search-simpli"
              and "tools" in init.get("capabilities", {}) and "resources" in init.get("capabilities", {}), init)
        check("ping answers an empty result", client.request("ping").get("result") == {})
        client.notify("notifications/cancelled", {"requestId": 2, "reason": "conformance: nothing in flight"})
        check("a cancellation of nothing in flight is ignored; ping is still answered",
              client.request("ping").get("result") == {})

        tools = client.list_tools()
        names = [tool["name"] for tool in tools]
        check("tools/list lists the eight read tools, no write", tuple(names) == READ_TOOLS, names)
        check("every tool has an object inputSchema and outputSchema",
              all(t["inputSchema"].get("type") == "object" and t["outputSchema"].get("type") == "object" for t in tools))

        called: dict[str, Any] = {}

        def call(name: str, arguments: dict) -> Any:
            try:
                value = structured(client.call_tool(name, arguments))
                check(f"tools/call {name}", True)
                called[name] = value
                return value
            except McpError as error:
                check(f"tools/call {name}", False, error)
                return None

        status = call("index_status", {})
        listing = call("list_files", {"status": "indexed", "page_size": 1000})
        markdown = next((f for f in (listing or {}).get("files", []) if f["path"].endswith(".md")), None)
        call("list_sources", {})
        tokens: list[str] = []
        if markdown:
            call("outline", {"root_id": markdown["root_id"], "path": markdown["path"]})
            span = call("read_span", {"root_id": markdown["root_id"], "path": markdown["path"], "start_line": 1, "end_line": 20})
            tokens = [w.lower() for w in re.findall(r"[A-Za-z]{4,}", (span or {}).get("text", ""))]
        # The first word of the file that `find` finds (front matter is not indexed).
        word = tokens[0] if tokens else "the"
        for candidate in tokens[:20]:
            probe = structured(client.call_tool("find", {"query": candidate, "page_size": 1}))
            if probe["hits"]:
                word = candidate
                break
        found = call("find", {"query": word})
        call("search_knowledge", {"query": word})
        if found and found["hits"]:
            call("read_chunk", {"chunk_id": found["hits"][0]["chunk_id"]})
        else:
            check("tools/call read_chunk", False, f"no find hit for {word!r} to read")
        check("every listed tool was called", sorted(called) == sorted(READ_TOOLS), sorted(set(READ_TOOLS) - set(called)))

        templates = client.result("resources/templates/list")["resourceTemplates"]
        check("resources/templates/list names search://{root_id}/{path}",
              [t["uriTemplate"] for t in templates] == ["search://{root_id}/{path}"], templates)
        resources: list[dict] = []
        cursor = None
        while True:
            page = client.result("resources/list", {"cursor": cursor} if cursor else {})
            resources.extend(page["resources"])
            cursor = page.get("nextCursor")
            if not cursor:
                break
        check("resources/list lists indexed files", len(resources) > 0, len(resources))
        small = next((r for r in resources if r.get("size", 0) < 4096 and r["mimeType"] == "text/markdown"), None)
        if small:
            read = client.result("resources/read", {"uri": small["uri"]})
            contents = read["contents"]
            check("resources/read returns the whole file", len(contents) == 1 and contents[0]["uri"] == small["uri"]
                  and len(contents[0]["text"].encode("utf-8")) == small["size"], small)
        else:
            check("resources/read returns the whole file", False, "no small Markdown resource")
        missing = client.request("resources/read", {"uri": "search://no-such-root/none.md"})
        check("resources/read of an absent file is -32002", missing.get("error", {}).get("code") == -32002, missing)

        client.send_line("{this is not json")
        malformed = client.read_message()
        check("a malformed line is -32700 and the server keeps reading",
              malformed.get("error", {}).get("code") == -32700 and malformed.get("id") is None, malformed)
        unknown = client.request("prompts/list")
        check("an unknown method is -32601", unknown.get("error", {}).get("code") == -32601, unknown)
        write = client.request("tools/call", {"name": "apply_changes", "arguments": {"changes": []}})
        check("apply_changes without --allow-write is refused", write.get("error", {}).get("code") == -32602
              and "apply_changes" in write["error"]["message"], write)
        check("ping after everything", client.request("ping").get("result") == {})
        check("nothing unrequested on stdout", not client.pending())
        status_code = client.close()
        check("the server exits 0 when stdin closes", status_code == 0, status_code)
        check("stdout carried only protocol messages", not client.protocol_errors, client.protocol_errors)
    return checks


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        print(__doc__.split("Usage")[1].strip(), file=sys.stderr)
        return 2
    binary, index, *flags = argv
    checks = run_conformance([binary, "mcp", index, *flags])
    for item in checks:
        print(f"{'ok  ' if item.ok else 'FAIL'} {item.name}" + (f" ({item.detail})" if not item.ok and item.detail else ""))
    failed = [c for c in checks if not c.ok]
    print(f"{len(checks) - len(failed)}/{len(checks)} checks passed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
