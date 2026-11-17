"""S6-T5 verifier: the number of warnings the head writes per timing cell (both, filename), untimed."""
import json, sys
sys.path.insert(0, __import__("os").path.dirname(__file__))
import ssdrv
lib = ssdrv.Lib(sys.argv[1]); V = sys.argv[2]; out = {}
for c in ("timing-10k", "prose-10k", "tamil-10k"):
    q = json.load(open(f"{V}/q/{c}.json")); h = lib.open(f"{V}/idx/{c}")
    for field in ("both", "filename"):
        for text in q["queries"]:
            a, _ = lib.query(h, text, field, {}, top_k=10)
            out[f"{c}|{field} {text}"] = [w["code"] for w in json.loads(ssdrv.warnings_bytes(a))]
    lib.close(h)
json.dump(out, open(sys.argv[3], "w"), ensure_ascii=False, indent=0)
