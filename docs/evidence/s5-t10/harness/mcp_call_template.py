#!/usr/bin/env python3
"""The answering agent's only way to the folder (S5-T10 ruling 3).

A command-line MCP client, standard library only. Each call starts the MCP
server with the command line fixed below (read-only default mode; the scope
comes from that command line), performs the initialize handshake, sends one
request (`tools/list` or one `tools/call`), prints what an MCP host would hand
a model (the tool descriptions, or the tool result's text block), and appends
the whole exchange to a transcript the client writes itself: one JSON object
per invocation, each carrying the SHA-256 of the previous entry, so an edit or
a removed line breaks the chain. The hash is taken over the entry with this
machine's folder prefixes replaced by placeholders (`SCRUB`), so the copy
committed with those prefixes scrubbed verifies with the same function.

    python3 mcp_call.py <label> tools
    python3 mcp_call.py <label> call <tool> '<json arguments>'

<label> is the question the call is for (Q1 to Q6).

`snapshot.py agent-dir` writes a configured copy of this file; the constants
below are filled in there and nowhere else.
"""

from __future__ import annotations

import datetime
import fcntl
import hashlib
import json
import re
import subprocess
import sys

SERVER_ARGV = __SERVER_ARGV__
TRANSCRIPT = __TRANSCRIPT__
BATCH = __BATCH__
SCRUB = __SCRUB__
PROTOCOL_VERSION = "2025-11-25"
TIMEOUT_S = 60


def scrubbed(text: str) -> str:
    for prefix, placeholder in SCRUB:
        text = text.replace(prefix, placeholder)
    return text


def entry_hash(entry: dict) -> str:
    """Over the entry with the machine's folder prefixes replaced by placeholders,
    so the committed (scrubbed) transcript verifies with the same function."""
    body = {k: v for k, v in entry.items() if k != "sha256"}
    text = scrubbed(json.dumps(body, sort_keys=True, ensure_ascii=False))
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def exchange(request: dict) -> tuple:
    messages = [
        {"jsonrpc": "2.0", "id": 1, "method": "initialize",
         "params": {"protocolVersion": PROTOCOL_VERSION, "capabilities": {},
                    "clientInfo": {"name": "s5-t10-cli-client", "version": "1"}}},
        {"jsonrpc": "2.0", "method": "notifications/initialized"},
        dict(request, jsonrpc="2.0", id=2),
    ]
    payload = "".join(json.dumps(m, ensure_ascii=False) + "\n" for m in messages)
    done = subprocess.run(SERVER_ARGV, input=payload.encode("utf-8"), capture_output=True, timeout=TIMEOUT_S)
    replies = [json.loads(line) for line in done.stdout.decode("utf-8").splitlines() if line.strip()]
    return messages, replies, done.stderr.decode("utf-8", "replace"), done.returncode


def record(label: str, command: list, messages: list, replies: list, stderr: str, status: int) -> None:
    with open(TRANSCRIPT, "a+", encoding="utf-8") as handle:
        fcntl.flock(handle, fcntl.LOCK_EX)
        handle.seek(0)
        lines = [line for line in handle.read().splitlines() if line.strip()]
        prev = json.loads(lines[-1])["sha256"] if lines else None
        entry = {"seq": len(lines) + 1, "batch": BATCH, "label": label,
                 "time": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="milliseconds"),
                 "command": command, "server_argv": SERVER_ARGV, "sent": messages, "received": replies,
                 "stderr": stderr, "exit_status": status, "prev_sha256": prev}
        entry["sha256"] = entry_hash(entry)
        handle.seek(0, 2)
        handle.write(json.dumps(entry, ensure_ascii=False) + "\n")


def answer_of(replies: list) -> dict:
    for reply in replies:
        if reply.get("id") == 2:
            return reply
    return {}


def main(argv: list) -> int:
    if len(argv) < 2 or not re.fullmatch(r"Q[1-9]", argv[0]) or argv[1] not in ("tools", "call"):
        print("usage: mcp_call.py <Q1..Q6> tools | mcp_call.py <Q1..Q6> call <tool> '<json arguments>'")
        return 2
    label = argv[0]
    if argv[1] == "tools":
        if len(argv) != 2:
            print("usage: mcp_call.py <label> tools")
            return 2
        messages, replies, stderr, status = exchange({"method": "tools/list", "params": {}})
        record(label, argv[1:], messages, replies, stderr, status)
        init = next((r for r in replies if r.get("id") == 1), {}).get("result", {})
        reply = answer_of(replies)
        if "result" not in reply:
            print(json.dumps(reply.get("error", {"message": "no answer", "stderr": stderr}), ensure_ascii=False))
            return 1
        info = init.get("serverInfo", {})
        print(f"Server: {info.get('name')} {info.get('version')} (MCP {init.get('protocolVersion')})")
        if init.get("instructions"):
            print("Server instructions:")
            print(init["instructions"])
        for tool in reply["result"]["tools"]:
            print()
            print(f"## {tool['name']}")
            if tool.get("description"):
                print(tool["description"])
            print("inputSchema: " + json.dumps(tool.get("inputSchema", {}), ensure_ascii=False))
        return 0
    if len(argv) not in (3, 4):
        print("usage: mcp_call.py <label> call <tool> '<json arguments>'")
        return 2
    try:
        arguments = json.loads(argv[3]) if len(argv) == 4 else {}
    except json.JSONDecodeError as error:
        print(f"the arguments are not JSON: {error}")
        return 2
    messages, replies, stderr, status = exchange(
        {"method": "tools/call", "params": {"name": argv[2], "arguments": arguments}})
    record(label, argv[1:], messages, replies, stderr, status)
    reply = answer_of(replies)
    if "error" in reply:
        print("MCP error: " + json.dumps(reply["error"], ensure_ascii=False))
        return 1
    result = reply.get("result")
    if result is None:
        print("no answer from the server: " + stderr[:500])
        return 1
    texts = [block.get("text", "") for block in result.get("content", []) if block.get("type") == "text"]
    if result.get("isError"):
        print("Tool error: " + "\n".join(texts))
        return 1
    print("\n".join(texts))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
