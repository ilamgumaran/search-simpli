#!/usr/bin/env python3
"""S4-T10: `read_span` and `outline` parity and timing over the C ABI.

Two libraries (the one before a change and the one after) answer the same
requests over the same index bytes; every answer is captured and compared,
and the per-call times are measured in interleaved rounds. Each library runs
in a child process of its own. Invented text only; every number printed is a
measurement.

    python3 -I scripts/source_read_parity.py index --lib LIB --folder DIR --out INDEX [--filename-index]
    python3 -I scripts/source_read_parity.py capture --lib LIB --index INDEX --out OUT.jsonl
    python3 -I scripts/source_read_parity.py compare BEFORE.jsonl AFTER.jsonl
    python3 -I scripts/source_read_parity.py time --lib BEFORE --lib AFTER --index INDEX \\
        --span-path PATH [--span-path PATH ...] [--root r-legacy] [--samples 30] [--rounds 2]

`index` builds an index with `ss_index_folder` (build it once, with one
library, and capture both libraries over it).

`capture` writes one JSON line per request: the function, the request, then
the exact output (or `ERROR <ss_last_error()>`). Handle 1: `ss_list_files`
(every page); for every listed file `ss_outline` and several `ss_read_span`s
(lines 1-400; 2-3 with two lines of context; the last line with 20 lines of
context; the middle line to past the end, clamped; one line past the end, a
refusal; 1-401, a refusal); `ss_find` in words, prefix and phrase modes;
`ss_query` over the content, filename and both fields at two depths. Handle 2
(fresh): filename and both queries first, then `ss_read_span`. Handle 3
(fresh): `ss_read_span` and `ss_outline` first, then queries. A line per
handle's `ss_list_files` file count and a final `requests N files M` summary
are printed; the file's SHA-256 is printed after it is written.

`compare` reports the number of lines and whether the two captures are
byte-identical (exit 1 when they are not, with the first differing line).

`time` measures p50 per library, in `--rounds` interleaved rounds of
`--samples`: `ss_open` (open then close); the first `ss_read_span` after an
open (it loads the source section; open, read, close per sample); then, on
one handle that has made that first read, each `--span-path`'s later
`ss_read_span` (lines 1-400) and `ss_outline`, `ss_find` ("the", words),
`ss_query` content (lexical), filename and both. The load average is printed
at the start and the end.
"""
import argparse
import ctypes
import hashlib
import json
import os
import statistics
import subprocess
import sys
import time


def load(path):
    lib = ctypes.CDLL(path)
    lib.ss_open.restype = ctypes.c_void_p
    lib.ss_open.argtypes = [ctypes.c_char_p]
    lib.ss_close.argtypes = [ctypes.c_void_p]
    lib.ss_last_error.restype = ctypes.c_char_p
    lib.ss_free.argtypes = [ctypes.c_void_p]
    for name in ("ss_find", "ss_outline", "ss_read_span", "ss_list_files"):
        function = getattr(lib, name)
        function.restype = ctypes.c_void_p
        function.argtypes = [ctypes.c_void_p, ctypes.c_char_p]
    lib.ss_query.restype = ctypes.c_void_p
    lib.ss_query.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_size_t, ctypes.c_char_p]
    lib.ss_index_folder.restype = ctypes.c_void_p
    lib.ss_index_folder.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_char_p]
    return lib


def take(lib, pointer):
    if not pointer:
        return "ERROR " + (lib.ss_last_error() or b"").decode("utf-8", "replace")
    text = ctypes.string_at(pointer).decode("utf-8", "replace")
    lib.ss_free(pointer)
    return text


def open_handle(lib, index):
    handle = lib.ss_open(index.encode())
    if not handle:
        raise SystemExit("ss_open failed: " + lib.ss_last_error().decode())
    return handle


def query_options(field):
    return json.dumps({"retrieval_mode": "lexical", "search_field": field}).encode()


