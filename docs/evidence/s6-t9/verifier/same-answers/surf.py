"""S6-T7 verifier: searchd surfaces (CLI, JSON-RPC `serve`, MCP `mcp`, `search FOLDER`) with the
verifier's own requests; answers kept whole with generation numbers, cursors and timing fields normalised.

  surf.py SEARCHD INDEX FOLDER-or-- OUT.jsonl
Files: the 6 smallest, the 6 largest, every kept-whole-looking file (CR, empty, BOM) and 20 sampled
(seeded) from `list-files`; queries: words sampled (seeded) from those files' bytes plus fixed ones.
"""
import json
import random
import re
import subprocess
import sys

searchd, index, folder, out_path = sys.argv[1:5]
qfile = sys.argv[5] if len(sys.argv) > 5 else None  # S6-T8 verifier: the boundary find queries
rng = random.Random(1771)
GEN = re.compile(r'("generation"\s*:\s*)\d+')
CUR = re.compile(r'("(?:next_)?cursor"\s*:\s*")\d+:')
MS = re.compile(r'"(ms|elapsed_ms|took_ms|[a-z_]*_ms|[a-z_]*_us)":\s*[0-9.]+')


def norm(s):
    return MS.sub(r'"\1":T', CUR.sub(r"\1G:", GEN.sub(r"\1G", s)))


def run(argv, stdin=None):
    d = subprocess.run(argv, input=stdin.encode() if stdin is not None else None, capture_output=True, timeout=300)
    return norm(d.stdout.decode("utf-8", "replace")) + "\n--stderr--\n" + norm(d.stderr.decode("utf-8", "replace")) + f"\n--exit {d.returncode}"


listed = json.loads(subprocess.run([searchd, "list-files", index, "--json", "--page-size", "1000"], capture_output=True,
                                   check=True).stdout)
files = listed["files"]
cur = listed.get("next_cursor")
while cur:
    page = json.loads(subprocess.run([searchd, "list-files", index, "--json", "--page-size", "1000", "--cursor", cur],
                                     capture_output=True, check=True).stdout)
    files += page["files"]
    cur = page.get("next_cursor")
by_size = sorted(files, key=lambda f: ((f["size"] or 0), f["root_id"], f["path"]))
pick = by_size[:6] + by_size[-6:] + rng.sample(files, min(20, len(files)))
seen, chosen = set(), []
for f in pick:
    k = (f["root_id"], f["path"])
    if k not in seen:
        seen.add(k)
        chosen.append(f)
roots = sorted({f["root_id"] for f in files})
words = []
for f in chosen[12:]:
    o = run([searchd, "read-span", index, f["root_id"], f["path"], "1", "40", "--json"])
    toks = re.findall(r"[^\W\d_]{4,}", o.split("\n--stderr--")[0])
    toks = [t for t in toks if t not in ("text", "start_line", "end_line", "context", "before", "after", "request", "roots",
                                         "scope", "labels_applied", "warnings", "generation", "byte_exact", "sha256", "true",
                                         "false", "null", "path", "root_id")]
    if toks:
        words.append(rng.choice(toks))
words = words[:10]
queries = words + [" ".join(words[0:2]), " ".join(words[2:5]), "பள்ளி நாளை", "", "?!", chosen[-1]["path"].split("/")[-1].split(".")[0]]
rows = []
for q in queries:
    rows.append(("cli query", q, run([searchd, "query", index, q, "--json", "--top-k", "7"])))
    rows.append(("cli query text", q, run([searchd, "query", index, q, "--top-k", "3"])))
    rows.append(("cli evidence", q, run([searchd, "evidence", index, q, "--top-k", "4"])))
finds = [(w, "words") for w in words[:5]] + [(f'"{words[0]} {words[1]}"', "phrase"), (words[2][:3] + "*", "prefix"),
                                             (words[3], "phrase"), ("பள்ளி", "words")]
