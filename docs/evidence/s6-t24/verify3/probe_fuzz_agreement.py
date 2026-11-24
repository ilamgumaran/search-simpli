#!/usr/bin/env python3
"""S6-T24 verifier probe: random patterns, the engine against two oracles.

Verdict 3: hits carry `matches_truncated` too, compared everywhere; the `re` oracle applies rework 2's rule
(empty matches are not counted; a 17th non-empty match starting within the text cuts it there and sets
`matches_truncated`); "cut" now counts hits with `matches_truncated`.

Verdict 2: hits now carry `text` and `text_truncated` too (the 16-match cut moves them); a difference from the
reference is counted apart when the reference's `offsets_may_differ(pattern)` says the pattern is in the stated
class (there only lines and counts must agree); the `re` oracle applies the cut as docs/scan.md states it (at
most 16 matches looked for, empty ones included; a 17th starting within the text cuts it there); four lines of
40 code points are added to each file so the cut is reached.

1. The Python reference (`src/search_platform/scan.py`, `scan_folder`), every page joined: hits, offsets,
   refusals and messages must agree exactly (the builder's own agreement test uses 36 fixed patterns and
   literals; this one generates patterns from the grammar at random, nested).
2. Python's `re` used directly, written by the verifier and independent of the reference: for patterns that use
   only characters, `.`, classes of literal members, groups, alternation, repeats and `^`/`$` (no `\\w \\b \\d
   \\s`, whose meaning is the analyser's), sensitive case, over LF-only lines. The engine's hit lines must be
   the lines on which `re.search` succeeds; offsets are compared and differences printed (the known
   empty-iteration divergence, `(|a)*`, is a class of them).

Usage: python3 -I probe_fuzz_agreement.py REPO SEARCHD WORKDIR [N] [SEED]
"""
import json
import os
import random
import re
import signal
import subprocess
import sys
from pathlib import Path

repo, searchd, work = Path(sys.argv[1]), sys.argv[2], Path(sys.argv[3])
N = int(sys.argv[4]) if len(sys.argv) > 4 else 400
SEED = int(sys.argv[5]) if len(sys.argv) > 5 else 20261123
sys.path.insert(0, str(repo))
from src.search_platform import scan  # noqa: E402

rng = random.Random(SEED)
CHARS = ["a", "b", "c", "A", "B", "_", "1", "7", "٣", "²", " ", "\t", "ß", "ẞ", "K", "k", "K", "s", "S",
         "ſ", "த", "ி", "்", "é", "é", "İ", "ı", "i", ".", "-", "$", "(", "σ", "ς", "Σ"]
PLAIN = ["a", "b", "c", "A", "B", "_", "1", "7", " ", "-", "ß", "é", "த", "σ", "k", "s"]


def gen_folder(root: Path) -> list[str]:
    root.mkdir(parents=True, exist_ok=True)
    all_lines = []
    for f in range(4):
        lines = []
        for _ in range(60):
            lines.append("".join(rng.choice(CHARS) for _ in range(rng.randint(0, 24))))
        lines += ["", "aaaa", "abab", "aab", "ba", "_a_", "a_b", "AB ab", "a" * 40, "ab" * 20, "a b " * 10, "é" * 20 + "a" * 20]
        (root / f"f{f}.txt").write_text("\n".join(lines) + "\n", encoding="utf-8")
        all_lines.append(lines)
    return all_lines


def atom(depth, plain):
    pool = PLAIN if plain else CHARS
    r = rng.random()
    if r < 0.45 or depth > 3:
        c = rng.choice(pool)
        return re.escape(c) if c in ".-$(" else c.replace("\t", "\\t")
    if r < 0.55:
        return "."
    if r < 0.70:
        members = "".join(rng.choice(["a", "b", "c", "A", "1", "ß", "k", "s", "a-c", "A-Z", "0-9"]) for _ in range(rng.randint(1, 3)))
        if not plain and rng.random() < 0.3:
            members += rng.choice(["\\w", "\\d", "\\s", "\\W"])
        return "[" + ("^" if rng.random() < 0.3 else "") + members + "]"
    if r < 0.82:
        return "(" + ("?:" if rng.random() < 0.5 else "") + regex(depth + 1, plain) + ")"
    if not plain and r < 0.95:
        return rng.choice(["\\w", "\\W", "\\d", "\\D", "\\s", "\\S", "\\b", "\\B"])
    return rng.choice(["^", "$"])


def piece(depth, plain):
    a = atom(depth, plain)
    if a in ("^", "$", "\\b", "\\B"):
        return a
    r = rng.random()
    if r < 0.6:
        return a
    q = rng.choice(["*", "+", "?", "{2}", "{0,2}", "{1,}", "{1,3}"])
    return a + q


def regex(depth=0, plain=False):
    branches = []
    for _ in range(1 if rng.random() < 0.7 else rng.randint(2, 3)):
        branches.append("".join(piece(depth, plain) for _ in range(rng.randint(0 if rng.random() < 0.1 else 1, 3))))
    return "|".join(branches)


def engine_all(root, params):
    hits, cursor = [], None
    while True:
        argv = [searchd, "scan", "--folder", str(root), params["pattern"], "--json", "--page-size", "100",
                "--max-per-file", "1000", "--time-ms", "30000", "--case", params["case"]]
        if params["mode"] == "regex":
            argv.append("--regex")
        if params.get("whole_word"):
            argv.append("--word")
        if cursor:
            argv += ["--cursor", cursor]
        done = subprocess.run(argv, capture_output=True)
        if done.returncode != 0:
            message = done.stderr.decode().strip()
            prefix = "searchd: SS_ERR_INVALID_ARGUMENT: "
            return {"refused": message[len(prefix):] if message.startswith(prefix) else message}
        page = json.loads(done.stdout)
        hits += [(h["path"], h["line"], h["text"], h["text_truncated"], h["match_offsets"], h["matches_truncated"]) for h in page["hits"]]
        cursor = page["next_cursor"]
        if not cursor:
            return {"hits": hits, "case_applied": page["case_applied"]}


