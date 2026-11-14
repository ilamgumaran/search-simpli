#!/usr/bin/env python3
"""S5-T12 Phase 2: the same requests through two `searchd` binaries.

    python3 -I equivalence.py REPO BEFORE_SEARCHD AFTER_SEARCHD WORKDIR OUT_JSON

Builds one J2 index the way `scripts/j2_run.py` does (three host roots,
every file as content_base64, the file-name channel on) with BEFORE's
`searchd apply`, then asks every J2 query of `fixtures/j2/judgments.json`
of one `searchd serve` per binary, on that one index:

- `search_knowledge`, lexical, top 10, `search_field` content, both and
  filename, under two scopes: all three roots, and `school` + `home`
  (`laptop` hidden: a mask that hides a root);
- `find` words, phrase and prefix, first page of 10, under the same scopes.

Every result is compared byte for byte (its JSON as served). Also a
labelled-file check: a fourth index, J2 plus one file in `home` that
requires the label `adults` and holds two made-up words, asked without the
label (both binaries) under content and both, the plain and the plural
form, and by `find`: no result may cite the file and no response may hold
its words beyond the query's own echo (`query`, and `find`'s `request`).
The same requests with the label (`principal_labels: ["adults"]`) must
find the file, so the check is not vacuous.
"""

from __future__ import annotations

import base64
import json
import subprocess
import sys
from pathlib import Path

SCOPES = {"all": ["school", "home", "laptop"], "two": ["school", "home"]}
HIDDEN_PATH = "notes/zarvelo-plans.md"
HIDDEN_TEXT = "# Zarvelo plans\n\nThe zarvelo weekend and the quindles for the trip.\n"
HIDDEN_QUERIES = ["zarvelo", "zarvelos", "quindle", "quindles", "zarvelo weekend"]
# `find` is exact: with the label it finds only the words the file holds.
FIND_HELD = {"zarvelo", "quindles", "zarvelo weekend"}


class Serve:
    def __init__(self, binary: Path, index: Path) -> None:
        self.process = subprocess.Popen([str(binary), "serve", str(index)], stdin=subprocess.PIPE,
                                        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, encoding="utf-8")
        self.next_id = 0

    def call(self, method: str, params: dict) -> str:
        self.next_id += 1
        self.process.stdin.write(json.dumps({"jsonrpc": "2.0", "id": self.next_id, "method": method,
                                             "params": params}, ensure_ascii=False) + "\n")
        self.process.stdin.flush()
        line = self.process.stdout.readline()
        if not line:
            raise SystemExit(f"searchd closed during {method}: {self.process.stderr.read()[:2000]}")
        reply = json.loads(line)
        if "result" not in reply:
            return json.dumps({"error": reply.get("error")}, sort_keys=True)
        return json.dumps(reply["result"], ensure_ascii=False, sort_keys=True)

    def close(self) -> None:
        self.process.stdin.close()
        self.process.wait(timeout=60)
        self.process.stdout.close()
        self.process.stderr.close()


def changes(pack: Path, judgments: dict, extra: list[dict]) -> dict:
    request = {"roots": [{"root_id": r, "label": r, "kind": "host"} for r in judgments["roots"]], "changes": []}
    for root in judgments["roots"]:
        base = pack / root
        for path in sorted(p for p in base.rglob("*") if p.is_file()):
            request["changes"].append({"op": "add", "root_id": root, "path": path.relative_to(base).as_posix(),
                                       "content_base64": base64.b64encode(path.read_bytes()).decode("ascii")})
    request["changes"].extend(extra)
    return request


def build(binary: Path, work: Path, name: str, request: dict) -> Path:
    (work / f"{name}.json").write_text(json.dumps(request), encoding="utf-8")
    index = work / name
    done = subprocess.run([str(binary), "apply", str(index), "--changes", str(work / f"{name}.json"), "--filename-index"],
                          capture_output=True, text=True, timeout=300)
    if done.returncode != 0:
        raise SystemExit(f"apply failed: {done.stdout}\n{done.stderr}")
    return index


