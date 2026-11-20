#!/usr/bin/env python3
"""S6-T9 (rulings 2 and 3): the first publish over main's index, and change detection.

    python3 -I first_publish.py MAIN_SEARCHD HEAD_SEARCHD WORK_DIR NAME=MAIN_INDEX=CORPUS ...

WORK_DIR must not exist. For each corpus (a folder, or `apply:CHANGES.json`
for J2), on copies under WORK_DIR:

- unchanged: HEAD updates a copy of MAIN_INDEX (main's format) with the
  folder unchanged (J2: an empty batch). Its report must plan zero work
  (added, changed, removed and moved 0). Its new generation must be,
  file for file, the bytes HEAD writes when it indexes the same folder
  fresh and then updates it once unchanged (the same generation number):
  every section, MANIFEST and INDEX-STATE.json.
- changed: one file changed, one added, one removed and one renamed
  (J2: the same four as `apply` operations). MAIN and HEAD each update
  their own copy of MAIN_INDEX; the two reports' counts must be equal, and
  HEAD's generation must be the bytes HEAD writes for the changed folder
  fresh and then updated once unchanged.

Prints one line per corpus and step; exits 1 on any difference. Not part
of any library.
"""
import base64
import json
import shutil
import subprocess
import sys
from pathlib import Path

COUNTS = ("added", "changed", "removed", "moved", "unchanged", "rejected", "conflicts")


def run(argv) -> dict:
    done = subprocess.run([str(x) for x in argv], capture_output=True)
    if done.returncode != 0:
        raise SystemExit(f"{argv[0]} {argv[1]} failed ({done.returncode}): {done.stderr.decode()[:300]}")
    out = done.stdout.decode().strip().splitlines()
    for line in reversed(out):
        if line.startswith("{"):
            return json.loads(line)
        if line.startswith("applied:"):
            return {k: int(v) for k, v in (w.split("=", 1) for w in line.split()[1:])}
    return {}


def generation(index: Path) -> int:
    return int.from_bytes((index / "MANIFEST").read_bytes()[12:20], "little")


def current(index: Path) -> dict:
    g = generation(index)
    return {p.name: p.read_bytes() for p in index.iterdir()
            if p.name in ("MANIFEST", "INDEX-STATE.json") or p.stem.endswith(f"-{g}")}


def counts(report: dict) -> dict:
    return {k: report.get(k, 0) for k in COUNTS}


def main() -> int:
    main_bin, head_bin = Path(sys.argv[1]).resolve(), Path(sys.argv[2]).resolve()
    work = Path(sys.argv[3])
    if work.exists():
        raise SystemExit("WORK_DIR must not exist")
    bad = 0
    for spec in sys.argv[4:]:
        name, main_index, corpus = spec.split("=", 2)
        base = work / name
        base.mkdir(parents=True)
        is_apply = corpus.startswith("apply:")

        def update(binary, index, folder, batch):
            if is_apply:
                return run([binary, "apply", index, "--changes", batch])
            return run([binary, "index", folder, "--out", index, "--update"])

        def fresh(binary, out, folder, batches):
            if is_apply:
                run([binary, "apply", out, "--changes", corpus[len("apply:"):], "--filename-index"])
                for b in batches:
                    run([binary, "apply", out, "--changes", b])
                return run([binary, "apply", out, "--changes", empty])
            run([binary, "index", folder, "--out", out, "--filename-index"])
            return run([binary, "index", folder, "--out", out, "--update"])

        folder = None if is_apply else Path(corpus)
        roots = json.loads(Path(corpus[len("apply:"):]).read_text(encoding="utf-8"))["roots"] if is_apply else None
        empty = base / "empty.json"
        if is_apply:
            empty.write_text(json.dumps({"roots": roots, "changes": []}), encoding="utf-8")

        # unchanged
        migrated = base / "unchanged"
        shutil.copytree(main_index, migrated)
        report = update(head_bin, migrated, folder, empty)
        zero = all(report.get(k, 0) == 0 for k in ("added", "changed", "removed", "moved"))
        reference = base / "unchanged-fresh"
        fresh(head_bin, reference, folder, [])
        a, b = current(migrated), current(reference)
        same = a == b and generation(migrated) == generation(reference)
        differ = sorted(k for k in set(a) | set(b) if a.get(k) != b.get(k))
        print(f"{name} unchanged: report {counts(report)}; zero work {zero}; "
              f"{len(a)} files, byte-identical to fresh {same}{'' if same else ' differ ' + str(differ)}")
        bad += (not zero) + (not same)

        # changed, added, removed, renamed
        batch = None
        if is_apply:
            listed = json.loads(Path(corpus[len("apply:"):]).read_text(encoding="utf-8"))["changes"]
            adds = [c for c in listed if c["op"] == "add"]
            first, second, third = adds[0], adds[1], adds[2]
            text = base64.b64decode(first["content_base64"]) + b"\nA changed line.\n"
            batch = base / "changes.json"
            batch.write_text(json.dumps({"roots": roots, "changes": [
                {"op": "add", "root_id": first["root_id"], "path": first["path"],
                 "content_base64": base64.b64encode(text).decode()},
                {"op": "add", "root_id": roots[0]["root_id"], "path": "s6t9-added.md",
                 "content_base64": base64.b64encode(b"# Added\n\nA new file.\n").decode()},
                {"op": "remove", "root_id": second["root_id"], "path": second["path"]},
                {"op": "move", "root_id": third["root_id"], "path": "s6t9-renamed/" + third["path"],
                 "moved_from": third["path"]},
            ]}), encoding="utf-8")
            changed_folder = None
        else:
            changed_folder = base / "corpus"
            shutil.copytree(folder, changed_folder)
            files = sorted(p for p in changed_folder.rglob("*") if p.is_file())
            with open(files[0], "a", encoding="utf-8") as f:
                f.write("A changed line.\n")
            (files[0].parent / "s6t9-added.md").write_text("# Added\n\nA new file.\n", encoding="utf-8")
            files[1].unlink()
            files[2].rename(files[2].parent / ("s6t9-renamed-" + files[2].name))
        reports = {}
        for side, binary in (("main", main_bin), ("head", head_bin)):
            index = base / f"changed-{side}"
            shutil.copytree(main_index, index)
            reports[side] = update(binary, index, changed_folder, batch)
        planned_same = counts(reports["main"]) == counts(reports["head"])
        reference = base / "changed-fresh"
        if is_apply:
            run([head_bin, "apply", reference, "--changes", corpus[len("apply:"):], "--filename-index"])
            run([head_bin, "apply", reference, "--changes", batch])
        else:
            run([head_bin, "index", changed_folder, "--out", reference, "--filename-index"])
            run([head_bin, "index", changed_folder, "--out", reference, "--update"])
        a, b = current(base / "changed-head"), current(reference)
        same = a == b
        differ = sorted(k for k in set(a) | set(b) if a.get(k) != b.get(k))
        print(f"{name} changed: main {counts(reports['main'])}; head {counts(reports['head'])}; "
              f"planned the same {planned_same}; byte-identical to fresh {same}{'' if same else ' differ ' + str(differ)}")
        bad += (not planned_same) + (not same)
    return 1 if bad else 0


if __name__ == "__main__":
    raise SystemExit(main())
