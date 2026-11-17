"""S6-T4 second rework: summarise placement.sh's runs.

    python3 -I placement_cells.py RUNS.jsonl [RUNS.jsonl ...]

For every corpus: each variant's median over the rounds minus `main`'s, in
microseconds, on the cells the second Verdict failed (and on every warm cell).
"""
import json
import statistics as st
import sys

FAILED = {
    "tamil-10k": [("q", "content", "hashing"), ("q", "content", "hybrid retrieval"), ("q", "content", "retrieval hybrid"),
                  ("q", "content", "systems system"), ("q", "both", "hashing"), ("q", "both", "hybrid retrieval"),
                  ("q", "both", "retrieval hybrid"), ("q", "content", "system"), ("q", "content", "system systems"),
                  ("q", "both", "systems system"), ("q", "content", "bazecha"), ("q", "content", "benico"),
                  ("f", "words", "றூகுஞங்கள்"), ("f", "words", "கீகசை"), ("f", "prefix", "டூகன*")],
    "prose-10k": [("q", "content", "system"), ("q", "content", "retrieval hybrid"),
                  ("f", "words", "across lengthy seeming 04276"), ("q", "filename", "have")],
    "timing-10k": [("f", "words", "badamo")],
}
NAMES = ["head", "headctl1", "headctl2", "head-v3", "headctl1-v3"]


def cells(row):
    out = {("q", c["field"], c["query"]): c["p50_ms"] for c in row["warm"]}
    out.update({("f", c["mode"], c["query"]): c["p50_ms"] for c in row["find"]})
    return out


def main(paths):
    by_corpus = {}
    for path in paths:
        for line in open(path, encoding="utf-8"):
            row = json.loads(line)
            corpus = row["index"].rstrip("/").rsplit("/", 1)[-1]
            by_corpus.setdefault(corpus, {}).setdefault(row["variant"], []).append(cells(row))
    for corpus, variants in by_corpus.items():
        rounds = len(variants["main"])
        print(f"== {corpus}: {rounds} rounds; variant median - main median, us")
        print("cell".ljust(42) + "".join(n.rjust(12) for n in NAMES) + "   main, us")

        def med(name, key):
            return st.median(x[key] for x in variants[name])
        for key in FAILED.get(corpus, []):
            if key not in variants["main"][0]:
                print(f"{key} not in this query set")
                continue
            m = med("main", key)
            print(f"{key[1] + ' ' + key[2]:42}" + "".join(f"{(med(n, key) - m) * 1000:+12.2f}" for n in NAMES) + f"   {m * 1000:.2f}")
        warm = [k for k in variants["main"][0] if k[0] == "q"]
        for n in NAMES:
            d = [med(n, k) - med("main", k) for k in warm]
            print(f"{n}: all {len(d)} warm cells, median {st.median(d) * 1000:+.3f} us; slower by more than 0.1 us: {sum(1 for x in d if x > 0.0001)}")


if __name__ == "__main__":
    main(sys.argv[1:])
