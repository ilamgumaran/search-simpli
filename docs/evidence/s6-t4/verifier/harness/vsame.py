#!/usr/bin/env python3
"""Verifier's same-answers harness (S6-T4). Two (searchd, index) pairs, every
CLI read compared on stdout, stderr and exit code, plus `index_status` through
`serve`.

    vsame.py CORPUS_DIR A_SEARCHD A_INDEX B_SEARCHD B_INDEX OUT.json [--search FOLDER]

With --search, additionally compares B's `search FOLDER q` against B's
`query B_INDEX q` (text, --json, --evidence; three fields; several top-k).
"""
import collections
import concurrent.futures as cf
import json
import random
import re
import subprocess
import sys
from pathlib import Path

WORD = re.compile(r"(?:[^\W\d_][̀-ͯ஀-௿]*)+", re.UNICODE)
FIELDS = ["content", "filename", "both"]


def run(cmd, stdin=None):
    p = subprocess.run(cmd, input=stdin, capture_output=True)
    return [p.returncode, p.stdout.decode("utf-8", "replace"), p.stderr.decode("utf-8", "replace")]


def words_by_df(corpus: Path, limit_files=4000):
    files = sorted(p for p in corpus.rglob("*") if p.is_file() and p.suffix in (".md", ".txt", ".markdown", ""))
    df = collections.Counter()
    for path in files[:limit_files]:
        try:
            text = path.read_text(encoding="utf-8")
        except Exception:
            continue
        df.update({w.lower() for w in WORD.findall(text) if len(w) >= 3})
    ranked = [w for w, _ in df.most_common()]
    return files, ranked


