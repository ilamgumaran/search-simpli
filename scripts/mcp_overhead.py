#!/usr/bin/env python3
"""S3-T6 measurement (section 13 profile; CAP-13's gate: adapter overhead
p95 <= 5 ms over the direct call). Standard library only; not a test (a
wall-clock number is never a test here, ROLES 2026-10-08).

What it does, on the family-folder fixture published as three host roots
plus the labelled `private` root (`tests/test_folder_surfaces.fixture_request`):

1. Builds `searchd` with `zig build -Doptimize=<mode>` into a scratch prefix.
2. Writes the request set: the fixture's phrase, prefix and words judgment
   queries, each as a `find` (its judged mode, page size 20) and as a
   `search_knowledge` (top 10).
3. Per repetition: the direct Zig call (`zig run -O<mode>
   zig/src/mcp_bench.zig`: `ops.find` / `ops.searchKnowledge` in process,
   5 warm-up rounds, then ROUNDS timed rounds), then the same rounds over
   one `searchd mcp` session (a `tools/call` line written, the response line
   read, timed in this client), then over `searchd serve` (the RPC round
   trip, for reference). Overhead = MCP round trip minus the direct call,
   paired by (round, request).
4. Startup: `searchd mcp` spawned STARTS times; time to the `initialize`
   response and to the first `tools/list` response.

Usage: python3 scripts/mcp_overhead.py [--optimize ReleaseSmall] [--rounds 15]
       [--repetitions 3] [--starts 20]
"""

from __future__ import annotations

import argparse
import json
import math
import subprocess
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tests"))

from test_folder_surfaces import PACK, fixture_request  # noqa: E402

PROTOCOL_VERSION = "2025-11-25"
WARMUPS = 5


def percentile(values: list[float], fraction: float) -> float:
    ordered = sorted(values)
    return ordered[max(0, math.ceil(fraction * len(ordered)) - 1)]


def requests_of_fixture() -> list[dict]:
    judgments = json.loads((PACK / "judgments.json").read_text(encoding="utf-8"))
    queries = [(c["query"], c["mode"]) for c in judgments["phrase"] + judgments["prefix"]]
    queries += [(c["query"], c["mode"]) for c in judgments["scenarios"] if c.get("mode") == "words" and c.get("query")]
    requests = [{"tool": "find", "arguments": {"query": q, "mode": m, "page_size": 20}} for q, m in queries]
    requests += [{"tool": "search_knowledge", "arguments": {"query": q.rstrip("*"), "top_k": 10}} for q, _ in queries]
    return requests


class Session:
    """One server process driven with pre-serialized lines on raw pipes."""

    def __init__(self, argv: list[str]) -> None:
        self.process = subprocess.Popen(argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)

    def round_trip(self, line: bytes) -> tuple[int, bytes]:
        start = time.perf_counter_ns()
        self.process.stdin.write(line)
        self.process.stdin.flush()
        answer = self.process.stdout.readline()
        return time.perf_counter_ns() - start, answer

    def close(self) -> None:
        self.process.stdin.close()
        self.process.wait(timeout=60)
        self.process.stdout.close()
        self.process.stderr.close()


def mcp_line(index: int, request: dict) -> bytes:
    message = {"jsonrpc": "2.0", "id": index, "method": "tools/call", "params": {"name": request["tool"], "arguments": request["arguments"]}}
    return (json.dumps(message, separators=(",", ":")) + "\n").encode()


def rpc_line(index: int, request: dict) -> bytes:
    message = {"jsonrpc": "2.0", "id": index, "method": request["tool"], "params": request["arguments"]}
    return (json.dumps(message, separators=(",", ":")) + "\n").encode()


