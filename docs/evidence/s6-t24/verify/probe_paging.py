#!/usr/bin/env python3
"""S6-T24 verifier probe: paging, cursors and the time budget, through `searchd scan` (index and folder).

Usage: python3 -I probe_paging.py SEARCHD WORKDIR
WORKDIR gets a generated folder, its index, a second folder and index, and a big folder for the budget.
Every check prints one line: OK or FAIL, with what was seen.
"""
import json
import os
import random
import shutil
import subprocess
import sys
from pathlib import Path

searchd, work = sys.argv[1], Path(sys.argv[2])
rng = random.Random(7)
failures = 0


def check(ok, what):
    global failures
    if not ok:
        failures += 1
    print(("OK   " if ok else "FAIL ") + what)


def sd(*argv):
    return subprocess.run([searchd, *argv], capture_output=True)


def page(src_args, pattern, *flags, cursor=None):
    argv = ["scan", *src_args, pattern, "--json", *flags]
    if cursor:
        argv += ["--cursor", cursor]
    done = sd(*argv)
    if done.returncode != 0:
        return None, done.stderr.decode().strip(), done.returncode
    return json.loads(done.stdout), None, 0


def all_pages(src_args, pattern, *flags, limit=100000):
    hits, cursor, pages, counts, stops = [], None, 0, {"files_scanned": 0, "files_matched": 0, "files_capped": 0, "bytes_scanned": 0}, 0
    while True:
        answer, error, code = page(src_args, pattern, *flags, cursor=cursor)
        if answer is None:
            return {"error": error, "pages": pages, "hits": hits}
        pages += 1
        if answer["next_cursor"] is not None and answer["next_cursor"] == cursor:
            return {"error": "the cursor handed back is the one sent", "pages": pages, "hits": hits}
        hits += [(h["root_id"], h["path"], h["line"], tuple(map(tuple, h["match_offsets"]))) for h in answer["hits"]]
        for key in counts:
            counts[key] += answer[key]
        stops += answer["stopped"] == "time"
        cursor = answer["next_cursor"]
        if cursor is None or pages >= limit:
            return {"hits": hits, "pages": pages, "counts": counts, "stops": stops, "last": answer}


# ---- the folder: 40 files, hits spread unevenly, CRLF, CR-only, a BOM, no final newline, empty files.
folder = work / "pg-folder"
if folder.exists():
    shutil.rmtree(folder)
folder.mkdir(parents=True)
for n in range(40):
    lines = []
    for _ in range(rng.randint(0, 60)):
        words = [rng.choice(["tide", "pool", "TS-0142", "142.50", "x", "y", "zz", "Tide", "tide_pool"]) for _ in range(rng.randint(0, 6))]
        lines.append(" ".join(words))
    sep = ["\n", "\r\n", "\r"][n % 3]
    data = sep.join(lines) + (sep if n % 4 else "")
    raw = data.encode()
    if n == 5:
        raw = b"\xef\xbb\xbf" + raw
    sub = folder / ("sub" if n % 2 else "") / f"f{n:02d}.txt"
    sub.parent.mkdir(parents=True, exist_ok=True)
    sub.write_bytes(raw)
index = work / "pg-index"
if index.exists():
    shutil.rmtree(index)
done = sd("index", str(folder), "--out", str(index))
check(done.returncode == 0, f"index the folder (exit {done.returncode})")

for src_name, src in (("index", [str(index)]), ("folder", ["--folder", str(folder)])):
    for pattern, flags in (("tide", []), ("\\d+", ["--regex"]), ("Tide", ["--word"])):
        full = all_pages(src, pattern, *flags, "--page-size", "100", "--max-per-file", "1000", "--time-ms", "30000")
        check("error" not in full, f"{src_name} {pattern!r}: the full answer ({len(full['hits'])} hits, {full['pages']} pages)")
        for size in (1, 2, 7, 100):
            got = all_pages(src, pattern, *flags, "--page-size", str(size), "--max-per-file", "1000", "--time-ms", "30000")
            same = got.get("hits") == full["hits"] and len(set(got["hits"])) == len(got["hits"])
            check(same and got.get("counts") == full["counts"],
                  f"{src_name} {pattern!r} page size {size}: {len(got.get('hits', []))} hits in {got['pages']} pages, each once, counts {got.get('counts')}")
        # max_hits_per_file 3 across page boundaries: the first three of each file, files_capped right.
        per_file = {}
        for hit in full["hits"]:
            per_file.setdefault(hit[1], []).append(hit)
        want = [h for path in per_file for h in per_file[path][:3]]
        want_capped = sum(1 for path in per_file if len(per_file[path]) > 3)
        for size in (1, 2, 7):
            got = all_pages(src, pattern, *flags, "--page-size", str(size), "--max-per-file", "3", "--time-ms", "30000")
            check(got.get("hits") == want and got["counts"]["files_capped"] == want_capped,
                  f"{src_name} {pattern!r} max 3 per file, page size {size}: {len(got.get('hits', []))} hits (want {len(want)}), capped {got.get('counts', {}).get('files_capped')} (want {want_capped})")

