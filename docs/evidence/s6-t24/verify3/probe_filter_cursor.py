#!/usr/bin/env python3
"""S6-T24 verifier probe (Verdict 3): the cursor's new meaning. The file in a cursor is an ordinal among all the
files the caller may see, counted before `path_prefix` and `name_glob` (docs/scan.md, "Paging").

1. Exactly once. A folder of 600 files in 6 folders (names drawn with seed 2412: ASCII, `é`, `த`), each holding
   1-4 lines with `tide`. For 12 scopes (globs, prefixes, both), over the folder and over its index, every page
   is followed at page sizes 1, 3 and 100, `--max-per-file` 1 and 2, `--time-ms` 1 and 30000; the hits of all
   pages must be exactly those of one page of 1,000 per file at 30,000 ms, each (path, line) once, and those must
   be exactly the no-scope answer's hits whose path is in the scope (tested here).
2. Stops among non-matching names. The probe_glob3 folder of 20,000 names (`a` x 245 + 5 digits + `.txt`) and
   its index, glob `*7.txt` (2,000 files) and `*19999.txt` (one file, the last), page size 100, `--time-ms 1`:
   pages are followed to the end (at most 5,000), and every matching file must be listed once.
3. Adds and removes between pages (ruling O-4). Over the folder: a first page with a glob, then a file added
   that matches, one added that does not, one removed that does not match, one renamed; the next page must be
   refused `stale cursor` each time. Over the index: `index --update` publishes a new generation; the cursor is
   refused `stale cursor`.
4. A cursor used with another filter: glob A's cursor with glob B, with no glob, with a prefix; prefix A's with
   prefix B; must be refused `cursor does not belong to this request`. A cursor whose file ordinal is edited to
   point at any file (same request, so it hashes alike) must answer from that file on, listing only in-scope
   files; one past the last file must be refused as malformed.

Usage: python3 -I probe_filter_cursor.py SEARCHD WORKDIR GLOB_WORKDIR
GLOB_WORKDIR holds probe_glob3.py's `g-ascii` and `g-ascii.idx`. Every call bounded (300 s), every loop bounded.
"""
import json
import random
import subprocess
import sys
from pathlib import Path

searchd, work, gwork = sys.argv[1], Path(sys.argv[2]), Path(sys.argv[3])
failures = 0


def check(ok, what):
    global failures
    failures += not ok
    print(("OK   " if ok else "FAIL ") + what)


def sd(*argv):
    return subprocess.run([searchd, *map(str, argv)], capture_output=True, timeout=300)


def page(src, pattern, flags, cursor=None):
    argv = ["scan", *src, pattern, "--json", *flags] + (["--cursor", cursor] if cursor else [])
    done = sd(*argv)
    if done.returncode != 0:
        return None, done.stderr.decode().strip()
    return json.loads(done.stdout), None


def follow(src, pattern, flags, limit=5000):
    hits, cursor, pages, stops = [], None, 0, 0
    for _ in range(limit):
        answer, error = page(src, pattern, flags, cursor)
        if answer is None:
            return None, error, pages, stops
        pages += 1
        stops += answer["stopped"] == "time"
        hits += [(h["path"], h["line"]) for h in answer["hits"]]
        cursor = answer["next_cursor"]
        if not cursor:
            return hits, None, pages, stops
    return None, "did not end", pages, stops


def glob_ok(glob, name):
    import re
    return re.fullmatch("".join(".*" if c == "*" else "." if c == "?" else re.escape(c) for c in glob), name, re.DOTALL) is not None


def in_scope(path, prefix, glob):
    if prefix and not path.startswith(prefix):
        return False
    return glob is None or glob_ok(glob, path.rsplit("/", 1)[-1])


