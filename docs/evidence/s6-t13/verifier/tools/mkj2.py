"""S6-T7 verifier: write the J2 changes request (as scripts/j2_run.py changes_request) to argv[2] from pack argv[1]."""
import base64, json, sys
from pathlib import Path
pack = Path(sys.argv[1])
j = json.loads((pack / "judgments.json").read_text(encoding="utf-8"))
req = {"roots": [{"root_id": r, "label": r, "kind": "host"} for r in j["roots"]], "changes": []}
for root in j["roots"]:
    base = pack / root
    for p in sorted(x for x in base.rglob("*") if x.is_file()):
        req["changes"].append({"op": "add", "root_id": root, "path": p.relative_to(base).as_posix(),
                               "content_base64": base64.b64encode(p.read_bytes()).decode("ascii")})
Path(sys.argv[2]).write_text(json.dumps(req), encoding="utf-8")
print(len(req["changes"]), j["roots"])
