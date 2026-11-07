#!/usr/bin/env python3
"""S5-T3 prototype (planner scratch): the term dictionary of a corpus and the work
a bounded scan per df-0 query term would do. Counts only, no timing.

    python3 <this dir>/dict_stats.py CORPUS_DIR [--probes N] [--seed S]

CORPUS_DIR is e.g. the 10k timing corpus (`scripts/gen_timing_corpus.py DIR 10000`)
or a J2 root. Tokens are analyzer-v2's (`core._filename_tokenize`: NFC, simple fold),
which is what the Zig dictionary holds. Probes: dictionary words with one random
edit (substitution, insertion, deletion or adjacent swap) that land outside the
dictionary, i.e. df-0 query terms.
"""
from __future__ import annotations

import argparse
import bisect
import random
import statistics
import sys
from collections import Counter
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(Path.cwd()))
sys.path.insert(0, str(HERE))

import src.search_platform.core as core  # noqa: E402
from fuzzy_expand import osa_bounded  # noqa: E402


def bound(n):
    return 2 if n >= 6 else 1 if n >= 3 else 0


def bag_ok(a, b, k):
    """Bag distance (letters one side has and the other lacks, the larger count) is a
    lower bound on OSA distance: a cheap filter before the banded table."""
    ca, cb = Counter(a), Counter(b)
    return max(sum((ca - cb).values()), sum((cb - ca).values())) <= k


def osa_cells(a, b, k):
    """Cells a banded OSA (|i-j| <= k) fills before it stops; the operation count."""
    la, lb = len(a), len(b)
    if abs(la - lb) > k:
        return 0
    cells = 0
    for i in range(1, la + 1):
        lo, hi = max(1, i - k), min(lb, i + k)
        cells += max(0, hi - lo + 1)
    return cells


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("corpus", type=Path)
    ap.add_argument("--probes", type=int, default=200)
    ap.add_argument("--seed", type=int, default=7)
    args = ap.parse_args()
    df = Counter()
    files = 0
    for p in sorted(args.corpus.rglob("*")):
        if not p.is_file() or p.suffix not in (".md", ".txt"):
            continue
        files += 1
        df.update(set(core._filename_tokenize(p.read_text(encoding="utf-8", errors="replace"))))
    terms = sorted(df, key=lambda t: t.encode("utf-8"))
    lens = Counter(len(t) for t in terms)
    print(f"files {files}; distinct terms {len(terms)}; term bytes {sum(len(t.encode()) for t in terms)}")
    print("length (code points) histogram: " + ", ".join(f"{k}:{lens[k]}" for k in sorted(lens)))
    firsts = Counter(t[0] for t in terms)
    print(f"distinct first code points {len(firsts)}; largest first-letter range {firsts.most_common(1)[0]}; "
          f"median range {statistics.median(firsts.values())}")
    keys = [t.encode("utf-8") for t in terms]
    rnd = random.Random(args.seed)
    alphabet = sorted({ch for t in terms for ch in t if ch.isalpha() and ch.isascii()})
    pool = [t for t in terms if len(t) >= 3 and t.isascii() and t.isalpha()]
    probes = []
    while len(probes) < args.probes and pool:
        w = rnd.choice(pool)
        i = rnd.randrange(1, len(w))  # keep the first letter
        op = rnd.choice("sidt")
        if op == "s":
            m = w[:i] + rnd.choice(alphabet) + w[i + 1:]
        elif op == "i":
            m = w[:i] + rnd.choice(alphabet) + w[i:]
        elif op == "d":
            m = w[:i] + w[i + 1:]
        else:
            m = w[:i - 1] + w[i] + w[i - 1] + w[i + 1:] if i < len(w) else w
        if m != w and m not in df and len(m) >= 3:
            probes.append((m, w))
    rows = []
    for m, w in probes:
        k = bound(len(m))
        lo = bisect.bisect_left(keys, m[0].encode("utf-8"))
        hi = bisect.bisect_left(keys, (chr(ord(m[0]) + 1)).encode("utf-8"))
        rng = terms[lo:hi]
        len_ok = [t for t in rng if abs(len(t) - len(m)) <= k]
        bag = [t for t in len_ok if bag_ok(m, t, k)]
        cells = sum(osa_cells(m, t, k) for t in len_ok)
        cells_bag = sum(osa_cells(m, t, k) for t in bag)
        cells_all = sum(osa_cells(m, t, k) for t in terms if abs(len(t) - len(m)) <= k)
        found = [t for t in len_ok if osa_bounded(m, t, k) is not None]
        rows.append((len(rng), len(len_ok), cells, cells_all, len(found), w in found, len(bag), cells_bag))
    if rows:
        def med(i):
            return statistics.median(r[i] for r in rows)

        def mx(i):
            return max(r[i] for r in rows)
        print(f"probes {len(rows)} (one random edit of a dictionary word, first letter kept, df 0)")
        print(f"  first-letter range scanned: median {med(0)}, max {mx(0)}")
        print(f"  after the length filter: median {med(1)}, max {mx(1)}")
        print(f"  banded OSA cells, first-letter range: median {med(2)}, max {mx(2)}")
        print(f"  banded OSA cells, whole dictionary (no first-letter rule): median {med(3)}, max {mx(3)}")
        print(f"  after the bag-distance filter: median {med(6)}, max {mx(6)}; banded OSA cells then: median {med(7)}, max {mx(7)}")
        print(f"  candidates within the bound: median {med(4)}, max {mx(4)}, "
              f"share of probes with > 3: {sum(1 for r in rows if r[4] > 3) / len(rows):.2f}, > 50: {sum(1 for r in rows if r[4] > 50) / len(rows):.2f}")
        print(f"  the original word among the candidates: {sum(1 for r in rows if r[5]) / len(rows):.2f}")


if __name__ == "__main__":
    main()
