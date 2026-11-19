"""S6-T8 verifier (recheck): the v4 damage cases on fa61957 against the first Verdict's results on 6b340b4 (same cases,
same edge index bytes): per case, the results with the scratch directory name left out, equal or not."""
import json, sys
def load(paths):
    out = {}
    for p in paths:
        for l in open(p):
            r = json.loads(l)
            if "result" in r:
                res = dict(r["result"]); res.pop("idx", None)
                out[r["info"]["case"]] = (r["info"]["expected"], res)
    return out
old = load(sys.argv[2:]); new = load([sys.argv[1]])
same = 0
for k, (exp, res) in new.items():
    if k not in old:
        print("new only:", k, exp, json.dumps(res, ensure_ascii=False)[:300]); continue
    if old[k][1] == res: same += 1
    else: print("DIFFERS:", k, "\n  old:", json.dumps(old[k][1], ensure_ascii=False)[:400], "\n  new:", json.dumps(res, ensure_ascii=False)[:400])
print(f"{same} of {len(new)} cases identical to the first Verdict's; {len(set(old) - set(new))} old-only")
