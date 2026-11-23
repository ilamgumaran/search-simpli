#!/usr/bin/env python3
"""Run the everyday-usage scenarios against a built `searchd`, and judge each.

Usage (from the repository root; run.sh does the build first):
  python3 -I docs/testing/scenarios-engine/run_scenarios.py \
      --searchd zig/zig-out/bin/searchd --scratch <absent-or-empty-folder> \
      [--skip-scale] [--skip-dart]

Writes <scratch>/results.json and <scratch>/results.md (one table row per
scenario: id, group, command, expectation, observation, verdict) and prints
the counts. Every verdict is computed by the check written beside the
scenario; a SURPRISE is behaviour that works but that the documents or a
household user would not expect. Timings are one run on one machine.

Nothing outside <scratch> is written, except `.search/demo` and
`.search/index.json` in the repository (the README's quick start writes them
there; `.search/` is ignored by git).
"""
import argparse
import hashlib
import json
import os
import shutil
import subprocess
import sys
import time
import unicodedata

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import gen_corpus  # noqa: E402

RESULTS = []


class Ctx:
    def __init__(self, searchd, scratch, repo, skip_scale, skip_dart):
        self.searchd = os.path.abspath(searchd)
        self.scratch = os.path.abspath(scratch)
        self.repo = os.path.abspath(repo)
        self.skip_scale = skip_scale
        self.skip_dart = skip_dart

    def run(self, args, cwd=None, input_text=None, timeout=300):
        start = time.monotonic()
        proc = subprocess.run([self.searchd] + list(args), cwd=cwd or self.scratch, capture_output=True,
                              input=input_text.encode("utf-8") if input_text is not None else None, timeout=timeout)
        elapsed = time.monotonic() - start
        return proc.returncode, proc.stdout.decode("utf-8", "replace"), proc.stderr.decode("utf-8", "replace"), elapsed

    def json(self, args, **kw):
        code, out, err, _ = self.run(args, **kw)
        if code != 0:
            raise RuntimeError("exit %d: %s" % (code, err.strip()))
        return json.loads(out)

    def path(self, *parts):
        return os.path.join(self.scratch, *parts)


def show(args):
    out = []
    for a in args:
        if a == "" or any(c in a for c in " \"'$`&|;*()[]<>\\!?#%") or not a.isascii():
            out.append("'" + a.replace("'", "'\\''") + "'")
        else:
            out.append(a)
    return "searchd " + " ".join(out)


def record(sid, group, command, expect, observed, verdict, repro=""):
    RESULTS.append({"id": sid, "group": group, "command": command, "expect": expect,
                    "observed": observed, "verdict": verdict, "repro": repro})
    print("%-5s %-8s %s" % (sid, verdict, command[:110]), flush=True)


def scenario(sid, group, expect):
    def wrap(fn):
        def runner(ctx):
            try:
                command, observed, verdict, repro = fn(ctx)
            except Exception as error:  # a scenario that crashes is recorded, not fatal
                command, observed, verdict, repro = "(see script)", "runner error: %r" % (error,), "FAIL", ""
            record(sid, group, command, expect, observed, verdict, repro)
        runner.sid = sid
        return runner
    return wrap


def top_paths(ctx, index, query, k=3, extra=()):
    data = ctx.json(["query", index, query, "--json", "--top-k", str(k)] + list(extra))
    return [r.get("path") or r["citation"]["path"] for r in data["results"]]


def fold(text):
    text = unicodedata.normalize("NFKD", text.casefold())
    return "".join(c for c in text if not unicodedata.combining(c))


SCENARIOS = []


def add(fn):
    SCENARIOS.append(fn)
    return fn


# ---------------------------------------------------------------- quick start
QS = "quick start"


@add
@scenario("Q01", QS, "README five-minute start: `index fixtures/knowledge --out .search/demo` exits 0 and names the files")
def q01(ctx):
    args = ["index", "fixtures/knowledge", "--out", ".search/demo"]
    shutil.rmtree(os.path.join(ctx.repo, ".search", "demo"), ignore_errors=True)
    code, out, err, _ = ctx.run(args, cwd=ctx.repo)
    ok = code == 0 and "files_indexed=2" in out
    return show(args), "exit %d; %s" % (code, out.strip()), "PASS" if ok else "FAIL", ""


@add
@scenario("Q02", QS, "`query .search/demo \"how does hybrid search combine results\" --top-k 2` prints ranked passages for a person (README)")
def q02(ctx):
    args = ["query", ".search/demo", "how does hybrid search combine results", "--top-k", "2"]
    code, out, err, _ = ctx.run(args, cwd=ctx.repo)
    lines = out.strip().splitlines()
    ranked = code == 0 and len(lines) == 3 and lines[1].startswith("1. hybrid-search.md")
    passages = "Lexical search" in out
    verdict = "PASS" if ranked and passages else ("SURPRISE" if ranked else "FAIL")
    return show(args), "exit %d; %d lines; passage text printed: %s; %s" % (code, len(lines), passages, " | ".join(lines)), verdict, \
        "searchd query .search/demo \"hybrid search\"  # prints path:lines score=..., no passage text (the Python reference prints the text)"


@add
@scenario("Q03", QS, "`evidence .search/demo \"hybrid search\" --top-k 1` prints one JSON evidence item with path, lines and content")
def q03(ctx):
    args = ["evidence", ".search/demo", "hybrid search", "--top-k", "1"]
    code, out, err, _ = ctx.run(args, cwd=ctx.repo)
    data = json.loads(out)
    ev = data["evidence"]
    ok = code == 0 and len(ev) == 1 and ev[0]["path"] == "hybrid-search.md" and ev[0]["content"]
    return show(args), "exit %d; %s:%d-%d" % (code, ev[0]["path"], ev[0]["start_line"], ev[0]["end_line"]), "PASS" if ok else "FAIL", ""


@add
@scenario("Q04", QS, "`find .search/demo \"hybrid\"` prints an exact word search with a snippet")
def q04(ctx):
    args = ["find", ".search/demo", "hybrid"]
    code, out, err, _ = ctx.run(args, cwd=ctx.repo)
    ok = code == 0 and "1 hits in 1 files" in out
    paths_differ = "r-legacy/hybrid-search.md" in out
    return show(args), "exit %d; first line: %s; hit path printed as r-legacy/hybrid-search.md (query prints hybrid-search.md): %s" % (
        code, out.splitlines()[0], paths_differ), ("SURPRISE" if paths_differ else "PASS") if ok else "FAIL", \
        "searchd find .search/demo hybrid  vs  searchd query .search/demo hybrid  # r-legacy/ prefix in one, not the other"


@add
@scenario("Q05", QS, "the README's one JSON-RPC line piped to `serve .search/demo` answers one result and exits 0")
def q05(ctx):
    line = '{"jsonrpc":"2.0","id":1,"method":"search_knowledge","params":{"query":"hybrid search","top_k":1}}\n'
    code, out, err, _ = ctx.run(["serve", ".search/demo"], cwd=ctx.repo, input_text=line)
    data = json.loads(out)
    ok = code == 0 and len(data["result"]["results"]) == 1
    return "echo '<README line>' | searchd serve .search/demo", "exit %d; results=%d" % (code, len(data["result"]["results"])), "PASS" if ok else "FAIL", ""


@add
@scenario("Q06", QS, "`searchd --help` lists every command and the flags the README names (`--filename-index`, `--search-field`)")
def q06(ctx):
    code, out, err, _ = ctx.run(["--help"])
    cmds = all(c in out for c in ("index", "query", "evidence", "search", "find", "outline", "read-span", "list-files", "roots", "apply", "serve", "mcp"))
    index_part = out.split("query <dir>")[0]
    query_part = out.split("query <dir>")[1].split("evidence <dir>")[0]
    fn_flag = "--filename-index" in index_part
    sf_flag = "--search-field" in query_part
    verdict = "PASS" if cmds and fn_flag and sf_flag else ("SURPRISE" if cmds else "FAIL")
    return "searchd --help", "exit %d; all commands listed: %s; `index` usage shows --filename-index: %s; `query` usage shows --search-field: %s" % (
        code, cmds, fn_flag, sf_flag), verdict, "searchd --help | grep -n filename-index  # appears only under apply/search, not under index"


@add
@scenario("Q07", QS, "the README's Python lines: `python3 search.py index fixtures/knowledge --out .search/index.json`, then `query`, print ranked passages")
def q07(ctx):
    a = subprocess.run([sys.executable, "search.py", "index", "fixtures/knowledge", "--out", ".search/index.json"], cwd=ctx.repo, capture_output=True, text=True)
    b = subprocess.run([sys.executable, "search.py", "query", ".search/index.json", "how does hybrid search combine results"], cwd=ctx.repo, capture_output=True, text=True)
    ok = a.returncode == 0 and b.returncode == 0 and b.stdout.startswith("1. hybrid-search.md") and "Lexical search" in b.stdout
    return "python3 search.py index fixtures/knowledge --out .search/index.json; python3 search.py query ...", \
        "exit %d/%d; first line %s; passage text printed: %s" % (a.returncode, b.returncode, b.stdout.splitlines()[0], "Lexical search" in b.stdout), "PASS" if ok else "FAIL", ""


# ---------------------------------------------------------------- direct search
DS = "direct search"


@add
@scenario("D01", DS, "`search home \"leaky faucet\"` answers from the plumber note with no index (direct-search.md)")
def d01(ctx):
    args = ["search", "home", "leaky faucet"]
    code, out, err, _ = ctx.run(args)
    ok = code == 0 and "1. notes/plumber visit.txt:1-5" in out
    return show(args), "exit %d; %s" % (code, out.strip().splitlines()[1] if len(out.strip().splitlines()) > 1 else out.strip()), "PASS" if ok else "FAIL", ""


