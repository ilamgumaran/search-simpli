#!/usr/bin/env python3
"""Measure filename-field costs on disposable invented files, never user data."""

import argparse
import hashlib
import json
import platform
import select
import subprocess
import tempfile
import time
from pathlib import Path


def rpc(process, request):
    process.stdin.write(json.dumps(request) + "\n")
    process.stdin.flush()
    if not select.select([process.stdout], [], [], 30)[0]:
        raise RuntimeError("RPC measurement timed out")
    response = json.loads(process.stdout.readline())
    if "error" in response:
        raise RuntimeError(f"RPC failed: {response['error']}")
    return response["result"]


def percentiles(values):
    ordered = sorted(values)
    return {"p50_ms": ordered[len(ordered) // 2],
            "p95_ms": ordered[min(len(ordered) - 1, int(len(ordered) * .95))]}


def peak_rss_kib(pid):
    try:
        for line in Path(f"/proc/{pid}/status").read_text().splitlines():
            if line.startswith("VmHWM:"):
                return int(line.split()[1])
    except (FileNotFoundError, PermissionError):
        pass
    return None


def measure_server(binary, snapshot, field, files):
    start = time.perf_counter()
    process = subprocess.Popen([str(binary), "serve", str(snapshot)], text=True,
                               encoding="utf-8", stdin=subprocess.PIPE,
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    try:
        rpc(process, {"jsonrpc": "2.0", "id": 0, "method": "index_status", "params": {}})
        open_ms = (time.perf_counter() - start) * 1000
        timings = []
        for number in range(30):
            item = number % files
            query = f"marker{item:04d}" if field == "content" else f"note{item:04d}"
            if field == "both":
                query += f" marker{item:04d}"
            params = {"query": query, "retrieval_mode": "lexical", "top_k": 3}
            if field != "content":
                params["search_field"] = field
            start_query = time.perf_counter()
            result = rpc(process, {"jsonrpc": "2.0", "id": number + 1,
                                   "method": "search_knowledge", "params": params})
            timings.append((time.perf_counter() - start_query) * 1000)
            expected = f"note{item:04d}_record.md"
            if not result["results"] or result["results"][0]["citation"]["path"] != expected:
                raise AssertionError(f"wrong top result for {field} query {number}")
        return {"field": field, "startup_to_status_ms": open_ms,
                "queries": 30, **percentiles(timings),
                "process_peak_rss_kib": peak_rss_kib(process.pid), "errors": 0}
    finally:
        process.stdin.close()
        try:
            process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()
        process.stdout.close()
        process.stderr.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--searchd", type=Path, required=True)
    parser.add_argument("--baseline-searchd", type=Path, required=True)
    parser.add_argument("--files", type=int, default=1000)
    args = parser.parse_args()
    if args.files < 1:
        parser.error("--files must be positive")
    candidate, baseline = args.searchd.resolve(), args.baseline_searchd.resolve()
    report = {"kind": "filename-field-cost-v1", "files": args.files,
              "platform": platform.platform(), "binaries": {}, "builds": [], "queries": [],
              "method": "Three fresh-output builds per mode; existing OS page cache is not cleared. Startup is process launch to first status reply; steady timings are 30 sequential real RPC round trips including serialization. Linux VmHWM is KiB, otherwise null. No device latency target or representative relevance claim."}
    try:
        with tempfile.TemporaryDirectory(prefix="filename-cost-") as temporary:
            root = Path(temporary)
            corpus = root / "corpus"
            corpus.mkdir()
            digest = hashlib.sha256()
            for item in range(args.files):
                name = f"note{item:04d}_record.md"
                text = f"Field observation marker{item:04d} describes a stored measurement.\n"
                (corpus / name).write_text(text, encoding="utf-8")
                digest.update(name.encode() + b"\0" + text.encode() + b"\0")
            report["corpus_sha256"] = digest.hexdigest()
            for label, binary, enabled in (("baseline", baseline, False), ("candidate", candidate, True)):
                report["binaries"][label] = hashlib.sha256(binary.read_bytes()).hexdigest()
                for repetition in range(3):
                    snapshot = root / f"{label}-{repetition}"
                    command = [str(binary), "index", str(corpus), "--out", str(snapshot)]
                    if enabled:
                        command.append("--filename-index")
                    start = time.perf_counter()
                    built = subprocess.run(command, capture_output=True, timeout=120)
                    elapsed = (time.perf_counter() - start) * 1000
                    if built.returncode:
                        raise RuntimeError(f"{label} index failed: {built.stderr.decode(errors='replace')}")
                    report["builds"].append({"binary": label, "repetition": repetition,
                                             "wall_ms": elapsed,
                                             "snapshot_bytes": sum(p.stat().st_size for p in snapshot.iterdir() if p.is_file()),
                                             "exit_code": built.returncode})
                for field in (("content",) if not enabled else ("content", "filename", "both")):
                    report["queries"].append({"binary": label, **measure_server(binary, snapshot, field, args.files)})
        report["status"] = "passed"
    except Exception as error:
        report["status"] = "failed"
        report["error"] = str(error)
    print(json.dumps(report, indent=2))
    return 0 if report["status"] == "passed" else 1


if __name__ == "__main__":
    raise SystemExit(main())
