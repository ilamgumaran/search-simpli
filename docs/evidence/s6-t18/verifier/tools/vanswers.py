#!/usr/bin/env python3
"""S6-T18 verifier, ruling 1: `searchd query`, `evidence` and `search` of main and head compared as bytes
(stdout, stderr, exit status), on a sample the verifier chose. Written by the verifier; not part of any build.

    python3 -I vanswers.py MAIN_SEARCHD HEAD_SEARCHD REPO_ROOT WORK CORPORA_DIR OUT.txt

Indexes: each binary writes its own, with `searchd index <folder> --out` (no file-name channel: a different
index from the J2 gate's `apply`), of fixtures/j2 (all three roots as one folder), fixtures/tamil,
fixtures/family-folder, fixtures/knowledge, fixtures/mixed-knowledge, a small invented folder made here whose
file is found only by its folder name ("titleonly"), and the three 10k corpora; the two indexes of each are
compared file for file.
Cases (each on both binaries, each on its own index; `search` on the same folder):
- fixtures/j2: every one of the 290 query strings (judgments.json) as `query` text, `query --json --top-k 3`,
  `evidence --top-k 7`, and `search fixtures/j2 --json --top-k 5`;
- every index: the edge queries below as `query`, `query --json`, `evidence`, each at --top-k 0, 1, default and
  100000 (larger than any corpus), and `search` text, `--json` and `--evidence` on the small folders;
- edge queries: empty, one space, invalid UTF-8 (0xff 0xfe, and a lone continuation byte 0x80 after a word), a tab
  inside, punctuation only, a 2,000-character query, mixed case, Tamil, a combining mark, the title-only word
  "orchard" (in a folder name only), a path-like query, a word absent everywhere, and stop words;
- usage errors: `query` with no text, `--top-k` with no number, `--top-k -1`, `--top-k abc`, a missing index.
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path

EDGE = [b"", b" ", b"\xff\xfe", b"garden \x80", b"a\tb", b"!!! ??? ...", b"lantern " * 250, b"VoLcAnO Project",
        "கீகசை வீடு".encode(), "café".encode(), b"orchard", b"school/volcano-project.md",
        b"zzqqxxnotaword", b"the of and", b"doc 00000"]
TOPK = [["--top-k", "0"], ["--top-k", "1"], [], ["--top-k", "100000"]]


def run(cmd):
    done = subprocess.run(cmd, capture_output=True, timeout=600)
    return done.returncode, done.stdout, done.stderr


def same_tree(a: Path, b: Path):
    names = sorted(p.relative_to(a).as_posix() for p in a.rglob("*") if p.is_file())
    other = sorted(p.relative_to(b).as_posix() for p in b.rglob("*") if p.is_file())
    bad = [] if names == other else ["file lists differ"]
    bad += [n for n in names if n in other and (a / n).read_bytes() != (b / n).read_bytes()]
    return len(names), bad


def main(argv):
    main_bin, head_bin, repo, work, corpora, out = (os.fsencode(argv[1]), os.fsencode(argv[2]), Path(argv[3]),
                                                    Path(argv[4]), Path(argv[5]), Path(argv[6]))
    work.mkdir(parents=True, exist_ok=False)
    title = work / "titleonly"
    (title / "orchard").mkdir(parents=True)
    (title / "orchard" / "apples.md").write_text("# Apples\n\nPick the red ones in October.\n")
    (title / "week.md").write_text("# Week\n\nThe tide table for the harbour walk.\n")
    folders = {"j2": repo / "fixtures/j2", "tamil": repo / "fixtures/tamil",
               "family": repo / "fixtures/family-folder", "knowledge": repo / "fixtures/knowledge",
               "mixed": repo / "fixtures/mixed-knowledge", "titleonly": title}
    for c in ("timing-10k", "prose-10k", "tamil-10k"):
        folders[c] = corpora / c
    lines, differ, counts = [], [], {}
    idx = {}
    for name, folder in folders.items():
        pair = []
        for tag, binary in (("main", main_bin), ("head", head_bin)):
            d = work / tag / name
            d.parent.mkdir(exist_ok=True)
            code, so, se = run([binary, b"index", os.fsencode(folder), b"--out", os.fsencode(d)])
            if code != 0:
                differ.append(f"index {name} {tag} exit {code}: {se[:200]!r}")
            pair.append(d)
        n, bad = same_tree(*pair)
        lines.append(f"index {name}: {n} files, {'identical' if not bad else 'DIFFER ' + ', '.join(bad)}")
        differ += [f"index {name}: {b}" for b in bad]
        idx[name] = pair

    def case(kind, args_main, args_head):
        a, b = run([main_bin] + args_main), run([head_bin] + args_head)
        counts[kind] = counts.get(kind, 0) + 1
        if a != b:
            differ.append(f"{kind}: {args_head!r} main exit {a[0]} head exit {b[0]}")
        return a

    exits = {}
    j2q = [q["query"].encode() for q in json.loads((repo / "fixtures/j2/judgments.json").read_text())["queries"]]
    mi, hi = (os.fsencode(p) for p in idx["j2"])
    for q in j2q:
        case("j2 query", [b"query", mi, q], [b"query", hi, q])
        case("j2 query --json --top-k 3", [b"query", mi, q, b"--json", b"--top-k", b"3"],
             [b"query", hi, q, b"--json", b"--top-k", b"3"])
        case("j2 evidence --top-k 7", [b"evidence", mi, q, b"--top-k", b"7"], [b"evidence", hi, q, b"--top-k", b"7"])
        f = os.fsencode(folders["j2"])
        case("j2 search --json --top-k 5", [b"search", f, q, b"--json", b"--top-k", b"5"],
             [b"search", f, q, b"--json", b"--top-k", b"5"])
    for name, (m, h) in idx.items():
        m, h = os.fsencode(m), os.fsencode(h)
        for q in EDGE:
            for k in TOPK:
                kb = [os.fsencode(x) for x in k]
                for form, extra in (("query", []), ("query --json", [b"--json"])):
                    r = case(f"edge {form}", [b"query", m, q] + extra + kb, [b"query", h, q] + extra + kb)
                    exits.setdefault(f"query exit {r[0]}", 0)
                    exits[f"query exit {r[0]}"] += 1
                r = case("edge evidence", [b"evidence", m, q] + kb, [b"evidence", h, q] + kb)
                exits.setdefault(f"evidence exit {r[0]}", 0)
                exits[f"evidence exit {r[0]}"] += 1
                if name in ("titleonly", "tamil", "family"):
                    f = os.fsencode(folders[name])
                    for extra in ([], [b"--json"], [b"--evidence"]):
                        r = case("edge search", [b"search", f, q] + extra + kb, [b"search", f, q] + extra + kb)
                        exits.setdefault(f"search exit {r[0]}", 0)
                        exits[f"search exit {r[0]}"] += 1
    m, h = (os.fsencode(p) for p in idx["titleonly"])
    title_hit = case("title-only", [b"query", m, b"orchard", b"--json"], [b"query", h, b"orchard", b"--json"])
    lines.append(f"title-only query `orchard` (main's answer): {title_hit[1].decode().strip()}")
    for args in ([b"query", m], [b"query", m, b"x", b"--top-k"], [b"query", m, b"x", b"--top-k", b"-1"],
                 [b"query", m, b"x", b"--top-k", b"abc"], [b"query", os.fsencode(work / "nope"), b"x"],
                 [b"evidence", m], [b"search", os.fsencode(work / "nope"), b"x"]):
        r = case("usage", args, [h if a == m else a for a in args])
        lines.append(f"usage {[a.decode(errors='replace') for a in args[0:1] + args[2:]]}: exit {r[0]}, "
                     f"stderr {r[2].decode(errors='replace').strip()[:100]!r}")
    for q in (b"\xff\xfe", b"", b"garden \x80"):
        r = run([main_bin, b"query", m, q])
        lines.append(f"query {q!r} on main: exit {r[0]}, stdout {r[1][:80]!r}, stderr {r[2][:100]!r}")
    lines.append("exit statuses of the edge cases (main = head): " + ", ".join(f"{k}: {v}" for k, v in sorted(exits.items())))
    total = sum(counts.values())
    lines += [f"{k}: {v}" for k, v in counts.items()]
    lines.append(f"TOTAL {total} cases, {len(differ)} differ")
    lines += [f"DIFFER {d}" for d in differ]
    out.write_text("\n".join(lines) + "\n")
    print("\n".join(lines[-12:]))
    return 1 if differ else 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
