#!/usr/bin/env python3
"""S6-T24 verifier probe: the same `scan` request on every interface over one index.

CLI `searchd scan <index> --json`, RPC `searchd serve` method `scan` (the result member's bytes), MCP `searchd mcp`
tool `scan` (the content text), the C ABI `ss_scan` through ctypes on the committed macOS dylib, and the Python
reference `scan(index, request)` over `core.build_index` of the same folder (hits only: its generation and cursor
are its own). Byte-identical answers are required of the first four; refusals are compared by code and message.
Also: `ss_scan` with a NULL handle, NULL request, malformed JSON, a closed handle (not called: use after free is
the caller's error and is not probed), a 1 MiB request, and the result schema check on every answer.

Usage: python3 -I probe_interfaces.py REPO SEARCHD DYLIB WORKDIR
"""
import ctypes
import json
import shutil
import subprocess
import sys
from pathlib import Path

repo, searchd, dylib, work = Path(sys.argv[1]), sys.argv[2], sys.argv[3], Path(sys.argv[4])
sys.path.insert(0, str(repo))
from src.search_platform import core, scan  # noqa: E402

failures = 0


def check(ok, what):
    global failures
    failures += not ok
    print(("OK   " if ok else "FAIL ") + what)


folder = work / "if-folder"
if folder.exists():
    shutil.rmtree(folder)
(folder / "notes").mkdir(parents=True)
(folder / "notes" / "a.md").write_text("# Ledger\nPaid 142.50 to TS-0142\nthe tide_pool and the tide\n\nமழை பெய்தால்\n")
(folder / "notes" / "b.txt").write_text("tide\r\nTIDE\r\nno match here\r\n")
(folder / "c.txt").write_text("x" * 600 + " tide\n" + "tide " * 3 + "\n")
index = work / "if-index"
if index.exists():
    shutil.rmtree(index)
subprocess.run([searchd, "index", str(folder), "--out", str(index)], check=True, capture_output=True)

REQUESTS = [
    {"pattern": "tide"},
    {"pattern": "tide", "case": "sensitive", "whole_word": True},
    {"pattern": "\\d+\\.\\d+", "mode": "regex"},
    {"pattern": "TS-0142", "context_lines": 2},
    {"pattern": "tide", "page_size": 1},
    {"pattern": "tide", "max_hits_per_file": 1, "page_size": 100},
    {"pattern": "^$", "mode": "regex"},
    {"pattern": "மழை", "whole_word": True},
    {"pattern": "tide", "path_prefix": "notes/", "name_glob": "*.md"},
    {"pattern": "tide", "roots": ["r-legacy"]},
    {"pattern": "tide", "roots": ["nope"]},
    # refusals
    {"pattern": ""},
    {"pattern": "a(", "mode": "regex"},
    {"pattern": "x", "page_size": 0},
    {"pattern": "x", "page_size": 101},
    {"pattern": "x", "time_budget_ms": 0},
    {"pattern": "x", "time_budget_ms": 30001},
    {"pattern": "x", "context_lines": 21},
    {"pattern": "x", "max_hits_per_file": 1001},
    {"pattern": "x", "name_glob": "a/b"},
    {"pattern": "x", "cursor": "garbage"},
    {"pattern": "x", "cursor": ""},
    {"pattern": "x", "mode": "glob"},
    {"pattern": "x", "case": "upper"},
    {"pattern": "x", "whole_word": "yes"},
    {"pattern": "x", "bogus": 1},
    {"pattern": 5},
]


def cli_args(request):
    argv = ["scan", str(index), request["pattern"], "--json"]
    if request.get("mode") == "regex":
        argv.append("--regex")
    if "case" in request:
        argv += ["--case", request["case"]]
    if request.get("whole_word"):
        argv.append("--word")
    for field, flag in (("context_lines", "--context"), ("max_hits_per_file", "--max-per-file"), ("page_size", "--page-size"),
                        ("time_budget_ms", "--time-ms"), ("path_prefix", "--path-prefix"), ("name_glob", "--glob"), ("cursor", "--cursor")):
        if field in request:
            argv += [flag, str(request[field])]
    if "roots" in request:
        argv += ["--roots", ",".join(request["roots"])]
    return argv


lib = ctypes.CDLL(dylib)
lib.ss_open.restype = ctypes.c_void_p
lib.ss_open.argtypes = [ctypes.c_char_p]
lib.ss_scan.restype = ctypes.c_void_p
lib.ss_scan.argtypes = [ctypes.c_void_p, ctypes.c_char_p]
lib.ss_free.argtypes = [ctypes.c_void_p]
lib.ss_last_error.restype = ctypes.c_char_p
lib.ss_close.argtypes = [ctypes.c_void_p]
lib.ss_version.restype = ctypes.c_char_p
handle = lib.ss_open(str(index).encode())
check(bool(handle), f"ss_open (version {lib.ss_version().decode()})")


def abi(request_bytes, h=None):
    pointer = lib.ss_scan(handle if h is None else h, request_bytes)
    if not pointer:
        return None, lib.ss_last_error().decode()
    text = ctypes.string_at(pointer).decode()
    lib.ss_free(pointer)
    return text, None


