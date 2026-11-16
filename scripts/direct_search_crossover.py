#!/usr/bin/env python3
"""S6-T2 ruling 4: where `searchd search <folder>` stops paying for itself.

For each folder, three ways to answer one query, each run `--runs` times
(default 5), in this order per run so neither is always warm or cold:

  search   `searchd search <folder> <query>` (build in memory, answer, exit)
  index+q  `searchd index <folder> --out X --filename-index` then
           `searchd query X <query>` (X fresh each run, removed afterwards)
  query    `searchd query X <query>` on an index built once beforehand

Wall time is `time.perf_counter()` around each process (it includes the fork
and exec of `/usr/bin/time`, about a millisecond); peak memory is
`/usr/bin/time -l`'s "maximum resident set size". For `index+q` the time is the
sum of the two processes and the memory the larger of the two peaks. Medians
and ranges are reported; nothing is cached between runs beyond what the
operating system's file cache holds (every folder is read once before the
first run, so all three see a warm file cache).

Refuses to start (exit 3) when the 5-minute load average is 4.0 or more or
the lock directory given by `--lock` exists, and records the load before and
after every folder so a disturbed batch can be rerun.

Usage:
  python3 -I scripts/direct_search_crossover.py --searchd <ReleaseSmall searchd>
      --work <scratch dir> --folder NAME=PATH [--folder NAME=PATH ...]
      [--query TEXT] [--field content|filename|both] [--runs 5] [--lock DIR]
      [--json OUT]
  python3 -I scripts/direct_search_crossover.py --prose <dir> [--prose-files N]
      writes the invented ordinary-prose folder used for the prose row and exits.
  python3 -I scripts/direct_search_crossover.py --table <json>
      prints a --json result as the Markdown table of docs/direct-search.md.
"""
import argparse
import json
import os
import random
import shutil
import statistics
import subprocess
import sys
import time
from pathlib import Path

PROSE_WORDS = (
    "the a an of and to in for with on at by from about after before over under "
    "is was are were be been has had have will would can could should may might "
    "we they she he it you our their his her its this that these those some every "
    "morning evening week month year day night spring summer autumn winter "
    "garden kitchen library school market station river bridge village road hill "
    "letter list note plan recipe meeting visit trip lesson project report "
    "bread soup apples tomatoes lentils rice tea coffee honey flour butter "
    "bicycle train bus ferry umbrella lantern blanket notebook pencil map "
    "neighbour teacher friend cousin grandmother uncle baker gardener "
    "bring carry cook clean fix paint plant read write walk wait visit borrow "
    "return remember forget finish start open close share mend count "
    "early late quiet busy warm cold bright dark small large old new careful "
    "slowly quickly together again always never often sometimes usually"
).split()


def write_prose(out: Path, files: int) -> None:
    """An invented folder of ordinary prose: Markdown notes with headings and
    short paragraphs drawn from a small everyday vocabulary (seeded, so the
    same folder every time)."""
    rng = random.Random(20261116)
    out.mkdir(parents=True, exist_ok=True)
    for index in range(files):
        sub = out / f"notes-{index // 50:03d}"
        sub.mkdir(exist_ok=True)
        lines = [f"# Note {index}: the {rng.choice(PROSE_WORDS)} {rng.choice(PROSE_WORDS)}", ""]
        for _ in range(rng.randint(2, 6)):
            lines.append(f"## {rng.choice(PROSE_WORDS).capitalize()} and {rng.choice(PROSE_WORDS)}")
            lines.append("")
            sentences = []
            for _ in range(rng.randint(3, 8)):
                words = [rng.choice(PROSE_WORDS) for _ in range(rng.randint(6, 18))]
                sentences.append(" ".join(words).capitalize() + ".")
            lines.append(" ".join(sentences))
            lines.append("")
        (sub / f"note-{index:05d}.md").write_text("\n".join(lines), encoding="utf-8")


def load_ok(lock: Path) -> tuple:
    five = os.getloadavg()[1]
    return five < 4.0 and not lock.exists(), five


def timed(argv: list) -> tuple:
    start = time.perf_counter()
    done = subprocess.run(["/usr/bin/time", "-l", *argv], capture_output=True, timeout=540)
    wall = time.perf_counter() - start
    if done.returncode != 0:
        raise SystemExit(f"failed ({done.returncode}): {' '.join(map(str, argv))}\n{done.stderr.decode()[-2000:]}")
    rss = None
    for line in done.stderr.decode().splitlines():
        if "maximum resident set size" in line:
            rss = int(line.split()[0])
    if rss is None:
        raise SystemExit("no maximum resident set size in /usr/bin/time -l output")
    return wall, rss


def summary(values: list) -> dict:
    return {"median": statistics.median(values), "min": min(values), "max": max(values), "runs": values}


