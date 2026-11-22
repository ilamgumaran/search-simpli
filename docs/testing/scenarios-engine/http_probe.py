#!/usr/bin/env python3
"""Start `searchd serve <index> --http 127.0.0.1:<port>`, send a few POSTs, stop it.

Usage: python3 -I http_probe.py <searchd> <index-dir> <port>
Prints one JSON line per probe: {"probe": ..., "status": ..., "body": ...}.
The server's stdin is a pipe that is closed at the end; the process is then
terminated if it is still running. Connecting is retried for at most 3 s
while the server starts.
"""
import http.client
import json
import subprocess
import sys
import time


def post(port, body, path="/", method="POST", headers=None):
    conn = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
    conn.request(method, path, body=body, headers=headers or {"Content-Type": "application/json"})
    response = conn.getresponse()
    data = response.read().decode("utf-8", "replace")
    conn.close()
    return response.status, data


def main():
    searchd, index_dir, port = sys.argv[1], sys.argv[2], int(sys.argv[3])
    proc = subprocess.Popen([searchd, "serve", index_dir, "--http", "127.0.0.1:%d" % port],
                            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    deadline = time.monotonic() + 3.0
    ready = False
    while time.monotonic() < deadline:
        try:
            post(port, json.dumps({"jsonrpc": "2.0", "id": 0, "method": "index_status", "params": {}}))
            ready = True
            break
        except OSError:
            time.sleep(0.05)
    probes = [
        ("index_status", json.dumps({"jsonrpc": "2.0", "id": 1, "method": "index_status", "params": {}}), "POST"),
        ("search", json.dumps({"jsonrpc": "2.0", "id": 2, "method": "search_knowledge",
                                "params": {"query": "leaky faucet", "retrieval_mode": "lexical", "top_k": 1}}), "POST"),
        ("find", json.dumps({"jsonrpc": "2.0", "id": 3, "method": "find", "params": {"query": "compost"}}), "POST"),
        ("malformed", "{not json", "POST"),
        ("get", "", "GET"),
    ]
    out = [{"probe": "ready", "status": ready}]
    if ready:
        for name, body, method in probes:
            try:
                status, data = post(port, body, method=method)
                out.append({"probe": name, "status": status, "body": data[:4000]})
            except OSError as error:
                out.append({"probe": name, "status": "error", "body": str(error)})
    proc.stdin.close()
    try:
        proc.wait(timeout=3)
        exited = "exited %d on stdin close" % proc.returncode
    except subprocess.TimeoutExpired:
        proc.terminate()
        proc.wait(timeout=3)
        exited = "still running after stdin close; terminated"
    out.append({"probe": "shutdown", "status": exited, "stderr": proc.stderr.read().decode("utf-8", "replace")[:300]})
    for item in out:
        print(json.dumps(item, ensure_ascii=False))


if __name__ == "__main__":
    main()