def timed_rounds(session: Session, lines: list[bytes], rounds: int, check) -> list[list[int]]:
    times: list[list[int]] = []
    for round_index in range(WARMUPS + rounds):
        row = []
        for line in lines:
            elapsed, answer = session.round_trip(line)
            check(answer)
            row.append(elapsed)
        if round_index >= WARMUPS:
            times.append(row)
    return times


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--optimize", default="ReleaseSmall", choices=("ReleaseSmall", "ReleaseFast", "Debug", "ReleaseSafe"))
    parser.add_argument("--rounds", type=int, default=15)
    parser.add_argument("--repetitions", type=int, default=3)
    parser.add_argument("--starts", type=int, default=20)
    options = parser.parse_args()

    with tempfile.TemporaryDirectory() as scratch_name:
        scratch = Path(scratch_name)
        built = subprocess.run(["zig", "build", f"-Doptimize={options.optimize}", "--prefix", str(scratch / "prefix")],
                               cwd=ROOT / "zig", capture_output=True, text=True)
        if built.returncode != 0:
            print(built.stderr, file=sys.stderr)
            return 1
        searchd = str(scratch / "prefix" / "bin" / "searchd")
        changes = scratch / "changes.json"
        changes.write_text(json.dumps(fixture_request()), encoding="utf-8")
        index = scratch / "index"
        subprocess.run([searchd, "apply", str(index), "--changes", str(changes)], check=True, capture_output=True)
        requests = requests_of_fixture()
        requests_file = scratch / "requests.jsonl"
        requests_file.write_text("".join(json.dumps(r) + "\n" for r in requests), encoding="utf-8")
        tools = ("find", "search_knowledge")
        print(f"optimize {options.optimize}; {len(requests)} requests ({len(requests) // 2} per tool), "
              f"{WARMUPS} warm-up then {options.rounds} timed rounds = {options.rounds * len(requests) // 2} timed calls per tool per repetition")

        def ok_mcp(answer: bytes) -> None:
            message = json.loads(answer)
            if message["result"].get("isError"):
                raise SystemExit(f"tool error: {answer[:200]!r}")

        def ok_rpc(answer: bytes) -> None:
            if b'"result"' not in answer[:60]:
                raise SystemExit(f"rpc error: {answer[:200]!r}")

        gate = True
        for repetition in range(1, options.repetitions + 1):
            direct_run = subprocess.run(
                ["zig", "run", f"-O{options.optimize}", str(ROOT / "zig" / "src" / "mcp_bench.zig"), "--",
                 str(index), str(requests_file), str(options.rounds)],
                capture_output=True, text=True, cwd=ROOT)
            if direct_run.returncode != 0:
                print(direct_run.stderr, file=sys.stderr)
                return 1
            direct = [[0] * len(requests) for _ in range(options.rounds)]
            for line in direct_run.stdout.splitlines():
                round_index, request_index, nanoseconds = (int(x) for x in line.split())
                direct[round_index][request_index] = nanoseconds

            mcp = Session([searchd, "mcp", str(index)])
            mcp.round_trip((json.dumps({"jsonrpc": "2.0", "id": 0, "method": "initialize", "params": {
                "protocolVersion": PROTOCOL_VERSION, "capabilities": {}, "clientInfo": {"name": "bench", "version": "1"}}}) + "\n").encode())
            mcp.process.stdin.write(b'{"jsonrpc":"2.0","method":"notifications/initialized"}\n')
            mcp_times = timed_rounds(mcp, [mcp_line(i + 1, r) for i, r in enumerate(requests)], options.rounds, ok_mcp)
            mcp.close()
            rpc = Session([searchd, "serve", str(index)])
            rpc_times = timed_rounds(rpc, [rpc_line(i + 1, r) for i, r in enumerate(requests)], options.rounds, ok_rpc)
            rpc.close()

            for tool in tools:
                columns = [i for i, r in enumerate(requests) if r["tool"] == tool]
                d = [direct[k][i] / 1000 for k in range(options.rounds) for i in columns]
                m = [mcp_times[k][i] / 1000 for k in range(options.rounds) for i in columns]
                r = [rpc_times[k][i] / 1000 for k in range(options.rounds) for i in columns]
                o = [(mcp_times[k][i] - direct[k][i]) / 1000 for k in range(options.rounds) for i in columns]
                p95_overhead = percentile(o, 0.95)
                gate = gate and p95_overhead <= 5000
                print(f"rep {repetition} {tool:16} n={len(d)}  direct p50 {percentile(d, .5):8.1f} p95 {percentile(d, .95):8.1f} us | "
                      f"MCP round trip p50 {percentile(m, .5):8.1f} p95 {percentile(m, .95):8.1f} us | "
                      f"RPC round trip p50 {percentile(r, .5):8.1f} p95 {percentile(r, .95):8.1f} us | "
                      f"overhead (paired) p50 {percentile(o, .5):8.1f} p95 {p95_overhead:8.1f} us | "
                      f"p95(MCP)-p95(direct) {percentile(m, .95) - percentile(d, .95):8.1f} us")

        init_ms: list[float] = []
        list_ms: list[float] = []
        initialize = (json.dumps({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
            "protocolVersion": PROTOCOL_VERSION, "capabilities": {}, "clientInfo": {"name": "bench", "version": "1"}}}) + "\n").encode()
        for _ in range(options.starts):
            start = time.perf_counter_ns()
            process = subprocess.Popen([searchd, "mcp", str(index)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            process.stdin.write(initialize)
            process.stdin.flush()
            process.stdout.readline()
            init_ms.append((time.perf_counter_ns() - start) / 1e6)
            process.stdin.write(b'{"jsonrpc":"2.0","method":"notifications/initialized"}\n{"jsonrpc":"2.0","id":2,"method":"tools/list"}\n')
            process.stdin.flush()
            process.stdout.readline()
            list_ms.append((time.perf_counter_ns() - start) / 1e6)
            process.stdin.close()
            process.wait(timeout=60)
            process.stdout.close()
            process.stderr.close()
        print(f"startup (spawn to initialize response) n={len(init_ms)}: p50 {percentile(init_ms, .5):.1f} ms, p95 {percentile(init_ms, .95):.1f} ms; "
              f"to the first tools/list response: p50 {percentile(list_ms, .5):.1f} ms, p95 {percentile(list_ms, .95):.1f} ms")
        print(f"gate (overhead p95 <= 5 ms for find and search_knowledge, every repetition): {'pass' if gate else 'FAIL'}")
        return 0 if gate else 1


if __name__ == "__main__":
    sys.exit(main())