def measure(searchd: str, work: Path, name: str, folder: Path, query: str, field: str, runs: int) -> dict:
    files = sum(1 for p in folder.rglob("*") if p.is_file())
    size = sum(p.stat().st_size for p in folder.rglob("*") if p.is_file())
    for p in folder.rglob("*"):  # warm the file cache for all three ways alike
        if p.is_file():
            p.read_bytes()
    standing = work / f"standing-{name}"
    if standing.exists():
        shutil.rmtree(standing)
    timed([searchd, "index", folder, "--out", standing, "--filename-index"])
    fresh = work / f"fresh-{name}"
    field_args = ["--search-field", field]
    rows = {"search": ([], []), "index+q": ([], []), "query": ([], [])}
    for _ in range(runs):
        wall, rss = timed([searchd, "search", folder, query, *field_args])
        rows["search"][0].append(wall)
        rows["search"][1].append(rss)
        if fresh.exists():
            shutil.rmtree(fresh)
        w1, r1 = timed([searchd, "index", folder, "--out", fresh, "--filename-index"])
        w2, r2 = timed([searchd, "query", fresh, query, *field_args])
        shutil.rmtree(fresh)
        rows["index+q"][0].append(w1 + w2)
        rows["index+q"][1].append(max(r1, r2))
        wall, rss = timed([searchd, "query", standing, query, *field_args])
        rows["query"][0].append(wall)
        rows["query"][1].append(rss)
    shutil.rmtree(standing)
    return {
        "folder": name, "files": files, "bytes": size, "query": query, "field": field,
        "ways": {way: {"wall_s": summary(w), "peak_rss_bytes": summary(r)} for way, (w, r) in rows.items()},
    }


def print_table(results: list) -> None:
    """Wall time in ms (median, range) and peak memory in MiB (median) per way."""
    print("| Folder | Files | Bytes | Load (5 min) | `search` ms | `index`+`query` ms | `query` ms | "
          "`search` MiB | `index`+`query` MiB | `query` MiB |")
    print("| --- | ---: | ---: | --- | ---: | ---: | ---: | ---: | ---: | ---: |")
    for row in results:
        ways = row["ways"]

        def ms(way):
            wall = ways[way]["wall_s"]
            return f"{wall['median'] * 1000:.1f} ({wall['min'] * 1000:.1f}–{wall['max'] * 1000:.1f})"

        def mib(way):
            return f"{ways[way]['peak_rss_bytes']['median'] / 1048576:.1f}"

        print(f"| {row['folder']} | {row['files']:,} | {row['bytes']:,} | {row['load_before']:.2f} → {row['load_after']:.2f} | "
              f"{ms('search')} | {ms('index+q')} | {ms('query')} | {mib('search')} | {mib('index+q')} | {mib('query')} |")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--searchd")
    parser.add_argument("--work", type=Path)
    parser.add_argument("--folder", action="append", default=[])
    parser.add_argument("--query", default="hybrid retrieval")
    parser.add_argument("--field", default="content", choices=("content", "filename", "both"))
    parser.add_argument("--runs", type=int, default=5)
    parser.add_argument("--lock", type=Path, default=Path("/nonexistent-lock"))
    parser.add_argument("--json", type=Path)
    parser.add_argument("--prose", type=Path)
    parser.add_argument("--prose-files", type=int, default=2000)
    parser.add_argument("--table", type=Path, help="print a --json result as a Markdown table and exit")
    args = parser.parse_args()
    if args.table:
        print_table(json.loads(args.table.read_text(encoding="utf-8")))
        return 0
    if args.prose:
        write_prose(args.prose, args.prose_files)
        print(f"wrote {args.prose_files} prose files")
        return 0
    args.work.mkdir(parents=True, exist_ok=True)
    results = []
    for spec in args.folder:
        name, _, path = spec.partition("=")
        ok, before = load_ok(args.lock)
        if not ok:
            print(f"refused: 5-minute load {before:.2f} (needs < 4.0) or lock {args.lock} present", file=sys.stderr)
            return 3
        started = time.strftime("%Y-%m-%d %H:%M:%S")
        row = measure(args.searchd, args.work, name, Path(path), args.query, args.field, args.runs)
        # Wall-clock bounds of the folder's runs, to check against `pmset -g log`
        # for a sleep inside them (perf_counter does not count sleep, but a run
        # that straddles one is disturbed and is rerun).
        row["started"], row["ended"] = started, time.strftime("%Y-%m-%d %H:%M:%S")
        row["load_before"] = before
        row["load_after"] = os.getloadavg()[1]
        results.append(row)
        ways = row["ways"]
        print(f"{row['started'][11:]}-{row['ended'][11:]} {name:>8} {row['files']:>6} files {row['bytes'] / 1e6:7.1f} MB  load {before:.2f}->{row['load_after']:.2f}  "
              + "  ".join(f"{way} {ways[way]['wall_s']['median'] * 1000:8.1f} ms "
                          f"[{ways[way]['wall_s']['min'] * 1000:.1f}-{ways[way]['wall_s']['max'] * 1000:.1f}] "
                          f"{ways[way]['peak_rss_bytes']['median'] / 1048576:6.1f} MiB" for way in ways), flush=True)
    if args.json:
        args.json.write_text(json.dumps(results, indent=1) + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    sys.exit(main())