# index and folder give the same hits
a = all_pages([str(index)], "\\w+\\.\\d", "--regex", "--page-size", "100", "--max-per-file", "1000")
b = all_pages(["--folder", str(folder)], "\\w+\\.\\d", "--regex", "--page-size", "100", "--max-per-file", "1000")
check(a["hits"] == b["hits"] and a["counts"] == b["counts"], f"index scan = folder scan ({len(a['hits'])} hits, counts {a['counts']} / {b['counts']})")

# ---- cursors
first, _, _ = page([str(index)], "tide", "--page-size", "2")
cursor = first["next_cursor"]
parts = cursor.split(":")
print(f"     an index cursor: {cursor}")


def refused(src, pattern, flags, cur, expect):
    answer, error, code = page(src, pattern, *flags, cursor=cur)
    ok = answer is None and expect in (error or "")
    check(ok, f"cursor {cur!r} with {pattern!r} {flags}: {'refused: ' + error if error else 'ANSWERED, ' + str(len(answer['hits'])) + ' hits'} (want '{expect}')")


refused([str(index)], "pool", ["--page-size", "2"], cursor, "cursor does not belong to this request")
refused([str(index)], "tide", ["--page-size", "2", "--case", "sensitive"], cursor, "cursor does not belong to this request")
refused([str(index)], "tide", ["--page-size", "2", "--context", "1"], cursor, "cursor does not belong to this request")
refused([str(index)], "tide", ["--page-size", "2", "--glob", "*.txt"], cursor, "cursor does not belong to this request")
ans, err, _ = page([str(index)], "tide", "--page-size", "5", "--time-ms", "100", cursor=cursor)
check(ans is not None, "the same request with another page size and budget takes the cursor")
tampered_hash = ":".join([parts[0], format(int(parts[1], 16) ^ 1, "016x"), *parts[2:]])
refused([str(index)], "tide", ["--page-size", "2"], tampered_hash, "cursor does not belong to this request")
refused([str(index)], "tide", ["--page-size", "2"], ":".join([str(int(parts[0]) + 1), *parts[1:]]), "stale cursor")
for bad in ("", "x", "1:2:3:4", ":".join(parts + ["0"]), ":".join(parts[:3] + ["0", parts[4]]),
            ":".join(parts[:2] + ["99999", *parts[3:]]), ":".join(parts[:4] + ["51"]),
            ":".join(parts[:2] + ["-1", *parts[3:]]), ":".join(parts[:3] + ["99999999999", parts[4]])):
    refused([str(index)], "tide", ["--page-size", "2"], bad, "")
# a folder cursor on the index and the other way round
fpage, _, _ = page(["--folder", str(folder)], "tide", "--page-size", "2")
refused([str(index)], "tide", ["--page-size", "2"], fpage["next_cursor"], "stale cursor")
refused(["--folder", str(folder)], "tide", ["--page-size", "2"], cursor, "stale cursor")
# non-canonical numbers in a cursor
plus = ":".join(parts[:2] + ["+" + parts[2], *parts[3:]])
ans, err, _ = page([str(index)], "tide", "--page-size", "2", cursor=plus)
print(f"     cursor with '+' before the file ordinal: {'answered' if ans else 'refused: ' + err}")

# a cursor from another index with the same generation
other = work / "pg-folder2"
if other.exists():
    shutil.rmtree(other)
other.mkdir()
for n in range(3):
    (other / f"o{n}.txt").write_text("tide\n" * 4)
other_index = work / "pg-index2"
if other_index.exists():
    shutil.rmtree(other_index)
sd("index", str(other), "--out", str(other_index))
ans, err, _ = page([str(other_index)], "tide", "--page-size", "2", cursor=cursor)
print(f"     a cursor of index 1 (generation {parts[0]}) on index 2: {'ANSWERED with ' + str(len(ans['hits'])) + ' hits, generation ' + str(ans['generation']) if ans else 'refused: ' + err}")

