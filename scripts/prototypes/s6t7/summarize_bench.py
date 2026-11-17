#!/usr/bin/env python3
"""S6-T7 Phase 2: medians over rounds of bench.py's rows, main against head.

    python3 -I summarize_bench.py BENCH.jsonl [...]

Per corpus and measure: the median over runs of main and of head, and head
against main in per cent. Not part of any library.
"""
import json
import statistics
import sys

MEASURES = [
    ("open p50 ms", lambda r: r["open"]["p50_ms"]),
    ("memory after open B", lambda r: r["memory"]["open_delta"]),
    ("memory after first read_span B", lambda r: r["memory"]["read_delta"]),
    ("first read_span p50 ms", lambda r: r["first_read_span"]["p50_ms"]),
    ("first outline after it p50 ms", lambda r: r["first_outline_after"]["p50_ms"]),
]
for kind in ("read_span head", "read_span middle", "read_span tail", "outline",
             "median read_span", "median outline", "smallest read_span", "smallest outline"):
    MEASURES.append((f"later {kind} p50 ms", lambda r, k=kind: r["later"].get(k, {}).get("p50_ms")))
    MEASURES.append((f"later {kind} CPU ms/call", lambda r, k=kind: r["later"].get(k, {}).get("cpu_ms_per_call")))

for path in sys.argv[1:]:
    rows = [json.loads(line) for line in open(path, encoding="utf-8")]
    corpus = rows[0]["index"]
    f = rows[-1]["file"]
    loads = [r["load_before"][1] for r in rows] + [r["load_after"][1] for r in rows]
    sm, md = rows[-1].get("file_smallest"), rows[-1].get("file_median")
    print(f"## {corpus}: largest file {f['root_id']}/{f['path']} ({f['bytes']} B, {f['lines']} lines); "
          f"{sum(r['variant'] == 'main' for r in rows)} main and {sum(r['variant'] == 'head' for r in rows)} head runs; "
          f"5-minute load {min(loads):.2f}-{max(loads):.2f}")
    if sm:
        print(f"   median file {md['path']} ({md['bytes']} B, {md['lines']} lines); smallest {sm['path']} ({sm['bytes']} B, {sm['lines']} lines)")
    for name, get in MEASURES:
        ms = [get(r) for r in rows if r["variant"] == "main"]
        hs = [get(r) for r in rows if r["variant"] == "head"]
        if None in ms or None in hs:
            continue
        m, h = statistics.median(ms), statistics.median(hs)
        fmt = (lambda v: f"{v:,.0f}") if name.endswith(" B") else (lambda v: f"{v:.4f}")
        print(f"  {name:36s} main {fmt(m):>12s}  head {fmt(h):>12s}  {(h - m) / m * 100:+7.2f} %")
