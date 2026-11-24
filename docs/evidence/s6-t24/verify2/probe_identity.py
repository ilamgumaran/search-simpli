#!/usr/bin/env python3
"""S6-T24 verifier probe: what existed answers as on `main`, checked with the verifier's own builds, queries and
update sequence (not the builder's script).

1. Full index of each corpus by main's and the head's `searchd` (each into its own folder): every file compared.
2. On each build's own index: `query --json` (content, and --top-k 3), `evidence`, `find` (words, phrase, prefix,
   page size 3), `search <folder> --json --evidence`, `list-files`, `roots` for 40 words and 10 two-word phrases
   drawn with seed 4711 from the corpus, plus fixed punctuation and Tamil queries: stdout, stderr, exit compared.
3. The writer's path that the read-and-caps extraction (540bb09) moved: a folder indexed, then changed (an
   edit, an add, a delete, a file grown over --max-file-bytes, a file turned binary, a known-name file made
   invalid UTF-8, enough new bytes to spend --max-total-bytes) and `index --update` run with the caps, by each
   build on its own copy: the update's JSON report and every index file compared.

Verdict 2 adds, in 2: `read-span` (lines 1-400 --json, lines 2-3 --context 2, a range past the end) and
`outline --json` on up to 150 files a corpus drawn with seed 4713 from `list-files --json`, since rework 1 changed
`source_v2.rebuildChecked`, the read those take.

Usage: python3 -I probe_identity.py MAIN_SEARCHD HEAD_SEARCHD WORKDIR CORPUS...
"""
import json
import random
import re
import shutil
import subprocess
import sys
from pathlib import Path

main_bin, head_bin, work = sys.argv[1], sys.argv[2], Path(sys.argv[3])
corpora = [Path(p) for p in sys.argv[4:]]
failures = 0


def run(binary, *args):
    done = subprocess.run([binary, *map(str, args)], capture_output=True, stdin=subprocess.DEVNULL, timeout=900)
    return done.returncode, done.stdout, done.stderr


def same_tree(a: Path, b: Path):
    fa = sorted(p.relative_to(a) for p in a.rglob("*") if p.is_file())
    fb = sorted(p.relative_to(b) for p in b.rglob("*") if p.is_file())
    differ = [str(p) for p in fa if p in fb and (a / p).read_bytes() != (b / p).read_bytes()]
    return fa == fb, differ, len(fa)


