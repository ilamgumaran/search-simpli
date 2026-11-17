#!/usr/bin/env python3
"""Real-process crash test (S6-T4): SIGKILL the branch's `searchd index --update`
on a copy of a v2 index (written by main) at a spread of delays; after each
kill, the directory must open under the branch binary and answer exactly as
the complete v2 generation or as the complete v3 one, and its manifest flag
and both lexical sections must agree.

    vkill.py SEARCHD V2_INDEX CORPUS WORK TRIALS [LO_MS HI_MS]
"""
import json
import os
import shutil
import signal
import struct
import subprocess
import sys
import time
from pathlib import Path

searchd, v2_index, corpus, work, trials = sys.argv[1], Path(sys.argv[2]), Path(sys.argv[3]), Path(sys.argv[4]), int(sys.argv[5])
QUERIES = ["system", "hybrid retrieval", "doc 00001", "zzqq"]


def answers(idx):
    out = []
    for q in QUERIES:
        for f in ("content", "filename", "both"):
            p = subprocess.run([searchd, "query", str(idx), q, "--search-field", f, "--json", "--top-k", "5"], capture_output=True)
            out.append((p.returncode, p.stdout))
    p = subprocess.run([searchd, "find", str(idx), "system", "--json"], capture_output=True)
    out.append((p.returncode, p.stdout))
    return out


def _strip(o):
    if isinstance(o, dict):
        return {k: _strip(v) for k, v in o.items() if k != "generation"}
    if isinstance(o, list):
        return [_strip(x) for x in o]
    return o


def strip_generation(ans):
    res = []
    for code, body in ans:
        try:
            body = json.dumps(_strip(json.loads(body)), sort_keys=True).encode()
        except Exception:
            pass
        res.append((code, body))
    return res


def state(idx):
    m = (idx / "MANIFEST").read_bytes()
    flags = struct.unpack_from("<H", m, 10)[0]
    gen = struct.unpack_from("<Q", m, 12)[0]
    lex = sorted(p.name for p in idx.glob("lexical-*.hyblex"))
    fn = sorted(p.name for p in idx.glob("filename-lexical-*.hyblex"))
    cur_lex = idx / f"lexical-{gen}.hyblex"
    cur_fn = idx / f"filename-lexical-{gen}.hyblex"
    return flags, gen, cur_lex.read_bytes()[:8], cur_fn.read_bytes()[:8]


# The two complete answers: v2 as it is, and v3 after an uninterrupted update.
changed = sorted(p for p in corpus.rglob("*.md"))[7]
original = changed.read_bytes()
work.mkdir(parents=True, exist_ok=True)
ref_v2 = strip_generation(answers(v2_index))
full = work / "complete"
shutil.copytree(v2_index, full)
changed.write_bytes(original + b"\nAn added line about hybrid retrieval systems.\n")
try:
    t0 = time.perf_counter()
    subprocess.run([searchd, "index", str(corpus), "--out", str(full), "--update", "--filename-index"], capture_output=True, check=True)
    t_full = time.perf_counter() - t0
    ref_v3 = strip_generation(answers(full))
    v3_state = state(full)
    ref_v2_new = None
    results = []
    for i in range(trials):
        d = work / f"t{i}"
        shutil.copytree(v2_index, d)
        lo, hi = (float(sys.argv[6]) / 1000, float(sys.argv[7]) / 1000) if len(sys.argv) > 7 else (0.0, t_full)
        delay = lo + (hi - lo) * (i + 0.5) / trials
        proc = subprocess.Popen([searchd, "index", str(corpus), "--out", str(d), "--update", "--filename-index"],
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        time.sleep(delay)
        killed = proc.poll() is None
        if killed:
            os.kill(proc.pid, signal.SIGKILL)
        proc.wait()
        flags, gen, lex_magic, fn_magic = state(d)
        ans = strip_generation(answers(d))
        which = "v2" if ans == ref_v2 else ("v3" if ans == ref_v3 else "NEITHER")
        consistent = ((flags & 0x20 != 0) == (lex_magic == b"HYBLEX03") == (fn_magic == b"HYBLEX03"))
        results.append({"trial": i, "delay_ms": round(delay * 1000, 1), "killed": killed, "generation": gen,
                        "flag5": bool(flags & 0x20), "lexical": lex_magic.decode(), "filename": fn_magic.decode(),
                        "answers": which, "flag_and_sections_agree": consistent})
        # a later update over the leftovers must publish a whole v3 generation
        if killed and (i % 3 == 0 or os.environ.get('VKILL_ALL_AFTER')):
            subprocess.run([searchd, "index", str(corpus), "--out", str(d), "--update", "--filename-index"], capture_output=True, check=True)
            f2, g2, l2, n2 = state(d)
            results[-1]["after_next_update"] = {"generation": g2, "flag5": bool(f2 & 0x20), "lexical": l2.decode(),
                                                "filename": n2.decode(),
                                                "answers_v3": strip_generation(answers(d)) == ref_v3}
        shutil.rmtree(d)
finally:
    changed.write_bytes(original)
summary = {"update_ms": round(t_full * 1000, 1), "trials": len(results),
           "killed": sum(r["killed"] for r in results),
           "v2": sum(r["answers"] == "v2" for r in results), "v3": sum(r["answers"] == "v3" for r in results),
           "neither": sum(r["answers"] == "NEITHER" for r in results),
           "inconsistent": sum(not r["flag_and_sections_agree"] for r in results)}
print(json.dumps({"summary": summary, "results": results}, indent=1))