# stale after a publish
sd("index", str(folder), "--out", str(index))
refused([str(index)], "tide", ["--page-size", "2"], cursor, "stale cursor")
# a folder cursor after a file is added, and after an edit that keeps the path
fp1, _, _ = page(["--folder", str(folder)], "tide", "--page-size", "2")
(folder / "zz-new.txt").write_text("tide\n")
refused(["--folder", str(folder)], "tide", ["--page-size", "2"], fp1["next_cursor"], "stale cursor")
fp2, _, _ = page(["--folder", str(folder)], "tide", "--page-size", "2")
(folder / "zz-new.txt").write_text("tide tide\ntide\n")
ans, err, _ = page(["--folder", str(folder)], "tide", "--page-size", "2", cursor=fp2["next_cursor"])
check(ans is not None, "a folder cursor after an edit that keeps every path is taken (documented, ruling O-4)")

# ---- budget
for bad in ("0", "30001", "-1", "x"):
    done = sd("scan", str(index), "tide", "--time-ms", bad)
    check(done.returncode == 2, f"--time-ms {bad}: exit {done.returncode}, {done.stderr.decode().strip()[:90]}")
big = work / "pg-big"
if not big.exists():
    big.mkdir()
    for n in range(300):
        lines = [" ".join(rng.choice(["alpha", "beta", "gamma", "delta", "x9", "q1.5", "tide"]) for _ in range(12)) for _ in range(400)]
        (big / f"b{n:03d}.txt").write_text("\n".join(lines) + "\n")
full = all_pages(["--folder", str(big)], "q1\\.5 (tide|x9) x9", "--regex", "--page-size", "100", "--max-per-file", "1000", "--time-ms", "30000")
check("error" not in full, f"big folder, q1\\.5 (tide|x9) x9: {len(full['hits'])} hits in {full['pages']} pages at budget 30000")
tiny = all_pages(["--folder", str(big)], "q1\\.5 (tide|x9) x9", "--regex", "--page-size", "100", "--max-per-file", "1000", "--time-ms", "1", limit=20000)
check("error" not in tiny and tiny["hits"] == full["hits"],
      f"big folder at --time-ms 1: {len(tiny['hits'])} hits in {tiny['pages']} pages, {tiny.get('stops')} stopped by time, every hit once in order: {tiny['hits'] == full['hits']}; error: {tiny.get('error')}")

# ---- the O-7 case: a line that alone outlasts the budget
o7 = work / "pg-o7"
o7.mkdir(exist_ok=True)
(o7 / "a.txt").write_text("tide\n" + "a" * (1 << 20) + "\ntide\n")
ans, err, code = page(["--folder", str(o7)], "tide|a(.*b)?", "--regex", "--time-ms", "50", "--page-size", "100")
print(f"     O-7: tide|a(.*b)? at --time-ms 50, first page: {'answered, ' + str(len(ans['hits'])) + ' hits, stopped ' + ans['stopped'] + ', cursor ' + str(ans['next_cursor']) if ans else 'refused: ' + err}")
if ans and ans["next_cursor"]:
    ans2, err2, code2 = page(["--folder", str(o7)], "tide|a(.*b)?", "--regex", "--time-ms", "50", "--page-size", "100", cursor=ans["next_cursor"])
    check(ans2 is None and "outlasts" in err2, f"O-7: the next page is refused, exit {code2}: {err2}")
    ans3, err3, _ = page(["--folder", str(o7)], "tide|a(.*b)?", "--regex", "--time-ms", "30000", "--page-size", "100", cursor=ans["next_cursor"])
    print(f"     O-7: the same cursor at --time-ms 30000: {'answered, ' + str(len(ans3['hits'])) + ' hits' if ans3 else 'refused: ' + err3}")

# ---- a tiny budget where the first line of a page is quick but the file read is not
slow = work / "pg-slowread"
slow.mkdir(exist_ok=True)
(slow / "a.txt").write_bytes(("x" * 5000 + "\n").encode() + b"y\n" * (4 << 20))
ans, err, code = page(["--folder", str(slow)], "x\\d", "--regex", "--time-ms", "1")
print(f"     an 8 MiB file whose first line is 5,000 x's, x\\d at --time-ms 1: {'answered, stopped ' + ans['stopped'] if ans else 'refused: ' + err}")

print(f"failures: {failures}")