for corpus in corpora:
    name = corpus.name
    idx = {}
    for label, binary in (("main", main_bin), ("head", head_bin)):
        out = work / f"id-{name}-{label}"
        if out.exists():
            shutil.rmtree(out)
        code, _, err = run(binary, "index", corpus, "--out", out)
        assert code == 0, err
        idx[label] = out
    names_same, differ, count = same_tree(idx["main"], idx["head"])
    failures += (not names_same) or bool(differ)
    print(f"{name}: index folders, {count} files: same names {names_same}, byte-different {differ}")
    rng = random.Random(4711)
    files = sorted(p for p in corpus.rglob("*") if p.is_file())
    # Bounded draws (a first version looped forever on the Tamil corpus: Python's `\w` does not take the
    # vowel signs, so `\w{3,} \w{3,}` found nothing). Words are split on white space; at most 2,000 draws.
    words, phrases = [], []
    for _ in range(2000):
        if len(words) >= 40 and len(phrases) >= 10:
            break
        tokens = [t.strip(".,;:!?()[]\"'#*") for t in rng.choice(files).read_bytes().decode("utf-8", "replace").split()]
        tokens = [t for t in tokens if len(t) >= 3]
        if len(tokens) >= 2:
            if len(words) < 40:
                words.append(rng.choice(tokens).lower())
            if len(phrases) < 10:
                k = rng.randrange(len(tokens) - 1)
                phrases.append((tokens[k] + " " + tokens[k + 1]).lower())
    print(f"{name}: drew {len(words)} words and {len(phrases)} phrases")
    fixed = ["142.50", "TS-0142", "don't", "e-mail", "மழை", "naïve café", "x", "the and of"]
    calls = []
    for q in words + phrases + fixed:
        calls += [("query", "{i}", q, "--json"), ("query", "{i}", q, "--json", "--top-k", "3"), ("evidence", "{i}", q),
                  ("find", "{i}", q, "--json"), ("find", "{i}", q, "--json", "--mode", "phrase"),
                  ("find", "{i}", q[:4], "--json", "--mode", "prefix", "--page-size", "3")]
    for q in words[:10] + fixed[:4]:
        calls.append(("search", str(corpus), q, "--json", "--evidence"))
    calls += [("list-files", "{i}"), ("roots", "{i}", "--json")]
    listed, cursor = [], None
    for _ in range(1000):  # bounded paging
        page = json.loads(run(head_bin, "list-files", idx["head"], "--json", "--page-size", "1000", *(["--cursor", cursor] if cursor else []))[1])
        listed += [(f["root_id"], f["path"]) for f in page["files"] if f["status"] == "indexed"]
        cursor = page["next_cursor"]
        if not cursor:
            break
    chosen = sorted(random.Random(4713).sample(listed, min(150, len(listed))))
    for root, path in chosen:
        calls += [("read-span", "{i}", root, path, "1", "400", "--json"), ("read-span", "{i}", root, path, "2", "3", "--context", "2"),
                  ("read-span", "{i}", root, path, "100000", "100001", "--json"), ("outline", "{i}", root, path, "--json")]
    print(f"{name}: {len(chosen)} files for read-span and outline")
    diff = 0
    for call in calls:
        outs = [run(b, *[idx[label] if c == "{i}" else c for c in call]) for label, b in (("main", main_bin), ("head", head_bin))]
        a, b = outs
        # the index path appears in some outputs; each build has its own: compare with it replaced
        norm = [(o[0], o[1].replace(str(idx[l]).encode(), b"<index>"), o[2].replace(str(idx[l]).encode(), b"<index>")) for o, l in zip(outs, ("main", "head"))]
        if norm[0] != norm[1]:
            diff += 1
            if diff <= 3:
                print(f"   differs: {call}")
    failures += diff > 0
    print(f"{name}: {len(calls)} calls, {diff} differ (stdout, stderr, exit)")

# 3. the update path with caps
base = work / "id-update-src"
if base.exists():
    shutil.rmtree(base)
base.mkdir(parents=True)
rng = random.Random(4712)
for n in range(30):
    (base / f"n{n:02d}.md").write_text("\n".join(" ".join(rng.choice(["tide", "pool", "harbour", "ledger", "142.50"]) for _ in range(8)) for _ in range(30)) + "\n")
(base / "grow.txt").write_text("small\n")
(base / "turns-binary.log").write_text("plain text for now\n")
(base / "goes-bad.md").write_text("valid text\n")
reports = {}
for label, binary in (("main", main_bin), ("head", head_bin)):
    folder = work / f"id-update-{label}"
    out = work / f"id-update-{label}-index"
    for p in (folder, out):
        if p.exists():
            shutil.rmtree(p)
    shutil.copytree(base, folder)
    code, _, err = run(binary, "index", folder, "--out", out)
    assert code == 0, err
    (folder / "n03.md").write_text("edited tide line\n")
    (folder / "n04.md").unlink()
    (folder / "added.md").write_text("added harbour\n")
    (folder / "grow.txt").write_text("x" * 9000 + "\n")
    (folder / "turns-binary.log").write_bytes(b"\x00\x01\x02binary now\x00" * 50)
    (folder / "goes-bad.md").write_bytes(b"now caf\xe9 is latin-1\n")
    for k in range(6):
        (folder / f"big{k}.md").write_text(("budget " * 300 + "\n") * 2)
    code, stdout, stderr = run(binary, "index", folder, "--out", out, "--update", "--max-file-bytes", "8000", "--max-total-bytes", "20000")
    reports[label] = (code, stdout.replace(str(folder).encode(), b"<folder>").replace(str(out).encode(), b"<index>"), stderr)
names_same, differ, count = same_tree(work / "id-update-main-index", work / "id-update-head-index")
same_report = reports["main"] == reports["head"]
failures += (not names_same) or bool(differ) or not same_report
print(f"update with caps: exit {reports['head'][0]}; report identical {same_report}; index files {count}: same names {names_same}, byte-different {differ}")
print(f"   head's report: {reports['head'][1].decode()[:600]}")
print(f"failures: {failures}")
