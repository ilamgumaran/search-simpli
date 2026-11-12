#!/usr/bin/env python3
"""Build the S5-T10 snapshots and the answering agents' client folders.

    snapshot.py s0 --searchd BIN --work DIR
    snapshot.py s1 --searchd BIN --work DIR --run N
    snapshot.py agent-dir --searchd BIN --work DIR --run N --batch ID

s0: copies the three J2 roots (fixtures/j2/school, home, laptop) to
DIR/corpus-s0 and builds DIR/index-s0 the way scripts/j2_run.py does (an empty
folder indexed with --filename-index, then `searchd apply` adds the three roots
with every file as content_base64), then writes DIR/identifiers-s0.json: the
source commit, the binary's hash, the generation, the roots and the policy ids,
as an unscoped `searchd serve` and as the agent's scoped `searchd mcp` see them.

s1: the refresh of tasks.json (category f), applied for run N: DIR/corpus-s1-runN
is the S0 copy with the edits, moves and removals made; DIR/index-s1-runN is a
copy of index-s0 to which the same changes are published through `searchd
apply` (host-fed changes). Writes DIR/identifiers-s1-runN.json with the apply
report. fixtures/j2 is never written.

agent-dir: DIR/agents/runN-ID/mcp_call.py, the client with its server command
line (`searchd mcp <index> --roots school,home`, read-only default mode) and its
transcript path (DIR/transcripts/runN-ID.jsonl) filled in. The folder holds
nothing else.

brief: DIR/briefs/runN-ID.txt, the answering agent's whole prompt: brief_template.txt
with the client's folder, skills/folder-knowledge/SKILL.md verbatim and the
batch's questions as Q1..Q6 in the frozen order. Nothing else of tasks.json.
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import shutil
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
EVIDENCE = HERE.parent
REPO = EVIDENCE.parent.parent.parent
FIXTURE = REPO / "fixtures" / "j2"
TASKS = EVIDENCE / "tasks.json"
ROOTS = ("school", "home", "laptop")
AGENT_ROOTS = "school,home"
POLICY_KEYS = ("filename_policy_id", "title_policy_id", "fuzzy_policy_id", "fold_policy_id")


def sha256_file(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def run(cmd: list) -> str:
    done = subprocess.run([str(c) for c in cmd], capture_output=True, text=True, timeout=300)
    if done.returncode != 0:
        raise SystemExit(f"snapshot: {cmd[1]} failed ({done.returncode}):\n{done.stdout}\n{done.stderr}")
    return done.stdout


def rpc(binary: Path, index: Path, calls: list, extra: tuple = ()) -> list:
    lines = "".join(json.dumps({"jsonrpc": "2.0", "id": i + 1, "method": m, "params": p}, ensure_ascii=False) + "\n"
                    for i, (m, p) in enumerate(calls))
    done = subprocess.run([str(binary), "serve", str(index), *extra], input=lines, capture_output=True,
                          text=True, encoding="utf-8", timeout=120)
    replies = [json.loads(line) for line in done.stdout.splitlines() if line.strip()]
    out = []
    for reply in replies:
        if "result" not in reply:
            raise SystemExit(f"snapshot: serve refused: {reply}")
        out.append(reply["result"])
    return out


def mcp_status(binary: Path, index: Path) -> dict:
    msgs = [{"jsonrpc": "2.0", "id": 1, "method": "initialize",
             "params": {"protocolVersion": "2025-11-25", "capabilities": {}, "clientInfo": {"name": "snapshot", "version": "1"}}},
            {"jsonrpc": "2.0", "method": "notifications/initialized"},
            {"jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": {"name": "index_status", "arguments": {}}},
            {"jsonrpc": "2.0", "id": 3, "method": "tools/list", "params": {}}]
    done = subprocess.run([str(binary), "mcp", str(index), "--roots", AGENT_ROOTS],
                          input="".join(json.dumps(m) + "\n" for m in msgs), capture_output=True, text=True,
                          encoding="utf-8", timeout=60)
    replies = {r.get("id"): r for r in (json.loads(x) for x in done.stdout.splitlines() if x.strip())}
    tools = replies[3]["result"]["tools"]
    return {"initialize": {k: replies[1]["result"].get(k) for k in ("protocolVersion", "serverInfo")},
            "index_status": replies[2]["result"]["structuredContent"],
            "tools": [t["name"] for t in tools],
            "tools_list_sha256": hashlib.sha256(json.dumps(tools, sort_keys=True).encode("utf-8")).hexdigest()}


def identifiers(binary: Path, index: Path) -> dict:
    status, both, content = rpc(binary, index, [
        ("index_status", {}),
        ("search_knowledge", {"query": "j2", "top_k": 1, "retrieval_mode": "lexical", "roots": list(ROOTS), "search_field": "both"}),
        ("search_knowledge", {"query": "j2", "top_k": 1, "retrieval_mode": "lexical", "roots": list(ROOTS), "search_field": "content"}),
    ])
    policies = {"analyzer_id": status.get("analyzer_id"), "chunkers": status.get("chunkers"),
                **{k: both["retrieval"].get(k) for k in POLICY_KEYS},
                "content_retrieval": {k: content["retrieval"].get(k) for k in POLICY_KEYS}}
    head = subprocess.run(["git", "-C", str(REPO), "rev-parse", "HEAD"], capture_output=True, text=True).stdout.strip()
    return {"source_commit": head,
            "binary": {"sha256": sha256_file(binary), "size": binary.stat().st_size},
            "tasks_sha256": sha256_file(TASKS),
            "unscoped_index_status": status, "policies": policies,
            "agent_view": mcp_status(binary, index)}


def corpus_files(base: Path) -> list:
    out = []
    for root in ROOTS:
        for path in sorted(p for p in (base / root).rglob("*") if p.is_file()):
            out.append((root, path.relative_to(base / root).as_posix(), path))
    return out


def cmd_s0(binary: Path, work: Path) -> None:
    corpus, index = work / "corpus-s0", work / "index-s0"
    if corpus.exists() or index.exists():
        raise SystemExit(f"snapshot: {corpus} or {index} exists; S0 is built once")
    for root in ROOTS:
        shutil.copytree(FIXTURE / root, corpus / root)
    empty = work / "empty"
    empty.mkdir(exist_ok=True)
    request = {"roots": [{"root_id": r, "label": r, "kind": "host"} for r in ROOTS],
               "changes": [{"op": "add", "root_id": r, "path": p,
                            "content_base64": base64.b64encode(f.read_bytes()).decode("ascii")}
                           for r, p, f in corpus_files(corpus)]}
    changes = work / "changes-s0.json"
    changes.write_text(json.dumps(request), encoding="utf-8")
    run([binary, "index", empty, "--out", index, "--filename-index"])
    report = run([binary, "apply", index, "--changes", changes, "--json"])
    ids = identifiers(binary, index)
    ids["apply_report"] = json.loads(report)
    ids["corpus_files"] = len(request["changes"])
    (work / "identifiers-s0.json").write_text(json.dumps(ids, indent=1, ensure_ascii=False) + "\n", encoding="utf-8")
    print(json.dumps({"generation": ids["unscoped_index_status"].get("generation"),
                      "agent_generation": ids["agent_view"]["index_status"].get("generation"),
                      "files": ids["corpus_files"]}))


def cmd_s1(binary: Path, work: Path, run_no: int) -> None:
    spec = json.loads(TASKS.read_text(encoding="utf-8"))["refresh"]["changes"]
    corpus, index = work / f"corpus-s1-run{run_no}", work / f"index-s1-run{run_no}"
    if corpus.exists() or index.exists():
        raise SystemExit(f"snapshot: {corpus} or {index} exists")
    shutil.copytree(work / "corpus-s0", corpus)
    shutil.copytree(work / "index-s0", index, symlinks=True)
    changes = []
    for change in spec:
        root = corpus / change["root_id"]
        if change["op"] == "edit":
            target = root / change["path"]
            data = target.read_bytes()
            old, new = change["replace"].encode("utf-8"), change["with"].encode("utf-8")
            if data.count(old) != 1:
                raise SystemExit(f"snapshot: {change['path']} holds the text to replace {data.count(old)} times")
            target.write_bytes(data.replace(old, new))
            changes.append({"op": "change", "root_id": change["root_id"], "path": change["path"],
                            "content_base64": base64.b64encode(target.read_bytes()).decode("ascii")})
        elif change["op"] == "move":
            source, target = root / change["moved_from"], root / change["path"]
            target.parent.mkdir(parents=True, exist_ok=True)
            source.rename(target)
            changes.append({"op": "move", "root_id": change["root_id"], "path": change["path"],
                            "moved_from": change["moved_from"]})
        elif change["op"] == "remove":
            (root / change["path"]).unlink()
            changes.append({"op": "remove", "root_id": change["root_id"], "path": change["path"]})
        else:
            raise SystemExit(f"snapshot: unknown refresh op {change['op']}")
    before = rpc(binary, index, [("index_status", {})])[0]
    path = work / f"changes-s1-run{run_no}.json"
    path.write_text(json.dumps({"expect_generation": before["generation"], "changes": changes}), encoding="utf-8")
    report = run([binary, "apply", index, "--changes", path, "--json"])
    ids = identifiers(binary, index)
    ids["apply_report"] = json.loads(report)
    ids["refreshed_from_generation"] = before["generation"]
    (work / f"identifiers-s1-run{run_no}.json").write_text(json.dumps(ids, indent=1, ensure_ascii=False) + "\n",
                                                           encoding="utf-8")
    print(json.dumps({"from": before["generation"], "generation": ids["unscoped_index_status"].get("generation"),
                      "report": ids["apply_report"]}, ensure_ascii=False))


def cmd_agent_dir(binary: Path, work: Path, run_no: int, batch: str) -> None:
    tasks = json.loads(TASKS.read_text(encoding="utf-8"))
    snapshot = next(b["snapshot"] for b in tasks["batches"] if b["id"] == batch)
    index = work / ("index-s0" if snapshot == "S0" else f"index-s1-run{run_no}")
    if not index.is_dir():
        raise SystemExit(f"snapshot: {index} is missing")
    folder = work / "agents" / f"run{run_no}-{batch}"
    transcript = work / "transcripts" / f"run{run_no}-{batch}.jsonl"
    if folder.exists() or transcript.exists():
        raise SystemExit(f"snapshot: {folder} or {transcript} exists")
    folder.mkdir(parents=True)
    transcript.parent.mkdir(parents=True, exist_ok=True)
    text = (HERE / "mcp_call_template.py").read_text(encoding="utf-8")
    argv = [str(binary), "mcp", str(index), "--roots", AGENT_ROOTS]
    text = (text.replace("__SERVER_ARGV__", json.dumps(argv)).replace("__TRANSCRIPT__", json.dumps(str(transcript)))
            .replace("__BATCH__", json.dumps(f"run{run_no}-{batch}"))
            .replace("__SCRUB__", json.dumps([[str(work.parent), "<scratch>"], [str(Path.home()), "<home>"]])))
    (folder / "mcp_call.py").write_text(text, encoding="utf-8")
    print(folder / "mcp_call.py")


def cmd_brief(work: Path, run_no: int, batch: str) -> None:
    tasks = json.loads(TASKS.read_text(encoding="utf-8"))
    by_id = {t["id"]: t for t in tasks["tasks"]}
    order = next(b["tasks"] for b in tasks["batches"] if b["id"] == batch)
    folder = work / "agents" / f"run{run_no}-{batch}"
    if not (folder / "mcp_call.py").is_file():
        raise SystemExit(f"snapshot: run agent-dir first ({folder})")
    questions = "\n".join(f"Q{n}. {by_id[t]['question']}" for n, t in enumerate(order, 1))
    skill = (REPO / "skills" / "folder-knowledge" / "SKILL.md").read_text(encoding="utf-8").rstrip("\n")
    text = ((HERE / "brief_template.txt").read_text(encoding="utf-8").replace("__AGENT_DIR__", str(folder))
            .replace("__SKILL__", skill).replace("__QUESTIONS__", questions))
    out = work / "briefs" / f"run{run_no}-{batch}.txt"
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(text, encoding="utf-8")
    print(out)


def main(argv: list = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("command", choices=("s0", "s1", "agent-dir", "brief"))
    parser.add_argument("--searchd", type=Path)
    parser.add_argument("--work", type=Path, required=True)
    parser.add_argument("--run", type=int)
    parser.add_argument("--batch")
    args = parser.parse_args(argv)
    work = args.work.resolve()
    work.mkdir(parents=True, exist_ok=True)
    if args.command == "brief":
        cmd_brief(work, args.run, args.batch)
        return 0
    if args.searchd is None:
        parser.error("--searchd is required")
    binary = args.searchd.resolve()
    if args.command == "s0":
        cmd_s0(binary, work)
    elif args.command == "s1":
        cmd_s1(binary, work, args.run)
    else:
        cmd_agent_dir(binary, work, args.run, args.batch)
    return 0


if __name__ == "__main__":
    sys.exit(main())
