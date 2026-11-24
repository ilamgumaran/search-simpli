#!/usr/bin/env python3
"""S6-T24 verifier probe (Verdict 3, ruling 2): is every unit of the meter a bounded amount of work?

Each case is a pattern of at most 1,024 bytes over one file of 2,000 lines of 254 code points, chosen to make a
unit as costly as the code allows, run through the CLI over a folder and over an index at `--time-ms 1` and
`--time-ms 1000`, and over `serve` at 1 ms with an `index_status` queued behind. The stated bound is the budget
plus 50 ms (process start, 2-4 ms, comes on top for the CLI). A case that finishes inside the budget is reported
with its time; one that stops is reported with its stop.

Cases (the line text in brackets):
  w508   `[^\\w x 508]{255}` [→]                          Verdict 2's case
  s508   `[^\\s x 508]{255}` [→]                          Verdict 2's case
  fold   --case insensitive, a class of single upper-case letters from Greek, Cyrillic, Armenian, Glagolitic,
         Deseret and Georgian (so its folds, `extras`, are many), `{1,3}` [lower-case Deseret]
  foldw  --case insensitive, `[^\\W\\d]{255}` [Deseret lower case: fold, then \\w's two tables]
  bnd    `(?:\\b|\\B)` x 100 then `z` [Tamil letters and marks: the word test per position]
  bnd2   `\\b\\B\\b\\B...` x 255 assertions then `(?:z)` [Tamil]
  alt    `(?:அ|ஆ|இ|...)` 70 Tamil alternatives `{1,3}` then `z` [Tamil]
  b2b    `[\\w][\\d][\\s][\\W][\\D][\\S]` repeated to 1,024 bytes [mixed Tamil, digits, spaces]
  rep    `(?:[\\w\\W]){1,255}(?:[\\w\\W]){1,255}z` [mixed]
  lit    a 1,020-byte literal of த (340 code points) then `|z`, regex mode [254 த]
  litci  the same literal, --case insensitive, regex mode [254 த]
  dot    `(?:.{1,255}){1,4}z` [→] (near the compile cap)
  wclass `[\\w\\d\\s\\W]` inside `(?:...|...)` nested alternations [mixed]

Usage: python3 -I probe_units3.py SEARCHD WORKDIR
Every call bounded (120 s); every loop bounded. Times are of a machine not kept quiet.
"""
import json
import subprocess
import sys
import time
from pathlib import Path

searchd, work = sys.argv[1], Path(sys.argv[2])
LIMIT = 120

TAMIL = "அஆஇஈஉஊஎஏஐஒஓஔகஙசஞடணதநபமயரலவழளறனஜஷஸஹ"
MARKS = "ாிீுூெேைொோௌ்"
UPPER = ([chr(c) for c in range(0x391, 0x3AA) if c != 0x3A2] + [chr(c) for c in range(0x410, 0x430)]
         + [chr(c) for c in range(0x531, 0x557)] + [chr(c) for c in range(0x2C00, 0x2C2F)]
         + [chr(c) for c in range(0x10400, 0x10428)] + [chr(c) for c in range(0x10A0, 0x10C6)])


def lines_of(make):
    return "".join(make(i) + "\n" for i in range(2000))


def mixed(i):
    s = []
    for j in range(254):
        k = (i * 7 + j) % 4
        s.append(TAMIL[j % len(TAMIL)] if k == 0 else MARKS[j % len(MARKS)] if k == 1 else "0123456789"[j % 10] if k == 2 else " ")
    return "".join(s)


texts = {
    "arrow": lines_of(lambda i: "→" * 254),
    "deseret": lines_of(lambda i: "".join(chr(0x10428 + (i + j) % 40) for j in range(254))),
    "tamil": lines_of(lambda i: "".join((TAMIL[(i + j) % len(TAMIL)] if j % 2 == 0 else MARKS[(i + j) % len(MARKS)]) for j in range(254))),
    "ta": lines_of(lambda i: "த" * 254),
    "mixed": lines_of(mixed),
}


def fill(unit, cap=1024, tail=""):
    out = ""
    while len((out + unit + tail).encode()) <= cap:
        out += unit
    return out + tail