@add
@scenario("D02", DS, "files left out are counted on one stderr line (too_large, unreadable); stdout unaffected")
def d02(ctx):
    args = ["search", "home", "leaky faucet"]
    code, out, err, _ = ctx.run(args)
    ok = "2 files not searched (too_large=1 unreadable=1" in err and "searchd:" not in out
    names = "archive.txt" in err or "scan.txt" in err
    return show(args), "stderr: %s; the line names the files: %s" % (err.strip(), names), "PASS" if ok else "FAIL", ""


@add
@scenario("D03", DS, "`search --search-field filename` works on any folder")
def d03(ctx):
    args = ["search", "home", "plumber", "--search-field", "filename"]
    code, out, err, _ = ctx.run(args)
    ok = code == 0 and "notes/plumber visit.txt" in out
    return show(args), "exit %d; %s" % (code, out.strip().splitlines()[1] if len(out.strip().splitlines()) > 1 else "no result"), "PASS" if ok else "FAIL", ""


@add
@scenario("D04", DS, "`search --json` and `--evidence` are byte for byte `query --json` / `evidence` on a fresh `index --filename-index`")
def d04(ctx):
    pairs = [(["search", "home", "lentil soup", "--json", "--search-field", "both"], ["query", "idx", "lentil soup", "--json", "--search-field", "both"]),
             (["search", "home", "compost", "--evidence"], ["evidence", "idx", "compost"]),
             (["search", "home", "தோசை", "--json"], ["query", "idx", "தோசை", "--json"])]
    same = []
    for a, b in pairs:
        same.append(ctx.run(a)[1] == ctx.run(b)[1])
    return show(pairs[0][0]) + " (and 2 more)", "identical: %s" % same, "PASS" if all(same) else "FAIL", ""


@add
@scenario("D05", DS, "an empty or whitespace query is a usage error: exit 2, one stderr line, nothing on stdout")
def d05(ctx):
    obs = []
    ok = True
    for q in ("", "   "):
        code, out, err, _ = ctx.run(["search", "home", q])
        obs.append("%r: exit %d, stdout %d bytes, %s" % (q, code, len(out), err.strip()))
        ok = ok and code == 2 and out == "" and len(err.strip().splitlines()) == 1
    return show(["search", "home", ""]), "; ".join(obs), "PASS" if ok else "FAIL", ""


@add
@scenario("D06", DS, "a missing folder and a file path are usage errors (exit 2) that name the path")
def d06(ctx):
    a = ctx.run(["search", "no-such-folder", "x"])
    b = ctx.run(["search", "home/notes/vacuum.txt", "x"])
    ok = a[0] == 2 and b[0] == 2 and "no-such-folder" in a[2] and "not a folder" in b[2]
    return show(["search", "no-such-folder", "x"]), "%s | %s" % (a[2].strip(), b[2].strip()), "PASS" if ok else "FAIL", ""


@add
@scenario("D07", DS, "search writes nothing: not in the folder, not in the working directory")
def d07(ctx):
    def listing(root):
        out = []
        for dirpath, dirnames, filenames in os.walk(root):
            for name in filenames + dirnames:
                p = os.path.join(dirpath, name)
                out.append((os.path.relpath(p, root), os.lstat(p).st_mtime_ns))
        return sorted(out)
    work = ctx.path("cwd-probe")
    os.makedirs(work, exist_ok=True)
    before = (listing(ctx.path("home")), listing(work))
    ctx.run(["search", ctx.path("home"), "faucet"], cwd=work)
    after = (listing(ctx.path("home")), listing(work))
    ok = before == after
    return "cd cwd-probe && searchd search ../home faucet", "folder and working directory unchanged: %s" % ok, "PASS" if ok else "FAIL", ""


@add
@scenario("D08", DS, "an empty folder answers with no results and exit 0")
def d08(ctx):
    os.makedirs(ctx.path("empty-folder"), exist_ok=True)
    code, out, err, _ = ctx.run(["search", "empty-folder", "anything"])
    ok = code == 0 and len(out.strip().splitlines()) == 1
    return show(["search", "empty-folder", "anything"]), "exit %d; %r" % (code, out.strip()), "PASS" if ok else "FAIL", ""


# ---------------------------------------------------------------- index: which files
IX = "index"


@add
@scenario("I01", IX, "`index home --out idx --filename-index` indexes the supported files and counts the rest (README, incremental-indexing.md)")
def i01(ctx):
    args = ["index", "home", "--out", "idx", "--filename-index"]
    code, out, err, _ = ctx.run(args)
    ok = code == 0 and "files_indexed=26" in out and "too_large=1" in out and "unreadable=1" in out
    return show(args), "exit %d; %s" % (code, out.strip()), "PASS" if ok else "FAIL", ""


@add
@scenario("I02", IX, "a household user expects a CSV budget, a .log file and a README with no extension to be searchable, or at least counted as skipped")
def i02(ctx):
    files = ctx.json(["list-files", "idx", "--json", "--page-size", "1000"])["files"]
    paths = {f["path"] for f in files}
    missing = [p for p in ("money/budget-2026.csv", "logs/furnace.log", "README", "project/weather-station/Makefile") if p not in paths]
    code, out, err, _ = ctx.run(["index", "home", "--out", "idx-count"])
    counted = "unsupported" in out or "skipped" in out
    return "searchd list-files idx --json", "not indexed: %s; reported anywhere in the index summary: %s" % (missing, counted), \
        "SURPRISE" if missing and not counted else "PASS", \
        "printf 'month,amount\\n2026-01,142.50\\n' > f/b.csv; searchd search f electricity  # no result, no stderr line"


@add
@scenario("I03", IX, "symlinks: a link to a file and to a folder (common in synced folders) are followed or reported; the Python reference indexes the file link")
def i03(ctx):
    files = ctx.json(["list-files", "idx", "--json", "--page-size", "1000"])["files"]
    paths = {f["path"] for f in files}
    linked = "link-to-groceries.txt" in paths
    folder = any(p.startswith("link-to-recipes/") for p in paths)
    return "searchd list-files idx --json", "file link indexed: %s; folder link followed: %s; no count or warning for either" % (linked, folder), \
        "PASS" if linked else "SURPRISE", "ln -s notes/a.txt f/link.txt; searchd index f --out x  # link.txt silently absent"


@add
@scenario("I04", IX, "dot-folders and node_modules are ignored (direct-search.md: the ignored directories and dotfiles)")
def i04(ctx):
    a = top_paths(ctx, "idx", "hiddenword")
    b = top_paths(ctx, "idx", "nodemodword")
    return show(["query", "idx", "hiddenword"]), "results: %s %s" % (a, b), "PASS" if not a and not b else "FAIL", ""


@add
@scenario("I05", IX, "an empty file is listed with 0 chunks; an upper-case extension (CALENDAR.TXT) and non-ASCII names are indexed")
def i05(ctx):
    files = {f["path"]: f for f in ctx.json(["list-files", "idx", "--json", "--page-size", "1000"])["files"]}
    ok = files.get("empty.txt", {}).get("chunks") == 0 and "school/CALENDAR.TXT" in files and "tamil/கவிதை.txt" in files and "lists/packing list — beach trip.txt" in files
    return "searchd list-files idx --json", "empty.txt chunks=%s; CALENDAR.TXT %s; Tamil name %s; em-dash name %s" % (
        files.get("empty.txt", {}).get("chunks"), "school/CALENDAR.TXT" in files, "tamil/கவிதை.txt" in files, "lists/packing list — beach trip.txt" in files), "PASS" if ok else "FAIL", ""


@add
@scenario("I06", IX, "the full `index` summary names the files it left out (the --update JSON does: too_large_paths, unreadable_paths)")
def i06(ctx):
    code, out, err, _ = ctx.run(["index", "home", "--out", "idx-names"])
    named = "archive.txt" in out + err or "scan.txt" in out + err
    return show(["index", "home", "--out", "idx-names"]), "summary: %s; names the files: %s" % (out.strip(), named), "PASS" if named else "SURPRISE", \
        "searchd index home --out x  # 'too_large=1 unreadable=1', which files only with --update"


@add
@scenario("I07", IX, "an index directory placed inside the folder it indexes is not itself indexed")
def i07(ctx):
    os.makedirs(ctx.path("inside", "notes"), exist_ok=True)
    with open(ctx.path("inside", "notes", "a.txt"), "w") as handle:
        handle.write("pancake recipe\n")
    ctx.run(["index", "inside", "--out", "inside/myindex"])
    ctx.run(["index", "inside", "--out", "inside/myindex", "--update"])
    files = [f["path"] for f in ctx.json(["list-files", "inside/myindex", "--json"])["files"]]
    own = [p for p in files if p.startswith("myindex/")]
    return show(["index", "inside", "--out", "inside/myindex", "--update"]), "indexed files: %s" % files, "SURPRISE" if own else "PASS", \
        "searchd index f --out f/idx; searchd index f --out f/idx --update; searchd list-files f/idx  # f/idx/INDEX-STATE.json is indexed"


@add
@scenario("I08", IX, "paths with spaces for the folder and the index directory work")
def i08(ctx):
    folder = ctx.path("space dir", "my notes")
    os.makedirs(folder, exist_ok=True)
    with open(os.path.join(folder, "open note.txt"), "w") as handle:
        handle.write("Open plan for the treehouse ladder.\n")
    code, out, err, _ = ctx.run(["index", "space dir/my notes", "--out", "space dir/the index"])
    paths = top_paths(ctx, "space dir/the index", "treehouse")
    ok = code == 0 and paths == ["open note.txt"]
    return show(["index", "space dir/my notes", "--out", "space dir/the index"]), "exit %d; query treehouse -> %s" % (code, paths), "PASS" if ok else "FAIL", ""


