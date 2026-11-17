#!/usr/bin/env python3
"""S6-T5 verifier, check 2: every surface's answers from one build (searchd + library).

    surf.py SEARCHD LIB SPEC.json OUT.jsonl

SPEC: {"indexes": [{"name", "dir", "queries": [...], "roots": [...] | null}],
       "folders": [{"name", "dir", "queries": [...]}]}
Surfaces per index, query and field (content, both, filename): CLI `query --json`, `evidence`,
JSON-RPC `serve` search_knowledge, MCP `tools/call` search_knowledge, `ss_query`; per folder:
CLI `search --json` and `search --evidence`. Every line: surface, case, the exact output.
One library per process.
"""
import json
import subprocess
import sys

sys.path.insert(0, __import__("os").path.dirname(__file__))
import ssdrv  # noqa: E402

FIELDS = ["content", "both", "filename"]


class Rpc:
    def __init__(self, argv):
        self.p = subprocess.Popen(argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                  text=True, encoding="utf-8")
        self.n = 0

    def call(self, method, params, notify=False):
        msg = {"jsonrpc": "2.0", "method": method, "params": params}
        if not notify:
            self.n += 1
            msg["id"] = self.n
        self.p.stdin.write(json.dumps(msg, ensure_ascii=False) + "\n")
        self.p.stdin.flush()
        if notify:
            return None
        return self.p.stdout.readline()

    def close(self):
        self.p.stdin.close()
        self.p.wait(timeout=60)


def main():
    searchd, lib_path, spec_path, out_path = sys.argv[1:5]
    spec = json.load(open(spec_path))
    lib = ssdrv.Lib(lib_path)
    out = open(out_path, "w", encoding="utf-8")

    def emit(surface, case, text):
        out.write(json.dumps({"surface": surface, "case": case, "out": text}, ensure_ascii=False) + "\n")

    for ix in spec["indexes"]:
        d, roots = ix["dir"], ix.get("roots")
        serve = Rpc([searchd, "serve", d])
        mcp = Rpc([searchd, "mcp", d])
        emit("mcp-initialize", ix["name"], mcp.call("initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                                                                  "clientInfo": {"name": "v", "version": "1"}}))
        mcp.call("notifications/initialized", {}, notify=True)
        h = lib.open(d)
        for q in ix["queries"]:
            for field in FIELDS:
                case = f"{ix['name']}\t{field}\t{q}"
                argv_field = ["--search-field", field]
                r = subprocess.run([searchd, "query", d, q, "--json"] + argv_field, capture_output=True, text=True)
                emit("cli-query-json", case, f"{r.returncode}\n{r.stdout}\n{r.stderr}")
                r = subprocess.run([searchd, "evidence", d, q] + argv_field, capture_output=True, text=True)
                emit("cli-evidence", case, f"{r.returncode}\n{r.stdout}\n{r.stderr}")
                params = {"query": q, "top_k": 10, "retrieval_mode": "lexical", "search_field": field}
                if roots:
                    params["roots"] = roots
                emit("jsonrpc", case, serve.call("search_knowledge", params))
                args = {"query": q, "top_k": 10, "retrieval_mode": "lexical", "search_field": field}
                emit("mcp", case, mcp.call("tools/call", {"name": "search_knowledge", "arguments": args}))
                extra = {"roots": roots} if roots else {}
                ans, err = lib.query(h, q, field, extra, top_k=10)
                emit("ss_query", case, ans.decode() if ans else "ERR " + err)
        lib.close(h)
        serve.close()
        mcp.close()
    for fo in spec.get("folders", []):
        for q in fo["queries"]:
            for field in FIELDS:
                case = f"{fo['name']}\t{field}\t{q}"
                for flag in ("--json", "--evidence"):
                    r = subprocess.run([searchd, "search", fo["dir"], q, flag, "--search-field", field],
                                       capture_output=True, text=True)
                    emit("cli-search" + flag, case, f"{r.returncode}\n{r.stdout}\n{r.stderr}")
    out.close()


if __name__ == "__main__":
    main()