fold_class = "[" + "".join(UPPER[:250]) + "]"
while len((fold_class + "{1,3}").encode()) > 1024:
    fold_class = fold_class[:-2] + "]"
cases = [
    ("w508", "[^" + "\\w" * 508 + "]{255}", [], "arrow"),
    ("s508", "[^" + "\\s" * 508 + "]{255}", [], "arrow"),
    ("fold", fold_class + "{1,3}", ["--case", "insensitive"], "deseret"),
    ("foldw", "[^\\W\\d]{255}", ["--case", "insensitive"], "deseret"),
    ("bnd", "(?:\\b|\\B)" * 100 + "z", [], "tamil"),
    ("bnd2", fill("\\b\\B", tail="(?:z)"), [], "tamil"),
    ("alt", "(?:" + "|".join(TAMIL) + "){1,3}z", [], "tamil"),
    ("b2b", fill("[\\w][\\d][\\s][\\W][\\D][\\S]"), [], "mixed"),
    ("rep", "(?:[\\w\\W]){1,255}(?:[\\w\\W]){1,255}z", [], "mixed"),
    ("lit", fill("த", 1020) + "|z", [], "ta"),
    ("litci", fill("த", 1020) + "|z", ["--case", "insensitive"], "ta"),
    ("dot", "(?:.{1,255}){1,4}z", [], "arrow"),
    ("wclass", fill("(?:[\\w\\d]|[\\s\\W])", 1000) + "z", [], "mixed"),
]

folders = {}
for name, text in texts.items():
    f = work / f"u-{name}"
    idx = work / f"u-{name}.idx"
    if not f.exists():
        f.mkdir(parents=True)
        (f / "t.txt").write_text(text)
    if not idx.exists():
        subprocess.run([searchd, "index", str(f), "--out", str(idx)], check=True, capture_output=True, timeout=600)
    folders[name] = (f, idx)


def cli(src, pattern, extra, tm):
    start = time.monotonic()
    try:
        done = subprocess.run([searchd, "scan", *src, pattern, "--regex", "--json", "--time-ms", tm, *extra],
                              capture_output=True, timeout=LIMIT)
    except subprocess.TimeoutExpired:
        return f"killed after {LIMIT} s"
    ms = (time.monotonic() - start) * 1000
    if done.returncode != 0:
        return f"{ms:.0f} ms, exit {done.returncode}: {done.stderr.decode().strip()[:90]}"
    a = json.loads(done.stdout)
    return f"{ms:.0f} ms, stopped {a['stopped']}, hits {len(a['hits'])}"


def serve(idx, params):
    server = subprocess.Popen([searchd, "serve", str(idx)], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                              stderr=subprocess.PIPE, text=True)
    try:
        server.stdin.write(json.dumps({"jsonrpc": "2.0", "id": 0, "method": "index_status", "params": {}}) + "\n")
        server.stdin.flush()
        server.stdout.readline()
        start = time.monotonic()
        server.stdin.write(json.dumps({"jsonrpc": "2.0", "id": 1, "method": "scan", "params": params}) + "\n")
        server.stdin.write(json.dumps({"jsonrpc": "2.0", "id": 2, "method": "index_status", "params": {}}) + "\n")
        server.stdin.flush()
        first = json.loads(server.stdout.readline())
        t1 = (time.monotonic() - start) * 1000
        server.stdout.readline()
        t2 = (time.monotonic() - start) * 1000
        r = first.get("result")
        what = f"stopped {r['stopped']}" if r else f"error {first['error'].get('message', '')[:60]}"
        return f"scan {t1:.0f} ms ({what}), queued call {t2:.0f} ms"
    finally:
        server.stdin.close()
        server.wait(timeout=60)


print("budget + 50 ms is the bound; CLI times include process start (2-4 ms)")
for name, pattern, extra, text in cases:
    f, idx = folders[text]
    print(f"{name}: {len(pattern.encode())} B over {text}")
    for tm in ("1", "1000"):
        print(f"  --time-ms {tm:>4}: folder {cli(['--folder', f], pattern, extra, tm)}; index {cli([idx], pattern, extra, tm)}")
    params = {"pattern": pattern, "mode": "regex", "time_budget_ms": 1}
    if extra:
        params["case"] = extra[1]
    print(f"  serve, 1 ms: {serve(idx, params)}")
