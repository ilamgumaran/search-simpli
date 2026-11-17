"""S6-T5 second verification probe: per cell, five-round medians of (nhead - nmain), (ntroff - nmain), (nhead - ntroff), µs."""
import json, statistics, sys
from collections import defaultdict
def cells(row):
    out = {}
    for w in row["warm"]:
        out[f"{w['field']} {w['query']}"] = w["p50_ms"]
    return out
for path in sys.argv[1:]:
    runs = defaultdict(dict)
    for line in open(path):
        r = json.loads(line); runs[r["round"]][r["variant"]] = cells(r)
    print(f"== {path.split('/')[-1]}")
    print("cell | main µs | head-main | troff-main | head-troff")
    keys = list(runs[1]["nmain"])
    for k in keys:
        if not k.startswith(("both", "filename", "content")):
            continue
        m = statistics.median(runs[r]["nmain"][k] for r in runs) * 1000
        if m < 50:
            continue
        hm = statistics.median((runs[r]["nhead"][k] - runs[r]["nmain"][k]) * 1000 for r in runs)
        tm = statistics.median((runs[r]["ntroff"][k] - runs[r]["nmain"][k]) * 1000 for r in runs)
        ht = statistics.median((runs[r]["nhead"][k] - runs[r]["ntroff"][k]) * 1000 for r in runs)
        print(f"{k} | {m:.1f} | {hm:+.2f} | {tm:+.2f} | {ht:+.2f}")