serve = subprocess.Popen([searchd, "serve", str(index)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
mcp = subprocess.Popen([searchd, "mcp", str(index)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
counter = [0]


def rpc(process, method, params):
    counter[0] += 1
    process.stdin.write(json.dumps({"jsonrpc": "2.0", "id": counter[0], "method": method, "params": params}) + "\n")
    process.stdin.flush()
    return process.stdout.readline()


rpc(mcp, "initialize", {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "verifier-probe", "version": "0"}})
mcp.stdin.write(json.dumps({"jsonrpc": "2.0", "method": "notifications/initialized"}) + "\n")
mcp.stdin.flush()

result_schema = json.loads((repo / "contracts/tools/scan.result.schema.json").read_text())
from src.search_platform.schema_check import validate  # noqa: E402  (the repository's validator; no jsonschema here)
request_schema = json.loads((repo / "contracts/tools/scan.request.schema.json").read_text())

reference_index = core.build_index(folder)
for request in REQUESTS:
    label = json.dumps(request, ensure_ascii=False)
    answers = {}
    # CLI (only requests the flags can say)
    if isinstance(request.get("pattern"), str) and "bogus" not in request and request.get("whole_word", False) in (True, False) \
            and request.get("mode", "regex") in ("literal", "regex") and request.get("case", "smart") in ("sensitive", "insensitive", "smart"):
        done = subprocess.run([searchd, *cli_args(request)], capture_output=True)
        answers["cli"] = ("ok", done.stdout.decode().rstrip("\n")) if done.returncode == 0 else ("refused", done.stderr.decode().strip().removeprefix("searchd: "), done.returncode)
    line = rpc(serve, "scan", request)
    message = json.loads(line)
    if "result" in message:
        prefix = '{"jsonrpc":"2.0","id":%d,"result":' % counter[0]
        answers["rpc"] = ("ok", line[len(prefix):].rstrip("\n")[:-1])
    else:
        answers["rpc"] = ("refused", message["error"]["message"], message["error"]["code"])
    message = json.loads(rpc(mcp, "tools/call", {"name": "scan", "arguments": request}))
    if "result" in message and not message["result"].get("isError"):
        answers["mcp"] = ("ok", message["result"]["content"][0]["text"])
    elif "result" in message:
        answers["mcp"] = ("refused", message["result"]["content"][0]["text"])
    else:
        answers["mcp"] = ("refused", message["error"]["message"], message["error"]["code"])
    text, error = abi(json.dumps(request).encode())
    answers["abi"] = ("ok", text) if text is not None else ("refused", error)
    oks = {k: v[1] for k, v in answers.items() if v[0] == "ok"}
    if oks and len(oks) == len(answers):
        same = len(set(oks.values())) == 1
        answer = json.loads(next(iter(oks.values())))
        try:
            ref = scan.scan(reference_index, {k: v for k, v in request.items()})
            ref_hits = [(h["path"], h["line"], h["text"], h["match_offsets"], h["before"], h["after"]) for h in ref["hits"]]
            eng_hits = [(h["path"], h["line"], h["text"], h["match_offsets"], h["before"], h["after"]) for h in answer["hits"]]
            ref_same = ref_hits == eng_hits
        except scan.ScanError as error:
            ref_same = f"reference refused: {error}"
        errors = validate(answer, result_schema) + validate(request, request_schema)
        check(same and ref_same is True and not errors, f"{label}: schema errors {errors[:2]}: {len(answer['hits'])} hits; CLI = RPC = MCP = ABI byte-identical: {same}; reference hits equal: {ref_same}")
    else:
        try:
            scan.scan(reference_index, dict(request))
            ref = "answered"
        except (scan.ScanError, TypeError, AttributeError) as error:
            ref = f"{type(error).__name__}: {error}"
        print(f"     {label}: " + " | ".join(f"{k}: {v[1:]}" for k, v in answers.items()) + f" | reference: {ref}")

# the result schema on a folder answer, a stopped page and a capped file
for argv in (["--folder", str(folder), "tide"], ["--folder", str(folder), "tide", "--max-per-file", "1"],
             ["--folder", str(folder), "x?", "--regex"], [str(index), "\\w", "--regex", "--time-ms", "1"]):
    done = subprocess.run([searchd, "scan", *argv, "--json"], capture_output=True)
    answer = json.loads(done.stdout) if done.returncode == 0 else None
    errors = validate(answer, result_schema) if answer else ["exit %d %s" % (done.returncode, done.stderr.decode().strip())]
    check(not errors, f"result schema on scan {argv[1:]} ({answer and answer['source']}, stopped {answer and answer['stopped']}): {errors[:2]}")

# ss_scan edge calls
text, error = abi(b'{"pattern":"tide"}', h=0)
check(text is None, f"ss_scan(NULL handle): {error}")
pointer = lib.ss_scan(handle, None)
check(not pointer, f"ss_scan(handle, NULL): {lib.ss_last_error().decode()}")
for raw in (b"", b"{", b"[]", b"null", b'{"pattern":"tide"} trailing', b'\xff\xfe'):
    text, error = abi(raw)
    check(text is None, f"ss_scan(handle, {raw!r}): {error}")
big = json.dumps({"pattern": "tide", "path_prefix": "n" * (1 << 20)}).encode()
text, error = abi(big)
check(text is not None and json.loads(text)["hits"] == [], f"ss_scan with a 1 MiB path_prefix: {'answered, 0 hits' if text else error}")
big = json.dumps({"pattern": "t" * 5000}).encode()
text, error = abi(big)
check(text is None, f"ss_scan with a 5,000-byte pattern: {error}")
lib.ss_close(handle)
serve.stdin.close(); serve.wait(timeout=30)
mcp.stdin.close(); mcp.wait(timeout=30)
print(f"failures: {failures}")