class Capture:
    def __init__(self, lib, out):
        self.lib = lib
        self.out = out
        self.count = 0

    def emit(self, name, request, output):
        self.out.write(json.dumps([name, request, output], ensure_ascii=False) + "\n")
        self.count += 1
        return output

    def call(self, handle, name, request):
        body = json.dumps(request)
        return self.emit(name, body, take(self.lib, getattr(self.lib, name)(handle, body.encode())))

    def query(self, handle, text, field, top_k):
        output = take(self.lib, self.lib.ss_query(handle, text.encode(), None, 0, top_k, query_options(field)))
        return self.emit("ss_query", json.dumps([text, field, top_k]), output)

    def spans(self, handle, root_id, path):
        """`ss_outline`, then the spans; the outline's line count sets them."""
        outline = self.call(handle, "ss_outline", {"root_id": root_id, "path": path})
        lines = 0
        if not outline.startswith("ERROR"):
            lines = json.loads(outline).get("lines", 0)
        first = self.call(handle, "ss_read_span", {"root_id": root_id, "path": path, "start_line": 1, "end_line": 400})
        self.call(handle, "ss_read_span", {"root_id": root_id, "path": path, "start_line": 2, "end_line": 3, "context_lines": 2})
        if lines:
            self.call(handle, "ss_read_span", {"root_id": root_id, "path": path, "start_line": lines, "end_line": lines, "context_lines": 20})
            middle = max(1, (lines + 1) // 2)
            self.call(handle, "ss_read_span", {"root_id": root_id, "path": path, "start_line": middle, "end_line": lines + 50})
        self.call(handle, "ss_read_span", {"root_id": root_id, "path": path, "start_line": lines + 1, "end_line": lines + 1})
        self.call(handle, "ss_read_span", {"root_id": root_id, "path": path, "start_line": 1, "end_line": 401})
        return first


def list_all(capture, handle):
    files = []
    cursor = None
    while True:
        request = {"page_size": 1000}
        if cursor:
            request["cursor"] = cursor
        output = capture.call(handle, "ss_list_files", request)
        if output.startswith("ERROR"):
            break
        page = json.loads(output)
        files += [(item["root_id"], item["path"]) for item in page["files"]]
        cursor = page.get("next_cursor")
        if not cursor:
            break
    return files


def capture(args):
    lib = load(args.lib)
    with open(args.out, "w", encoding="utf-8") as out:
        run = Capture(lib, out)
        handle = open_handle(lib, args.index)
        files = list_all(run, handle)
        words = set()
        content = []
        for number, (root_id, path) in enumerate(files):
            span = run.spans(handle, root_id, path)
            if number < 40 and not span.startswith("ERROR"):
                text = json.loads(span).get("text", "")
                content += [word for word in text.split() if word.isalpha()][:3]
            for part in path.replace("/", " ").replace(".", " ").replace("-", " ").split():
                words.add(part)
        queries = sorted(words)[:60] + ["doc", "group", "the", "doc the", "garden pond", "hybrid retrieval"]
        for text in queries:
            run.call(handle, "ss_find", {"query": text.split()[0], "mode": "words", "page_size": 20})
            run.call(handle, "ss_find", {"query": text.split()[0][:3], "mode": "prefix", "page_size": 20})
            run.query(handle, text, "content", 10)
            run.query(handle, text, "filename", 10)
            run.query(handle, text, "both", 10)
            run.query(handle, text, "both", 50)
        content = sorted(set(content))[:60]
        for number, word in enumerate(content):
            run.call(handle, "ss_find", {"query": word, "mode": "words", "page_size": 20})
            if number + 1 < len(content):
                run.call(handle, "ss_find", {"query": word + " " + content[number + 1], "mode": "phrase", "page_size": 20})
            run.query(handle, word, "content", 10)
            run.query(handle, word, "both", 10)
        lib.ss_close(handle)
        second = open_handle(lib, args.index)
        for text in queries[:20]:
            run.query(second, text, "filename", 10)
            run.query(second, text, "both", 10)
        for root_id, path in files[:50]:
            run.call(second, "ss_read_span", {"root_id": root_id, "path": path, "start_line": 1, "end_line": 400})
        lib.ss_close(second)
        third = open_handle(lib, args.index)
        for root_id, path in files[:50]:
            run.call(third, "ss_read_span", {"root_id": root_id, "path": path, "start_line": 1, "end_line": 400})
            run.call(third, "ss_outline", {"root_id": root_id, "path": path})
        for text in queries[:20]:
            run.query(third, text, "both", 10)
        lib.ss_close(third)
    digest = hashlib.sha256(open(args.out, "rb").read()).hexdigest()
    print(f"requests {run.count} files {len(files)} sha256 {digest}")


def compare(args):
    before = open(args.before, "rb").read().splitlines()
    after = open(args.after, "rb").read().splitlines()
    for number, (left, right) in enumerate(zip(before, after)):
        if left != right:
            print(f"differ at line {number + 1}:\n  {left[:300]!r}\n  {right[:300]!r}")
            return 1
    if len(before) != len(after):
        print(f"differ in length: {len(before)} and {len(after)} lines")
        return 1
    print(f"identical: {len(before)} lines, sha256 {hashlib.sha256(open(args.before, 'rb').read()).hexdigest()}")
    return 0


def timed(clock, function):
    start = clock()
    result = function()
    return (clock() - start) / 1e6, result


def child(args):
    lib = load(args.lib[0])
    clock = time.perf_counter_ns
    index = args.index.encode()
    root = args.root
    first_span = json.dumps({"root_id": root, "path": args.span_path[0], "start_line": 1, "end_line": 400}).encode()
    samples = {}

    def keep(label, value):
        samples.setdefault(label, []).append(value)

    def checked(pointer):
        if not pointer:
            raise SystemExit("call failed: " + lib.ss_last_error().decode())
        lib.ss_free(pointer)

    for number in range(2 + args.samples):
        elapsed, handle = timed(clock, lambda: lib.ss_open(index))
        if not handle:
            raise SystemExit("ss_open failed: " + lib.ss_last_error().decode())
        span_ms, pointer = timed(clock, lambda: lib.ss_read_span(handle, first_span))
        checked(pointer)
        lib.ss_close(handle)
        if number >= 2:
            keep("ss_open", elapsed)
            keep("first read_span", span_ms)
    handle = open_handle(lib, args.index)
    checked(lib.ss_read_span(handle, first_span))
    requests = []
    for path in args.span_path:
        requests.append((f"read_span {path}", lambda p=path: lib.ss_read_span(handle, json.dumps({"root_id": root, "path": p, "start_line": 1, "end_line": 400}).encode())))
        requests.append((f"outline {path}", lambda p=path: lib.ss_outline(handle, json.dumps({"root_id": root, "path": p}).encode())))
    requests.append(("find", lambda: lib.ss_find(handle, json.dumps({"query": "the", "mode": "words", "page_size": 20}).encode())))
    for field in ("content", "filename", "both"):
        if field != "content" and not args.filename:
            continue
        requests.append((f"query {field}", lambda f=field: lib.ss_query(handle, b"the doc", None, 0, 10, query_options(f))))
    for _ in range(2):
        for _, function in requests:
            checked(function())
    for _ in range(args.samples):
        for label, function in requests:
            elapsed, pointer = timed(clock, function)
            checked(pointer)
            keep(label, elapsed)
    lib.ss_close(handle)
    return {label: statistics.median(values) for label, values in samples.items()}


def time_command(args):
    report = {"load_average": list(os.getloadavg()), "rounds": []}
    for round_number in range(args.rounds):
        for lib in args.lib:
            command = [sys.executable, "-I", os.path.abspath(__file__), "time-child", "--lib", lib, "--index", args.index, "--root", args.root,
                       "--samples", str(args.samples)] + sum((["--span-path", path] for path in args.span_path), [])
            if args.filename:
                command.append("--filename")
            output = subprocess.run(command, check=True, capture_output=True, text=True, timeout=540).stdout
            report["rounds"].append({"round": round_number + 1, "lib": lib, "p50_ms": json.loads(output)})
    report["load_average_end"] = list(os.getloadavg())
    print(json.dumps(report, indent=1))


def index(args):
    lib = load(args.lib)
    options = json.dumps({"filename_index": True} if args.filename_index else {})
    print(take(lib, lib.ss_index_folder(args.out.encode(), args.folder.encode(), options.encode()))[:200])


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    commands = parser.add_subparsers(dest="command", required=True)
    build = commands.add_parser("index")
    build.add_argument("--lib", required=True)
    build.add_argument("--folder", required=True)
    build.add_argument("--out", required=True)
    build.add_argument("--filename-index", action="store_true")
    run = commands.add_parser("capture")
    run.add_argument("--lib", required=True)
    run.add_argument("--index", required=True)
    run.add_argument("--out", required=True)
    check = commands.add_parser("compare")
    check.add_argument("before")
    check.add_argument("after")
    for name in ("time", "time-child"):
        measure = commands.add_parser(name)
        measure.add_argument("--lib", action="append", required=True)
        measure.add_argument("--index", required=True)
        measure.add_argument("--root", default="r-legacy")
        measure.add_argument("--span-path", action="append", required=True)
        measure.add_argument("--filename", action="store_true", help="also time filename and both queries")
        measure.add_argument("--samples", type=int, default=30)
        measure.add_argument("--rounds", type=int, default=2)
    args = parser.parse_args()
    if args.command == "index":
        index(args)
    elif args.command == "capture":
        capture(args)
    elif args.command == "compare":
        sys.exit(compare(args))
    elif args.command == "time":
        time_command(args)
    else:
        print(json.dumps(child(args)))


if __name__ == "__main__":
    main()
