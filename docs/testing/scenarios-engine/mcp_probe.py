#!/usr/bin/env python3
"""Call `searchd mcp <index>` as an LLM host would, and print what came back.

Usage: python3 -I mcp_probe.py <searchd> <index-dir>
Sends one session of newline-delimited JSON-RPC over stdin and prints one
JSON line per response: {"id", "summary"}. The session: initialize,
initialized, tools/list, then the read tools with arguments an LLM would
write, resources, a refused call and an unknown tool.
"""
import json
import subprocess
import sys
import urllib.parse


def main():
    searchd, index_dir = sys.argv[1], sys.argv[2]
    uri_space = "search://r-legacy/" + urllib.parse.quote("notes/plumber visit.txt")
    uri_tamil = "search://r-legacy/" + urllib.parse.quote("tamil/கவிதை.txt")
    requests = [
        {"jsonrpc": "2.0", "id": 1, "method": "initialize",
         "params": {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "probe", "version": "0"}}},
        {"jsonrpc": "2.0", "method": "notifications/initialized"},
        {"jsonrpc": "2.0", "id": 2, "method": "tools/list"},
        {"jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": {"name": "search_knowledge", "arguments": {"query": "when is the water heater anode rod due"}}},
        {"jsonrpc": "2.0", "id": 4, "method": "tools/call", "params": {"name": "find", "arguments": {"query": "\"compost bin\""}}},
        {"jsonrpc": "2.0", "id": 5, "method": "tools/call", "params": {"name": "read_span", "arguments": {"root_id": "r-legacy", "path": "notes/plumber visit.txt", "start_line": 4, "end_line": 4}}},
        {"jsonrpc": "2.0", "id": 6, "method": "tools/call", "params": {"name": "list_files", "arguments": {"page_size": 3}}},
        {"jsonrpc": "2.0", "id": 7, "method": "tools/call", "params": {"name": "outline", "arguments": {"root_id": "r-legacy", "path": "notes/garden-plan.md"}}},
        {"jsonrpc": "2.0", "id": 8, "method": "tools/call", "params": {"name": "index_status", "arguments": {}}},
        {"jsonrpc": "2.0", "id": 9, "method": "resources/list"},
        {"jsonrpc": "2.0", "id": 10, "method": "resources/read", "params": {"uri": uri_space}},
        {"jsonrpc": "2.0", "id": 11, "method": "resources/read", "params": {"uri": uri_tamil}},
        {"jsonrpc": "2.0", "id": 12, "method": "tools/call", "params": {"name": "search_knowledge", "arguments": {"query": "faucet", "principal_labels": ["x"]}}},
        {"jsonrpc": "2.0", "id": 13, "method": "tools/call", "params": {"name": "apply_changes", "arguments": {}}},
        {"jsonrpc": "2.0", "id": 14, "method": "tools/call", "params": {"name": "search_knowledge", "arguments": {"query": "zzqqxx nothing like this"}}},
        {"jsonrpc": "2.0", "id": 15, "method": "tools/call", "params": {"name": "search_knowledge", "arguments": {"query": "plumber", "search_field": "both", "retrieval_mode": "lexical", "top_k": 1}}},
        {"jsonrpc": "2.0", "id": 16, "method": "tools/call", "params": {"name": "read_span", "arguments": {"root_id": "r-legacy", "path": "long/diary.md", "start_line": 1, "end_line": 500}}},
        {"jsonrpc": "2.0", "id": 17, "method": "resources/read", "params": {"uri": "search://r-legacy/long/diary.md"}},
    ]
    payload = "".join(json.dumps(r, ensure_ascii=False) + "\n" for r in requests)
    proc = subprocess.run([searchd, "mcp", index_dir], input=payload.encode("utf-8"), capture_output=True, timeout=30)
    print(json.dumps({"exit": proc.returncode, "stderr": proc.stderr.decode("utf-8", "replace")[:200]}))
    for line in proc.stdout.decode("utf-8").splitlines():
        message = json.loads(line)
        if "error" in message:
            summary = {"error": message["error"]}
        else:
            result = message["result"]
            if "tools" in result:
                summary = {"tools": [t["name"] for t in result["tools"]]}
            elif "protocolVersion" in result:
                summary = {"protocolVersion": result["protocolVersion"], "serverInfo": result.get("serverInfo")}
            elif "content" in result:
                text = result["content"][0].get("text", "")
                summary = {"isError": result.get("isError"), "text": text[:300]}
                structured = result.get("structuredContent") or {}
                if "results" in structured:
                    summary["top"] = [r["citation"]["path"] for r in structured["results"][:3]]
            elif "resources" in result:
                summary = {"resources": len(result["resources"]), "first": result["resources"][0] if result["resources"] else None, "nextCursor": result.get("nextCursor") is not None}
            elif "contents" in result:
                summary = {"contents": result["contents"][0].get("text", "")[:120]}
            else:
                summary = result
        print(json.dumps({"id": message.get("id"), "summary": summary}, ensure_ascii=False))


if __name__ == "__main__":
    main()