# 1. exactly once
rng = random.Random(2412)
folder = work / "fc-folder"
if not folder.exists():
    for d in ("alpha", "beta", "gamma", "délta", "தமிழ்", "z"):
        (folder / d).mkdir(parents=True)
    made = set()
    for _ in range(5000):
        if len(made) >= 600:
            break
        d = rng.choice(("alpha", "beta", "gamma", "délta", "தமிழ்", "z"))
        stem = "".join(rng.choice("abxyé0123த") for _ in range(rng.randint(1, 8)))
        name = f"{d}/{stem}.{rng.choice(('txt', 'md', 'log'))}"
        if name in made:
            continue
        made.add(name)
        lines = ["tide" if rng.random() < 0.5 else "other" for _ in range(rng.randint(1, 6))]
        (folder / name).write_text("\n".join(lines + ["tide"]) + "\n")
index = work / "fc-index"
if not index.exists():
    subprocess.run([searchd, "index", folder, "--out", index], check=True, capture_output=True, timeout=600)

scopes = [(None, "*.md"), (None, "a*"), (None, "?.txt"), (None, "*é*"), (None, "*த*"), (None, "*0*.log"),
          ("beta/", None), ("délta/", None), ("தமிழ்/", None), ("z/", "*.txt"), ("gamma/a", "*"), ("nope/", None)]
for src_label, src in (("folder", ["--folder", folder]), ("index", [index])):
    whole, error, _, _ = follow(src, "tide", ["--page-size", "100", "--max-per-file", "1000", "--time-ms", "30000"])
    for prefix, glob in scopes:
        scope = (["--path-prefix", prefix] if prefix else []) + (["--glob", glob] if glob else [])
        want = [h for h in whole if in_scope(h[0], prefix, glob)]
        one, error, _, _ = follow(src, "tide", ["--page-size", "100", "--max-per-file", "1000", "--time-ms", "30000", *scope])
        ok = one == want
        detail = []
        for size in ("1", "3", "100"):
            for per in ("1", "2"):
                for tm in ("1", "30000"):
                    got, err, pages, stops = follow(src, "tide", ["--page-size", size, "--max-per-file", per, "--time-ms", tm, *scope])
                    expect = []
                    seen_files = {}
                    for h in want:
                        seen_files[h[0]] = seen_files.get(h[0], 0) + 1
                        if seen_files[h[0]] <= int(per):
                            expect.append(h)
                    same = got == expect and got is not None and len(set(got)) == len(got)
                    ok = ok and same
                    if not same and len(detail) < 2:
                        detail.append(f"size {size} per {per} time {tm}: {len(got) if got is not None else err} against {len(expect)}")
        check(ok, f"{src_label}, prefix {prefix!r} glob {glob!r}: {len(want)} hits in scope; one page equal {one == want}; "
                  f"18 pagings (sizes 1/3/100, per-file 1/2, 1 ms/30,000 ms) each list every hit once {detail}")

# 2. stops among names that do not match
gfolder, gindex = gwork / "g-ascii", gwork / "g-ascii.idx"
for src_label, src in (("folder", ["--folder", gfolder]), ("index", [gindex])):
    for glob, count in (("*7.txt", 2000), ("*19999.txt", 1)):
        got, error, pages, stops = follow(src, "tide", ["--page-size", "100", "--time-ms", "1", "--glob", glob])
        paths = [h[0] for h in got] if got is not None else []
        check(got is not None and len(paths) == count == len(set(paths)) and all(glob_ok(glob, p.rsplit("/", 1)[-1]) for p in paths),
              f"20,000 names, {src_label}, glob {glob} at --time-ms 1: {len(paths) if got is not None else error} files listed "
              f"(want {count}, each once) in {pages} pages, {stops} stopped by time")

# 3. adds and removes between pages
def first_cursor(src, glob):
    answer, error = page(src, "tide", ["--page-size", "1", "--glob", glob, "--time-ms", "30000"])
    return answer["next_cursor"] if answer else None


mfolder = work / "fc-mut"
if not mfolder.exists():
    mfolder.mkdir(parents=True)
    for i in range(20):
        (mfolder / f"m{i:02d}.md").write_text("tide\n")
        (mfolder / f"t{i:02d}.txt").write_text("tide\n")
changes = [("added, matching", lambda: (mfolder / "m99.md").write_text("tide\n")),
           ("added, not matching", lambda: (mfolder / "t99.txt").write_text("tide\n")),
           ("removed, not matching", lambda: (mfolder / "t05.txt").unlink()),
           ("renamed, matching", lambda: (mfolder / "m07.md").rename(mfolder / "m07b.md"))]