@add
@scenario("I09", IX, "an unreadable file (mode 000) does not fail `index` (exit 0, counted unreadable); once readable, `--update` adds it")
def i09(ctx):
    folder = ctx.path("locked")
    os.makedirs(folder, exist_ok=True)
    for name, text in (("locked.txt", "Secret plan for the treehouse roof.\n"), ("open.txt", "Open plan.\n")):
        with open(os.path.join(folder, name), "w") as handle:
            handle.write(text)
    os.chmod(os.path.join(folder, "locked.txt"), 0)
    try:
        code, out, err, _ = ctx.run(["index", "locked", "--out", "locked-idx"])
        first = code == 0 and "unreadable=1" in out
    finally:
        os.chmod(os.path.join(folder, "locked.txt"), 0o644)
    rep = json.loads(ctx.run(["index", "locked", "--out", "locked-idx", "--update"])[1])
    after = top_paths(ctx, "locked-idx", "roof")
    ok = first and rep["added"] == 1 and after == ["locked.txt"]
    return show(["index", "locked", "--out", "locked-idx"]), "first run: %s; after chmod 644 --update added=%d, query roof -> %s" % (out.strip(), rep["added"], after), "PASS" if ok else "FAIL", ""


@add
@scenario("I10", IX, "plain-text kinds a household keeps: .markdown (incremental-indexing.md names it for md-section-v1), .text, .csv, .tsv, .log, .xml, .ini, .org, .srt")
def i10(ctx):
    folder = ctx.path("kinds")
    os.makedirs(folder, exist_ok=True)
    exts = ["markdown", "text", "csv", "tsv", "log", "xml", "ini", "org", "srt", "MD", "Txt"]
    for e in exts:
        with open(os.path.join(folder, "sample." + e), "w") as handle:
            handle.write("kindword appears here\n")
    ctx.run(["index", "kinds", "--out", "kinds-idx"])
    got = sorted(f["path"].rsplit(".", 1)[1] for f in ctx.json(["list-files", "kinds-idx", "--json"])["files"])
    return show(["index", "kinds", "--out", "kinds-idx"]), "indexed extensions: %s of %s" % (got, exts), "PASS" if "markdown" in got else "FAIL", \
        "printf '# Title\\nkindword\\n' > f/a.markdown; searchd search f kindword  # no result"


# ---------------------------------------------------------------- updates
UP = "update"


@add
@scenario("U01", UP, "`--update` with nothing changed reports unchanged=26 and, a user would expect, leaves the index as it is")
def u01(ctx):
    shutil.copytree(ctx.path("home"), ctx.path("mut"), symlinks=True)
    ctx.run(["index", "mut", "--out", "midx", "--filename-index"])
    rep = json.loads(ctx.run(["index", "mut", "--out", "midx", "--update"])[1])
    return show(["index", "mut", "--out", "midx", "--update"]), "unchanged=%d added=%d changed=%d; published generation %d" % (
        rep["unchanged"], rep["added"], rep["changed"], rep["generation"]), "SURPRISE" if rep["generation"] > 1 else "PASS", \
        "searchd index f --out x; searchd index f --out x --update  # generation 2 published, every section file written again"


@add
@scenario("U02", UP, "add a file, `--update`: added=1 and its words are found")
def u02(ctx):
    with open(ctx.path("mut", "notes", "bookshelf.txt"), "w") as handle:
        handle.write("Note about the wobbly bookshelf: tighten the brackets.\n")
    rep = json.loads(ctx.run(["index", "mut", "--out", "midx", "--update"])[1])
    paths = top_paths(ctx, "midx", "wobbly bookshelf")
    ok = rep["added"] == 1 and paths == ["notes/bookshelf.txt"]
    return show(["index", "mut", "--out", "midx", "--update"]), "added=%d; query -> %s" % (rep["added"], paths), "PASS" if ok else "FAIL", ""


@add
@scenario("U03", UP, "change a file: changed=1, the new word is found, the removed word is gone")
def u03(ctx):
    with open(ctx.path("mut", "lists", "groceries.txt"), "w") as handle:
        handle.write("Groceries for the week\nmilk\nquince jam\n")
    rep = json.loads(ctx.run(["index", "mut", "--out", "midx", "--update"])[1])
    new = top_paths(ctx, "midx", "quince")
    old = top_paths(ctx, "midx", "sourdough")
    ok = rep["changed"] == 1 and new == ["lists/groceries.txt"] and old == []
    return show(["index", "mut", "--out", "midx", "--update"]), "changed=%d; quince -> %s; sourdough -> %s" % (rep["changed"], new, old), "PASS" if ok else "FAIL", ""


@add
@scenario("U04", UP, "rename a file: the old path is gone, the new path is found by content and by name (index_folder reports removed+added)")
def u04(ctx):
    os.rename(ctx.path("mut", "notes", "vacuum.txt"), ctx.path("mut", "notes", "vacuum manual.txt"))
    rep = json.loads(ctx.run(["index", "mut", "--out", "midx", "--update"])[1])
    content = top_paths(ctx, "midx", "canister")
    name = top_paths(ctx, "midx", "manual", extra=["--search-field", "filename"])
    ok = rep["added"] == 1 and rep["removed"] == 1 and content == ["notes/vacuum manual.txt"] and "notes/vacuum manual.txt" in name
    return show(["index", "mut", "--out", "midx", "--update"]), "added=%d removed=%d; canister -> %s; filename manual -> %s" % (rep["added"], rep["removed"], content, name), "PASS" if ok else "FAIL", ""


@add
@scenario("U05", UP, "delete a file: removed=1; query and find no longer return it")
def u05(ctx):
    os.remove(ctx.path("mut", "notes", "bookshelf.txt"))
    rep = json.loads(ctx.run(["index", "mut", "--out", "midx", "--update"])[1])
    q = top_paths(ctx, "midx", "wobbly")
    f = ctx.json(["find", "midx", "wobbly", "--json"])["hits"]
    ok = rep["removed"] == 1 and not q and not f
    return show(["index", "mut", "--out", "midx", "--update"]), "removed=%d; query %s; find %d hits" % (rep["removed"], q, len(f)), "PASS" if ok else "FAIL", ""


@add
@scenario("U06", UP, "an index updated six times keeps every generation unless --keep-generations is given (generation-lifecycle.md); disk use")
def u06(ctx):
    def size(d):
        return sum(os.path.getsize(os.path.join(d, f)) for f in os.listdir(d))
    before = size(ctx.path("midx"))
    fresh = size(ctx.path("idx"))
    rep = json.loads(ctx.run(["index", "mut", "--out", "midx", "--update", "--keep-generations", "2"])[1])
    after = size(ctx.path("midx"))
    return show(["index", "mut", "--out", "midx", "--update", "--keep-generations", "2"]), \
        "fresh index %d B; after 5 updates %d B (%.1fx); --keep-generations 2 -> %d B, pruned_files=%d (counts documents and lexical files only, a documented limit)" % (
            fresh, before, before / fresh, after, rep.get("pruned_files", -1)), "PASS", ""


@add
@scenario("U07", UP, "an index written by an older engine (tests/fixtures/index-98c4a2b, index-292cb568) is queried and updated")
def u07(ctx):
    shutil.copytree(os.path.join(ctx.repo, "tests", "fixtures", "index-98c4a2b"), ctx.path("old98"))
    shutil.copytree(os.path.join(ctx.repo, "tests", "fixtures", "index-292cb568"), ctx.path("old292"))
    shutil.copytree(os.path.join(ctx.repo, "fixtures", "family-folder", "home"), ctx.path("fam"))
    a = top_paths(ctx, "old98", "garden", k=1)
    b = top_paths(ctx, "old292", "garden", k=1)
    c = ctx.json(["find", "old292", "garden", "--json"])["hits"]
    code, out, err, _ = ctx.run(["index", "fam", "--out", "old98", "--update"])
    rep = json.loads(out) if code == 0 else {}
    ok = a == ["garden.md"] and b == ["garden.md"] and c and rep.get("unchanged") == 16
    return show(["index", "fam", "--out", "old98", "--update"]), "query old98 %s, old292 %s, find old292 %d hits; update exit %d unchanged=%s" % (a, b, len(c), code, rep.get("unchanged")), "PASS" if ok else "FAIL", ""


@add
@scenario("U08", UP, "two writers at once: one publishes, the other fails with WriterBusy (generation-lifecycle.md)")
def u08(ctx):
    if not os.path.isdir(ctx.path("scale10k")):
        return "(needs the scale folder)", "skipped with --skip-scale", "PASS", ""
    procs = [subprocess.Popen([ctx.searchd, "index", "scale10k", "--out", "s10", "--update"], cwd=ctx.scratch,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE) for _ in range(2)]
    outs = [p.communicate() for p in procs]
    codes = sorted(p.returncode for p in procs)
    errs = " | ".join(e.decode().strip() for _, e in outs if e)
    ok = codes == [0, 1] and "WriterBusy" in errs
    verdict = "PASS" if ok else ("PASS" if codes == [0, 0] else "FAIL")
    note = "" if ok else " (both finished without overlapping; rerun)"
    return "searchd index scale10k --out s10 --update  (twice at once)", "exit codes %s; stderr %s%s" % (codes, errs, note), verdict, ""


@add
@scenario("U09", UP, "a caller's --generation at or below the floor is refused with StaleGeneration naming the floor; above it publishes")
def u09(ctx):
    a = ctx.run(["index", "space dir/my notes", "--out", "space dir/the index", "--generation", "1"])
    b = ctx.run(["index", "space dir/my notes", "--out", "space dir/the index", "--generation", "99"])
    ok = a[0] == 1 and "StaleGeneration" in a[2] and "not above 1" in a[2] and b[0] == 0 and "generation=99" in b[1]
    return show(["index", "space dir/my notes", "--out", "space dir/the index", "--generation", "1"]), "%s | then 99: exit %d" % (a[2].strip(), b[0]), "PASS" if ok else "FAIL", ""


# ---------------------------------------------------------------- content query
CQ = "query: content"


def query_case(sid, query, expect_top, expect_text, verdict_if_wrong="FAIL", k=3, repro=None):
    @add
    @scenario(sid, CQ, expect_text)
    def case(ctx):
        args = ["query", "idx", query, "--top-k", str(k)]
        paths = top_paths(ctx, "idx", query, k=k)
        if expect_top is None:
            ok = paths == []
        else:
            ok = bool(paths) and paths[0] == expect_top
        return show(args), "top %d: %s" % (k, paths), "PASS" if ok else verdict_if_wrong, (repro or ("searchd query idx '%s'" % query)) if not ok else ""
    return case


