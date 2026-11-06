#!/usr/bin/env python3
"""Capture every page `ss_find` returns for a fixed query set, one line per page.

S4-T17 bar 5(d): ranking `find`'s hits through an index list must not change a
single byte of any page. Run this once per library (each against the same
--work, so every library reads the same snapshot bytes), then `cmp` the
output files.

    python3 -I scripts/capture_find_pages.py --lib LIB --searchd SEARCHD \\
        --work WORKDIR --out OUT.jsonl [--raw-dir DIR]
    python3 -I scripts/capture_find_pages.py --s4t16 --lib LIB --searchd SEARCHD --work WORKDIR
    cmp OUT-before.jsonl OUT-after.jsonl

Every query is paged by `next_cursor` to its end, at most `PAGE_CAP` (200)
pages; a query that still has a cursor after that many pages is recorded as
capped (a line saying so), never silently cut. Each output line: the case,
the request, the page number, the page's hit count and `files` count, the
output's length and SHA-256 (a 10k page lists every matching file in
`files`, several hundred KB, so the outputs themselves are not kept), or
`ERROR <ss_last_error()>`. The file's SHA-256 and a digest over all outputs
in order are printed. --raw-dir keeps the first page of each case verbatim,
so a differing digest can be diffed.

The query set (ruled at S4-T17's plan):

* the 10,000-file `scripts/gen_timing_corpus.py` corpus, indexed by `searchd
  index`, page size 50: words `the` (common), `bababa` (rare), `the and`
  (two words); prefix `th*` and `babab*` (short and rare); phrase
  `"of the"` and `"to the"` (both return hits: the script stops if they do
  not); and `the`, `"of the"` at page size 7 under `path_prefix` `group-4`;
* `fixtures/family-folder` as three host roots plus the labelled `private`
  root (`capture_query_outputs.family_batch`, through `ss_apply_changes`):
  the pack's scenario queries in their kinds, its phrase and prefix cases in
  their modes, the words of its file paths, and `the`, `and`, `th*`; under
  five scopes (all, `roots: [school]`, `roots: [home, laptop]`,
  `principal_labels: [adults]`, `path_prefix: home/trips/`); page sizes 7
  and 50.

--s4t16 repeats S4-T16's 84-page check exactly (its six queries `the`,
`doc`, `the doc` as words, `th*` prefix, `the doc` phrase, `group` words; page
size 50; at most 40 pages each; SHA-256 over the outputs concatenated): on
the 10k corpus `doc`, `the doc` (both modes) and `group` return no hits (one
page each) and `the` and `th*` stop at 40 pages, 40 + 40 + 4 pages in all.

Only the standard library plus `capture_query_outputs.py` (beside this
script) is used. Invented text only.
"""

from __future__ import annotations

import argparse
import ctypes
import hashlib
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import capture_query_outputs as cqo  # noqa: E402

PAGE_CAP = 200
FAMILY_SCOPES = (
    ("all", {}),
    ("roots-school", {"roots": ["school"]}),
    ("roots-home-laptop", {"roots": ["home", "laptop"]}),
    ("labels-adults", {"principal_labels": ["adults"]}),
    ("prefix-home-trips", {"path_prefix": "home/trips/"}),
)
C10K_CASES = [
    ("the", "words", 50, {}),
    ("bababa", "words", 50, {}),
    ("the and", "words", 50, {}),
    ("th*", "prefix", 50, {}),
    ("babab*", "prefix", 50, {}),
    ("of the", "phrase", 50, {}),
    ("to the", "phrase", 50, {}),
    ("the", "words", 7, {"path_prefix": "group-4"}),
    ("of the", "phrase", 7, {"path_prefix": "group-4"}),
]
# Ruling 5: these must return hits on the 10k corpus.
MUST_HIT = {("of the", "phrase"), ("to the", "phrase"), ("bababa", "words"), ("the and", "words"), ("babab*", "prefix")}
S4T16_QUERIES = (("the", "words"), ("doc", "words"), ("the doc", "words"), ("th*", "prefix"), ("the doc", "phrase"), ("group", "words"))


class Finder:
    def __init__(self, path: str) -> None:
        self.library = cqo.Library(path)
        lib = self.library.lib
        lib.ss_find.argtypes = [ctypes.c_void_p, ctypes.c_char_p]
        lib.ss_find.restype = ctypes.c_void_p
        self.lib = lib

    def find(self, handle, request: dict) -> str | None:
        pointer = self.lib.ss_find(handle, json.dumps(request).encode())
        if not pointer:
            return None
        try:
            return ctypes.string_at(pointer).decode()
        finally:
            self.lib.ss_free(pointer)


def snapshot_10k(args) -> Path:
    folder = cqo.make_corpus(args.work, "c10k", 10000)
    return cqo.ensure_index(args.searchd, folder, args.work / "snap-c10k")


def s4t16(args) -> int:
    finder = Finder(args.lib)
    handle = finder.library.open(snapshot_10k(args))
    digest = hashlib.sha256()
    pages = 0
    for query, mode in S4T16_QUERIES:
        cursor = None
        for _ in range(40):
            request = {"query": query, "mode": mode, "page_size": 50}
            if cursor:
                request["cursor"] = cursor
            output = finder.find(handle, request)
            if output is None:
                break
            digest.update(output.encode())
            pages += 1
            cursor = json.loads(output).get("next_cursor")
            if not cursor:
                break
    finder.lib.ss_close(handle)
    print(f"s4t16 pages {pages} sha256={digest.hexdigest()}")
    return 0


