#!/usr/bin/env python3
"""S6-T24 verifier probe: random pattern text (metacharacters, digits, Unicode, lone surrogates escaped in JSON,
huge counts, unbalanced brackets) sent to `searchd serve` method `scan` (regex and literal), one server for the
whole run. Watches for a crash (the server exits), a hang (no answer within 10 s) and a disagreement with the
Python reference's `compile_pattern` on acceptance or on the refusal message.

Usage: python3 -I probe_parser_fuzz.py REPO SEARCHD WORKDIR [N] [SEED]
"""
import json
import random
import select
import shutil
import subprocess
import sys
import time
from pathlib import Path

repo, searchd, work = Path(sys.argv[1]), sys.argv[2], Path(sys.argv[3])
N = int(sys.argv[4]) if len(sys.argv) > 4 else 20000
SEED = int(sys.argv[5]) if len(sys.argv) > 5 else 99
sys.path.insert(0, str(repo))
from src.search_platform import scan  # noqa: E402

rng = random.Random(SEED)
folder = work / "pf-folder"
if folder.exists():
    shutil.rmtree(folder)
folder.mkdir(parents=True)
(folder / "a.txt").write_text("abc 123 tide_pool\nσίσυφος மழை\n\n" + "a" * 3000 + "\n")
index = work / "pf-index"
if index.exists():
    shutil.rmtree(index)
subprocess.run([searchd, "index", str(folder), "--out", str(index)], check=True, capture_output=True)

ALPHABET = list("()[]{}\\|*+?^$.-,:=!<>0123456789abcdkswbBdDWS ") + ["255", "256", "99999999999", "\t", "é", "ß", "ſ", "K", "மழை", "́", "\ud800", "\U0001F600", " ", "\x00", "(?", "(?:", "[^", "{2,", "\\p{L}", "\\x41", "\\u0041"]

server = subprocess.Popen([searchd, "serve", str(index)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
counts = {"answered": 0, "refused": 0, "accept_mismatch": 0, "message_mismatch": 0, "slow": 0, "lone_surrogate_json_parse_error": 0}
examples = []
slowest = (0.0, "")
for i in range(N):
    pattern = "".join(rng.choice(ALPHABET) for _ in range(rng.randint(1, 24)))
    mode = "regex" if rng.random() < 0.85 else "literal"
    request = {"pattern": pattern, "mode": mode, "case": rng.choice(["sensitive", "insensitive", "smart"]), "time_budget_ms": 2000}
    line = json.dumps({"jsonrpc": "2.0", "id": i, "method": "scan", "params": request}) + "\n"
    start = time.monotonic()
    server.stdin.write(line.encode())
    server.stdin.flush()
    ready, _, _ = select.select([server.stdout], [], [], 10.0)
    took = time.monotonic() - start
    if not ready:
        print(f"HANG: no answer in 10 s to {json.dumps(request)}")
        server.kill()
        break
    reply = server.stdout.readline()
    if not reply:
        print(f"CRASH: the server closed after {json.dumps(request)}; stderr {server.stderr.read()[:400]!r}")
        break
    if took > slowest[0]:
        slowest = (took, pattern)
    if took > 2.5:
        counts["slow"] += 1
        examples.append(f"slow {took:.2f} s (budget 2 s): {json.dumps(request)}")
    message = json.loads(reply)
    engine = ("ok",) if "result" in message else ("refused", message["error"]["message"].removeprefix("Invalid params: "))
    counts["answered" if engine[0] == "ok" else "refused"] += 1
    try:
        scan.compile_pattern(pattern, mode, request["case"])
        ref = ("ok",)
    except scan.ScanError as error:
        ref = ("refused", str(error))
    except Exception as error:  # noqa: BLE001
        ref = ("reference raised", f"{type(error).__name__}: {error}")
    if engine[0] != ref[0]:
        counts["accept_mismatch"] += 1
        if len(examples) < 20:
            examples.append(f"accept differs: {json.dumps(request)}: engine {engine}, reference {ref}")
    elif engine != ref and "\ud800" in pattern and engine[1] == "Parse error":
        # A lone surrogate escaped in JSON: the server's JSON-RPC layer answers "Parse error" for every method
        # (not scan's code); the reference sees a str it cannot encode.
        counts["lone_surrogate_json_parse_error"] += 1
    elif engine != ref:
        counts["message_mismatch"] += 1
        if len(examples) < 20:
            examples.append(f"message differs: {json.dumps(request)}: engine {engine[1]!r}, reference {ref[1]!r}")
else:
    server.stdin.close()
    server.wait(timeout=30)
print(f"seed {SEED}: {N} patterns: {counts}; slowest answer {slowest[0]:.3f} s for {slowest[1]!r}")
for example in examples[:30]:
    print("  " + example)
