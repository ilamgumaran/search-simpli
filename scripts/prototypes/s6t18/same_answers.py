#!/usr/bin/env python3
"""S6-T18 ruling 1: `searchd query`, `evidence` and `search` answer byte for byte as `main`'s.

    python3 -I same_answers.py MAIN_SEARCHD HEAD_SEARCHD WORK CORPORA_DIR OUT.txt

Each binary writes its own J2 index (`apply --filename-index` of the pack's three roots, as scripts/j2_run.py
does) and the two indexes are compared file by file. Then every case runs on both binaries, each on its own
index (or, for `search`, on the same folder), and stdout, stderr and the exit status are compared as bytes:

- J2, every one of the pack's 290 query strings (knowledge and find rows alike): `query` plain, `query --json`,
  `query --json --top-k 25`, `query --json --search-field both`, `query --json --search-field filename`,
  `evidence`; and `search fixtures/j2` plain, `--json`, `--evidence`;
- each 10k corpus of CORPORA_DIR (timing-10k, prose-10k, tamil-10k; each binary's own index, `searchd index`),
  the 15 queries of scripts/prototypes/s6t9/bench.py `queries`: `query` plain, `query --json`, `evidence`;
  and `search` of timing-10k for its 7 corpus-derived queries, plain.

The output lists the count of cases per kind and every case that differs (none expected). Not part of any build.
"""
from __future__ import annotations

import base64
import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
PACK = ROOT / "fixtures" / "j2"
sys.path.insert(0, str(ROOT / "scripts" / "prototypes" / "s6t9"))
import bench  # noqa: E402  (derive_queries: the timing tasks' query sets)


def run(cmd: list[str]) -> tuple[int, bytes, bytes]:
    done = subprocess.run(cmd, capture_output=True, timeout=600)
    return done.returncode, done.stdout, done.stderr


def changes(judgments: dict) -> dict:
    request = {"roots": [{"root_id": r, "label": r, "kind": "host"} for r in judgments["roots"]], "changes": []}
    for root in judgments["roots"]:
        base = PACK / root
        for path in sorted(p for p in base.rglob("*") if p.is_file()):
            request["changes"].append({"op": "add", "root_id": root, "path": path.relative_to(base).as_posix(),
                                       "content_base64": base64.b64encode(path.read_bytes()).decode("ascii")})
    return request


def same_tree(a: Path, b: Path) -> tuple[int, list[str]]:
    names = sorted(p.relative_to(a).as_posix() for p in a.rglob("*") if p.is_file())
    other = sorted(p.relative_to(b).as_posix() for p in b.rglob("*") if p.is_file())
    bad = [] if names == other else [f"file lists differ: {names} / {other}"]
    bad += [n for n in names if n in other and (a / n).read_bytes() != (b / n).read_bytes()]
    return len(names), bad


def main(argv: list[str]) -> int:
    main_bin, head_bin, work, corpora, out_path = argv[1], argv[2], Path(argv[3]), Path(argv[4]), Path(argv[5])
    work.mkdir(parents=True, exist_ok=False)
    lines, differ, counts = [], [], {}

    def compare(kind: str, args_main: list[str], args_head: list[str], label: str) -> None:
        a, b = run([main_bin, *args_main]), run([head_bin, *args_head])
        counts[kind] = counts.get(kind, 0) + 1
        if a != b:
            differ.append(f"{kind}: {label}: exit {a[0]}/{b[0]}, stdout {len(a[1])}/{len(b[1])} B, "
                          f"stderr {a[2][:200]!r}/{b[2][:200]!r}")
        elif a[0] != 0:
            lines.append(f"note: {kind}: {label}: both exit {a[0]}: {a[2][:200]!r}")

    judgments = json.loads((PACK / "judgments.json").read_text(encoding="utf-8"))
    (work / "changes.json").write_text(json.dumps(changes(judgments)), encoding="utf-8")
    idx = {}
    for name, binary in (("main", main_bin), ("head", head_bin)):
        idx[name] = work / f"j2-{name}"
        code, out, err = run([binary, "apply", str(idx[name]), "--changes", str(work / "changes.json"),
                              "--filename-index"])
        if code != 0:
            raise SystemExit(f"apply failed ({name}): {err!r}")
    n, bad = same_tree(idx["main"], idx["head"])
    lines.append(f"J2 index: {n} files written by each binary; {len(bad)} differ {bad}")
    queries = [q["query"] for q in judgments["queries"]]
    lines.append(f"J2 queries: {len(queries)} ({sum(1 for q in judgments['queries'] if q['mode'] == 'knowledge')} "
                 "knowledge, the rest find rows, their text asked as a query too)")
    variants = {
        "j2 query": [],
        "j2 query --json": ["--json"],
        "j2 query --json --top-k 25": ["--json", "--top-k", "25"],
        "j2 query --json --search-field both": ["--json", "--search-field", "both"],
        "j2 query --json --search-field filename": ["--json", "--search-field", "filename"],
    }
    for q in queries:
        for kind, extra in variants.items():
            compare(kind, ["query", str(idx["main"]), q, *extra], ["query", str(idx["head"]), q, *extra], q)
        compare("j2 evidence", ["evidence", str(idx["main"]), q], ["evidence", str(idx["head"]), q], q)
        for kind, extra in (("j2 search", []), ("j2 search --json", ["--json"]),
                            ("j2 search --evidence", ["--evidence"])):
            args = ["search", str(PACK), q, *extra]
            compare(kind, args, args, q)

    for corpus in ("timing-10k", "prose-10k", "tamil-10k"):
        folder = corpora / corpus
        for name, binary in (("main", main_bin), ("head", head_bin)):
            code, out, err = run([binary, "index", str(folder), "--out", str(work / f"{corpus}-{name}")])
            if code != 0:
                raise SystemExit(f"index failed ({corpus}, {name}): {err!r}")
        n, bad = same_tree(work / f"{corpus}-main", work / f"{corpus}-head")
        lines.append(f"{corpus} index: {n} files written by each binary; {len(bad)} differ {bad}")
        derived = bench.derive_queries(folder)["queries"]
        for q in derived:
            for kind, extra in ((f"{corpus} query", []), (f"{corpus} query --json", ["--json"])):
                compare(kind, ["query", str(work / f"{corpus}-main"), q, *extra],
                        ["query", str(work / f"{corpus}-head"), q, *extra], q)
            compare(f"{corpus} evidence", ["evidence", str(work / f"{corpus}-main"), q],
                    ["evidence", str(work / f"{corpus}-head"), q], q)
        if corpus == "timing-10k":
            for q in derived[8:15]:
                args = ["search", str(folder), q]
                compare(f"{corpus} search", args, args, q)

    total = sum(counts.values())
    lines += [f"{kind}: {count} cases" for kind, count in counts.items()]
    lines.append(f"all: {total} cases, {len(differ)} differ")
    lines += differ
    text = "\n".join(lines) + "\n"
    out_path.write_text(text, encoding="utf-8")
    sys.stdout.write(text)
    return 1 if differ else 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
