"""S6-T5 verifier: compare two capture_query_outputs.py files (main, head)."""
import json, sys, collections
sys.path.insert(0, __import__("os").path.dirname(__file__))
import ssdrv
m = [json.loads(l) for l in open(sys.argv[1])]
h = [json.loads(l) for l in open(sys.argv[2])]
assert [x["case"] for x in m] == [x["case"] for x in h]
c = collections.Counter(); codes = collections.Counter(); bad = []
for a, b in zip(m, h):
    field = a["options"].get("search_field", "content")
    A, B = a["output"].encode(), b["output"].encode()
    if a["options"] != b["options"]:
        bad.append(("options", a["case"]))
    if A == B:
        c[(field, "identical")] += 1
        continue
    if field != "content" and ssdrv.outside_warnings(A) == ssdrv.outside_warnings(B) and ssdrv.warnings_bytes(A) == b"[]":
        c[(field, "only-warnings")] += 1
        for w in json.loads(ssdrv.warnings_bytes(B)):
            codes[(field, w["code"])] += 1
        continue
    c[(field, "DIFFERS")] += 1
    bad.append(a["case"])
for k in sorted(c): print(k, c[k])
for k in sorted(codes): print(k, codes[k])
print("unexplained", len(bad), bad[:5])
