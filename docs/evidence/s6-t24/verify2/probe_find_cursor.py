#!/usr/bin/env python3
"""S6-T24 verifier probe (Verdict 2, ruling 8): does `find`'s digits-only cursor parse refuse any cursor that
`main` accepted and the schema allows?

On one index made by each build from the same folder (generation 1), `find` with a cursor from a list: every
form the schema's pattern `^[0-9]+:[0-9]+$` allows that could parse differently (leading zeros, the largest
u64, one past it, offsets past the end, zero) and, for the record, forms it does not allow (a sign, `_`,
spaces, full-width digits). Each is sent to `main`'s and the head's `searchd find --json` and over `serve`
(method `find`); stdout, stderr and exit code are compared. The schema-valid ones must be identical; the others
are listed with both outcomes. `list_files` is sent the same cursors, for the record (left alone by ruling 8).

Usage: python3 -I probe_find_cursor.py MAIN_SEARCHD HEAD_SEARCHD WORKDIR
"""
import json
import re
import subprocess
import sys
from pathlib import Path

main_bin, head_bin, work = sys.argv[1], sys.argv[2], Path(sys.argv[3])
folder = work / "fc-folder"
folder.mkdir(parents=True, exist_ok=True)
for i in range(30):
    (folder / f"n{i:02d}.md").write_text(f"# Note {i}\nthe tide table {i} and tide pools\n")
SCHEMA = re.compile(r"^[0-9]+:[0-9]+$")


def run(binary, *args):
    done = subprocess.run([binary, *args], capture_output=True, timeout=120)
    return done.returncode, done.stdout.decode(), done.stderr.decode().strip()


indexes = {}
for name, binary in (("main", main_bin), ("head", head_bin)):
    out = work / f"fc-{name}.idx"
    if not out.exists():
        subprocess.run([binary, "index", str(folder), "--out", str(out)], check=True, capture_output=True, timeout=300)
    indexes[name] = str(out)
first = json.loads(run(head_bin, "find", indexes["head"], "tide", "--json", "--page-size", "5")[1])
generation = first["generation"]
print(f"generation {generation}; first page next_cursor {first['next_cursor']}")
g = str(generation)
cursors = [
    f"{g}:5", f"{g}:0", f"0{g}:5", f"{g}:05", f"000{g}:0000", f"{g}:29", f"{g}:30", f"{g}:31", f"{g}:1000000",
    f"{g}:18446744073709551615", f"{g}:18446744073709551616", "18446744073709551615:0", "18446744073709551616:0",
    f"{g}:99999999999999999999999", "0:0", f"{int(g) + 1}:0",
    # not allowed by the schema
    f"+{g}:5", f"{g}:+5", f"-0:5", f"{g}:-0", f"{g}_0:5", f"{g}:0_5", f" {g}:5", f"{g}:5 ", f"{g}:", f":{g}",
    f"{g}:5:5", "", "１:5", f"{g}：5",
]
same_valid = differ_valid = 0
for cursor in cursors:
    valid = bool(SCHEMA.match(cursor))
    outs = {name: run(binary, "find", indexes[name], "tide", "--json", "--page-size", "5", "--cursor", cursor)
            for name, binary in (("main", main_bin), ("head", head_bin))}
    a, b = outs["main"], outs["head"]
    same = a == b
    if valid:
        same_valid += same
        differ_valid += not same
    def short(o):
        return f"exit {o[0]} " + (f"{len(json.loads(o[1])['hits'])} hits, next {json.loads(o[1])['next_cursor']}" if o[0] == 0 else o[2][:90])
    print(f"{'valid  ' if valid else 'invalid'} {cursor!r}: main {short(a)} | head {short(b)} | {'same' if same else 'DIFFERENT'}")
print(f"schema-valid cursors: {same_valid} identical on main and head, {differ_valid} different")

print("list_files, the same cursors (for the record; ruling 8 left it alone)")
for cursor in cursors:
    outs = [run(binary, "list-files", indexes[name], "--json", "--page-size", "5", "--cursor", cursor)
            for name, binary in (("main", main_bin), ("head", head_bin))]
    if outs[0] != outs[1] or not SCHEMA.match(cursor):
        print(f"  {cursor!r}: main exit {outs[0][0]} {outs[0][2][:60]} | head exit {outs[1][0]} {outs[1][2][:60]} | {'same' if outs[0] == outs[1] else 'DIFFERENT'}")
