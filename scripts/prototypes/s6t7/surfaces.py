#!/usr/bin/env python3
"""S6-T7 Phase 2: the same requests through `searchd`'s surfaces, for the
same-answers comparison against `main` (the C ABI is `same_answers.py`).

    python3 -I surfaces.py answers SEARCHD INDEX FOLDER QUERIES.json OUT.jsonl
    python3 -I surfaces.py compare A.jsonl B.jsonl

For one index: the CLI (`query`, `evidence`, `find`, `outline`,
`read-span`, `list-files`, `roots`), JSON-RPC over `serve`'s stdin
(`index_status`, `roots`, `list_files`, `search_knowledge` under the three
fields, `find`, `outline`, `read_span`) and MCP over `mcp`'s stdin
(`initialize`, `tools/list`, every tool, `resources/list`,
`resources/read`), and `searchd search FOLDER` (direct search, no index).
The files read are the first 15 listed and the last; `read_span` asks for
lines 1-400 and every adjacent pair of lines among the first 60. Each
answer is kept whole (stdout, then stderr and the exit code), with the
`ms` timing fields of `search`'s report removed. Not part of any library.
"""

from __future__ import annotations

import collections
import json
import subprocess
import sys
from pathlib import Path

FIELDS = ["content", "filename", "both"]


def run(argv: list[str], stdin: str | None = None) -> str:
    done = subprocess.run(argv, input=stdin, capture_output=True, text=True, timeout=300)
    return f"{done.stdout}\n--stderr--\n{done.stderr}\n--exit {done.returncode}"


def strip_ms(text: str) -> str:
    out = []
    for line in text.splitlines():
        try:
            value = json.loads(line)
        except ValueError:
            out.append(line)
            continue

        def scrub(v):
            if isinstance(v, dict):
                return {k: scrub(x) for k, x in v.items() if k not in ("ms", "elapsed_ms", "took_ms")}
            if isinstance(v, list):
                return [scrub(x) for x in v]
            return v
        out.append(json.dumps(scrub(value), ensure_ascii=False))
    return "\n".join(out)


