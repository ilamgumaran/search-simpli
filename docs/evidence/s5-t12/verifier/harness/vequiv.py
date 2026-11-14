#!/usr/bin/env python3
"""Verifier's equivalence run for S5-T12: the same requests through two
`searchd serve` binaries, compared byte for byte.

    python3 -I vequiv.py REPO BEFORE_SEARCHD AFTER_SEARCHD WORKDIR OUT_JSON

Two J2 indexes, both written by BEFORE's `searchd apply --filename-index`:
`plain` (the pack as is: no labelled record) and `labelled` (the pack plus
three invented files that require the label `grown-ups`, one per root, with
two invented words and real pack words, so a hidden file changes the visible
key df of common words). Every J2 query is asked of each index under four
scopes (no `roots` at all, all three named, two, one), as a caller without
and with the label, under `search_field` content, both and filename, and as
`find` words, phrase and prefix. Then the privacy check: without the label no
response may cite a hidden file or hold its invented words outside the echo.
"""
from __future__ import annotations

import base64
import json
import subprocess
import sys
from pathlib import Path

SCOPES = {"none": None, "all": ["school", "home", "laptop"], "two": ["school", "home"], "one": ["home"]}
PRINCIPALS = {"anon": None, "label": ["grown-ups"]}
HIDDEN = [
    ("home", "notes/vormish-ledger.md", "# Vormish ledger\n\nThe vormish budget for the school trip and the swimming lessons, "
     "the dentist and the birthday party. Kettrel savings, kettrels and homework money.\n"),
    ("school", "staff/kettrel-review.md", "# Kettrel review\n\nVolcano project marks, spelling test results and the reading "
     "log for the vormish group. Homework, homeworks.\n"),
    ("laptop", "private/vormish-plans.md", "# Vormish plans\n\nSystem passwords, the garden diary backup, planet model "
     "notes, kettrel painting and paintings.\n"),
]
SECRET_WORDS = ("vormish", "kettrel")
EXTRA_QUERIES = ["vormish", "vormishes", "kettrel", "kettrels", "kettrel review", "vormish budget", "homework", "homeworks",
                 "painting", "paint", "swimming", "swim", "volcano project", "birthday party", "system", "garden"]


class Serve:
    def __init__(self, binary: Path, index: Path) -> None:
        self.p = subprocess.Popen([str(binary), "serve", str(index)], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                  stderr=subprocess.PIPE, text=True, encoding="utf-8")
        self.n = 0

    def call(self, method: str, params: dict) -> str:
        self.n += 1
        self.p.stdin.write(json.dumps({"jsonrpc": "2.0", "id": self.n, "method": method, "params": params}, ensure_ascii=False) + "\n")
        self.p.stdin.flush()
        line = self.p.stdout.readline()
        if not line:
            raise SystemExit(f"searchd closed during {method}: {self.p.stderr.read()[:2000]}")
        reply = json.loads(line)
        if "result" not in reply:
            return json.dumps({"error": reply.get("error")}, sort_keys=True)
        return json.dumps(reply["result"], ensure_ascii=False, sort_keys=True)

    def close(self) -> None:
        self.p.stdin.close()
        self.p.wait(timeout=60)
        self.p.stdout.close()
        self.p.stderr.close()


def changes(pack: Path, roots: list[str], hidden: bool) -> dict:
    req = {"roots": [{"root_id": r, "label": r, "kind": "host"} for r in roots], "changes": []}
    for root in roots:
        base = pack / root
        for path in sorted(p for p in base.rglob("*") if p.is_file()):
            req["changes"].append({"op": "add", "root_id": root, "path": path.relative_to(base).as_posix(),
                                   "content_base64": base64.b64encode(path.read_bytes()).decode("ascii")})
    if hidden:
        for root, path, text in HIDDEN:
            req["changes"].append({"op": "add", "root_id": root, "path": path, "required_labels": ["grown-ups"],
                                   "content_base64": base64.b64encode(text.encode()).decode("ascii")})
    return req


