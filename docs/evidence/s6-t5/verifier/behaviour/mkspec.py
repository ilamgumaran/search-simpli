import base64, json, pathlib, random
V = pathlib.Path("<vscratch>"); W = pathlib.Path("<worktree>")
pack = W / "fixtures/j2"
j = json.loads((pack / "judgments.json").read_text())
req = {"roots": [{"root_id": r, "label": r, "kind": "host"} for r in j["roots"]], "changes": []}
for root in j["roots"]:
    base = pack / root
    for p in sorted(x for x in base.rglob("*") if x.is_file()):
        req["changes"].append({"op": "add", "root_id": root, "path": p.relative_to(base).as_posix(),
                               "content_base64": base64.b64encode(p.read_bytes()).decode()})
(V / "beh/j2-changes.json").write_text(json.dumps(req))
j2q = [q["query"] for q in j["queries"] if q["mode"] == "knowledge"]
idx = [{"name": "j2", "dir": str(V / "beh/j2idx.noindex/idx"), "queries": j2q, "roots": j["roots"]}]
for c in ("timing-10k", "prose-10k", "tamil-10k"):
    idx.append({"name": c, "dir": str(V / "idx" / c), "queries": json.loads((V / "q" / (c + ".json")).read_text())["queries"], "roots": None})
f1 = ["lantern festival", "lantren pear", "qorvix apple pear", "paint walk", "walkng painter", "orchard plum", "!!! ...", "canyon pebble"]
idx.append({"name": "f1", "dir": str(V / "beh/fx2.noindex/f1"), "queries": f1, "roots": None})
folders = [{"name": "j2-home", "dir": str(pack / "home"), "queries": j2q[:40]},
           {"name": "family", "dir": str(W / "fixtures/family-folder"), "queries": ["trip", "volcano", "spelling words", "dinosuar museum", "recorder practice"]},
           {"name": "tamil-10k", "dir": str(V / "corpora.noindex/tamil-10k"), "queries": ["system", "டூகனை", "doc 00000"]}]
(V / "beh/spec.json").write_text(json.dumps({"indexes": idx, "folders": folders}, ensure_ascii=False))
print(len(j2q), sum(len(i["queries"]) for i in idx))
