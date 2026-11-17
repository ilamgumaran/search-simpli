#!/usr/bin/env python3
"""S6-T5 verifier: check the battery (beh1.py) against the written expectations.

    check1.py HEAD.json MAIN.json
"""
import json
import re
import sys
from collections import Counter

sys.path.insert(0, __import__("os").path.dirname(__file__))
import beh1  # noqa: E402
import ssdrv  # noqa: E402

head = json.load(open(sys.argv[1]))
main = json.load(open(sys.argv[2]))
problems = Counter()
examples = {}
stats = Counter()


def bad(kind, detail):
    problems[kind] += 1
    examples.setdefault(kind, detail)


def terms_of(q):
    out = []
    for t in re.findall(r"[A-Za-z0-9]+", q):
        t = t.lower()
        if t not in out:
            out.append(t)
    return out


def visible_names(scope):
    names = set()
    for f in beh1.F1:
        if "roots" in scope and f["root"] not in scope["roots"]:
            continue
        if f.get("labels") and not set(f["labels"]) <= set(scope.get("principal_labels", [])):
            continue
        if "path_prefix" in scope and not (f["root"] + "/" + f["path"]).startswith(scope["path_prefix"]):
            continue
        stem = f["path"].rsplit("/", 1)[-1].rsplit(".", 1)[0]
        names |= {t.lower() for t in re.findall(r"[A-Za-z0-9]+", stem)}
    return names


def dump(ws):
    return json.dumps(ws, separators=(",", ":"), ensure_ascii=False)


def expected_both(content_ws, q, scope):
    pre = [w for w in content_ws if w["code"] == "query_empty_after_analysis"]
    post = [w for w in content_ws if w["code"] == "vector_ignored"]
    U, E, G = [], {}, {}
    for w in content_ws:
        if w["code"] == "query_term_unmatched":
            U.append(w["term"])
        elif w["code"] == "query_term_expanded":
            E[w["term"]] = w
        elif w["code"] == "query_term_grouped":
            G[w["term"]] = w
        elif w["code"] not in ("query_empty_after_analysis", "vector_ignored"):
            bad("content-unknown-code", w)
    names = visible_names(scope)
    U2 = [t for t in U if not (t in names and t not in E)]
    out = list(pre)
    for t in U2:
        out.append({"code": "query_term_unmatched", "message": "the term was not found in the searched files", "term": t})
        if t in E:
            out.append(E[t])
        if t in G:
            out.append(G[t])
    order = terms_of(q)
    for t in sorted((g for g in G if g not in U2), key=lambda g: order.index(g) if g in order else 999):
        out.append(G[t])
    return out + post


def expected_filename(q, scope, vector):
    ts = terms_of(q)
    out = []
    if not ts:
        out.append({"code": "query_empty_after_analysis", "message": "the query has no searchable terms after analysis"})
    names = visible_names(scope)
    for t in ts:
        if t not in names:
            out.append({"code": "query_term_unmatched", "message": "the term was not found in the searched files", "term": t})
    return out, vector


# --- F1: index by (q, scope, field, vector)
def key(r):
    return (r["q"], json.dumps(r["scope"], sort_keys=True), r["field"], bool(r.get("vector")))


