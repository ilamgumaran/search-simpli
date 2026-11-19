"""S6-T8 verifier (recheck): every v2rules case on the edge index of each old format (main = c0eae3d, pre7 = ad71cfb,
pre4 = 109bf11), read by the old reader and by the head, then published over by the head through four paths (CLI
`index --update`, CLI `apply`, C ABI `ss_index_folder` as a full rebuild and with `update`, C ABI `ss_apply_changes`) and by the old format's own writer
(CLI `index --update`), each on its own copy, with every file's size and SHA-256 before and after, then read again
by the head (and, where a writer published, by the old reader too).
  v2matrix.py HEAD_VARIANT OUT_JSONL [FORMATS...]
"""
import hashlib, json, os, shutil, subprocess, sys
from pathlib import Path

V = Path(__file__).resolve().parent.parent
HEAD = sys.argv[1]
OUT = Path(sys.argv[2])
FORMATS = sys.argv[3:] or ["main", "pre7", "pre4"]
W = V / os.environ.get("V2W", "dmgv2.noindex")
W.mkdir(exist_ok=True)
CORPUS = V / "corpora.noindex/edge"
TEXTS = V / "idx.noindex/main/edge"
CASES = subprocess.run([sys.executable, "-I", str(V / "dmg/v2rules.py"), "list"], capture_output=True, text=True, check=True).stdout.split()
if os.environ.get("V2CASES"):
    CASES = [c for c in CASES if c in os.environ["V2CASES"].split()]
ABI = V / "dmg/abi_call.py"


def snap(d):
    return {p.name: (p.stat().st_size, hashlib.sha256(p.read_bytes()).hexdigest()[:16]) for p in sorted(d.iterdir()) if p.is_file()}


def diff(a, b):
    return [f"{k}: {a.get(k, 'absent')} -> {b.get(k, 'absent')}" for k in sorted(set(a) | set(b)) if a.get(k) != b.get(k)]


def searchd(variant):
    return str(V / "bin" / variant / "bin/searchd")


def find(variant, idx, words, path):
    out = []
    for w in words:
        p = subprocess.run([searchd(variant), "find", str(idx), w, "--json"], capture_output=True, text=True)
        if p.returncode:
            out.append("ERR " + (p.stderr.strip() or p.stdout.strip())[-70:])
            continue
        hits = json.loads(p.stdout)["hits"]
        out.append([h["match_offsets"] for h in hits if h["path"] == path] or "no hit in the file")
    return out


def generation(idx):
    p = subprocess.run([searchd(HEAD), "list-files", str(idx), "--json"], capture_output=True, text=True)
    try:
        return json.loads(p.stdout)["generation"]
    except Exception:
        p2 = subprocess.run([searchd("main"), "list-files", str(idx), "--json"], capture_output=True, text=True)
        try:
            return json.loads(p2.stdout)["generation"]
        except Exception:
            return "?"


def bit7(idx):
    m = (idx / "MANIFEST").read_bytes()
    return bool(int.from_bytes(m[10:12], "little") & 0x80)


rows = []
for fmt in FORMATS:
    src = V / "idx.noindex" / fmt / "edge"
    for c in CASES:
        dmg = W / f"{fmt}-{c}"
        if not dmg.exists():
            r = subprocess.run([sys.executable, "-I", str(V / "dmg/v2rules.py"), "make", str(src), str(dmg), c, str(TEXTS)], capture_output=True, text=True)
            if r.returncode:
                rows.append({"format": fmt, "case": c, "make": r.stderr.strip()[-200:]}); continue
            (W / f"{fmt}-{c}.info.json").write_text(r.stdout)
        info = json.loads((W / f"{fmt}-{c}.info.json").read_text())
        path = info["path"]
        removed = c.startswith("removed_")
        folder = CORPUS
        if removed:
            folder = W / f"folder-minus-{path}"
            if not folder.exists():
                subprocess.run(["cp", "-c", "-R", str(CORPUS), str(folder)], check=True)
                (folder / path).unlink()
        change = {"changes": [{"op": "remove", "root_id": "r-legacy", "path": path}]} if removed else \
            {"changes": [{"op": "add", "root_id": "r-legacy", "path": "zz-verifier-note.md", "content_base64": "IyBOb3RlCgpBIG5ldyBub3RlLgo="}]}
        cf = W / f"change-{'remove' if removed else 'add'}.json"
        cf.write_text(json.dumps(change))
        row = {"format": fmt, "case": c, "note": info["note"], "v2_accepts": info["v2_accepts"], "doc": info["doc"], "path": path,
               "read_old": find(fmt, dmg, info["words"], path), "read_head": find(HEAD, dmg, info["words"], path), "writes": {}}
        for wname in ("head_cli_update", "head_cli_apply", "head_abi_index_folder", "head_abi_index_update", "head_abi_apply", "old_cli_update"):
            d = W / f"{fmt}-{c}.{wname}"
            if not d.exists():
                shutil.copytree(dmg, d)
            before = snap(d)
            if wname == "head_cli_update" or wname == "old_cli_update":
                v = HEAD if wname.startswith("head") else fmt
                p = subprocess.run([searchd(v), "index", str(folder), "--out", str(d), "--update", "--filename-index"], capture_output=True, text=True)
                res = f"exit {p.returncode}: " + (p.stderr.strip() or p.stdout.strip())[-90:]
            elif wname == "head_cli_apply":
                p = subprocess.run([searchd(HEAD), "apply", str(d), "--changes", str(cf), "--filename-index"], capture_output=True, text=True)
                res = f"exit {p.returncode}: " + (p.stderr.strip() or p.stdout.strip())[-90:]
            else:
                fn = "ss_index_folder" if wname.startswith("head_abi_index") else "ss_apply_changes"
                arg = str(folder) if fn == "ss_index_folder" else json.dumps(change)
                p = subprocess.run([sys.executable, "-I", str(ABI), str(V / "libs" / HEAD / "libsearch_simpli.dylib"), fn, str(d), arg] + (['{"filename_index":true,"update":true}'] if wname == "head_abi_index_update" else []), capture_output=True, text=True)
                res = (p.stdout.strip() or p.stderr.strip())[-110:]
            after = snap(d)
            published = after.get("MANIFEST") != before.get("MANIFEST")
            wrow = {"result": res, "published": published, "changed": diff(before, after), "generation": generation(d), "bit7": bit7(d),
                    "head_find_after": find(HEAD, d, info["words"], path)}
            if published and wname == "old_cli_update":
                wrow["old_find_after"] = find(fmt, d, info["words"], path)
            row["writes"][wname] = wrow
        rows.append(row)
        print(json.dumps(row, ensure_ascii=False), flush=True)
OUT.write_text("".join(json.dumps(r, ensure_ascii=False) + "\n" for r in rows))
