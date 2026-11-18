"""S6-T8 verifier: decode section 5 of every document in A (expected HYBLEX04) with v4dec, and of B (any
older format), compare token by token; check rule 11 against the chunk texts (v5dec); check that every
other lexical section and every other index file is byte-identical. compare.py A_IDX B_IDX LABEL"""
import json, sys, hashlib
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent))
import v4dec, v5dec
a, b, label = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3]
def lex(d):
    n = v4dec.content_lexical_name((d / "MANIFEST").read_bytes())
    return d / n
la, lb = lex(a), lex(b)
ba, bb = la.read_bytes(), lb.read_bytes()
# chunk texts from A's documents section
dpath = a / __import__("re").search(rb"documents-\d+\.hybseg", (a / "MANIFEST").read_bytes()).group(0).decode()
docs = v5dec.decode_documents(dpath.read_bytes(), has_source=any(a.glob("source-*.hybsrc")), check_checksum=False)
cps = [len(r["text"].decode("utf-8")) for r in docs["records"]]
ra = v4dec.decode_lexical(ba, cps)
rb = v4dec.decode_lexical(bb, cps)
assert ra["ndocs"] == rb["ndocs"] == len(cps)
ntok = sum(len(x) for x in ra["offsets"])
diff_docs = [i for i in range(ra["ndocs"]) if ra["offsets"][i] != rb["offsets"][i]]
# stats for boundary coverage
st = {"gap_neg": 0, "z14": 0, "z15": 0, "z16": 0, "zmax": 0, "len14": 0, "len15": 0, "len16": 0, "lenmax": 0,
      "both_escape": 0, "zero_tok_docs": 0, "one_tok_docs": 0, "tok_at_end": 0}
for i, toks in enumerate(ra["offsets"]):
    if len(toks) == 0: st["zero_tok_docs"] += 1
    if len(toks) == 1: st["one_tok_docs"] += 1
    pe = 0
    for s, l in toks:
        g = s - pe
        z = 2 * g if g >= 0 else -2 * g - 1
        if g < 0: st["gap_neg"] += 1
        for k in (14, 15, 16):
            if z == k: st["z%d" % k] += 1
            if l == k: st["len%d" % k] += 1
        st["zmax"] = max(st["zmax"], z); st["lenmax"] = max(st["lenmax"], l)
        if z >= 15 and l >= 15: st["both_escape"] += 1
        if s + l == cps[i]: st["tok_at_end"] += 1
        pe = s + l
# other sections identical
ha, hb = ra["header_len"], rb["header_len"]
same_sections = {}
pa, pb = ha, hb
for k, (x, y) in enumerate(zip(ra["sizes"], rb["sizes"])):
    same_sections[k + 1] = (x, y, ba[pa:pa + x] == bb[pb:pb + y])
    pa += x; pb += y
files = {}
for f in sorted(set(p.name for p in a.iterdir()) | set(p.name for p in b.iterdir())):
    fa, fb = a / f, b / f
    if fa.is_file() and fb.is_file():
        files[f] = "same" if fa.read_bytes() == fb.read_bytes() else "differs"
    else:
        files[f] = "only " + ("A" if fa.exists() else "B")
out = {"label": label, "A_magic": ra["magic"].decode(), "B_magic": rb["magic"].decode(), "docs": ra["ndocs"], "tokens": ntok,
       "docs_differing": len(diff_docs), "first_diff": diff_docs[:3], "rule11_checked_docs": len(cps),
       "section_sizes_A_B_same": same_sections, "lexical_file_A_B": [len(ba), len(bb)], "files": files, "coverage": st}
print(json.dumps(out))