for label, change in changes:
    cursor = first_cursor(["--folder", mfolder], "*.md")
    change()
    answer, error = page(["--folder", mfolder], "tide", ["--page-size", "1", "--glob", "*.md", "--time-ms", "30000"], cursor)
    check(answer is None and "stale cursor" in (error or ""), f"folder, a file {label} between pages with glob *.md: {error or 'ANSWERED'}")
mindex = work / "fc-mut.idx"
if not mindex.exists():
    subprocess.run([searchd, "index", mfolder, "--out", mindex], check=True, capture_output=True, timeout=600)
cursor = first_cursor([mindex], "*.md")
(mfolder / "m98.md").write_text("tide\n")
done = sd("index", mfolder, "--out", mindex, "--update")
answer, error = page([mindex], "tide", ["--page-size", "1", "--glob", "*.md", "--time-ms", "30000"], cursor)
check(answer is None and "stale cursor" in (error or ""), f"index, a new generation between pages (update exit {done.returncode}): {error or 'ANSWERED'}")

# 4. a cursor with another filter, and edited ordinals
src = [index]
base = ["--page-size", "1", "--time-ms", "30000"]
a, _ = page(src, "tide", base + ["--glob", "*.md"])
p, _ = page(src, "tide", base + ["--path-prefix", "beta/"])
for label, cur, flags in (("glob *.md's cursor with glob *.txt", a["next_cursor"], ["--glob", "*.txt"]),
                          ("glob *.md's cursor with no glob", a["next_cursor"], []),
                          ("glob *.md's cursor with prefix beta/", a["next_cursor"], ["--path-prefix", "beta/"]),
                          ("prefix beta/'s cursor with prefix gamma/", p["next_cursor"], ["--path-prefix", "gamma/"]),
                          ("prefix beta/'s cursor with prefix beta/ and glob *", p["next_cursor"], ["--path-prefix", "beta/", "--glob", "*"])):
    answer, error = page(src, "tide", base + flags, cur)
    check(answer is None and "does not belong" in (error or ""), f"{label}: {error or 'ANSWERED'}")
parts = a["next_cursor"].split(":")
print(f"     a glob cursor over the index: {a['next_cursor']}")
whole, _, _, _ = follow(src, "tide", ["--page-size", "100", "--max-per-file", "1000", "--time-ms", "30000"])
files = sorted({h[0] for h in whole})
total_files = len(files)
md_hits = [h for h in whole if h[0].endswith(".md")]
for ordinal in ("0", "1", "17", str(total_files - 1), str(total_files)):
    # Verdict 3, a probe fault fixed: the edited cursor is sent with the request that made it (page size 1, the
    # default per-file cap); the first run sent another page size and cap, which rightly refused it.
    cur = ":".join(parts[:2] + [ordinal, "1", "0"])
    got, cursor = [], cur
    for _ in range(2000):
        answer, error = page(src, "tide", base + ["--glob", "*.md"], cursor)
        if answer is None:
            break
        got += [(h["path"], h["line"]) for h in answer["hits"]]
        cursor = answer["next_cursor"]
        if not cursor:
            break
    expect = [h for h in md_hits if files.index(h[0]) >= int(ordinal)]
    check(answer is not None and got == expect,
          f"glob *.md cursor edited to file ordinal {ordinal}, followed to the end: "
          f"{(str(len(got)) + ' hits, the *.md hits of files from that ordinal: ' + str(got == expect) + f' (want {len(expect)})') if answer else error}")
for ordinal in (str(total_files + 1), "99999999"):
    cur = ":".join(parts[:2] + [ordinal, "1", "0"])
    answer, error = page(src, "tide", ["--page-size", "1", "--time-ms", "30000", "--glob", "*.md"], cur)
    check(answer is None, f"glob *.md cursor edited to file ordinal {ordinal} (past the {total_files} files): {error or 'ANSWERED'}")
print(f"failures: {failures}")