H = {key(r): r for r in head["f1"]}
M = {key(r): r for r in main["f1"]}
assert set(H) == set(M)
for k, r in H.items():
    m = M[k]
    if r["err"] or m["err"]:
        if r["err"] != m["err"]:
            bad("error-differs", (k, r["err"], m["err"]))
        stats["errors-equal"] += 1
        continue
    a, b = r["answer"].encode(), m["answer"].encode()
    q, scope, field, vec = r["q"], r["scope"], r["field"], bool(r.get("vector"))
    if field == "content":
        if a != b:
            bad("content-differs-head-main", k)
        stats["content-identical"] += 1
        continue
    if ssdrv.warnings_bytes(b) != b"[]":
        bad("main-nonempty", k)
    if ssdrv.outside_warnings(a) != ssdrv.outside_warnings(b):
        bad("outside-warnings-differs", k)
    wb = ssdrv.warnings_bytes(a)
    ws = json.loads(wb)
    if dump(ws).encode() != wb:
        bad("format-differs", k)
    content = H[(q, json.dumps(scope, sort_keys=True), "content", vec)]
    cws = json.loads(ssdrv.warnings_bytes(content["answer"].encode()))
    if field == "both":
        exp = expected_both(cws, q, scope)
        if ws != exp:
            bad("both-model", {"q": q, "scope": scope, "got": ws, "exp": exp, "content": cws})
        stats["both-checked"] += 1
        if ws != cws:
            stats["both-differs-from-content"] += 1
        stats["both-warnings"] += len(ws)
        for w in ws:
            stats["both-" + w["code"]] += 1
    else:
        exp, _ = expected_filename(q, scope, vec)
        if vec:
            exp = exp + [w for w in cws if w["code"] == "vector_ignored"]
            if not any(w["code"] == "vector_ignored" for w in exp):
                bad("vector-not-in-content", k)
        if ws != exp:
            bad("filename-model", {"q": q, "scope": scope, "got": ws, "exp": exp})
        stats["filename-checked"] += 1
        for w in ws:
            stats["filename-" + w["code"]] += 1
            if w["code"] in ("query_term_expanded", "query_term_grouped"):
                bad("filename-has-group", k)
    # Every warning object's bytes as content writes the same object.
    craw = {dump(w) for w in cws}
    for w in ws:
        if w["code"] != "query_term_unmatched" and dump(w) not in craw and field == "both":
            bad("both-object-not-in-content", (k, w))

# --- F2: hidden versus absent, same index, substitution.
pairs = {}
for r in head["f2"]:
    pairs.setdefault((r["pair"]["hidden"], r["ctx"], r["field"]), {})[r["side"]] = r
for (hid, ctx, field), sides in pairs.items():
    h, a = sides["hidden"], sides["absent"]
    if h["err"] or a["err"]:
        bad("f2-error", (hid, ctx, field, h["err"], a["err"]))
        continue
    absent_word = h["pair"]["absent"]
    expected = a["answer"].replace(absent_word, hid)
    if absent_word in h["answer"] or hid in a["answer"]:
        bad("f2-substitution-unsafe", (hid, absent_word))
    if expected != h["answer"]:
        wb_h = ssdrv.warnings_bytes(h["answer"].encode())
        wb_e = ssdrv.warnings_bytes(expected.encode())
        bad("f2-hidden-vs-absent-" + field + ("-warnings" if wb_h != wb_e else "-elsewhere"),
            {"kind": h["pair"]["kind"], "hidden": hid, "q": h["q"], "scope": h["pair"]["scope"],
             "got": wb_h.decode(), "exp": wb_e.decode()})
    stats["f2-pairs-" + field] += 1
    wsh = json.loads(ssdrv.warnings_bytes(h["answer"].encode()))
    stats["f2-unmatched-" + field] += sum(1 for w in wsh if w["code"] == "query_term_unmatched")
    stats["f2-expanded-" + field] += sum(1 for w in wsh if w["code"] == "query_term_expanded")
    stats["f2-grouped-" + field] += sum(1 for w in wsh if w["code"] == "query_term_grouped")
# main's f2: both/filename empty.
for r in main["f2"]:
    if r["field"] != "content" and ssdrv.warnings_bytes(r["answer"].encode()) != b"[]":
        bad("main-f2-nonempty", r["q"])

# --- F2 against F2 without its hidden files (cross-index), roots [north].
for r in head["f2bare"]:
    a, b = r["with_hidden"].encode(), r["bare"].encode()
    if ssdrv.warnings_bytes(a) != ssdrv.warnings_bytes(b):
        bad("f2bare-warnings-" + r["field"], {"q": r["q"], "kind": r["kind"], "with": ssdrv.warnings_bytes(a).decode(),
                                              "bare": ssdrv.warnings_bytes(b).decode()})
    stats["f2bare-" + r["field"]] += 1
    if a != b:
        stats["f2bare-whole-answer-differs-" + r["field"]] += 1

print(json.dumps({"versions": [head["version"], main["version"]], "stats": stats, "problems": problems,
                  "examples": examples}, indent=1, ensure_ascii=False, default=str))