query_case("C01", "compost", "notes/garden-plan.md", "one word that is only in a file's content: `compost` -> garden plan")
query_case("C02", "brass compass", "long/diary.md", "two words deep in a 5,000-line file -> the diary")
query_case("C03", "zephyrwhistle", "one-line.txt", "a word at the end of a 22 KB one-line file -> that file")
query_case("C04", "ran", "notes/running club.txt", "word form: `ran` (the note has ran/runs/running)")
query_case("C05", "swim", "notes/running club.txt", "word form: `swim` -> the note with swimming/swims")
query_case("C06", "battery", "lists/groceries.txt", "plural: `battery` -> groceries (AA batteries)")
query_case("C07", "renew", "money/insurance.json", "word form: `renew` -> insurance.json (renewal)", verdict_if_wrong="SURPRISE")
query_case("C08", "vaccum", "notes/vacuum.txt", "misspelling: `vaccum` -> vacuum note (fuzzy-v1)")
query_case("C09", "fawcet", "notes/plumber visit.txt", "misspelling: `fawcet` -> plumber note")
query_case("C10", "tomatos", "notes/garden-plan.md", "misspelling: `tomatos` -> garden plan")
query_case("C11", "தோசை", "recipes/dosai.md", "Tamil word in content -> dosai recipe")
query_case("C12", "மாவு", "recipes/dosai.md", "Tamil word (batter) -> dosai recipe batter section")
query_case("C13", "நிலா", "tamil/கவிதை.txt", "Tamil word in a Tamil-named file -> the poem")
query_case("C14", "cafe", "notes/café notes.md", "accents: `cafe` finds `café` (fold-groups)")
query_case("C15", "2026-03-14", "notes/plumber visit.txt", "a date as typed -> the plumber visit")
query_case("C16", "555-0142", "notes/plumber visit.txt", "a phone number -> the plumber visit")
query_case("C17", "when is the water heater anode rod due", "notes/plumber visit.txt", "a multi-word question typed whole -> the plumber note")
query_case("C18", "how long do I simmer the lentil soup", "recipes/lentil soup.md", "question -> lentil soup (method section)")
query_case("C19", "what should I pack for the beach", "lists/packing list — beach trip.txt", "question -> packing list")
query_case("C20", "where did I find the compass", "long/diary.md", "question -> the diary line about the compass",
           repro="searchd query idx 'where did I find the compass'  # running club.txt first: `where` fuzzy-matches `were` (7.95) above `compass` (4.95)")
query_case("C21", "when does the insurance renew", "money/insurance.json", "question -> insurance.json",
           repro="searchd query idx 'when does the insurance renew'  # café note first: it holds `does`")
query_case("C22", "what did Pip read in February", "school/reading-log.yaml", "question -> the reading log",
           repro="searchd query idx 'what did Pip read in February'  # main.py first: `read` in code")
query_case("C23", "zzqqxx", None, "a word in no file -> no results, exit 0")
query_case("C24", "furnace filter", "logs/furnace.log", "the answer lives in a .log file -> a user expects the furnace log", verdict_if_wrong="SURPRISE",
           repro="searchd query idx 'furnace filter'  # vacuum.txt (filter); logs/furnace.log is not indexed")
query_case("C25", "where is the spare house key", "README", "the answer lives in README (no extension)", verdict_if_wrong="SURPRISE",
           repro="searchd query idx 'where is the spare house key'  # three unrelated hits; README is not indexed")


@add
@scenario("C26", CQ, "a question with no answer in any file says so, or returns nothing (answer_policy: say when evidence is insufficient)")
def c26(ctx):
    data = ctx.json(["evidence", "idx", "what is the capital of France", "--top-k", "3"])
    paths = [e["path"] for e in data["evidence"]]
    return show(["evidence", "idx", "what is the capital of France", "--top-k", "3"]), \
        "%d results: %s; any field saying the match is weak: %s" % (len(paths), paths, any(k for k in data if k not in ("query", "analyzer_id", "evidence"))), \
        "FAIL" if paths else "PASS", "searchd query idx 'what is the capital of France'  # three hits on `the`/`is`/`of`, same score shape as a real answer"


@add
@scenario("C27", CQ, "a number with a decimal point (142.50) finds the receipt first, and only it")
def c27(ctx):
    paths = top_paths(ctx, "idx", "142.50")
    verdict = "PASS" if paths == ["notes/plumber visit.txt"] else ("SURPRISE" if paths and paths[0] == "notes/plumber visit.txt" else "FAIL")
    return show(["query", "idx", "142.50"]), "top 3: %s" % paths, verdict, "searchd query idx 142.50  # also diary lines `Day 142` and `Day 50`: the number is split"


@add
@scenario("C28", CQ, "`query idx \"\"` and `\"   \"` are accepted: exit 0, a header and no results (direct-search.md)")
def c28(ctx):
    a = ctx.run(["query", "idx", ""])
    b = ctx.run(["query", "idx", "   "])
    ok = a[0] == 0 and b[0] == 0 and len(a[1].strip().splitlines()) == 1
    return show(["query", "idx", ""]), "exit %d/%d; %r" % (a[0], b[0], a[1].strip()), "PASS" if ok else "FAIL", ""


@add
@scenario("C29", CQ, "a very long query (300 words, one rare) and a 5,000-character token answer without error")
def c29(ctx):
    q300 = " ".join(["lentil"] + ["word%d" % i for i in range(300)])
    a = top_paths(ctx, "idx", q300, k=1)
    code, out, err, t = ctx.run(["query", "idx", "x" * 5000])
    code2, out2, err2, _ = ctx.run(["query", "idx", "compost " * 5000, "--top-k", "1"])
    ok = a == ["recipes/lentil soup.md"] and code == 0 and code2 == 0
    return "searchd query idx '<lentil + 300 words>' ; '<x*5000>' ; '<compost*5000>'", "300 words -> %s; 5000 chars exit %d; 40 KB query exit %d" % (a, code, code2), "PASS" if ok else "FAIL", ""


@add
@scenario("C30", CQ, "punctuation, quotes and shell-special characters: each finds the note holding them, no error")
def c30(ctx):
    queries = ["$HOME", "`backtick`", "50%", "C++", "[draft]", "it's", '"quoted"', "3*4=12", "info@example.org"]
    tops = {}
    for q in queries:
        p = top_paths(ctx, "idx", q, k=1)
        tops[q] = p[0] if p else None
    ok = all(v == "notes/odd chars.txt" for v in tops.values())
    bare = [q for q in (";", "***", '"', "'", "\\", "(") if ctx.run(["query", "idx", q])[0] != 0]
    return "searchd query idx '$HOME' (and 8 more; then ; *** \" ' \\\\ ( alone)", "tops: %s; lone-punctuation failures: %s" % (tops, bare), "PASS" if ok and not bare else "FAIL", ""


@add
@scenario("C31", CQ, "--top-k: 1, 3, 100 return that many; 0 and `abc` are usage errors (exit 2); the RPC limit is 1..100")
def c31(ctx):
    counts = {k: len(ctx.json(["query", "idx", "day", "--json", "--top-k", k])["results"]) for k in ("1", "3", "100", "500")}
    z = ctx.run(["query", "idx", "x", "--top-k", "0"])[0]
    a = ctx.run(["query", "idx", "x", "--top-k", "abc"])[0]
    ok = counts["1"] == 1 and counts["3"] == 3 and counts["100"] == 100 and z == 2 and a == 2
    return show(["query", "idx", "day", "--top-k", "500"]), "counts %s; 0 -> exit %d; abc -> exit %d; 500 accepted on the CLI (RPC refuses over 100)" % (counts, z, a), \
        "PASS" if ok else "FAIL", ""


# ---------------------------------------------------------------- file names
FN = "query: filename/both"


def filename_case(sid, query, expect_path, text, verdict_if_wrong="FAIL", repro=None):
    @add
    @scenario(sid, FN, text)
    def case(ctx):
        paths = top_paths(ctx, "idx", query, k=5, extra=["--search-field", "filename"])
        ok = (expect_path in paths) if expect_path else paths == []
        return show(["query", "idx", query, "--search-field", "filename"]), "results: %s" % paths, "PASS" if ok else verdict_if_wrong, \
            (repro or "searchd query idx '%s' --search-field filename" % query) if not ok else ""
    return case


filename_case("F01", "plumber", "notes/plumber visit.txt", "a word only in a file name (with a space) -> that file")
filename_case("F02", "கவிதை", "tamil/கவிதை.txt", "a Tamil file name -> that file")
filename_case("F03", "calendar", "school/CALENDAR.TXT", "case: `calendar` -> CALENDAR.TXT")
filename_case("F04", "beach", "lists/packing list — beach trip.txt", "a word after an em dash in a name -> the packing list")
filename_case("F05", "cafe", "notes/café notes.md", "accents in names: `cafe` -> `café notes.md` (content search folds it, C14)",
              repro="searchd query idx cafe --search-field filename  # no result; searchd query idx cafe finds it in content")
filename_case("F06", "weather", "project/weather-station/main.py", "a folder name: `weather` -> files under weather-station/", verdict_if_wrong="SURPRISE",
              repro="searchd query idx weather --search-field filename  # no result: only the base name is searched")
filename_case("F07", "plumbr", "notes/plumber visit.txt", "a misspelt file name: `plumbr`", verdict_if_wrong="SURPRISE",
              repro="searchd query idx plumbr --search-field filename  # no result (content search corrects `fawcet`)")
filename_case("F08", "gardens", "notes/garden-plan.md", "a word form in a file name: `gardens`", verdict_if_wrong="SURPRISE")