def derive(corpus: Path, j2_queries=None):
    files, ranked = words_by_df(corpus)
    rnd = random.Random(20261116)
    picks = []
    for r in (0, 2, 7, 30, 120, 500, 2000, 8000):
        if r < len(ranked):
            picks.append(ranked[r])
    rare = ranked[-40:]
    picks += rnd.sample(rare, min(3, len(rare)))
    queries = list(picks)
    if len(picks) >= 4:
        queries += [picks[0] + " " + picks[3], picks[4] + " " + picks[1], " ".join(picks[2:5])]
    # misspelling (drop a letter), capitalised, a stem of a file name, nothing
    if len(picks) > 3 and len(picks[3]) > 4:
        w = picks[3]
        queries.append(w[:2] + w[3:])
    if picks:
        queries.append(picks[1].upper())
    stem = re.split(r"[-_. ]", files[len(files) // 3].stem)[0] if files else "x"
    queries += [stem, files[0].stem, "zzqqxv nothinghere"]
    if j2_queries:
        queries += j2_queries
    finds = []
    for w in picks[:6]:
        finds.append(("words", w))
    if len(picks) >= 3:
        finds.append(("words", picks[0] + " " + picks[5 % len(picks)]))
    # phrases: three adjacent words from a few files
    for path in (files[1], files[len(files) // 2], files[-1]) if files else ():
        toks = WORD.findall(path.read_text(encoding="utf-8"))
        if len(toks) > 12:
            finds.append(("phrase", " ".join(toks[5:8])))
            finds.append(("phrase", " ".join(toks[9:11])))
    for w in picks[:5]:
        finds.append(("prefix", w[: max(2, len(w) // 2)] + "*"))
    return files, queries, finds


def commands(searchd, idx, queries, finds, files, corpus):
    cmds = {}
    for q in queries:
        for f in FIELDS:
            for k in (1, 5, 10, 40):
                cmds[f"query|{q}|{f}|{k}"] = [searchd, "query", idx, q, "--search-field", f, "--top-k", str(k)]
                cmds[f"query-json|{q}|{f}|{k}"] = [searchd, "query", idx, q, "--search-field", f, "--top-k", str(k), "--json"]
            cmds[f"evidence|{q}|{f}"] = [searchd, "evidence", idx, q, "--search-field", f, "--top-k", "7"]
    for mode, q in finds:
        for ps in ("5", "20"):
            cmds[f"find|{mode}|{q}|{ps}"] = [searchd, "find", idx, q, "--mode", mode, "--page-size", ps]
            cmds[f"find-json|{mode}|{q}|{ps}"] = [searchd, "find", idx, q, "--mode", mode, "--page-size", ps, "--json"]
    cmds["roots"] = [searchd, "roots", idx, "--json"]
    cmds["roots-text"] = [searchd, "roots", idx]
    return cmds


def cursor_of(out):
    try:
        return json.loads(out).get("next_cursor") or json.loads(out).get("cursor")
    except Exception:
        return None


def run_all(cmds):
    with cf.ThreadPoolExecutor(8) as ex:
        futs = {k: ex.submit(run, c) for k, c in cmds.items()}
        return {k: f.result() for k, f in futs.items()}


def follow(searchd, idx, base, first):
    """Follow the cursor chain of a paged command (two more pages at most)."""
    pages = []
    out = first[1]
    for _ in range(2):
        c = cursor_of(out)
        if not c:
            break
        r = run(base + ["--cursor", c])
        pages.append(r)
        out = r[1]
    return pages


def side(searchd, idx, queries, finds, files, corpus):
    res = run_all(commands(searchd, idx, queries, finds, files, corpus))
    # list-files, every page
    lf = run([searchd, "list-files", idx, "--json", "--page-size", "1000"])
    res["list-files"] = lf
    for i, p in enumerate(follow(searchd, idx, [searchd, "list-files", idx, "--json", "--page-size", "1000"], lf)):
        res[f"list-files-p{i + 2}"] = p
    res["list-files-text"] = run([searchd, "list-files", idx, "--page-size", "50"])
    # find second pages by cursor
    for mode, q in finds:
        base = [searchd, "find", idx, q, "--mode", mode, "--page-size", "5", "--json"]
        for i, p in enumerate(follow(searchd, idx, base, res[f"find-json|{mode}|{q}|5"])):
            res[f"find-json|{mode}|{q}|5|p{i + 2}"] = p
    # outline / read-span for the files list-files names (first 12 and a spread)
    try:
        listed = json.loads(lf[1])["files"]
    except Exception:
        listed = []
    chosen = listed[:6] + listed[len(listed) // 2: len(listed) // 2 + 3] + listed[-3:]
    more = {}
    for f in chosen:
        r, p = f["root_id"], f["path"]
        more[f"outline|{r}|{p}"] = [searchd, "outline", idx, r, p, "--json"]
        more[f"outline-text|{r}|{p}"] = [searchd, "outline", idx, r, p]
        more[f"read-span|{r}|{p}|1-40"] = [searchd, "read-span", idx, r, p, "1", "40", "--json"]
        more[f"read-span|{r}|{p}|3-5c2"] = [searchd, "read-span", idx, r, p, "3", "5", "--context", "2"]
    res.update(run_all(more))
    # status through serve
    req = "\n".join(json.dumps({"jsonrpc": "2.0", "id": i, "method": m, "params": {}})
                    for i, m in enumerate(["index_status", "list_sources"])) + "\n"
    res["serve-status"] = run([searchd, "serve", idx], stdin=req.encode())
    return res


def normalise(key, r):
    return r


def main():
    corpus, a_bin, a_idx, b_bin, b_idx, out = sys.argv[1:7]
    search_folder = sys.argv[sys.argv.index("--search") + 1] if "--search" in sys.argv else None
    j2q = None
    if "--j2" in sys.argv:
        j = json.loads(Path(sys.argv[sys.argv.index("--j2") + 1]).read_text())
        j2q = sorted({q["query"] for q in j["queries"]}) if "queries" in j else None
    files, queries, finds = derive(Path(corpus), j2q)
    a = side(a_bin, a_idx, queries, finds, files, corpus)
    b = side(b_bin, b_idx, queries, finds, files, corpus)
    diffs = [k for k in a if a[k] != b.get(k)] + [k for k in b if k not in a]
    errors = sum(1 for k in a if a[k][0] != 0)
    report = {"corpus": corpus, "commands": len(a), "differ": len(diffs), "diff_keys": diffs[:50],
              "nonzero_exit": errors, "queries": len(queries), "finds": len(finds)}
    if search_folder:
        sc = {}
        for q in queries[:12]:
            for f in FIELDS:
                for k in ("3", "10"):
                    sc[f"s|{q}|{f}|{k}|text"] = ([b_bin, "search", search_folder, q, "--search-field", f, "--top-k", k],
                                                 [b_bin, "query", b_idx, q, "--search-field", f, "--top-k", k])
                    sc[f"s|{q}|{f}|{k}|json"] = ([b_bin, "search", search_folder, q, "--search-field", f, "--top-k", k, "--json"],
                                                 [b_bin, "query", b_idx, q, "--search-field", f, "--top-k", k, "--json"])
                sc[f"s|{q}|{f}|ev"] = ([b_bin, "search", search_folder, q, "--search-field", f, "--top-k", "5", "--evidence"],
                                       [b_bin, "evidence", b_idx, q, "--search-field", f, "--top-k", "5"])
        flat = {}
        for k, (x, y) in sc.items():
            flat[k + "|search"] = x
            flat[k + "|query"] = y
        r = run_all(flat)
        sd = [k for k in sc if r[k + "|search"] != r[k + "|query"]]
        report["search_vs_index_query"] = {"pairs": len(sc), "differ": len(sd), "keys": sd[:20],
                                           "nonzero_exit": sum(1 for k in sc if r[k + "|search"][0] != 0)}
    Path(out).write_text(json.dumps({"report": report, "a": a, "b": b}, ensure_ascii=False))
    print(json.dumps(report, ensure_ascii=False))


if __name__ == "__main__":
    main()