def build(binary: Path, work: Path, name: str, req: dict) -> Path:
    (work / f"{name}.json").write_text(json.dumps(req), encoding="utf-8")
    index = work / name
    done = subprocess.run([str(binary), "apply", str(index), "--changes", str(work / f"{name}.json"), "--filename-index"],
                          capture_output=True, text=True, timeout=300)
    if done.returncode != 0:
        raise SystemExit(f"apply failed: {done.stdout}\n{done.stderr}")
    return index


def requests(queries: list[str]):
    for qi, q in enumerate(queries):
        for scope, roots in SCOPES.items():
            for who, labels in PRINCIPALS.items():
                extra = {}
                if roots is not None:
                    extra["roots"] = roots
                if labels is not None:
                    extra["principal_labels"] = labels
                for field in ("content", "both", "filename"):
                    yield (qi, scope, who, field), "search_knowledge", {"query": q, "top_k": 10, "retrieval_mode": "lexical",
                                                                       "search_field": field, **extra}
                for mode in ("words", "phrase", "prefix"):
                    yield (qi, scope, who, "find-" + mode), "find", {"query": q, "mode": mode, "page_size": 10, **extra}


def main(argv: list[str]) -> int:
    repo, before, after, work, out = (Path(a) for a in argv[1:6])
    pack = repo / "fixtures" / "j2"
    judgments = json.loads((pack / "judgments.json").read_text(encoding="utf-8"))
    queries = [q["query"] for q in judgments["queries"]] + EXTRA_QUERIES
    work.mkdir(parents=True, exist_ok=False)
    report = {"queries": len(queries)}
    total_differ = total_errors = 0
    leaks = []
    found_with_label = {"cases": 0, "found": 0}
    for name, hidden in (("plain", False), ("labelled", True)):
        index = build(before, work, name, changes(pack, judgments["roots"], hidden))
        answers = {}
        for side, binary in (("before", before), ("after", after)):
            s = Serve(binary, index)
            try:
                answers[side] = {k: s.call(m, p) for k, m, p in requests(queries)}
            finally:
                s.close()
        keys = list(answers["before"])
        differ = [k for k in keys if answers["before"][k] != answers["after"][k]]
        errors = [k for k in keys if answers["after"][k].startswith('{"error"') or answers["before"][k].startswith('{"error"')]
        by = {}
        for k in keys:
            kind = f"{k[1]}/{k[2]}/{k[3]}"
            by.setdefault(kind, [0, 0])
            by[kind][0] += 1
            by[kind][1] += k in differ
        report[name] = {"requests": len(keys), "differ": len(differ), "errors": len(errors),
                        "differ_examples": [[queries[k[0]], *k[1:]] for k in differ[:10]],
                        "error_examples": [[queries[k[0]], *k[1:]] for k in errors[:5]], "by_kind": by}
        total_differ += len(differ)
        total_errors += len(errors)
        if hidden:
            for side in ("before", "after"):
                for k, text in answers[side].items():
                    body = json.loads(text)
                    body.pop("query", None)
                    body.pop("request", None)
                    rest = json.dumps(body, ensure_ascii=False).lower()
                    cites = any(path in rest for _, path, _ in HIDDEN)
                    words = any(w in rest for w in SECRET_WORDS)
                    if k[2] == "anon" and (cites or words):
                        leaks.append([side, queries[k[0]], *k[1:]])
                    if k[2] == "label" and side == "after" and queries[k[0]] in ("vormish", "kettrel", "kettrel review", "vormish budget") \
                            and not k[3].startswith("find-prefix") and k[3] != "filename":
                        found_with_label["cases"] += 1
                        found_with_label["found"] += cites
    report["leaks"] = leaks
    report["found_with_label"] = found_with_label
    out.write_text(json.dumps(report, indent=1, ensure_ascii=False) + "\n", encoding="utf-8")
    print(json.dumps({"plain": {k: report["plain"][k] for k in ("requests", "differ", "errors")},
                      "labelled": {k: report["labelled"][k] for k in ("requests", "differ", "errors")},
                      "leaks": len(leaks), "found_with_label": found_with_label}))
    return 0 if not total_differ and not total_errors and not leaks else 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
