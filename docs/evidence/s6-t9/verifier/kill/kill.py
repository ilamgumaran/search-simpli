#!/usr/bin/env python3
"""S6-T9 verifier (the S6-T8 verifier's kill.py; manifest bits 8 and 9 for bit 7; its own probe.py/probe_raw.py): publishes killed (SIGKILL) at seeded random delays; each result must open as a whole old or a
whole new generation.

    kill.py V MODE TRIALS SEED OUT.jsonl [LO HI]   (delay window as fractions of the unkilled duration; default 0 1.3)
MODE: cli-first   searchd index --update, main's timing-10k index (v2.5) -> HYBSTA03, catalog v6, v2.6 (first publish)
      cli-v6      searchd index --update, head's timing-10k index (v2.6 -> v2.6)
      abi-first   ss_apply_changes (one add) in a child process, main's timing-10k index (first publish)
      abi-v6      ss_apply_changes (one add), head's timing-10k index (v2.6 -> v2.6)
Per trial: an APFS clone of the index (and for cli modes of the corpus, one line appended to one file); the writer
started; SIGKILL after a delay drawn from [0, 1.3 x the unkilled duration]; then the head library opens the result
and its answers (status generation, a query, list_files total, read_span of three files) are hashed and compared
with the old and the new generation's references (made by unkilled runs). A trial passes when the answers equal one
reference exactly and the manifest's bits 8 and 9 match that generation.
"""
import ctypes
import hashlib
import json
import os
import random
import re
import signal
import subprocess
import sys
import time
from pathlib import Path

V, mode, trials, seed, out_path = Path(sys.argv[1]), sys.argv[2], int(sys.argv[3]), int(sys.argv[4]), sys.argv[5]
LO, HI = (float(sys.argv[6]), float(sys.argv[7])) if len(sys.argv) > 7 else (0.0, 1.3)  # delay window, fractions of the unkilled duration
W = V / "kill.noindex" / f"{mode}-{seed}"
W.mkdir(parents=True)
searchd = str(V / "bin/head/bin/searchd")
headlib = str(V / "libs/head/libsearch_simpli.dylib")
src_idx = V / "idx.noindex" / ("main" if mode.endswith("first") else "head") / "timing-10k"
corpus = V / "corpora.noindex/timing-10k"
CHANGE = json.dumps({"changes": [{"op": "add", "root_id": "r-legacy", "path": "zz-killed-note.md",
                                  "content_base64": "IyBLaWxsZWQgbm90ZQoKT25lIGxpbmUgYWJvdXQgcG90dGVyeSBhbmQgY2xheS4K"}]})
CHILD = r'''
import ctypes, sys
l = ctypes.CDLL(sys.argv[1])
l.ss_apply_changes.restype = ctypes.c_void_p
l.ss_apply_changes.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_char_p]
l.ss_last_error.restype = ctypes.c_char_p
p = l.ss_apply_changes(sys.argv[2].encode(), sys.argv[3].encode(), b'{"filename_index":true}')
sys.exit(0 if p else (print(l.ss_last_error()) or 3))
'''


def probe(idx):
    r = subprocess.run([sys.executable, "-I", str(Path(__file__).parent / "probe.py"), headlib, str(idx)], capture_output=True, text=True)
    if r.returncode != 0:
        return {"crash_or_fail": r.returncode, "err": (r.stdout + r.stderr)[-300:]}
    return json.loads(r.stdout)


def probe_norm(idx):
    """the answers with the generation number normalised (a later writer over a killed one may publish N+2)"""
    r = subprocess.run([sys.executable, "-I", str(Path(__file__).parent / "probe_raw.py"), headlib, str(idx)], capture_output=True, text=True)
    if r.returncode != 0:
        return {"crash_or_fail": r.returncode}
    out = {}
    for k, v in json.loads(r.stdout).items():
        v = v if isinstance(v, str) else json.dumps(v)
        v = re.sub(r'"(next_cursor|cursor)":"\d+:', 'CUR', re.sub(r'"generation":\d+', '"generation":G', v))
        out[k] = hashlib.sha256(v.encode()).hexdigest()[:16]
    return out