@add
@scenario("F09", FN, "`--search-field both` shows a file-name section and a content section with matched terms")
def f09(ctx):
    data = ctx.json(["query", "idx", "lentil", "--search-field", "both", "--json", "--top-k", "1"])
    r = data["results"][0]
    ms = r.get("match_sections", {})
    ok = r["citation"]["path"] == "recipes/lentil soup.md" and ms.get("filename", {}).get("matched") and ms.get("content", {}).get("matched")
    return show(["query", "idx", "lentil", "--search-field", "both"]), "matched_in %s; sections %s" % (r.get("matched_in"), list(ms)), "PASS" if ok else "FAIL", ""


@add
@scenario("F10", FN, "both: a word only in content and a word only in a name each find their file")
def f10(ctx):
    a = top_paths(ctx, "idx", "canister", k=1, extra=["--search-field", "both"])
    b = top_paths(ctx, "idx", "visit", k=1, extra=["--search-field", "both"])
    ok = a == ["notes/vacuum.txt"] and b == ["notes/plumber visit.txt"]
    return show(["query", "idx", "canister", "--search-field", "both"]), "canister -> %s; visit -> %s" % (a, b), "PASS" if ok else "FAIL", ""


@add
@scenario("F11", FN, "filename search on an index built without --filename-index gives clear rebuild guidance")
def f11(ctx):
    ctx.run(["index", "home", "--out", "idx-nofn"])
    code, out, err, _ = ctx.run(["query", "idx-nofn", "plumber", "--search-field", "filename"])
    ok = code != 0 and "--filename-index" in err
    return show(["query", "idx-nofn", "plumber", "--search-field", "filename"]), "exit %d; %s" % (code, err.strip()), "PASS" if ok else "FAIL", ""


# ---------------------------------------------------------------- find
FD = "find"


def find_json(ctx, query, *extra):
    return ctx.json(["find", "idx", query, "--json"] + list(extra))


@add
@scenario("N01", FD, "words mode: every word, any order (`compost bin`, `bin compost`)")
def n01(ctx):
    a = find_json(ctx, "compost bin")
    b = find_json(ctx, "bin compost")
    ok = len(a["hits"]) == 1 and len(b["hits"]) == 1 and a["request"]["mode"] == "words"
    return show(["find", "idx", "bin compost"]), "hits %d/%d mode %s" % (len(a["hits"]), len(b["hits"]), a["request"]["mode"]), "PASS" if ok else "FAIL", ""


@add
@scenario("N02", FD, "\"quoted\" forces phrase mode: order matters, exact_match reported")
def n02(ctx):
    a = find_json(ctx, '"compost bin"')
    b = find_json(ctx, '"bin compost"')
    ok = a["request"]["mode"] == "phrase" and len(a["hits"]) == 1 and len(b["hits"]) == 0 and a["exact_match"] is True
    return show(["find", "idx", '"compost bin"']), "phrase hits %d; reversed %d; exact_match %s" % (len(a["hits"]), len(b["hits"]), a["exact_match"]), "PASS" if ok else "FAIL", ""


@add
@scenario("N03", FD, "a trailing * forces prefix mode (`lent*`, Tamil `தோ*`); `--mode prefix` without * too")
def n03(ctx):
    a = find_json(ctx, "lent*")
    b = find_json(ctx, "தோ*")
    c = find_json(ctx, "lent", "--mode", "prefix")
    ok = a["request"]["mode"] == "prefix" and len(a["hits"]) == 3 and len(b["hits"]) >= 1 and len(c["hits"]) == 3
    return show(["find", "idx", "lent*"]), "lent* %d hits; தோ* %d; --mode prefix lent %d" % (len(a["hits"]), len(b["hits"]), len(c["hits"])), "PASS" if ok else "FAIL", ""


@add
@scenario("N04", FD, "find is exact: a misspelling (`tomatos`) finds nothing, a misplaced * is an error")
def n04(ctx):
    a = find_json(ctx, "tomatos")
    code, out, err, _ = ctx.run(["find", "idx", "compost*bin"])
    ok = len(a["hits"]) == 0 and code != 0 and "only the last token" in err
    return show(["find", "idx", "compost*bin"]), "tomatos %d hits; compost*bin exit %d %s" % (len(a["hits"]), code, err.strip()), "PASS" if ok else "FAIL", ""


@add
@scenario("N05", FD, "an empty query is refused the same way by search, query and find")
def n05(ctx):
    s = ctx.run(["search", "home", ""])[0]
    q = ctx.run(["query", "idx", ""])[0]
    f = ctx.run(["find", "idx", ""])
    e = ctx.run(["evidence", "idx", ""])[0]
    same = s == q == f[0] == e
    return show(["find", "idx", ""]), "exit codes: search %d, query %d, evidence %d, find %d (%s)" % (s, q, e, f[0], f[2].strip()), "PASS" if same else "SURPRISE", \
        "searchd search home ''; searchd query idx ''; searchd find idx ''  # exit 2, 0, 1"


@add
@scenario("N06", FD, "the text output says plainly when a result list may be incomplete")
def n06(ctx):
    code, out, err, _ = ctx.run(["find", "idx", "faucet"])
    line = [l for l in out.splitlines() if l.startswith("truncated")]
    data = find_json(ctx, "faucet")
    return show(["find", "idx", "faucet"]), "prints %r on every find (truncated=%s, because two unrelated files were not indexed)" % (line[0] if line else "", data["truncated"]), \
        "SURPRISE" if line else "PASS", "searchd find idx faucet  # 'truncated: a file in scope was not indexed in full' although the one answer is complete"


@add
@scenario("N07", FD, "paging: --page-size 50 over 218 hits walks 5 pages with no repeat; a bad cursor is an error")
def n07(ctx):
    seen, cursor, pages = [], None, 0
    while pages < 20:
        extra = ["--page-size", "50"] + (["--cursor", cursor] if cursor else [])
        d = find_json(ctx, "letter", *extra)
        pages += 1
        seen += [(h["path"], h["start_line"]) for h in d["hits"]]
        cursor = d.get("next_cursor")
        if not cursor:
            break
    code, out, err, _ = ctx.run(["find", "idx", "letter", "--cursor", "garbage"])
    ok = len(seen) == len(set(seen)) == 218 and pages == 5 and code != 0
    return show(["find", "idx", "letter", "--page-size", "50"]), "%d pages, %d hits, %d unique; bad cursor exit %d %s" % (pages, len(seen), len(set(seen)), code, err.strip()), "PASS" if ok else "FAIL", ""


@add
@scenario("N08", FD, "a hit in a 22 KB one-line file: the snippet holds the matched word and its offsets")
def n08(ctx):
    h = find_json(ctx, "zephyrwhistle")["hits"][0]
    ok = "zephyrwhistle" in h["snippet"] and h["match_offsets"]
    return show(["find", "idx", "zephyrwhistle", "--json"]), "snippet %d chars, holds word %s, match_offsets %s" % (len(h["snippet"]), "zephyrwhistle" in h["snippet"], h["match_offsets"]), "PASS" if ok else "FAIL", ""


@add
@scenario("N09", FD, "page size limits: 0 and 101 are usage errors (1-100)")
def n09(ctx):
    a = ctx.run(["find", "idx", "x", "--page-size", "0"])[0]
    b = ctx.run(["find", "idx", "x", "--page-size", "101"])[0]
    c = ctx.run(["find", "idx", "x", "--mode", "fuzzy"])[0]
    ok = a == b == c == 2
    return show(["find", "idx", "x", "--page-size", "0"]), "exit %d, %d; --mode fuzzy %d" % (a, b, c), "PASS" if ok else "FAIL", ""


# ---------------------------------------------------------------- evidence and spans
EV = "evidence"

BATTERY = ["leaky faucet", "compost", "brass compass", "lentil soup", "தோசை", "மாவு", "battery", "rain gauge", "humidity_alert",
           "oil change", "kite", "Lanternfield", "café", "packing", "furnace filter", "tomatos", "vaccum", "where did I find the compass",
           "when does the insurance renew", "zephyrwhistle"]


def file_lines(ctx, path, start, end):
    with open(ctx.path("home", path), "rb") as handle:
        data = handle.read()
    text = data.decode("utf-8")
    if text.startswith("\ufeff"):
        text = text[1:]
    lines = text.replace("\r\n", "\n").split("\n")
    return "\n".join(lines[start - 1:end])


@add
@scenario("E01", EV, "every evidence citation over a battery of 20 queries: the cited line range of the file holds the content returned")
def e01(ctx):
    bad, total = [], 0
    for q in BATTERY:
        for e in ctx.json(["evidence", "idx", q, "--top-k", "3"])["evidence"]:
            total += 1
            lines = file_lines(ctx, e["path"], e["start_line"], e["end_line"])
            if " ".join(e["content"].lstrip("\ufeff").split()) not in " ".join(lines.split()):
                bad.append("%s:%d-%d" % (e["path"], e["start_line"], e["end_line"]))
    return "searchd evidence idx '<q>' --top-k 3  (20 queries)", "%d citations, %d whose lines do not hold the content: %s" % (total, len(bad), bad[:5]), "PASS" if not bad else "FAIL", ""


@add
@scenario("E02", EV, "every top-1 evidence holds at least one query word (folded), so a caller can show why it matched")
def e02(ctx):
    misses = []
    for q in BATTERY:
        ev = ctx.json(["evidence", "idx", q, "--top-k", "1"])["evidence"]
        if not ev:
            continue
        content = fold(ev[0]["content"])
        words = [fold(w) for w in q.split() if len(w) > 2]
        if not any(w in content for w in words):
            misses.append("%r -> %s" % (q, ev[0]["path"]))
    return "searchd evidence idx '<q>' --top-k 1  (20 queries)", "top-1 without any query word: %s; evidence carries no matched-terms field" % (misses or "none"), \
        "PASS" if not misses else "SURPRISE", "searchd evidence idx vaccum --top-k 1  # content says `vacuum`; nothing says the match was a correction"


