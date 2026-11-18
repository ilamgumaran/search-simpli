"""S6-T8 verifier (recheck), audit item 14: a v4 table of a removed document damaged (length 0), then the file removed
through four head writers; prints each writer's result, files changed and finds after."""
import hashlib, json, shutil, subprocess, sys
from pathlib import Path
V = Path(__file__).resolve().parent.parent
W = V / "dmgv2b.noindex"
base = W / "i14-base"
folder = W / "folder-minus-edge14.txt"
SD = str(V / "bin/head2/bin/searchd")
LIB = str(V / "libs/head2/libsearch_simpli.dylib")
words = ["sabcdefghijklm", "middle", "the"]
def snap(d): return {p.name: hashlib.sha256(p.read_bytes()).hexdigest()[:12] for p in sorted(d.iterdir()) if p.is_file()}
def find(d):
    out = []
    for w in words:
        p = subprocess.run([SD, "find", str(d), w, "--json"], capture_output=True, text=True)
        out.append(w + "=" + (("ERR " + p.stderr.strip()[-40:]) if p.returncode else str(sorted({h["path"] for h in json.loads(p.stdout)["hits"]})[:4])))
    return out
print("before:", find(base))
change = json.dumps({"changes": [{"op": "remove", "root_id": "r-legacy", "path": "edge14.txt"}]})
cf = W / "i14-change.json"; cf.write_text(change)
for name in ["cli_update", "cli_apply", "abi_update", "abi_apply"]:
    d = W / ("i14-" + name)
    if not d.exists(): shutil.copytree(base, d)
    b = snap(d)
    if name == "cli_update": p = subprocess.run([SD, "index", str(folder), "--out", str(d), "--update", "--filename-index"], capture_output=True, text=True)
    elif name == "cli_apply": p = subprocess.run([SD, "apply", str(d), "--changes", str(cf), "--filename-index"], capture_output=True, text=True)
    elif name == "abi_update": p = subprocess.run([sys.executable, "-I", str(V / "dmg/abi_call.py"), LIB, "ss_index_folder", str(d), str(folder), '{"filename_index":true,"update":true}'], capture_output=True, text=True)
    else: p = subprocess.run([sys.executable, "-I", str(V / "dmg/abi_call.py"), LIB, "ss_apply_changes", str(d), change], capture_output=True, text=True)
    a = snap(d)
    res = (p.stdout.strip() or p.stderr.strip())[-90:]
    print(name, "exit", p.returncode, res, "| changed:", sorted(k for k in set(a) | set(b) if a.get(k) != b.get(k)), "|", find(d))