if qfile:
    _qs = json.load(open(qfile))["queries"]
    _step = max(1, len(_qs) // 30)
    finds = finds[:5] + [(x["query"], x["mode"]) for x in _qs[::_step]][:30] + finds[5:]
for q, m in finds:
    rows.append(("cli find", f"{m}\t{q}", run([searchd, "find", index, q, "--mode", m, "--page-size", "3", "--json"])))
    rows.append(("cli find text", f"{m}\t{q}", run([searchd, "find", index, q, "--mode", m, "--page-size", "3"])))
for f in chosen:
    r, p = f["root_id"], f["path"]
    rows.append(("cli outline", f"{r}\t{p}", run([searchd, "outline", index, r, p, "--json"])))
    rows.append(("cli outline text", f"{r}\t{p}", run([searchd, "outline", index, r, p])))
    rows.append(("cli read-span", f"{r}\t{p}", run([searchd, "read-span", index, r, p, "1", "400", "--json"])))
    rows.append(("cli read-span ctx", f"{r}\t{p}", run([searchd, "read-span", index, r, p, "3", "5", "--context", "3"])))
    rows.append(("cli read-span last", f"{r}\t{p}", run([searchd, "read-span", index, r, p, "1000000", "1000000"])))
rows.append(("cli list-files", "", run([searchd, "list-files", index, "--json", "--page-size", "17"])))
rows.append(("cli list-files text", "", run([searchd, "list-files", index, "--page-size", "50"])))
rows.append(("cli roots", "", run([searchd, "roots", index, "--json"])))

reqs = [("index_status", {}), ("roots", {}), ("list_files", {"page_size": 9}), ("list_files", {"status": "pending"})]
for field in ("content", "filename", "both"):
    for q in queries:
        for tk in (3, 50):
            reqs.append(("search_knowledge", {"query": q, "retrieval_mode": "lexical", "top_k": tk, "search_field": field}))
    reqs.append(("search_knowledge", {"query": words[0], "retrieval_mode": "lexical", "top_k": 5, "search_field": field,
                                      "roots": roots[:1]}))
for q, m in finds:
    reqs.append(("find", {"query": q, "mode": m, "page_size": 4}))
for f in chosen:
    r, p = f["root_id"], f["path"]
    reqs.append(("outline", {"root_id": r, "path": p}))
    for a, b, c in [(1, 1, 0), (1, 400, 0), (2, 3, 2), (7, 9, 1), (1, 1, 20)] + [(k, k + 2, 0) for k in range(1, 90, 4)]:
        reqs.append(("read_span", {"root_id": r, "path": p, "start_line": a, "end_line": b, "context_lines": c}))
lines = "".join(json.dumps({"jsonrpc": "2.0", "id": i, "method": m, "params": p}) + "\n" for i, (m, p) in enumerate(reqs))
served = run([searchd, "serve", index], lines)
for i, line in enumerate(served.split("\n--stderr--")[0].splitlines()):
    rows.append(("rpc", str(i), line))
rows.append(("rpc tail", "", served.split("\n--stderr--")[1]))

mcp = [("initialize", {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "v", "version": "1"}}),
       ("notifications/initialized", None), ("tools/list", {}), ("resources/list", {})]
for q in queries[:8]:
    mcp.append(("tools/call", {"name": "search_knowledge", "arguments": {"query": q, "retrieval_mode": "lexical", "top_k": 4,
                                                                        "search_field": "both"}}))
for q, m in finds[:20]:
    mcp.append(("tools/call", {"name": "find", "arguments": {"query": q, "mode": m}}))
for name in ("index_status", "list_sources", "list_files"):
    mcp.append(("tools/call", {"name": name, "arguments": {}}))
for f in chosen:
    r, p = f["root_id"], f["path"]
    mcp.append(("tools/call", {"name": "outline", "arguments": {"root_id": r, "path": p}}))
    mcp.append(("tools/call", {"name": "read_span", "arguments": {"root_id": r, "path": p, "start_line": 2, "end_line": 60,
                                                                  "context_lines": 1}}))
    mcp.append(("resources/read", {"uri": f"search://{r}/{p}"}))
msgs = []
for i, (m, p) in enumerate(mcp):
    msg = {"jsonrpc": "2.0", "method": m}
    if p is not None:
        msg["id"] = i
        msg["params"] = p
    msgs.append(json.dumps(msg))
served = run([searchd, "mcp", index], "\n".join(msgs) + "\n")
for i, line in enumerate(served.split("\n--stderr--")[0].splitlines()):
    rows.append(("mcp", str(i), line))
rows.append(("mcp tail", "", served.split("\n--stderr--")[1]))
if folder != "-":
    for field in ("content", "filename", "both"):
        for q in queries[:3] + ["பள்ளி"]:
            rows.append(("search", f"{field}\t{q}", run([searchd, "search", folder, q, "--json", "--top-k", "6", "--search-field", field])))
        rows.append(("search evidence", field, run([searchd, "search", folder, words[0], "--evidence", "--search-field", field])))
with open(out_path, "w", encoding="utf-8") as out:
    for r in rows:
        out.write(json.dumps(r, ensure_ascii=False) + "\n")
errs = sum(1 for r in rows if '"error"' in r[2] or ("--exit 0" not in r[2] and r[0].startswith(("cli", "search"))))
print(out_path.split("/")[-1], "rows", len(rows), "rpc", len(reqs), "mcp", len(mcp), "error-or-nonzero answers", errs)
