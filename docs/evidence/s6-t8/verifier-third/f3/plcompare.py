"""S6-T8 verifier (recheck): a planted build's v2matrix rows against head2's, per format, case and head writer:
the same result (published or refused, the error, files changed, generation, finds after) or not."""
import json, sys
def load(paths):
    out = {}
    for p in paths:
        for l in open(p):
            r = json.loads(l)
            for k, w in r["writes"].items():
                if k.startswith("head_"):
                    out[(r["format"], r["case"], k)] = (w["published"], w["result"].split(": ")[-1] if not w["published"] else "", len(w["changed"]), w["generation"], json.dumps(w["head_find_after"]))
    return out
plant, ref = load([sys.argv[1]]), load(sys.argv[2:])
same = diff = 0
for k, v in sorted(plant.items()):
    if k[2] == "head_abi_index_folder":
        continue
    if ref.get(k) == v:
        same += 1
    else:
        diff += 1
        print("DIFFERS", k, "\n   head2:", ref.get(k), "\n   plant:", v)
print(f"{same} writes the same as head2's, {diff} differ")
