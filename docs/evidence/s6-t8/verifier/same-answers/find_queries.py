"""S6-T8 verifier: derive find queries aimed at the one-byte offsets from an index's own decoded offsets
(my decoder) and chunk texts. find_queries.py IDX OUT.json [SEED]
Picks tokens of length 14, 15, 16 and >16; tokens after gaps z = 14, 15, 16 and > 16; negative gaps;
the first and last token of a chunk; Tamil and combining-mark tokens; one-token chunks; frequent words
(large hit counts, deep paging); prefixes and phrases from adjacent tokens."""
import json, random, sys, unicodedata
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "dec"))
import v4dec, v5dec

idx, out = Path(sys.argv[1]), Path(sys.argv[2])
rng = random.Random(int(sys.argv[3]) if len(sys.argv) > 3 else 8118)
lex = idx / v4dec.content_lexical_name((idx / "MANIFEST").read_bytes())
docs = v5dec.decode_documents((idx / __import__("re").search(rb"documents-\d+\.hybseg", (idx / "MANIFEST").read_bytes()).group(0).decode()).read_bytes(), True, check_checksum=False)
texts = [r["text"].decode("utf-8") for r in docs["records"]]
offs = v4dec.decode_lexical(lex.read_bytes())["offsets"]
buckets = {k: [] for k in ("len14", "len15", "len16", "lenlong", "z14", "z15", "z16", "zlong", "neg", "first", "last",
                           "tamil", "combining", "one", "pairs")}
freq = {}
for d, toks in enumerate(offs):
    t = texts[d]
    pe = 0
    words = []
    for i, (s, l) in enumerate(toks):
        w = t[s:s + l]
        words.append(w)
        g = s - pe
        z = 2 * g if g >= 0 else -2 * g - 1
        if l in (14, 15, 16): buckets["len%d" % l].append(w)
        elif l > 16: buckets["lenlong"].append(w)
        if z in (14, 15, 16): buckets["z%d" % z].append(w)
        elif z > 16: buckets["zlong"].append(w)
        if g < 0: buckets["neg"].append(w)
        if i == 0: buckets["first"].append(w)
        if i == len(toks) - 1: buckets["last"].append(w)
        if any("஀" <= c <= "௿" for c in w): buckets["tamil"].append(w)
        if any(unicodedata.combining(c) for c in w) or unicodedata.normalize("NFC", w) != w: buckets["combining"].append(w)
        if len(toks) == 1: buckets["one"].append(w)
        pe = s + l
        k = w.lower()
        freq[k] = freq.get(k, 0) + 1
    if len(words) >= 2:
        j = rng.randrange(len(words) - 1)
        buckets["pairs"].append(words[j] + " " + words[j + 1])
qs = []
for k, v in buckets.items():
    v = sorted(set(x for x in v if x.strip()))
    pick = rng.sample(v, min(8, len(v)))
    for w in pick:
        if k == "pairs":
            qs.append({"kind": k, "query": '"' + w + '"', "mode": "phrase", "pages": 2})
            qs.append({"kind": k, "query": w, "mode": "words", "pages": 2})
        else:
            qs.append({"kind": k, "query": w, "mode": "words", "pages": 2})
            if len(w) >= 3:
                qs.append({"kind": k, "query": w[:max(2, len(w) // 2)] + "*", "mode": "prefix", "pages": 2})
            qs.append({"kind": k, "query": '"' + w + '"', "mode": "phrase", "pages": 1})
top = sorted(freq.items(), key=lambda kv: -kv[1])[:4]
for w, n in top:
    qs.append({"kind": "frequent", "query": w, "mode": "words", "pages": 60, "hits_in_index": n})
    qs.append({"kind": "frequent", "query": w[:2] + "*", "mode": "prefix", "pages": 30})
out.write_text(json.dumps({"index": str(idx.name), "counts": {k: len(v) for k, v in buckets.items()}, "queries": qs},
                          ensure_ascii=False))
print(idx.name, len(qs), {k: len(v) for k, v in buckets.items()})
