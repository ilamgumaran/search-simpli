"""S6-T8 verifier (fourth check): a later update over a v4 index whose section 5 has one byte left over after the
last table (dmg4.py's r12_leftover_byte, every checksum resealed), through four writers (CLI index --update, CLI
apply, C ABI ss_index_folder with update, C ABI ss_apply_changes), each on its own copy, for one library variant.
    v4tail.py VARIANT WORKDIR OUT.jsonl"""
import json, shutil, subprocess, sys
from pathlib import Path
V = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(V / "dmg"))
variant, W, OUT = sys.argv[1], V / sys.argv[2], Path(sys.argv[3])
SRC = V / "idx.noindex/head2/edge"          # the head's own v2.5 (HYBLEX04) edge index
CORPUS = V / "corpora.noindex/edge"
ABI = V / "dmg/abi_call.py"
searchd = lambda v: str(V / "bin" / v / "bin/searchd")
W.mkdir(parents=True, exist_ok=True)
dmg = W / "v4-leftover"
if not dmg.exists():
    r = subprocess.run([sys.executable, "-I", str(V / "dmg/dmg4.py"), "make", str(SRC), str(dmg), "r12_leftover_byte"], capture_output=True, text=True)
    if r.returncode:
        raise SystemExit(r.stderr)
    (W / "v4-leftover.info.json").write_text(r.stdout)
info = json.loads((W / "v4-leftover.info.json").read_text())
words = info["words"][:2]
import hashlib
def snap(d):
    return {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(d.iterdir()) if p.is_file()}
def find(idx):
    out = []
    for w in words:
        p = subprocess.run([searchd("head2"), "find", str(idx), w, "--json"], capture_output=True, text=True)
        out.append(("ERR " + (p.stderr.strip() or p.stdout.strip())[-60:]) if p.returncode else "ok %d hits" % len(json.loads(p.stdout)["hits"]))
    return out
def gen(idx):
    p = subprocess.run([searchd("head2"), "list-files", str(idx), "--json"], capture_output=True, text=True)
    try:
        return json.loads(p.stdout).get("generation")
    except Exception:
        return "unread: " + (p.stderr.strip()[-60:])
change = {"changes": [{"op": "add", "root_id": "r-legacy", "path": "zz-verifier-note.md", "content_base64": "IyBOb3RlCgpBIG5ldyBub3RlLgo="}]}
cf = W / "change-add.json"
cf.write_text(json.dumps(change))
row = {"variant": variant, "case": "v4 section 5 with one byte left over after the last table", "read_before": find(dmg), "writes": {}}
for wname in ("cli_update", "cli_apply", "abi_index_update", "abi_apply"):
    d = W / f"{variant}.{wname}"
    if d.exists():
        raise SystemExit(f"{d} exists")
    shutil.copytree(dmg, d)
    before = snap(d)
    if wname == "cli_update":
        p = subprocess.run([searchd(variant), "index", str(CORPUS), "--out", str(d), "--update", "--filename-index"], capture_output=True, text=True)
        res = f"exit {p.returncode}: " + (p.stderr.strip() or p.stdout.strip())[-80:]
    elif wname == "cli_apply":
        p = subprocess.run([searchd(variant), "apply", str(d), "--changes", str(cf), "--filename-index"], capture_output=True, text=True)
        res = f"exit {p.returncode}: " + (p.stderr.strip() or p.stdout.strip())[-80:]
    else:
        fn = "ss_index_folder" if wname == "abi_index_update" else "ss_apply_changes"
        arg = str(CORPUS) if fn == "ss_index_folder" else json.dumps(change)
        p = subprocess.run([sys.executable, "-I", str(ABI), str(V / "libs" / variant / "libsearch_simpli.dylib"), fn, str(d), arg] + (['{"filename_index":true,"update":true}'] if fn == "ss_index_folder" else []), capture_output=True, text=True)
        res = (p.stdout.strip() or p.stderr.strip())[-100:]
    after = snap(d)
    row["writes"][wname] = {"result": res, "published": after.get("MANIFEST") != before.get("MANIFEST"),
                            "files_changed": sorted(k for k in set(before) | set(after) if before.get(k) != after.get(k)),
                            "generation": gen(d), "head_find_after": find(d)}
OUT.write_text(json.dumps(row, ensure_ascii=False) + "\n")
print(json.dumps(row, ensure_ascii=False, indent=1))