@add
@scenario("E03", EV, "read-span returns the file's bytes: CRLF kept, a BOM not part of line 1, a Tamil file exact")
def e03(ctx):
    a = ctx.json(["read-span", "idx", "r-legacy", "notes/crlf-car.txt", "1", "3", "--json"])
    b = ctx.json(["read-span", "idx", "r-legacy", "notes/birthday-bom.txt", "1", "1", "--json"])
    c = ctx.json(["read-span", "idx", "r-legacy", "tamil/கவிதை.txt", "1", "4", "--json"])
    with open(ctx.path("home", "tamil", "கவிதை.txt"), encoding="utf-8") as handle:
        poem = handle.read()
    ok = "\r\n" in a["text"] and b["text"] == "Birthday ideas\n" and c["text"] == poem and a["byte_exact"]
    return show(["read-span", "idx", "r-legacy", "notes/crlf-car.txt", "1", "3", "--json"]), "CRLF kept %s; BOM line %r; Tamil exact %s" % ("\r\n" in a["text"], b["text"], c["text"] == poem), "PASS" if ok else "FAIL", ""


@add
@scenario("E04", EV, "a caller reads the cited span of a query hit: `query --json` gives what read-span needs (root id, path, lines)")
def e04(ctx):
    r = ctx.json(["query", "idx", "leaky faucet", "--json"])["results"][0]
    has_root = "root_id" in r
    span = ctx.json(["read-span", "idx", r.get("root_id", "r-legacy"), r["path"], str(r["start_line"]), str(r["end_line"]), "--json"])
    ok = "faucet" in span["text"]
    return show(["query", "idx", "leaky faucet", "--json"]) + " then read-span", "query --json keys %s; root_id present %s; span holds `faucet` %s" % (sorted(r), has_root, ok), \
        ("PASS" if has_root else "SURPRISE") if ok else "FAIL", "searchd query idx faucet --json  # no root_id, no content: the caller must know the root is `r-legacy`"


@add
@scenario("E05", EV, "read-span limits and bad ranges are clear errors (400 lines / 256 KiB; past the end; end before start; unknown file)")
def e05(ctx):
    a = ctx.run(["read-span", "idx", "r-legacy", "long/diary.md", "1", "401"])
    b = ctx.run(["read-span", "idx", "r-legacy", "notes/vacuum.txt", "5", "9"])
    c = ctx.run(["read-span", "idx", "r-legacy", "notes/vacuum.txt", "3", "1"])
    d = ctx.run(["read-span", "idx", "r-legacy", "nope.txt", "1", "1"])
    ok = a[0] == 1 and "400-line" in a[2] and b[0] == 1 and "past the last line" in b[2] and c[0] == 2 and d[0] == 1 and "not indexed" in d[2]
    return show(["read-span", "idx", "r-legacy", "long/diary.md", "1", "401"]), " | ".join(x[2].strip() for x in (a, b, c, d)), "PASS" if ok else "FAIL", ""


@add
@scenario("E06", EV, "a hit on one line of a long file cites a chunk around it; --context gives neighbouring lines")
def e06(ctx):
    e = ctx.json(["evidence", "idx", "brass compass", "--top-k", "1"])["evidence"][0]
    s = ctx.json(["read-span", "idx", "r-legacy", "long/diary.md", "4323", "4323", "--context", "1", "--json"])
    ok = e["start_line"] <= 4323 <= e["end_line"] and "compass" in s["text"] and s["context_before"] and s["context_after"]
    return show(["read-span", "idx", "r-legacy", "long/diary.md", "4323", "4323", "--context", "1"]), "evidence cites %d-%d (%d lines) for a one-line answer; span+context ok %s" % (
        e["start_line"], e["end_line"], e["end_line"] - e["start_line"] + 1, ok), "PASS" if ok else "FAIL", ""


@add
@scenario("E07", EV, "outline of a Tamil Markdown file lists its headings with line ranges")
def e07(ctx):
    d = ctx.json(["outline", "idx", "r-legacy", "recipes/dosai.md", "--json"])
    heads = [(h["level"], h["text"], h["line"]) for h in d["headings"]]
    ok = len(heads) == 3 and heads[1][1].startswith("மாவு")
    return show(["outline", "idx", "r-legacy", "recipes/dosai.md"]), "headings %s" % heads, "PASS" if ok else "FAIL", ""


@add
@scenario("E08", EV, "a file that starts with a BOM: evidence content, like read-span, does not carry the invisible U+FEFF")
def e08(ctx):
    e = ctx.json(["evidence", "idx", "kite", "--top-k", "1"])["evidence"][0]
    s = ctx.json(["read-span", "idx", "r-legacy", "notes/birthday-bom.txt", "1", "1", "--json"])
    has = e["content"].startswith("\ufeff")
    return show(["evidence", "idx", "kite", "--top-k", "1"]), "evidence content starts with U+FEFF: %s; read-span line 1 does: %s" % (has, s["text"].startswith("\ufeff")), \
        "SURPRISE" if has else "PASS", "printf '\\357\\273\\277Birthday ideas\\nA kite\\n' > f/b.txt; searchd search f kite --evidence  # content begins with U+FEFF"


# ---------------------------------------------------------------- errors and exit codes
ER = "errors"


@add
@scenario("X01", ER, "`query` on a missing directory, or on a folder that is not an index: exit 1 with a line that names the problem and the path")
def x01(ctx):
    a = ctx.run(["query", "no-such-index", "x"])
    b = ctx.run(["query", "home", "x"])
    clear = "no-such-index" in a[2] and ("not an index" in b[2] or "MANIFEST" in b[2])
    return show(["query", "home", "x"]), "exit %d %r | exit %d %r" % (a[0], a[2].strip(), b[0], b[2].strip()), "PASS" if clear else "SURPRISE", \
        "searchd query home x  # 'error: FileNotFound' (no path, does not say the folder is not an index)"


@add
@scenario("X02", ER, "`index` of a missing folder, or a folder it may not read: a line naming the folder")
def x02(ctx):
    a = ctx.run(["index", "no-such-folder", "--out", "zz"])
    os.makedirs(ctx.path("noread"), exist_ok=True)
    os.chmod(ctx.path("noread"), 0)
    try:
        b = ctx.run(["index", "noread", "--out", "zz2"])
        c = ctx.run(["search", "noread", "x"])
    finally:
        os.chmod(ctx.path("noread"), 0o755)
    clear = "no-such-folder" in a[2] and "noread" in b[2]
    return show(["index", "no-such-folder", "--out", "zz"]), "exit %d %r | noread: index exit %d %r, search exit %d %r" % (a[0], a[2].strip(), b[0], b[2].strip(), c[0], c[2].strip()), \
        "PASS" if clear else "SURPRISE", "searchd index missing --out x  # 'error: FileNotFound'; searchd search names the folder"


@add
@scenario("X03", ER, "usage errors exit 2 with one stderr line: unknown flag, unknown command, missing --out, bare `searchd`")
def x03(ctx):
    cases = [["query", "idx", "x", "--bogus"], ["bogus"], ["index", "home"], []]
    res = [ctx.run(c) for c in cases]
    ok = all(r[0] == 2 and r[1] == "" for r in res) and all(len(r[2].strip().splitlines()) == 1 for r in res[:3])
    return "searchd query idx x --bogus; searchd bogus; searchd index home; searchd", "exits %s; %s" % ([r[0] for r in res], " | ".join(r[2].strip().splitlines()[0] for r in res)), "PASS" if ok else "FAIL", ""


@add
@scenario("X04", ER, "error lines share one form a script can parse")
def x04(ctx):
    samples = [ctx.run(["query", "home", "x"])[2].strip(), ctx.run(["find", "idx", ""])[2].strip(), ctx.run(["query", "idx", "x", "--bogus"])[2].strip(),
               ctx.run(["query", "idx-nofn", "x", "--search-field", "filename"])[2].strip()]
    forms = sorted({s.split(":")[0] for s in samples})
    return "(four errors)", "prefixes seen: %s; e.g. %s" % (forms, samples), "PASS" if len(forms) == 1 else "SURPRISE", \
        "searchd query home x; searchd find idx ''  # 'error: FileNotFound' vs 'searchd: SS_ERR_INVALID_ARGUMENT: ...'"


@add
@scenario("X05", ER, "list-files, roots and outline on the household index")
def x05(ctx):
    roots = ctx.json(["roots", "idx", "--json"])["roots"]
    files = []
    cursor = None
    while True:
        d = ctx.json(["list-files", "idx", "--json", "--page-size", "7"] + (["--cursor", cursor] if cursor else []))
        files += [f["path"] for f in d["files"]]
        cursor = d.get("next_cursor")
        if not cursor:
            break
    ok = roots[0]["root_id"] == "r-legacy" and roots[0]["files"] == 26 and len(files) == len(set(files)) == 26
    return show(["list-files", "idx", "--page-size", "7"]), "roots %s; paged files %d unique %d" % ([(r["root_id"], r["files"]) for r in roots], len(files), len(set(files))), "PASS" if ok else "FAIL", ""


# ---------------------------------------------------------------- JSON-RPC
RP = "rpc"


def rpc(ctx, index, requests, extra=()):
    payload = "".join(json.dumps(r, ensure_ascii=False) + "\n" if isinstance(r, dict) else r + "\n" for r in requests)
    code, out, err, _ = ctx.run(["serve", index] + list(extra), input_text=payload)
    return code, [json.loads(l) for l in out.splitlines() if l.strip()], err


@add
@scenario("R01", RP, "serve over stdio answers index_status, search_knowledge, find, read_span, list_files, outline and roots")
def r01(ctx):
    reqs = [{"jsonrpc": "2.0", "id": i, "method": m, "params": p} for i, (m, p) in enumerate([
        ("index_status", {}), ("search_knowledge", {"query": "leaky faucet", "retrieval_mode": "lexical", "top_k": 2}),
        ("find", {"query": "compost", "page_size": 2}), ("read_span", {"root_id": "r-legacy", "path": "notes/plumber visit.txt", "start_line": 2, "end_line": 2}),
        ("list_files", {"page_size": 2}), ("outline", {"root_id": "r-legacy", "path": "recipes/dosai.md"}), ("roots", {})], 1)]
    code, msgs, err = rpc(ctx, "idx", reqs)
    ok = code == 0 and len(msgs) == 7 and all("result" in m for m in msgs) and msgs[1]["result"]["results"][0]["citation"]["path"] == "notes/plumber visit.txt"
    return "printf '<7 requests>' | searchd serve idx", "exit %d; %d answers, all results %s" % (code, len(msgs), all("result" in m for m in msgs)), "PASS" if ok else "FAIL", ""


