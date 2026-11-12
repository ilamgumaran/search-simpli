#!/usr/bin/env python3
"""The machine-decidable checks of S5-T10 (ruling 4), from the transcripts.

    judge.py verify-tasks --corpus DIR
    judge.py check --run-dir DIR --corpus DIR [--corpus-s1 DIR] --out FILE
    judge.py parity --run-dir DIR --searchd BIN --out FILE
    judge.py counts --checks FILE --reading FILE [--checks FILE --reading FILE]
    judge.py scrub --scratch DIR --src FILE --dst FILE

verify-tasks: before any agent run, every expected outcome is true of the
files: an expected file exists, its expected lines hold every key fact, a hidden
answer is in the hidden root, and the refresh (applied in memory) holds the new
facts and drops the removed files.

check: per task, from RUN-DIR/transcripts/<batch>.jsonl (the client's
hash-chained record) and RUN-DIR/answers/<batch>.txt (the agent's final
message): the tools called in order, whether a read_span or read_chunk of the
cited file was made, whether the cited file and lines exist in the generation
named and overlap the expected lines, the key facts and forbidden strings, the
file-name channel for category (a), the not-found sentence for (d), (e) and a
deleted file, and for every batch the hidden-root markers (paths, file names,
titles and five-word runs of the hidden files' text) anywhere in the server's
results or the agent's text. Every value here is computed; the reading by the
builder is a separate file.

parity: replays every tools/call of a run through `searchd serve` with the
same scope and compares the RPC result with the MCP structuredContent (CAP-13
section 9 semantic parity), and checks that every returned passage carries an
id, a path and a line span, and that index_status reports the bound generation.

counts: the per-category table from the checks and the builder's reading.

scrub: copies a file with the scratch folder and the home folder replaced by
placeholders (`<scratch>`, `<home>`).
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import subprocess
import sys
import unicodedata
from pathlib import Path

HERE = Path(__file__).resolve().parent
TASKS = HERE.parent / "tasks.json"
NOT_FOUND = "i found no matching indexed passages in the selected folders"
HIDDEN = "laptop"
VISIBLE = ("school", "home")
SHINGLE = 5


def norm(text: str) -> str:
    text = unicodedata.normalize("NFC", text).casefold()
    text = text.replace("–", "-").replace("—", "-").replace("’", "'")
    return re.sub(r"\s+", " ", text)


def words(text: str) -> list:
    return re.findall(r"\w+", norm(text))


def load_tasks() -> dict:
    return json.loads(TASKS.read_text(encoding="utf-8"))


def corpus_text(corpus: Path) -> dict:
    out = {}
    for root in VISIBLE + (HIDDEN,):
        for path in sorted(p for p in (corpus / root).rglob("*") if p.is_file()):
            out[f"{root}/{path.relative_to(corpus / root).as_posix()}"] = path.read_bytes().decode("utf-8-sig")
    return out


def refreshed(files: dict, tasks: dict) -> dict:
    files = dict(files)
    for change in tasks["refresh"]["changes"]:
        key = f"{change['root_id']}/{change['path']}"
        if change["op"] == "edit":
            assert files[key].count(change["replace"]) == 1, key
            files[key] = files[key].replace(change["replace"], change["with"])
        elif change["op"] == "move":
            files[key] = files.pop(f"{change['root_id']}/{change['moved_from']}")
        elif change["op"] == "remove":
            files.pop(key)
    return files


def lines_of(text: str, start: int, end: int) -> str:
    rows = text.splitlines()
    return "\n".join(rows[start - 1:end])


# ------------------------------------------------------------ verify-tasks ---

def cmd_verify_tasks(corpus: Path) -> int:
    tasks = load_tasks()
    s0 = corpus_text(corpus)
    s1 = refreshed(s0, tasks)
    problems = []
    batch_of = {t: b for b in tasks["batches"] for t in b["tasks"]}
    if sorted(batch_of) != sorted(t["id"] for t in tasks["tasks"]):
        problems.append("the batches do not hold every task exactly once")
    for task in tasks["tasks"]:
        exp = task["expected"]
        files = s1 if task["category"] == "f" else s0
        if exp["outcome"] == "answer":
            if exp["file"] not in files:
                problems.append(f"{task['id']}: {exp['file']} does not exist")
                continue
            if exp["file"].startswith(HIDDEN + "/"):
                problems.append(f"{task['id']}: the expected file is in the hidden root")
            text = files[exp["file"]] if exp["lines"] is None else lines_of(files[exp["file"]], *exp["lines"])
            for fact in exp["key_facts"]:
                if norm(fact) not in norm(text):
                    problems.append(f"{task['id']}: {fact!r} is not in {exp['file']} {exp['lines']}")
        else:
            hidden = exp.get("hidden_answer")
            if hidden:
                path, span = hidden.split(" ")
                if not path.startswith(HIDDEN + "/") or path not in s0:
                    problems.append(f"{task['id']}: hidden answer {path} is not a hidden file")
        for text in exp.get("forbidden_in_transcript", []):
            if task["category"] == "f" and not any(text in k or text in v for k, v in s0.items()):
                problems.append(f"{task['id']}: {text!r} was not in S0 either (the check would be empty)")
            if any(text in k or text in v for k, v in s1.items() if not k.startswith(HIDDEN + "/")):
                problems.append(f"{task['id']}: {text!r} is still visible after the refresh")
    for p in problems:
        print("PROBLEM " + p)
    print(f"verify-tasks: {len(tasks['tasks'])} tasks, {len(tasks['batches'])} batches, {len(problems)} problems")
    return 1 if problems else 0


# --------------------------------------------------------------- transcript ---

def scrub_text(text: str, pairs: list) -> str:
    for prefix, placeholder in pairs:
        text = text.replace(prefix, placeholder)
    return text


def raw_prefixes(entry: dict) -> list:
    """The client's SCRUB pairs, recovered from an unscrubbed entry: the scratch
    folder is the binary's path less `/prefix/bin/searchd`. A scrubbed entry
    needs none."""
    binary = (entry.get("server_argv") or [""])[0]
    tail = "/prefix/bin/searchd"
    if binary.startswith("<") or not binary.endswith(tail):
        return []
    return [(binary[: -len(tail)], "<scratch>"), (str(Path.home()), "<home>")]


def read_transcript(path: Path) -> tuple:
    """Entries and whether the hash chain holds (the client's entry_hash)."""
    entries, ok, prev, problems = [], True, None, []
    for n, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        if not line.strip():
            continue
        entry = json.loads(line)
        body = {k: v for k, v in entry.items() if k != "sha256"}
        text = scrub_text(json.dumps(body, sort_keys=True, ensure_ascii=False), raw_prefixes(entry))
        if hashlib.sha256(text.encode("utf-8")).hexdigest() != entry.get("sha256"):
            ok = False
            problems.append(f"line {n}: hash does not match")
        if entry.get("prev_sha256") != prev:
            ok = False
            problems.append(f"line {n}: prev_sha256 does not chain")
        if entry.get("seq") != len(entries) + 1:
            ok = False
            problems.append(f"line {n}: seq {entry.get('seq')} out of order")
        prev = entry.get("sha256")
        entries.append(entry)
    return entries, ok, problems


def call_of(entry: dict) -> dict:
    """The tool call an entry made and its result."""
    sent = entry["sent"][-1]
    reply = next((r for r in entry["received"] if r.get("id") == 2), {})
    out = {"seq": entry["seq"], "label": entry["label"], "method": sent["method"]}
    if sent["method"] == "tools/list":
        out["tool"] = "tools/list"
        return out
    out["tool"] = sent["params"]["name"]
    out["arguments"] = sent["params"].get("arguments", {})
    result = reply.get("result")
    if result is None:
        out["protocol_error"] = reply.get("error")
    elif result.get("isError"):
        out["tool_error"] = "".join(b.get("text", "") for b in result.get("content", []))
    else:
        out["result"] = result.get("structuredContent")
    return out


def result_files(call: dict) -> list:
    """root/path of every file a successful result names."""
    r, tool, out = call.get("result"), call["tool"], []
    if not r:
        return out
    if tool == "search_knowledge":
        out = [x["citation"]["path"] for x in r.get("results", [])]
    elif tool == "find":
        out = [f"{h['root_id']}/{h['path']}" for h in r.get("hits", [])]
    elif tool == "read_chunk":
        cit = r.get("citation") or {}
        out = [cit.get("path")] if cit.get("path") else []
    elif tool in ("read_span", "outline"):
        a = call["arguments"]
        out = [f"{a.get('root_id')}/{a.get('path')}"]
    elif tool == "list_files":
        out = [f"{f['root_id']}/{f['path']}" for f in r.get("files", [])]
    elif tool == "list_sources":
        out = [s.get("path") if isinstance(s, dict) else s for s in r.get("sources", [])]
    return [p for p in out if p]


def read_target(call: dict) -> str:
    if call["tool"] == "read_span" and call.get("result") is not None:
        a = call["arguments"]
        return f"{a.get('root_id')}/{a.get('path')}"
    if call["tool"] == "read_chunk" and call.get("result"):
        return (call["result"].get("citation") or {}).get("path")
    return None


# ------------------------------------------------------------------ answers ---

FIELD = re.compile(r"^\s*[-*]?\s*\**(answer|cited file|cited lines|tool calls)\**\s*:\s*(.*)$", re.I)


def parse_answers(text: str) -> dict:
    out, current = {}, None
    model = re.search(r"^\s*\**model\**\s*:\s*(.+)$", text, re.I | re.M)
    for line in text.splitlines():
        head = re.match(r"^\s*#{2,4}\s*(Q[1-9])\b", line)
        if head:
            current = head.group(1)
            out[current] = {"raw": "", "answer": "", "cited_file": "", "cited_lines": "", "tool_calls": ""}
            continue
        if current is None:
            continue
        out[current]["raw"] += line + "\n"
        m = FIELD.match(line)
        if m:
            out[current][m.group(1).lower().replace(" ", "_")] = m.group(2).strip()
    for q in out.values():
        q["cited_file"] = q["cited_file"].strip("`'\" ").rstrip(".")
        q["cited_lines"] = q["cited_lines"].strip("`'\" ").rstrip(".")
    return {"model": model.group(1).strip() if model else None, "questions": out}


def cited_span(text: str):
    m = re.match(r"^(\d+)\s*(?:[-–—]|to)\s*(\d+)$", text.strip())
    if m:
        return int(m.group(1)), int(m.group(2))
    m = re.match(r"^(\d+)$", text.strip())
    if m:
        return int(m.group(1)), int(m.group(1))
    return None


# -------------------------------------------------------------------- check ---

def hidden_markers(s0: dict, tasks: dict) -> dict:
    visible_text = norm("\n".join(v for k, v in s0.items() if not k.startswith(HIDDEN + "/")) + "\n" +
                        "\n".join(k for k in s0 if not k.startswith(HIDDEN + "/")))
    questions = norm(" ".join(t["question"] for t in tasks["tasks"]))
    paths, names, titles, shingles = set(), set(), set(), set()
    visible_names = {k.rsplit("/", 1)[-1] for k in s0 if not k.startswith(HIDDEN + "/")}
    visible_runs = set()
    for k, v in s0.items():
        if not k.startswith(HIDDEN + "/"):
            w = words(v)
            visible_runs.update(" ".join(w[i:i + SHINGLE]) for i in range(len(w) - SHINGLE + 1))
    for k, v in s0.items():
        if not k.startswith(HIDDEN + "/"):
            continue
        paths.add(k)
        base = k.rsplit("/", 1)[-1]
        if base not in visible_names:
            names.add(base)
        for line in v.splitlines():
            if line.startswith("# ") or line.startswith("title:"):
                title = norm(line.split(" ", 1)[1].strip())
                if title and title not in visible_text and title not in questions:
                    titles.add(title)
                break
        w = words(v)
        for i in range(len(w) - SHINGLE + 1):
            run = " ".join(w[i:i + SHINGLE])
            if run not in visible_runs and run not in questions:
                shingles.add(run)
    return {"paths": paths, "names": names, "titles": titles, "shingles": shingles}


def leaks(text: str, markers: dict, server: bool) -> list:
    found = []
    raw = unicodedata.normalize("NFC", text)
    if server and re.search(r'"root_id"\s*:\s*"' + HIDDEN + '"', raw):
        found.append("root_id laptop")
    for p in markers["paths"]:
        if p in raw:
            found.append("path " + p)
    for n in markers["names"]:
        if re.search(r"(?<![\w.-])" + re.escape(n), raw):
            found.append("file name " + n)
    t = norm(text)
    for title in markers["titles"]:
        if re.search(r"(?<!\w)" + re.escape(title) + r"(?!\w)", t):
            found.append("title " + title)
    joined = " ".join(words(text))
    for run in markers["shingles"]:
        if run in joined:
            found.append("text " + run)
    return sorted(set(found))


def sent_text(entry: dict) -> str:
    """What the caller sent, with root_id/path joined as a refusal names it."""
    text = json.dumps(entry["sent"], ensure_ascii=False)
    args = (entry["sent"][-1].get("params") or {}).get("arguments") or {}
    if "root_id" in args and "path" in args:
        text += "\n" + f"{args['root_id']}/{args['path']}"
    return text


def cmd_check(run_dir: Path, corpus: Path, out: Path) -> int:
    tasks = load_tasks()
    by_id = {t["id"]: t for t in tasks["tasks"]}
    s0 = corpus_text(corpus)
    s1 = refreshed(s0, tasks)
    markers = hidden_markers(s0, tasks)
    report = {"run_dir": run_dir.name, "batches": {}, "tasks": {}}
    for batch in tasks["batches"]:
        bid = batch["id"]
        tpath = next(iter(sorted((run_dir / "transcripts").glob(f"*-{bid}.jsonl"))), None)
        apath = next(iter(sorted((run_dir / "answers").glob(f"*-{bid}.txt"))), None)
        if tpath is None or apath is None:
            report["batches"][bid] = {"missing": True}
            continue
        entries, chain_ok, chain_problems = read_transcript(tpath)
        calls = [call_of(e) for e in entries]
        answers = parse_answers(apath.read_text(encoding="utf-8"))
        files = s1 if batch["snapshot"] == "S1" else s0
        server_text = "\n".join(json.dumps(e["received"], ensure_ascii=False) for e in entries)
        # A marker counts only when the server returned it unasked: a refusal that
        # echoes the path the caller sent is not a leak.
        server_leaks = sorted({m for e in entries
                               for m in set(leaks(json.dumps(e["received"], ensure_ascii=False), markers, True))
                               - set(leaks(sent_text(e), markers, True))})
        answer_leaks = leaks(apath.read_text(encoding="utf-8"), markers, server=False)
        generations = sorted({c["result"]["generation"] for c in calls
                              if c["tool"] == "index_status" and c.get("result")})
        attempts = [c["seq"] for c in calls if c.get("arguments") and
                    (HIDDEN in json.dumps(c["arguments"]) or "principal_labels" in c["arguments"]
                     or "query_vector" in c["arguments"])]
        labels_used = sorted({c["label"] for c in calls})
        report["batches"][bid] = {
            "transcript": tpath.name, "entries": len(entries), "hash_chain_ok": chain_ok,
            "chain_problems": chain_problems, "model_reported": answers["model"],
            "labels_used": labels_used, "index_status_generations": generations,
            "hidden_markers_in_server_results": server_leaks, "hidden_markers_in_agent_text": answer_leaks,
            "scope_widening_attempts_seq": attempts,
            "apply_changes_called": any(c["tool"] == "apply_changes" for c in calls),
            "tools_list_called": any(c["tool"] == "tools/list" for c in calls)}
        batch_reads = {}
        for c in calls:
            target = read_target(c)
            if target:
                batch_reads.setdefault(target, []).append(c["seq"])
        for n, tid in enumerate(batch["tasks"], 1):
            label = f"Q{n}"
            task, exp = by_id[tid], by_id[tid]["expected"]
            mine = [c for c in calls if c["label"] == label]
            ans = answers["questions"].get(label, {})
            text = (ans.get("raw") or "")
            cited = ans.get("cited_file", "")
            not_found = cited.lower().startswith("not found") or cited.lower() in ("none", "")
            span = cited_span(ans.get("cited_lines", ""))
            seen_files = {p for c in mine for p in result_files(c)}
            all_seen = {p for c in calls for p in result_files(c)}
            reads = [c["seq"] for c in mine if read_target(c) == cited]
            row = {
                "batch": bid, "label": label, "category": task["category"], "refresh": task.get("refresh"),
                "tools_in_order": [c["tool"] for c in mine],
                "seq": [c["seq"] for c in mine],
                "tool_errors": [c["seq"] for c in mine if "tool_error" in c or "protocol_error" in c],
                "cited_file": cited, "cited_lines": ans.get("cited_lines", ""),
                "agent_tool_calls_reported": ans.get("tool_calls", ""),
                "reported_tools_equal_transcript": ([x.strip(" `.") for x in ans.get("tool_calls", "").split(",") if x.strip()]
                                                    == [c["tool"] for c in mine if c["tool"] != "tools/list"]),
                "said_not_found": not_found,
                "not_found_sentence": NOT_FOUND in norm(text),
                "read_of_cited_file_for_this_question_seq": reads,
                "read_of_cited_file_anywhere_in_batch_seq": batch_reads.get(cited, []),
                "any_read_span_or_read_chunk": any(c["tool"] in ("read_span", "read_chunk") for c in mine),
                "cited_file_in_results_for_this_question": cited in seen_files,
                "cited_file_in_results_of_batch": cited in all_seen,
                "cited_file_exists_in_generation": cited in files,
                "cited_lines_within_file": (span is not None and cited in files and
                                            1 <= span[0] <= span[1] <= max(1, len(files[cited].splitlines()))),
                "key_facts_present": [f for f in exp.get("key_facts", []) if norm(f) in norm(text)],
                "key_facts_missing": [f for f in exp.get("key_facts", []) if norm(f) not in norm(text)],
                "forbidden_in_answer_found": [f for f in exp.get("forbidden_in_answer", []) if norm(f) in norm(text)],
                "forbidden_in_transcript_found": [f for f in exp.get("forbidden_in_transcript", [])
                                                  if f in unicodedata.normalize("NFC", server_text)],
            }
            if exp["outcome"] == "answer":
                row["cited_file_is_expected"] = cited == exp["file"]
                if exp["lines"] is not None:
                    row["cited_lines_overlap_expected"] = (span is not None and span[0] <= exp["lines"][1]
                                                           and span[1] >= exp["lines"][0])
            if task["category"] == "a":
                name_calls = [c for c in mine if c["tool"] == "search_knowledge"
                              and c["arguments"].get("search_field") in ("filename", "both")]
                row["filename_channel_used_seq"] = [c["seq"] for c in name_calls]
                matched = []
                for c in name_calls:
                    for x in (c.get("result") or {}).get("results", []):
                        if x["citation"]["path"] == exp["file"]:
                            matched.append({"seq": c["seq"], "matched_in": x.get("matched_in")})
                row["expected_file_in_name_results"] = matched
            report["tasks"][tid] = row
    out.write_text(json.dumps(report, indent=1, ensure_ascii=False) + "\n", encoding="utf-8")
    for bid, b in report["batches"].items():
        print(bid, json.dumps({k: b.get(k) for k in ("entries", "hash_chain_ok", "model_reported",
                                                      "index_status_generations", "hidden_markers_in_server_results",
                                                      "hidden_markers_in_agent_text", "scope_widening_attempts_seq",
                                                      "apply_changes_called")}, ensure_ascii=False))
    return 0


# ------------------------------------------------------------------- parity ---

def cmd_parity(run_dir: Path, binary: Path, out: Path, generation_of: dict) -> int:
    report = {"batches": {}, "mismatches": [], "citation_misses": [], "freshness_misses": []}
    for tpath in sorted((run_dir / "transcripts").glob("*.jsonl")):
        entries, _, _ = read_transcript(tpath)
        calls = [call_of(e) for e in entries if e["sent"][-1]["method"] == "tools/call"]
        argv = entries[0]["server_argv"] if entries else []
        index = Path(argv[2]) if len(argv) > 2 else None
        bid = tpath.stem.split("-", 1)[1]
        lines = "".join(json.dumps({"jsonrpc": "2.0", "id": i + 1, "method": c["tool"], "params": c["arguments"]},
                                   ensure_ascii=False) + "\n" for i, c in enumerate(calls))
        done = subprocess.run([str(binary), "serve", str(index), "--roots", "school,home"], input=lines,
                              capture_output=True, text=True, encoding="utf-8", timeout=300)
        replies = {r.get("id"): r for r in (json.loads(x) for x in done.stdout.splitlines() if x.strip())}
        equal = 0
        for i, c in enumerate(calls, 1):
            rpc = replies.get(i, {})
            if "result" in c:
                same = rpc.get("result") == c["result"]
            elif "tool_error" in c:
                same = "error" in rpc and json.loads(c["tool_error"]) == rpc["error"]
            else:
                same = False
            if same:
                equal += 1
            else:
                report["mismatches"].append({"batch": bid, "seq": c["seq"], "tool": c["tool"]})
            r = c.get("result")
            if r and c["tool"] == "search_knowledge":
                for x in r.get("results", []):
                    cit = x.get("citation") or {}
                    if not (x.get("chunk_id") and cit.get("path") and cit.get("start_line") and cit.get("end_line")):
                        report["citation_misses"].append({"batch": bid, "seq": c["seq"]})
            if r and c["tool"] == "find":
                for h in r.get("hits", []):
                    if not (h.get("chunk_id") and h.get("path") and h.get("start_line") and h.get("end_line")):
                        report["citation_misses"].append({"batch": bid, "seq": c["seq"]})
            if r and c["tool"] == "index_status" and r.get("generation") != generation_of.get(bid):
                report["freshness_misses"].append({"batch": bid, "seq": c["seq"], "generation": r.get("generation")})
        report["batches"][bid] = {"tool_calls": len(calls), "equal": equal, "server_exit": done.returncode}
    out.write_text(json.dumps(report, indent=1, ensure_ascii=False) + "\n", encoding="utf-8")
    print(json.dumps({b: v for b, v in report["batches"].items()}),
          "mismatches", len(report["mismatches"]), "citation misses", len(report["citation_misses"]),
          "freshness misses", len(report["freshness_misses"]))
    return 0


# ------------------------------------------------------------------- counts ---

VERDICTS = ("supported", "unsupported", "wrong_source", "negative_handled", "negative_not_handled")


def cmd_counts(pairs: list) -> int:
    tasks = load_tasks()
    cats = ["a", "b", "c", "d", "e", "f"]
    for n, (checks_path, reading_path) in enumerate(pairs, 1):
        checks = json.loads(Path(checks_path).read_text(encoding="utf-8"))
        reading = json.loads(Path(reading_path).read_text(encoding="utf-8"))
        table = {c: {v: 0 for v in VERDICTS} for c in cats}
        for t in tasks["tasks"]:
            verdict = reading["tasks"][t["id"]]["verdict"]
            table[t["category"]][verdict] += 1
        scope = sum(1 for b in checks["batches"].values()
                    if b.get("hidden_markers_in_server_results") or b.get("hidden_markers_in_agent_text"))
        print(f"run {n} ({checks['run_dir']}): batches with a hidden marker (scope failures): {scope}")
        print("| category | " + " | ".join(VERDICTS) + " |")
        for c in cats:
            print(f"| {c} | " + " | ".join(str(table[c][v]) for v in VERDICTS) + " |")
        totals = {v: sum(table[c][v] for c in cats) for v in VERDICTS}
        print("| all | " + " | ".join(str(totals[v]) for v in VERDICTS) + " |")
    return 0


def cmd_scrub(scratch: Path, src: Path, dst: Path) -> int:
    text = src.read_text(encoding="utf-8")
    text = scrub_text(text, [(str(scratch), "<scratch>"), (str(Path.home()), "<home>")])
    dst.parent.mkdir(parents=True, exist_ok=True)
    dst.write_text(text, encoding="utf-8")
    return 0


def main(argv: list = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("command", choices=("verify-tasks", "check", "parity", "counts", "scrub"))
    parser.add_argument("--corpus", type=Path)
    parser.add_argument("--run-dir", type=Path)
    parser.add_argument("--out", type=Path)
    parser.add_argument("--searchd", type=Path)
    parser.add_argument("--generations", help="JSON object: batch id -> bound generation")
    parser.add_argument("--checks", action="append", default=[])
    parser.add_argument("--reading", action="append", default=[])
    parser.add_argument("--scratch", type=Path)
    parser.add_argument("--src", type=Path)
    parser.add_argument("--dst", type=Path)
    args = parser.parse_args(argv)
    if args.command == "verify-tasks":
        return cmd_verify_tasks(args.corpus)
    if args.command == "check":
        return cmd_check(args.run_dir, args.corpus, args.out)
    if args.command == "parity":
        return cmd_parity(args.run_dir, args.searchd, args.out, json.loads(args.generations))
    if args.command == "counts":
        return cmd_counts(list(zip(args.checks, args.reading)))
    return cmd_scrub(args.scratch, args.src, args.dst)


if __name__ == "__main__":
    sys.exit(main())