def bit6(idx):
    m = (Path(idx) / "MANIFEST").read_bytes()
    return int.from_bytes(m[10:12], "little") & 0x300  # bits 8 and 9


def prepare(d):
    subprocess.run(["cp", "-c", "-R", str(src_idx), str(d / "idx")], check=True)
    if mode.startswith("cli"):
        subprocess.run(["cp", "-c", "-R", str(corpus), str(d / "folder")], check=True)
        f = sorted((d / "folder").rglob("*.md"))[7]
        with open(f, "ab") as fh:
            fh.write(b"\nkilled publish line\n")
        for a, _, fs in os.walk(d / "folder"):
            for x in fs:
                open(os.path.join(a, x), "rb").read()
    for a, _, fs in os.walk(d / "idx"):
        for x in fs:
            open(os.path.join(a, x), "rb").read()


def start(d):
    if mode.startswith("cli"):
        return subprocess.Popen([searchd, "index", str(d / "folder"), "--out", str(d / "idx"), "--update", "--keep-generations", "2",
                                 "--filename-index"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return subprocess.Popen([sys.executable, "-I", "-c", CHILD, headlib, str(d / "idx"), CHANGE], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


# references: old (untouched) and new (an unkilled run)
ref_old_d = W / "ref-old"
ref_old_d.mkdir()
prepare(ref_old_d)
ref_old = probe(ref_old_d / "idx")
ref_new_d = W / "ref-new"
ref_new_d.mkdir()
prepare(ref_new_d)
t0 = time.perf_counter()
rc = start(ref_new_d).wait()
dur = time.perf_counter() - t0
ref_new = probe(ref_new_d / "idx")
ref_new_norm = probe_norm(ref_new_d / "idx")
assert rc == 0 and ref_old != ref_new, (rc, ref_old, ref_new)
rng = random.Random(seed)
summary = {"mode": mode, "window": [LO, HI], "seed": seed, "trials": trials, "unkilled_s": round(dur, 4), "old": 0, "new": 0, "fail": 0, "killed_before_exit": 0}
with open(out_path, "a") as out:
    for t in range(trials):
        d = W / f"t{t}"
        d.mkdir()
        prepare(d)
        delay = rng.uniform(LO * dur, HI * dur)
        p = start(d)
        time.sleep(delay)
        exited = p.poll() is not None
        if not exited:
            p.send_signal(signal.SIGKILL)
            summary["killed_before_exit"] += 1
        p.wait()
        got = probe(d / "idx")
        b6 = bit6(d / "idx")
        if got == ref_old and b6 == bit6(ref_old_d / "idx"):
            verdict = "old"
        elif got == ref_new and b6 == bit6(ref_new_d / "idx"):
            verdict = "new"
        else:
            verdict = "fail"
        summary[verdict] += 1
        # a later writer over whatever the kill left: runs to the end, then must answer as the new generation does
        # (status aside: the generation number may differ)
        later_rc = start(d).wait() if verdict == "old" else 0
        same = probe_norm(d / "idx") == ref_new_norm
        summary["later_ok" if later_rc == 0 and same else "later_fail"] = summary.get("later_ok" if later_rc == 0 and same else "later_fail", 0) + 1
        out.write(json.dumps({"mode": mode, "trial": t, "delay_ms": round(delay * 1000, 1), "killed": not exited,
                              "verdict": verdict, "bit6": b6, "later_same_as_new": same, "later_rc": later_rc, "files": sorted(x.name for x in (d / "idx").iterdir()),
                              **({"got": got} if verdict == "fail" else {})}) + "\n")
    out.write(json.dumps({"summary": summary}) + "\n")
print(json.dumps(summary))