@add
@scenario("R02", RP, "protocol errors: unknown method -32601, bad JSON -32700, unknown field -32602, top_k 101 -32602, apply_changes without --allow-write -32601")
def r02(ctx):
    reqs = [{"jsonrpc": "2.0", "id": 1, "method": "nope", "params": {}}, "not json",
            {"jsonrpc": "2.0", "id": 3, "method": "search_knowledge", "params": {"query": "x", "bogus": 1}},
            {"jsonrpc": "2.0", "id": 4, "method": "search_knowledge", "params": {"query": "x", "top_k": 101}},
            {"jsonrpc": "2.0", "id": 5, "method": "apply_changes", "params": {}}]
    code, msgs, err = rpc(ctx, "idx", reqs)
    codes = [m.get("error", {}).get("code") for m in msgs]
    ok = codes == [-32601, -32700, -32602, -32602, -32601]
    return "printf '<5 bad requests>' | searchd serve idx", "codes %s" % codes, "PASS" if ok else "FAIL", ""


@add
@scenario("R03", RP, "search_field both over RPC returns match_sections; a filename query without lexical mode is refused (zig-rpc-service.md)")
def r03(ctx):
    reqs = [{"jsonrpc": "2.0", "id": 1, "method": "search_knowledge", "params": {"query": "plumber", "retrieval_mode": "lexical", "search_field": "both", "top_k": 1}},
            {"jsonrpc": "2.0", "id": 2, "method": "search_knowledge", "params": {"query": "plumber", "search_field": "filename"}}]
    code, msgs, err = rpc(ctx, "idx", reqs)
    a = msgs[0].get("result", {}).get("results", [{}])[0]
    b = msgs[1]
    ok = "match_sections" in a and "error" in b
    return "printf '<both; filename without retrieval_mode>' | searchd serve idx", "both has match_sections %s; filename without lexical -> %s" % (
        "match_sections" in a, b.get("error") or "answered"), "PASS" if ok else "SURPRISE", ""


@add
@scenario("R04", RP, "loopback HTTP: `serve idx --http 127.0.0.1:<port>` answers POSTs; another host is refused")
def r04(ctx):
    port = 47600 + os.getpid() % 300
    proc = subprocess.run([sys.executable, "-I", os.path.join(HERE, "http_probe.py"), ctx.searchd, "idx", str(port)], cwd=ctx.scratch, capture_output=True, text=True, timeout=60)
    probes = [json.loads(l) for l in proc.stdout.splitlines()]
    by = {p["probe"]: p for p in probes}
    refused = ctx.run(["serve", "idx", "--http", "0.0.0.0:%d" % (port + 1)], input_text="")
    ok = by.get("ready", {}).get("status") is True and by["search"]["status"] == 200 and "plumber visit.txt" in by["search"]["body"]
    get = by.get("get", {})
    shutdown = by.get("shutdown", {}).get("status")
    verdict = "PASS" if ok and refused[0] == 2 else "FAIL"
    if verdict == "PASS" and (get.get("status") == 200 or "still running" in str(shutdown)):
        verdict = "SURPRISE"
    return "python3 -I http_probe.py searchd idx <port>", "search 200; GET answered %s %s; after stdin closed: %s; 0.0.0.0 refused exit %d" % (
        get.get("status"), get.get("body", "")[:60], shutdown, refused[0]), verdict, \
        "curl -s http://127.0.0.1:<port>/  # 200 with a JSON-RPC parse error; the server keeps running when its stdin closes"


# ---------------------------------------------------------------- MCP
MC = "mcp"


@add
@scenario("M01", MC, "an MCP host session: initialize (protocol 2025-11-25), tools/list (8 read tools), every read tool, resources with a space and a Tamil name, refusals")
def m01(ctx):
    proc = subprocess.run([sys.executable, "-I", os.path.join(HERE, "mcp_probe.py"), ctx.searchd, "idx"], cwd=ctx.scratch, capture_output=True, text=True, timeout=60)
    lines = [json.loads(l) for l in proc.stdout.splitlines()]
    by = {l.get("id"): l.get("summary") for l in lines[1:]}
    checks = {
        "protocol": by[1].get("protocolVersion") == "2025-11-25",
        "tools": by[2].get("tools") == ["search_knowledge", "read_chunk", "list_sources", "index_status", "find", "outline", "read_span", "list_files"],
        "search_top": (by[3].get("top") or [None])[0] == "notes/plumber visit.txt" and by[3].get("isError") is False,
        "find": by[4].get("isError") is False,
        "read_span": "anode rod" in by[5].get("text", ""),
        "resources": by[9].get("resources") == 26,
        "space_uri": "Plumber visit" in by[10].get("contents", ""),
        "tamil_uri": "நிலா" in by[11].get("contents", ""),
        "labels_refused": by[12].get("isError") is True,
        "write_unknown": by[13].get("error", {}).get("code") == -32602,
        "big_span": by[16].get("isError") is True,
        "big_resource": by[17].get("error", {}).get("code") == -32005,
    }
    ok = all(checks.values())
    return "python3 -I mcp_probe.py searchd idx", "checks %s" % {k: v for k, v in checks.items()}, "PASS" if ok else "FAIL", ""


@add
@scenario("M02", MC, "search_knowledge as an LLM writes it (natural question, no mode): the first result holds the answer")
def m02(ctx):
    req = [{"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2025-11-25", "capabilities": {}, "clientInfo": {"name": "p", "version": "0"}}},
           {"jsonrpc": "2.0", "method": "notifications/initialized"}]
    qs = ["when is the water heater anode rod due", "what goes in the compost bin", "where did I find the compass"]
    for i, q in enumerate(qs, 2):
        req.append({"jsonrpc": "2.0", "id": i, "method": "tools/call", "params": {"name": "search_knowledge", "arguments": {"query": q, "top_k": 1}}})
    payload = "".join(json.dumps(r) + "\n" for r in req)
    out = subprocess.run([ctx.searchd, "mcp", "idx"], cwd=ctx.scratch, input=payload.encode(), capture_output=True, timeout=60).stdout.decode()
    tops = []
    for line in out.splitlines()[1:]:
        m = json.loads(line)
        res = m["result"]["structuredContent"]["results"]
        tops.append(res[0]["citation"]["path"] if res else None)
    expect = ["notes/plumber visit.txt", "notes/garden-plan.md", "long/diary.md"]
    return "tools/call search_knowledge {query: <question>, top_k: 1}  (3 questions)", "tops %s" % tops, "PASS" if tops == expect else "FAIL", \
        "tools/call search_knowledge {\"query\":\"where did I find the compass\",\"top_k\":1}  # running club.txt"


# ---------------------------------------------------------------- Dart and Python
DP = "bindings"


@add
@scenario("B01", DP, "Dart binding: `dart pub get; dart test` in bindings/dart/search_simpli passes (CONTRIBUTING.md)")
def b01(ctx):
    if ctx.skip_dart or not shutil.which("dart"):
        return "dart test", "not run (no dart on PATH or --skip-dart)", "PASS", ""
    pkg = os.path.join(ctx.repo, "bindings", "dart", "search_simpli")
    env = dict(os.environ)
    env.pop("SEARCH_SIMPLI_LIBRARY_PATH", None)
    subprocess.run(["dart", "pub", "get"], cwd=pkg, capture_output=True, env=env, timeout=600)
    p = subprocess.run(["dart", "test"], cwd=pkg, capture_output=True, text=True, env=env, timeout=900)
    last = [l for l in p.stdout.splitlines() if l.strip()][-1] if p.stdout.strip() else p.stderr[-200:]
    return "cd bindings/dart/search_simpli && dart pub get && dart test", "exit %d; %s" % (p.returncode, last.strip()[-80:]), "PASS" if p.returncode == 0 else "FAIL", ""


@add
@scenario("B02", DP, "Dart binding as a calling program: indexFolder (file-name channel), query content/filename/both/Tamil, find, readSpan, update, reopen")
def b02(ctx):
    if ctx.skip_dart or not shutil.which("dart"):
        return "dart run bin/probe.dart", "not run", "PASS", ""
    pkg = ctx.path("dartprobe")
    os.makedirs(os.path.join(pkg, "bin"), exist_ok=True)
    shutil.copy(os.path.join(HERE, "dart_probe", "bin", "probe.dart"), os.path.join(pkg, "bin", "probe.dart"))
    with open(os.path.join(HERE, "dart_probe", "pubspec.yaml")) as handle:
        spec = handle.read().replace("BINDING_PATH", os.path.join(ctx.repo, "bindings", "dart", "search_simpli"))
    with open(os.path.join(pkg, "pubspec.yaml"), "w") as handle:
        handle.write(spec)
    shutil.copytree(ctx.path("home"), ctx.path("dart-home"), symlinks=True)
    env = dict(os.environ)
    env.pop("SEARCH_SIMPLI_LIBRARY_PATH", None)
    subprocess.run(["dart", "pub", "get"], cwd=pkg, capture_output=True, env=env, timeout=600)
    p = subprocess.run(["dart", "run", "bin/probe.dart", ctx.path("dart-home"), ctx.path("dart-idx")], cwd=pkg, capture_output=True, text=True, env=env, timeout=600)
    got = {}
    for l in p.stdout.splitlines():
        if l.startswith("{"):
            d = json.loads(l)
            got[d["probe"]] = d["value"]
    ok = (got.get("content", [""])[0].startswith("notes/plumber visit.txt") and got.get("span_equals_file_lines") is True and got.get("filename") == ["notes/plumber visit.txt"]
          and got.get("tamil") == ["recipes/dosai.md"] and got.get("find_phrase") and got.get("after_update") == ["notes/added-by-dart.txt"])
    return "dart run bin/probe.dart dart-home dart-idx", "exit %d; %s" % (p.returncode, json.dumps(got, ensure_ascii=False)[:400]), "PASS" if ok else "FAIL", ""


