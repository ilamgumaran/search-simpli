"""S6-T8 verifier (recheck): one line per format, case and writer from v2matrix's JSONL."""
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1])]
W = ["head_cli_update", "head_cli_apply", "head_abi_index_update", "head_abi_apply", "head_abi_index_folder", "old_cli_update"]
for r in rows:
    if "make" in r:
        print(r["format"], r["case"], "MAKE FAILED", r["make"]); continue
    rh = r["read_head"]; ro = r["read_old"]
    def short(v):
        if isinstance(v, str): return v.replace("ERR error: ", "E:")
        return "hits" if v != "no hit in the file" else "nohit"
    cells = []
    for k in W:
        x = r["writes"][k]
        if x["published"]:
            t = "PUB g%s bit7=%s" % (x["generation"], x["bit7"])
        else:
            res = x["result"]
            e = res.split(": ")[-1]
            t = "REF[%s] g%s chg=%d" % (e, x["generation"], len(x["changed"]))
        t += " after=" + ",".join(sorted(set(short(v) for v in x["head_find_after"])))
        cells.append(k + ": " + t)
    print(f"{r['format']:5} {r['case']:20} v2={'ok ' if r['v2_accepts'] else 'bad'} old_read={','.join(sorted(set(short(v) for v in ro)))} head_read={','.join(sorted(set(short(v) for v in rh)))}")
    for c in cells: print("      " + c)