def reference_all(root, params):
    hits, cursor = [], None
    while True:
        try:
            page = scan.scan_folder(root, {**params, "page_size": 100, "max_hits_per_file": 1000,
                                           "time_budget_ms": 30000, "cursor": cursor})
        except scan.ScanError as error:
            return {"refused": str(error)}
        hits += [(h["path"], h["line"], h["text"], h["text_truncated"], h["match_offsets"], h["matches_truncated"]) for h in page["hits"]]
        cursor = page["next_cursor"]
        if not cursor:
            return {"hits": hits, "case_applied": page["case_applied"]}


def oracle_re(lines_by_file, pattern):
    rx = re.compile(pattern, re.DOTALL)
    out = []
    for f, lines in enumerate(lines_by_file):
        for number, line in enumerate(lines, 1):
            ms = list(rx.finditer(line))
            if ms:
                text = line.encode("utf-8")[:512].decode("utf-8", "ignore")
                text_cps = len(text)
                offs, cut = [], False
                for m in ms:
                    if m.start() >= text_cps:
                        break
                    if m.start() == m.end():  # rework 2: an empty match is neither counted nor listed
                        continue
                    if len(offs) == 16:  # docs/scan.md: a 17th non-empty match cuts the text where it starts
                        text, cut = line[:m.start()], True
                        break
                    offs.append([m.start(), min(m.end(), text_cps)])
                out.append((f"f{f}.txt", number, text, len(text) < len(line), offs, cut))
    return out


class Slow(Exception):
    pass


def on_alarm(signum, frame):
    raise Slow()


signal.signal(signal.SIGALRM, on_alarm)
SLOW_SECONDS = 5
slow = []


def timed(fn, *args):
    """Python's backtracking `re` (the reference and the oracle) can take exponential time on a line; such a
    pattern is recorded and skipped, never waited for."""
    signal.alarm(SLOW_SECONDS)
    try:
        return fn(*args)
    finally:
        signal.alarm(0)


root = work / f"fuzz-{SEED}"
lines_by_file = gen_folder(root)
ref_diff = ref_line_diff = re_line_diff = re_off_diff = refused = in_class_diff = cut_lines = re_off_class = 0
examples = []
for i in range(N):
    plain = rng.random() < 0.5
    pattern = regex(plain=plain)
    if not pattern:
        continue
    case = "sensitive" if plain else rng.choice(["sensitive", "insensitive", "smart"])
    params = {"pattern": pattern, "mode": "regex", "case": case, "whole_word": (not plain) and rng.random() < 0.2}
    e = engine_all(root, params)
    try:
        r = timed(reference_all, root, params)
    except Slow:
        slow.append(pattern)
        continue
    if "refused" in e:
        refused += 1
    cut_lines += sum(1 for h in e.get("hits", []) if h[5])
    if e != r and "hits" in e and "hits" in r and scan.offsets_may_differ(pattern) \
            and [h[:2] for h in e["hits"]] == [h[:2] for h in r["hits"]]:
        in_class_diff += 1  # the stated class: lines agree, offsets and the cut text may not
    elif e != r:
        ref_diff += 1
        if "hits" in e and "hits" in r and [h[:2] for h in e["hits"]] != [h[:2] for h in r["hits"]]:
            ref_line_diff += 1
            examples.append(f"reference hit LINES differ: {pattern!r} case={case}")
        if len(examples) < 12:
            eh = e.get("hits", e)
            rh = r.get("hits", r)
            first = next(((a, b) for a, b in zip(eh, rh) if a != b), None) if isinstance(eh, list) and isinstance(rh, list) else (eh, rh)
            examples.append(f"reference differs: {pattern!r} case={case} ww={params['whole_word']}: engine {len(eh) if isinstance(eh, list) else eh} vs reference {len(rh) if isinstance(rh, list) else rh}; first {first}")
    if plain and "refused" not in e:
        try:
            o = timed(oracle_re, lines_by_file, pattern)
        except Slow:
            slow.append(pattern)
            continue
        eh = e["hits"]
        if [h[:2] for h in eh] != [h[:2] for h in o]:
            re_line_diff += 1
            examples.append(f"re hit LINES differ: {pattern!r}: engine {len(eh)} lines, re {len(o)}")
        elif eh != o and scan.offsets_may_differ(pattern):
            re_off_class += 1
        elif eh != o:
            re_off_diff += 1
            if len(examples) < 24:
                first = next((a, b) for a, b in zip(eh, o) if a != b)
                examples.append(f"re offsets differ: {pattern!r}: first engine {first[0]} re {first[1]}")
print(f"hits with matches_truncated (summed over patterns): {cut_lines}; differing from the reference "
      f"inside the stated class (lines equal): {in_class_diff}")
print(f"seed {SEED}: {N} patterns; refused by the engine {refused}; engine != reference outside the class {ref_diff} (of which hit lines differ {ref_line_diff}); "
      f"plain patterns: hit lines differ from re {re_line_diff}, offsets or text differ outside the class {re_off_diff}, inside it {re_off_class}")
print(f"skipped, Python's re over {SLOW_SECONDS} s on a line of at most 40 code points: {len(slow)} {slow[:5]}")
for line in examples:
    print("  " + line)
