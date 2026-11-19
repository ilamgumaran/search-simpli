"""S6-T8 verifier (fifth check): one dmg4.py v4 case on the head's own v2.5 edge index, read by `find`, then a later
update through six writers, each on its own copy: CLI index --update and ss_index_folder with update (the folder as it
is: every table carried), CLI apply and ss_apply_changes with a file added (carried), and the same two with the
damaged table's file removed (dropped). find runs with the head's searchd, or with V4FIND's (a variant name).
    v4case.py VARIANT CASE WORKDIR OUT.jsonl"""
import hashlib, json, os, shutil, subprocess, sys
from pathlib import Path
V = Path(__file__).resolve().parent.parent
variant, case, W, OUT = sys.argv[1], sys.argv[2], V / sys.argv[3], Path(sys.argv[4])
SRC, CORPUS, ABI = V / "idx.noindex/head2/edge", V / "corpora.noindex/edge", V / "dmg/abi_call.py"
searchd = lambda v: str(V / "bin" / v / "bin/searchd")
W.mkdir(parents=True, exist_ok=True)
dmg = W / case
if not dmg.exists():
    r = subprocess.run([sys.executable, "-I", str(V / "dmg/dmg4.py"), "make", str(SRC), str(dmg), case], capture_output=True, text=True)
    if r.returncode:
        raise SystemExit(r.stderr)
    (W / f"{case}.info.json").write_text(r.stdout)
info = json.loads((W / f"{case}.info.json").read_text())
words = info["words"][:2] or ["the"]
snap = lambda d: {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(d.iterdir()) if p.is_file()}
def find(idx):
    out = []
    for w in words:
        p = subprocess.run([searchd(os.environ.get("V4FIND", "head2")), "find", str(idx), w, "--json"], capture_output=True, text=True)
        out.append(("ERR " + (p.stderr.strip() or p.stdout.strip())[-50:]) if p.returncode else "ok %d hits" % len(json.loads(p.stdout)["hits"]))
    return out
def gen(idx):
    p = subprocess.run([searchd(os.environ.get("V4FIND", "head2")), "list-files", str(idx), "--json"], capture_output=True, text=True)
    try:
        return json.loads(p.stdout).get("generation")
    except Exception:
        return "unread"
add = {"changes": [{"op": "add", "root_id": "r-legacy", "path": "zz-verifier-note.md", "content_base64": "IyBOb3RlCgpBIG5ldyBub3RlLgo="}]}
rem = {"changes": [{"op": "remove", "root_id": "r-legacy", "path": info["path"]}]}
row = {"variant": variant, "find_with": os.environ.get("V4FIND", "head2"), "case": case, "doc": info["doc"], "path": info["path"], "find_before": find(dmg), "writes": {}}
for wname in ("cli_update", "abi_index_update", "cli_apply_add", "abi_apply_add", "cli_apply_remove", "abi_apply_remove"):
    d = W / f"{case}.{variant}.{wname}"
    if d.exists():
        raise SystemExit(f"{d} exists")
    shutil.copytree(dmg, d)
    before = snap(d)
    change = rem if wname.endswith("remove") else add
    if wname == "cli_update":
        p = subprocess.run([searchd(variant), "index", str(CORPUS), "--out", str(d), "--update", "--filename-index"], capture_output=True, text=True)
        res = f"exit {p.returncode}: " + (p.stderr.strip() or p.stdout.strip())[-60:]
    elif wname.startswith("cli_apply"):
        cf = W / f"change-{wname}.json"
        cf.write_text(json.dumps(change))
        p = subprocess.run([searchd(variant), "apply", str(d), "--changes", str(cf), "--filename-index"], capture_output=True, text=True)
        res = f"exit {p.returncode}: " + (p.stderr.strip() or p.stdout.strip())[-60:]
    else:
        fn = "ss_index_folder" if wname == "abi_index_update" else "ss_apply_changes"
        arg = str(CORPUS) if fn == "ss_index_folder" else json.dumps(change)
        p = subprocess.run([sys.executable, "-I", str(ABI), str(V / "libs" / variant / "libsearch_simpli.dylib"), fn, str(d), arg] + (['{"filename_index":true,"update":true}'] if fn == "ss_index_folder" else []), capture_output=True, text=True)
        res = (p.stdout.strip() or p.stderr.strip())[-80:]
    after = snap(d)
    row["writes"][wname] = {"result": res, "published": after.get("MANIFEST") != before.get("MANIFEST"),
                            "changed": len([k for k in set(before) | set(after) if before.get(k) != after.get(k)]),
                            "generation": gen(d), "find_after": find(d)}
with OUT.open("a") as f:
    f.write(json.dumps(row, ensure_ascii=False) + "\n")
print(case, variant, "doc", info["doc"], info["path"], "find before:", row["find_before"])
for k, w in row["writes"].items():
    print(f"  {k:18} {'PUBLISHED' if w['published'] else 'refused '} g{w['generation']} chg={w['changed']} {w['result'][-48:]!r} after={w['find_after']}")