def family_cases() -> list[tuple[str, str]]:
    judgments = json.loads((cqo.FAMILY / "judgments.json").read_text(encoding="utf-8"))
    cases: list[tuple[str, str]] = []
    for case in judgments["scenarios"]:
        if case.get("query") and case.get("kind") in ("words", "phrase", "prefix"):
            cases.append((case["query"], case["kind"]))
    cases += [(case["query"], "phrase") for case in judgments["phrase"]]
    cases += [(case["query"], "prefix") for case in judgments["prefix"]]
    words: set[str] = set()
    for root_id in cqo.FAMILY_ROOTS:
        base = cqo.FAMILY / root_id
        for path in base.rglob("*"):
            if path.is_file():
                rel = path.relative_to(base).as_posix()
                words.update(rel.replace("/", " ").replace(".", " ").replace("-", " ").lower().split())
    cases += [(word, "words") for word in sorted(words)]
    cases += [("the", "words"), ("and", "words"), ("th*", "prefix")]
    seen: set[tuple[str, str]] = set()
    return [case for case in cases if not (case in seen or seen.add(case))]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--lib", required=True)
    parser.add_argument("--searchd", required=True)
    parser.add_argument("--work", type=Path, required=True)
    parser.add_argument("--out", type=Path)
    parser.add_argument("--raw-dir", type=Path, help="keep each case's first page verbatim here")
    parser.add_argument("--s4t16", action="store_true", help="S4-T16's 84-page digest only")
    args = parser.parse_args()
    args.work.mkdir(parents=True, exist_ok=True)
    if args.s4t16:
        return s4t16(args)
    if args.out is None:
        parser.error("--out is required")
    if args.raw_dir:
        args.raw_dir.mkdir(parents=True, exist_ok=True)

    finder = Finder(args.lib)
    lines: list[dict] = []
    digest = hashlib.sha256()
    totals = {"cases": 0, "pages": 0, "hits": 0, "errors": 0, "capped": 0}

    def run_case(label: str, handle, query: str, mode: str, page_size: int, scope: dict) -> int:
        totals["cases"] += 1
        cursor = None
        hits_seen = 0
        for page in range(PAGE_CAP):
            request = dict(scope, query=query, mode=mode, page_size=page_size)
            if cursor:
                request["cursor"] = cursor
            output = finder.find(handle, request)
            if output is None:
                error = "ERROR " + finder.lib.ss_last_error().decode()
                digest.update(error.encode())
                lines.append({"case": label, "request": request, "page": page, "output": error})
                totals["errors"] += 1
                return hits_seen
            digest.update(output.encode())
            data = json.loads(output)
            if page == 0 and args.raw_dir:
                (args.raw_dir / (label.replace("/", "_").replace(" ", "_") + ".json")).write_text(output, encoding="utf-8")
            hits_seen += len(data["hits"])
            totals["pages"] += 1
            totals["hits"] += len(data["hits"])
            lines.append({
                "case": label,
                "request": request,
                "page": page,
                "hits": len(data["hits"]),
                "files": len(data["files"]),
                "bytes": len(output.encode()),
                "sha256": hashlib.sha256(output.encode()).hexdigest(),
            })
            cursor = data.get("next_cursor")
            if not cursor:
                return hits_seen
        lines.append({"case": label, "capped_after_pages": PAGE_CAP, "next_cursor": cursor})
        totals["capped"] += 1
        return hits_seen

    handle = finder.library.open(snapshot_10k(args))
    for number, (query, mode, page_size, scope) in enumerate(C10K_CASES):
        hits = run_case(f"c10k:{number}:{mode}:{page_size}", handle, query, mode, page_size, scope)
        if (query, mode) in MUST_HIT and not scope and hits == 0:
            raise SystemExit(f"{mode} {query!r} returned no hits on the 10k corpus")
    finder.lib.ss_close(handle)

    snapshot = args.work / "snap-family-find"
    if not snapshot.exists():
        finder.library.apply_changes(snapshot, cqo.family_batch(), {})
    handle = finder.library.open(snapshot)
    for scope_name, scope in FAMILY_SCOPES:
        for number, (query, mode) in enumerate(family_cases()):
            for page_size in (7, 50):
                run_case(f"family:{scope_name}:{number}:{mode}:{page_size}", handle, query, mode, page_size, scope)
    finder.lib.ss_close(handle)

    with args.out.open("w", encoding="utf-8") as stream:
        for line in lines:
            stream.write(json.dumps(line, ensure_ascii=False, sort_keys=True) + "\n")
    file_digest = hashlib.sha256(args.out.read_bytes()).hexdigest()
    print(f"captured {totals['cases']} cases, {totals['pages']} pages, {totals['hits']} hits, {totals['errors']} error outputs, "
          f"{totals['capped']} capped at {PAGE_CAP} pages; outputs sha256={digest.hexdigest()} file sha256={file_digest}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