def requests(judgments: dict):
    for q in judgments["queries"]:
        for scope, roots in SCOPES.items():
            for field in ("content", "both", "filename"):
                yield (q["id"], scope, field), "search_knowledge", {"query": q["query"], "top_k": 10, "retrieval_mode": "lexical",
                                                                     "roots": roots, "search_field": field}
            for mode in ("words", "phrase", "prefix"):
                yield (q["id"], scope, "find-" + mode), "find", {"query": q["query"], "mode": mode, "roots": roots, "page_size": 10}


def main(argv: list[str]) -> int:
    repo, before, after, work, out = (Path(a) for a in argv[1:6])
    pack = repo / "fixtures" / "j2"
    judgments = json.loads((pack / "judgments.json").read_text(encoding="utf-8"))
    work.mkdir(parents=True, exist_ok=False)
    index = build(before, work, "j2", changes(pack, judgments, []))
    answers = {}
    for label, binary in (("before", before), ("after", after)):
        serve = Serve(binary, index)
        try:
            answers[label] = {key: serve.call(method, params) for key, method, params in requests(judgments)}
        finally:
            serve.close()
    keys = list(answers["before"])
    differ = [k for k in keys if answers["before"][k] != answers["after"][k]]
    errors = [k for k in keys if answers["after"][k].startswith('{"error"')]
    by_kind = {}
    for k in keys:
        kind = f"{k[1]}/{k[2]}"
        by_kind.setdefault(kind, [0, 0])
        by_kind[kind][0] += 1
        if k in differ:
            by_kind[kind][1] += 1

    hidden = {"op": "add", "root_id": "home", "path": HIDDEN_PATH, "required_labels": ["adults"],
              "content_base64": base64.b64encode(HIDDEN_TEXT.encode()).decode("ascii")}
    labelled = build(before, work, "j2-labelled", changes(pack, judgments, [hidden]))
    leaks = []
    hidden_cases = 0
    found_with_label = 0
    missed_with_label = []
    for label, binary in (("before", before), ("after", after)):
        serve = Serve(binary, labelled)
        try:
            for query in HIDDEN_QUERIES:
                for scope, roots in SCOPES.items():
                    for method, params in (
                        ("search_knowledge", {"query": query, "top_k": 10, "retrieval_mode": "lexical", "roots": roots, "search_field": "content"}),
                        ("search_knowledge", {"query": query, "top_k": 10, "retrieval_mode": "lexical", "roots": roots, "search_field": "both"}),
                        ("find", {"query": query, "mode": "words", "roots": roots, "page_size": 10}),
                    ):
                        hidden_cases += 1
                        text = serve.call(method, params)
                        body = json.loads(text)
                        body.pop("query", None)
                        body.pop("request", None)
                        rest = json.dumps(body, ensure_ascii=False).lower()
                        if "zarvelo" in rest or "quindle" in rest:
                            leaks.append([label, method, params["query"], scope, params.get("search_field", params.get("mode"))])
                        if scope == "all" and (method != "find" or query in FIND_HELD):
                            labelled_text = serve.call(method, {**params, "principal_labels": ["adults"]})
                            if HIDDEN_PATH in labelled_text:
                                found_with_label += 1
                            else:
                                missed_with_label.append([label, method, params["query"], params.get("search_field", params.get("mode"))])
        finally:
            serve.close()
    report = {"requests": len(keys), "errors": len(errors), "differ": len(differ),
              "differ_examples": [list(k) for k in differ[:10]], "by_kind": by_kind,
              "hidden_file": {"path": "home/" + HIDDEN_PATH, "required_labels": ["adults"], "cases": hidden_cases, "leaks": leaks,
                              "with_label": {"found": found_with_label, "missed": missed_with_label}}}
    out.write_text(json.dumps(report, indent=1, ensure_ascii=False) + "\n", encoding="utf-8")
    print(json.dumps({k: report[k] for k in ("requests", "errors", "differ")}), "hidden cases", hidden_cases, "leaks", len(leaks),
          "found with the label", found_with_label, "missed", len(missed_with_label))
    return 0 if not differ and not errors and not leaks and not missed_with_label else 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