def cmd_answers(searchd: str, index: str, folder: str, queries_path: str, out_path: str) -> int:
    queries = json.loads(Path(queries_path).read_text(encoding="utf-8"))
    roots = queries.get("roots")
    words = queries["queries"][:12]
    finds = queries["finds"]
    listed = json.loads(subprocess.run([searchd, "list-files", index, "--json", "--page-size", "1000"],
                                       capture_output=True, text=True, check=True).stdout)["files"]
    files = [(f["root_id"], f["path"]) for f in listed[:15]] + [(listed[-1]["root_id"], listed[-1]["path"])]
    rows: list[tuple[str, str, str]] = []
    rf = ["--roots", ",".join(roots)] if roots else []

    # CLI
    for q in words:
        rows.append(("cli query", q, run([searchd, "query", index, q, "--json", "--top-k", "10"])))
        rows.append(("cli evidence", q, run([searchd, "evidence", index, q, "--top-k", "5"])))
    for item in finds:
        rows.append(("cli find", f"{item['mode']}\t{item['query']}",
                     run([searchd, "find", index, item["query"], "--mode", item["mode"], "--page-size", "10", "--json", *rf])))
    for root, path in files:
        rows.append(("cli outline", f"{root}\t{path}", run([searchd, "outline", index, root, path, "--json"])))
        rows.append(("cli read-span", f"{root}\t{path}", run([searchd, "read-span", index, root, path, "1", "400", "--json"])))
        rows.append(("cli read-span text", f"{root}\t{path}", run([searchd, "read-span", index, root, path, "2", "9", "--context", "2"])))
    rows.append(("cli list-files", "", run([searchd, "list-files", index, "--json", "--page-size", "1000"])))
    rows.append(("cli roots", "", run([searchd, "roots", index, "--json"])))

    # JSON-RPC over `serve` (one process, one request per line).
    requests = [("index_status", {}), ("roots", {}), ("list_files", {"page_size": 1000})]
    for field in FIELDS:
        for q in words:
            params = {"query": q, "retrieval_mode": "lexical", "top_k": 10, "search_field": field}
            if roots:
                params["roots"] = roots
            requests.append(("search_knowledge", params))
    for item in finds:
        params = {"query": item["query"], "mode": item["mode"], "page_size": 10}
        if roots:
            params["roots"] = roots
        requests.append(("find", params))
    for root, path in files:
        requests.append(("outline", {"root_id": root, "path": path}))
        requests.append(("read_span", {"root_id": root, "path": path, "start_line": 1, "end_line": 400}))
        for k in range(1, 60):
            requests.append(("read_span", {"root_id": root, "path": path, "start_line": k, "end_line": k + 1, "context_lines": 1}))
    lines = "".join(json.dumps({"jsonrpc": "2.0", "id": i, "method": m, "params": p}) + "\n" for i, (m, p) in enumerate(requests))
    flags = ["--roots", ",".join(roots)] if roots else []
    served = run([searchd, "serve", index, *flags], lines)
    for i, line in enumerate(served.split("\n--stderr--")[0].splitlines()):
        rows.append(("rpc", f"{i} {requests[i][0] if i < len(requests) else '?'}", line))
    rows.append(("rpc tail", "", served.split("\n--stderr--")[1]))

    # MCP over `mcp`.
    mcp = [("initialize", {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "t", "version": "1"}}),
           ("notifications/initialized", None), ("tools/list", {}), ("resources/list", {})]
    for q in words:
        mcp.append(("tools/call", {"name": "search_knowledge", "arguments": {"query": q, "retrieval_mode": "lexical", "top_k": 5}}))
    for item in finds:
        mcp.append(("tools/call", {"name": "find", "arguments": {"query": item["query"], "mode": item["mode"]}}))
    for name in ("index_status", "list_sources", "list_files"):
        mcp.append(("tools/call", {"name": name, "arguments": {}}))
    for root, path in files:
        mcp.append(("tools/call", {"name": "outline", "arguments": {"root_id": root, "path": path}}))
        mcp.append(("tools/call", {"name": "read_span", "arguments": {"root_id": root, "path": path, "start_line": 1, "end_line": 120}}))
        mcp.append(("resources/read", {"uri": f"search://{root}/{path}"}))
    out_lines = []
    for i, (m, p) in enumerate(mcp):
        message = {"jsonrpc": "2.0", "method": m}
        if p is not None:
            message["id"] = i
            message["params"] = p
        out_lines.append(json.dumps(message))
    flags = ["--roots", ",".join(roots)] if roots else []
    served = run([searchd, "mcp", index, *flags], "\n".join(out_lines) + "\n")
    for i, line in enumerate(served.split("\n--stderr--")[0].splitlines()):
        rows.append(("mcp", str(i), line))
    rows.append(("mcp tail", "", served.split("\n--stderr--")[1]))

    # Direct search (no index): the folder, the first three queries, each field.
    if folder != "-":
        for field in FIELDS:
            for q in words[:3]:
                rows.append(("search", f"{field}\t{q}",
                             strip_ms(run([searchd, "search", folder, q, "--json", "--top-k", "10", "--search-field", field]))))

    with open(out_path, "w", encoding="utf-8") as out:
        for kind, key, answer in rows:
            out.write(json.dumps({"kind": kind, "key": key, "answer": answer}, ensure_ascii=False) + "\n")
    print(f"answers: {len(rows)} rows ({len(requests)} RPC requests, {len(mcp)} MCP messages)")
    return 0


def cmd_compare(a_path: str, b_path: str) -> int:
    read = lambda p: [json.loads(line) for line in open(p, encoding="utf-8")]
    a, b = read(a_path), read(b_path)
    counts, differ, failed = collections.Counter(), collections.Counter(), collections.Counter()
    bad = len(a) != len(b)
    for x, y in zip(a, b):
        counts[x["kind"]] += 1
        if (x["kind"], x["key"]) != (y["kind"], y["key"]) or x["answer"] != y["answer"]:
            differ[x["kind"]] += 1
            if differ[x["kind"]] <= 3:
                print(f"DIFFERS {x['kind']} {x['key']!r}", file=sys.stderr)
            bad = True
        elif "--exit 0" not in x["answer"] and x["kind"].startswith(("cli", "search")) or '"error"' in x["answer"]:
            failed[x["kind"]] += 1
    summary = ", ".join(f"{k} {counts[k]} (differ {differ[k]}, error answers {failed[k]})" for k in sorted(counts))
    print(f"{'DIFFER' if bad else 'same'}: {len(a)} vs {len(b)} rows: {summary}")
    return 1 if bad else 0


def main(argv: list[str]) -> int:
    if len(argv) == 7 and argv[1] == "answers":
        return cmd_answers(*argv[2:7])
    if len(argv) == 4 and argv[1] == "compare":
        return cmd_compare(argv[2], argv[3])
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
