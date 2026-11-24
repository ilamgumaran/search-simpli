#!/usr/bin/env python3
"""S6-T24 verifier probe (Verdict 2): the 64 frozen exact-string questions, answered by a `searchd` the verifier
built (ReleaseSmall), not the Debug build `tests/test_exact_strings.py` makes for itself.

The folder is `gen_text_search_corpus.build_corpus()`, written fresh; the index is made by the same binary. Each
question is paged to the end (page size 100, max-per-file 1000, --time-ms 30000) over the index and over the
folder, and checked against the fixture: the lines in order, `case_applied`, `stopped` none, no file capped and,
where the fixture gives them, the offsets. Each question's frozen digest is checked first with the repository's
own function.

Usage: python3 -I probe_exact_strings.py REPO SEARCHD WORKDIR
"""
import json
import subprocess
import sys
from pathlib import Path

repo, searchd, work = Path(sys.argv[1]), sys.argv[2], Path(sys.argv[3])
sys.path.insert(0, str(repo / "scripts"))
import gen_text_search_corpus as corpus_mod  # noqa: E402
import exact_string_questions as questions_mod  # noqa: E402

fixture = json.loads((repo / "fixtures/text-search/exact-strings.json").read_text(encoding="utf-8"))
digests = json.loads((repo / "fixtures/text-search/exact-string-digests.json").read_text(encoding="utf-8"))
folder, index = work / "es-folder", work / "es-index"
if not folder.exists():
    for path, data in corpus_mod.build_corpus().items():
        (folder / path).parent.mkdir(parents=True, exist_ok=True)
        (folder / path).write_bytes(data)
if not index.exists():
    subprocess.run([searchd, "index", str(folder), "--out", str(index)], check=True, capture_output=True, timeout=600)
now = {q["id"]: questions_mod.question_digest(q) for q in fixture["questions"]}
print(f"{len(fixture['questions'])} questions; every digest equal to the frozen one: {now == digests['questions']} "
      f"({sum(now[k] == digests['questions'].get(k) for k in now)} of {len(digests['questions'])})")


def answer(where, request):
    hits, cursor, first, capped = [], None, None, 0
    for _ in range(10000):  # bounded paging
        args = [searchd, "scan", *where, request["pattern"], "--json", "--case", request["case"], "--page-size", "100",
                "--max-per-file", "1000", "--time-ms", "30000"]
        args += (["--regex"] if request["mode"] == "regex" else []) + (["--word"] if request["whole_word"] else [])
        args += ["--cursor", cursor] if cursor else []
        done = subprocess.run(args, capture_output=True, timeout=120)
        if done.returncode != 0:
            return None, done.stderr.decode(), 0
        page = json.loads(done.stdout)
        first = first or page
        hits += page["hits"]
        capped += page["files_capped"]
        cursor = page["next_cursor"]
        if cursor is None:
            return first, hits, capped
    return None, "paging did not end", 0


good = bad = 0
for where in ((str(index),), ("--folder", str(folder))):
    for q in fixture["questions"]:
        first, hits, capped = answer(where, q["request"])
        problems = []
        if first is None:
            problems.append(f"refused: {hits[:120]}")
        else:
            if [f"{h['path']}:{h['line']}" for h in hits] != q["expect"]["lines"]:
                problems.append("lines differ")
            if first["case_applied"] != q["expect"]["case_applied"]:
                problems.append("case_applied differs")
            if capped or first["stopped"] != "none":
                problems.append(f"capped {capped}, stopped {first['stopped']}")
            for key, spans in q["expect"].get("offsets", {}).items():
                hit = next((h for h in hits if f"{h['path']}:{h['line']}" == key), None)
                if hit is None or hit["match_offsets"] != spans:
                    problems.append(f"offsets of {key} differ")
        good += not problems
        bad += bool(problems)
        if problems:
            print(f"FAIL {q['id']} over {'index' if len(where) == 1 else 'folder'}: {problems}")
print(f"answered as frozen: {good} of {good + bad} (64 questions x index and folder)")
