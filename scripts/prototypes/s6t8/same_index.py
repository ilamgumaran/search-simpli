#!/usr/bin/env python3
"""S6-T8 (rulings on the Report, item 1b): two writers write the same index.

    python3 -I same_index.py SEARCHD_A SEARCHD_B WORK_DIR NAME=MAIN_INDEX=CORPUS ...

For each corpus, each writer on its own copies under WORK_DIR (which must not
exist): (fresh) index CORPUS from nothing; (first) the first one-line update
of a copy of MAIN_INDEX (main's format; the branch's HYBLEX03 -> HYBLEX04
publish); (second) the next one-line update. CORPUS `apply:CHANGES.json`
(J2) builds the fresh index with `searchd apply --filename-index` and makes
each update by `apply` of one added file. After each step every file of the
two index directories is compared; the only files allowed to differ are
`state-*.hybstate` (times) and `INDEX-STATE.json`. Prints one line per corpus
and step, and exits 1 if any other file differs. Not part of any library.
"""
import base64
import json
import shutil
import subprocess
import sys
from pathlib import Path


def run(argv) -> None:
    done = subprocess.run([str(x) for x in argv], stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    if done.returncode != 0:
        raise SystemExit(f"{argv[0]} {argv[1]} failed ({done.returncode}): {done.stderr.decode()[:300]}")


def compare(a: Path, b: Path) -> tuple[list[str], list[str]]:
    names = sorted({p.name for p in a.iterdir()} | {p.name for p in b.iterdir()})
    same, differ = [], []
    for name in names:
        pa, pb = a / name, b / name
        if pa.is_file() and pb.is_file() and pa.read_bytes() == pb.read_bytes():
            same.append(name)
        else:
            differ.append(name)
    return same, differ


def allowed(name: str) -> bool:
    return (name.startswith("state-") and name.endswith(".hybstate")) or name == "INDEX-STATE.json"


def main() -> int:
    searchd = [Path(sys.argv[1]).resolve(), Path(sys.argv[2]).resolve()]
    work = Path(sys.argv[3])
    if work.exists():
        raise SystemExit("WORK_DIR must not exist")
    bad = 0
    for spec in sys.argv[4:]:
        name, main_index, corpus = spec.split("=", 2)
        is_apply = corpus.startswith("apply:")
        roots = None
        if is_apply:
            roots = json.loads(Path(corpus[len("apply:"):]).read_text(encoding="utf-8"))["roots"]
        dirs = {}
        for side, binary in zip("ab", searchd):
            base = work / name / side
            base.mkdir(parents=True)
            fresh, index = base / "fresh", base / "index"
            if is_apply:
                run([binary, "apply", fresh, "--changes", corpus[len("apply:"):], "--filename-index"])
            else:
                run([binary, "index", corpus, "--out", fresh, "--filename-index"])
            shutil.copytree(main_index, index)
            if not is_apply:
                corpus_copy = base / "corpus"
                shutil.copytree(corpus, corpus_copy)
                first = sorted(p for p in corpus_copy.rglob("*") if p.is_file())[0]
            dirs[side] = {"fresh": fresh}
            for i, step in enumerate(("first", "second")):
                if is_apply:
                    text = f"# Added {i}\n\nAn added line for update {i}.\n".encode()
                    changes = base / f"changes-{i}.json"
                    changes.write_text(json.dumps({"roots": roots, "changes": [{
                        "op": "add", "root_id": roots[0]["root_id"], "path": f"s6t8-added-{i}.md",
                        "content_base64": base64.b64encode(text).decode()}]}), encoding="utf-8")
                    run([binary, "apply", index, "--changes", changes])
                else:
                    with open(first, "a", encoding="utf-8") as f:
                        f.write(f"An added line for update {i}.\n")
                    run([binary, "index", corpus_copy, "--out", index, "--update",
                         "--keep-generations", "2", "--filename-index"])
                snapshot = base / step
                shutil.copytree(index, snapshot)
                dirs[side][step] = snapshot
        for step in ("fresh", "first", "second"):
            same, differ = compare(dirs["a"][step], dirs["b"][step])
            unexpected = [d for d in differ if not allowed(d)]
            bad += len(unexpected)
            print(f"{name} {step}: {len(same)} files byte-identical; differ: {differ or 'none'}"
                  f"{'; UNEXPECTED: ' + ', '.join(unexpected) if unexpected else ''}")
    return 1 if bad else 0


if __name__ == "__main__":
    raise SystemExit(main())