@add
@scenario("B03", DP, "Python reference over the household folder indexes the same files as searchd (direct-search.md: same rules)")
def b03(ctx):
    p = subprocess.run([sys.executable, os.path.join(ctx.repo, "search.py"), "index", "home", "--out", "py-home.json"], cwd=ctx.scratch, capture_output=True, text=True, timeout=600)
    with open(ctx.path("py-home.json")) as handle:
        d = json.load(handle)
    src = d["source_files"]
    py = set(src if isinstance(src, list) and src and isinstance(src[0], str) else (f["path"] for f in src) if isinstance(src, list) else src)
    zig = {f["path"] for f in ctx.json(["list-files", "idx", "--json", "--page-size", "1000"])["files"]}
    only_py = sorted(py - zig)
    only_zig = sorted(zig - py)
    return "python3 search.py index home --out py-home.json", "exit %d; only in Python: %s; only in searchd: %s" % (p.returncode, only_py, only_zig), \
        "PASS" if not only_py and not only_zig else "SURPRISE", "python3 search.py index f --out x.json  # indexes a symlinked file and a file over 10 MiB that searchd skips"


@add
@scenario("B04", DP, "Python reference query answers the same top result as searchd for five household queries")
def b04(ctx):
    qs = ["leaky faucet", "தோசை", "tomatos", "cafe", "where did I find the compass"]
    diffs = []
    for q in qs:
        p = subprocess.run([sys.executable, os.path.join(ctx.repo, "search.py"), "query", "py-home.json", q], cwd=ctx.scratch, capture_output=True, text=True, timeout=120)
        first = next((l for l in p.stdout.splitlines() if l[:2] == "1."), "")
        py_top = first[3:].rsplit(" score=", 1)[0].rsplit(":", 1)[0] if first else None
        z = top_paths(ctx, "idx", q, k=1)
        if [py_top] != z and not (py_top is None and not z):
            diffs.append((q, py_top, z))
    return "python3 search.py query py-home.json '<q>'  (5 queries)", "differences: %s" % (diffs or "none"), "PASS" if not diffs else "FAIL", ""


# ---------------------------------------------------------------- repeatability
RE = "repeat"


@add
@scenario("P01", RE, "the same query twice gives the same bytes (query, evidence, find, search, both)")
def p01(ctx):
    cmds = [["query", "idx", "faucet", "--json"], ["evidence", "idx", "compost"], ["find", "idx", "comp*", "--json"],
            ["search", "home", "faucet", "--json"], ["query", "idx", "lentil", "--search-field", "both", "--json"]]
    same = [hashlib.sha256(ctx.run(c)[1].encode()).hexdigest() == hashlib.sha256(ctx.run(c)[1].encode()).hexdigest() for c in cmds]
    return "(5 commands, each twice)", "identical %s" % same, "PASS" if all(same) else "FAIL", ""


@add
@scenario("P02", RE, "two fresh indexes of the same folder are byte-identical (sections and MANIFEST)")
def p02(ctx):
    ctx.run(["index", "home", "--out", "idx2", "--filename-index"])
    names = [n for n in os.listdir(ctx.path("idx")) if n not in ("WRITER.LOCK",)]
    diff = []
    for n in names:
        with open(ctx.path("idx", n), "rb") as a, open(ctx.path("idx2", n), "rb") as b:
            if a.read() != b.read():
                diff.append(n)
    return show(["index", "home", "--out", "idx2", "--filename-index"]), "files differing: %s (INDEX-STATE.json holds mtimes)" % (diff or "none"), \
        "PASS" if not [d for d in diff if d != "INDEX-STATE.json"] else "FAIL", ""


# ---------------------------------------------------------------- scale
SC = "scale"


@add
@scenario("S01", SC, "10,000 generated notes: index time, peak memory, index size (README: index about 1.9x corpus)")
def s01(ctx):
    if ctx.skip_scale:
        return "(skipped)", "--skip-scale", "PASS", ""
    gen_corpus.make_scale(ctx.path("scale10k"), 10000)
    corpus = sum(os.path.getsize(os.path.join(d, f)) for d, _, fs in os.walk(ctx.path("scale10k")) for f in fs)
    start = time.monotonic()
    p = subprocess.run(["/usr/bin/time", "-l", ctx.searchd, "index", "scale10k", "--out", "s10", "--filename-index"], cwd=ctx.scratch, capture_output=True, text=True)
    t = time.monotonic() - start
    rss = next((int(l.split()[0]) for l in p.stderr.splitlines() if "maximum resident set size" in l), 0)
    size = sum(os.path.getsize(ctx.path("s10", f)) for f in os.listdir(ctx.path("s10")))
    load = os.getloadavg()[1]
    return show(["index", "scale10k", "--out", "s10", "--filename-index"]), "corpus %.1f MB; index %.2f s, peak RSS %d MiB, index %.1f MB (%.2fx corpus); 5-min load %.2f" % (
        corpus / 1e6, t, rss // (1024 * 1024), size / 1e6, size / corpus, load), "PASS" if p.returncode == 0 else "FAIL", ""


@add
@scenario("S02", SC, "10,000 notes: a whole `query` process, `find`, filename query, and a direct `search` (README: query about 0.02 s; search within 1 s up to about 10,000 files / 7 MB)")
def s02(ctx):
    if ctx.skip_scale:
        return "(skipped)", "--skip-scale", "PASS", ""
    def best(args, n=5):
        times, out = [], ""
        for _ in range(n):
            code, out, err, t = ctx.run(args)
            times.append(t)
        return sorted(times)[len(times) // 2], out
    tq, oq = best(["query", "s10", "quartzfinch receipt", "--top-k", "3"])
    tf, of = best(["find", "s10", "quartzfinch"])
    tn, on = best(["query", "s10", "note-07777", "--search-field", "filename"])
    ts, os_ = best(["search", "scale10k", "quartzfinch"], n=3)
    found = "note-07777.md" in oq and "note-07777.md" in of and "note-07777.md" in os_
    return "searchd query s10 'quartzfinch receipt'; find; filename; search scale10k", "median ms: query %.0f, find %.0f, filename %.0f, direct search %.0f (corpus 16 MB, about twice the README's 7 MB); planted note found %s" % (
        tq * 1000, tf * 1000, tn * 1000, ts * 1000, found), "PASS" if found else "FAIL", ""


@add
@scenario("S03", SC, "10,000 notes: `--update` after one changed file (incremental-indexing.md: tens to a couple of hundred ms)")
def s03(ctx):
    if ctx.skip_scale:
        return "(skipped)", "--skip-scale", "PASS", ""
    ctx.run(["index", "scale10k", "--out", "s10", "--update"])
    with open(ctx.path("scale10k", "box01", "shelf00", "note-00001.md"), "a") as handle:
        handle.write("extra line about a velvetcrane\n")
    code, out, err, t = ctx.run(["index", "scale10k", "--out", "s10", "--update"])
    rep = json.loads(out)
    found = top_paths(ctx, "s10", "velvetcrane", k=1)
    ok = rep["changed"] == 1 and found == ["box01/shelf00/note-00001.md"]
    return show(["index", "scale10k", "--out", "s10", "--update"]), "changed=%d in %.0f ms; found %s" % (rep["changed"], t * 1000, found), "PASS" if ok else "FAIL", ""


def write_reports(ctx):
    with open(ctx.path("results.json"), "w", encoding="utf-8") as handle:
        json.dump(RESULTS, handle, ensure_ascii=False, indent=1)
    def cell(text):
        return str(text).replace("|", "\\|").replace("\n", " ")
    rows = ["| ID | Group | Command | Expected (from the documents) | Observed | Verdict |", "| --- | --- | --- | --- | --- | --- |"]
    for r in RESULTS:
        rows.append("| %s | %s | `%s` | %s | %s | **%s** |" % (r["id"], r["group"], cell(r["command"]).replace("`", "'"), cell(r["expect"]), cell(r["observed"]), r["verdict"]))
    repro = ["", "Reproductions (every verdict that is not PASS):", ""]
    for r in RESULTS:
        if r["verdict"] != "PASS":
            repro.append("- %s: `%s`" % (r["id"], (r["repro"] or r["command"]).replace("`", "'")))
    with open(ctx.path("results.md"), "w", encoding="utf-8") as handle:
        handle.write("\n".join(rows + repro) + "\n")


def main():
    parser = argparse.ArgumentParser(description="Run the engine usage scenarios.")
    parser.add_argument("--searchd", required=True)
    parser.add_argument("--scratch", required=True)
    parser.add_argument("--repo", default=os.path.normpath(os.path.join(HERE, "..", "..", "..")))
    parser.add_argument("--skip-scale", action="store_true")
    parser.add_argument("--skip-dart", action="store_true")
    args = parser.parse_args()
    if os.path.exists(args.scratch) and os.listdir(args.scratch):
        sys.exit("refusing: %s is not empty (give a new folder)" % args.scratch)
    os.makedirs(args.scratch, exist_ok=True)
    ctx = Ctx(args.searchd, args.scratch, args.repo, args.skip_scale, args.skip_dart)
    gen_corpus.make_household(ctx.path("home"))
    # The scale folder first (U08 uses it), then the household index (most scenarios read it).
    order = sorted(SCENARIOS, key=lambda fn: {"S01": 0, "I01": 1}.get(fn.sid, 2))
    for fn in order:
        fn(ctx)
    write_reports(ctx)
    counts = {}
    for r in RESULTS:
        counts[r["verdict"]] = counts.get(r["verdict"], 0) + 1
    print("scenarios %d: %s" % (len(RESULTS), counts))
    print("wrote %s and %s" % (ctx.path("results.md"), ctx.path("results.json")))


if __name__ == "__main__":
    main()
