"""S6-T9 verifier: the change sets for change detection and 'updated once'. mkchg.py V
For each folder corpus a clone under corpora.noindex/chg/<corpus>: the first file (path order) gets a line appended
(changed), a new file is added (added), the second file is removed (removed), the third is renamed in its folder
(renamed: the engine plans a remove and an add, or a move), and an invented line. J2: corpora.noindex/chg/j2-chg.json:
one change (new bytes), one add, one remove and one explicit move, with the J2 roots."""
import base64, json, os, shutil, subprocess, sys
V = sys.argv[1]
C = f"{V}/corpora.noindex"; F = f"{V}/src.noindex/main/fixtures"
os.makedirs(f"{C}/chg", exist_ok=True)
src = {"timing-10k": f"{C}/timing-10k", "prose-10k": f"{C}/prose-10k", "tamil-10k": f"{C}/tamil-10k",
       "family": f"{F}/family-folder", "fixtures": F}
for c, s in src.items():
    d = f"{C}/chg/{c}"
    if os.path.exists(d):
        raise SystemExit(f"{d} exists")
    subprocess.run(["cp", "-c", "-R", s, d], check=True)
    files = sorted(os.path.relpath(os.path.join(a, f), d) for a, _, fs in os.walk(d) for f in fs)
    with open(f"{d}/{files[0]}", "ab") as fh:
        fh.write(b"\nA line the verifier added: the lantern by the north gate.\n")
    os.remove(f"{d}/{files[1]}")
    stem, ext = os.path.splitext(files[2])
    os.rename(f"{d}/{files[2]}", f"{d}/{stem}-moved{ext}")
    with open(f"{d}/zz-verifier-added.md", "w") as fh:
        fh.write("# Orchard notes\n\nThe quince tree by the wall gave twelve fruit this year.\n")
    print(c, "changed", files[0], "removed", files[1], "renamed", files[2])
j = json.load(open(f"{C}/j2-changes.json"))
adds = [x for x in j["changes"] if x["op"] == "add"]
t0, t1, t2 = adds[0], adds[1], adds[2]
new = base64.b64encode(base64.b64decode(t0["content_base64"]) + b"\nA line the verifier added.\n").decode()
chg = {"roots": j["roots"], "changes": [
    {"op": "change", "root_id": t0["root_id"], "path": t0["path"], "content_base64": new},
    {"op": "add", "root_id": "home", "path": "notes/verifier-orchard.md",
     "content_base64": base64.b64encode(b"# Orchard\n\nTwelve quinces this year.\n").decode()},
    {"op": "remove", "root_id": t1["root_id"], "path": t1["path"]},
    {"op": "move", "root_id": t2["root_id"], "moved_from": t2["path"], "path": t2["path"].rsplit(".", 1)[0] + "-moved.md"},
]}
json.dump(chg, open(f"{C}/chg/j2-chg.json", "w"))
json.dump({"roots": j["roots"], "changes": []}, open(f"{C}/chg/j2-empty.json", "w"))
print("j2 change", t0["path"], "remove", t1["path"], "move", t2["path"])
