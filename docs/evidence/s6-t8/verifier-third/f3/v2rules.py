"""S6-T8 verifier (recheck): v2-coded section 5 damage (HYBLEX03 of main or of ad71cfb, HYBLEX02 of 109bf11), one rule
at a time, built from the index's own decoded tables, the section's XXH3 and the manifest resealed (dmg4.reseal).
  v2rules.py list
  v2rules.py make SRC_IDX OUT CASE TEXTS_IDX   (TEXTS_IDX: main's index of the same folder, for texts and paths)
Prints one JSON line: case, doc, path, words, v2_accepts (whether v2's rules accept the section), note.
"""
import json, shutil, struct, sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE)); sys.path.insert(0, str(HERE.parent / "dec"))
import dmg4, v4dec, v5dec  # noqa: E402

ev = dmg4.ev


def model(spans):
    docs = []
    for toks in spans:
        ps, raw = 0, []
        for s, l in toks:
            raw.append([ev(s - ps), ev(l)])
            ps = s
        docs.append({"count": struct.pack("<I", len(toks)), "tokens": raw})
    return {"docs": docs, "tail": b""}


def encode(m):
    out = bytearray()
    for d in m["docs"]:
        out += d["count"]
        for a, b in d["tokens"]:
            out += a + b
    return bytes(out) + m["tail"]


def last_doc(spans, n=1):
    return max(i for i, t in enumerate(spans) if len(t) >= n)


def mid_doc(spans, n=3):
    for i in range(len(spans) // 2, len(spans)):
        if len(spans[i]) >= n:
            return i
    raise SystemExit("no mid doc")


def set_start(m, spans, d, k, new_start, new_len=None):
    """Token k of doc d to start at new_start (and length new_len); the next token's delta kept absolute."""
    prev_start = spans[d][k - 1][0] if k else 0
    m["docs"][d]["tokens"][k][0] = ev(new_start - prev_start)
    if new_len is not None:
        m["docs"][d]["tokens"][k][1] = ev(new_len)
    if k + 1 < len(spans[d]):
        m["docs"][d]["tokens"][k + 1][0] = ev(spans[d][k + 1][0] - new_start) if spans[d][k + 1][0] >= new_start else ev(0)


CASES = {}


def case(accepts, note):
    def deco(fn):
        CASES[fn.__name__] = (fn, accepts, note)
        return fn
    return deco


@case(False, "length 0, first token of the first document")
def z_first(m, spans, texts, recs):
    d = min(i for i, t in enumerate(spans) if t)
    m["docs"][d]["tokens"][0][1] = ev(0)
    return d


@case(False, "length 0, a middle token of a middle document")
def z_mid(m, spans, texts, recs):
    d = mid_doc(spans)
    m["docs"][d]["tokens"][len(spans[d]) // 2][1] = ev(0)
    return d


@case(False, "length 0, the last token of the last document (the Verdict's v2_zero_length)")
def z_last(m, spans, texts, recs):
    d = last_doc(spans)
    m["docs"][d]["tokens"][-1][1] = ev(0)
    return d


@case(False, "the last token's end at exactly 2^32")
def end_2p32(m, spans, texts, recs):
    d = last_doc(spans)
    s, l = spans[d][-1]
    set_start(m, spans, d, len(spans[d]) - 1, (1 << 32) - l)
    return d


@case(False, "the last document's count +1 (the section runs out)")
def count_plus1_last(m, spans, texts, recs):
    d = last_doc(spans)
    m["docs"][d]["count"] = struct.pack("<I", len(spans[d]) + 1)
    return d


@case(False, "a middle document's count -1 (its table holds one token more)")
def count_minus1_mid(m, spans, texts, recs):
    d = mid_doc(spans)
    m["docs"][d]["count"] = struct.pack("<I", len(spans[d]) - 1)
    return d


@case(False, "the last token's length varint with a sixth byte")
def varint_sixth(m, spans, texts, recs):
    d = last_doc(spans)
    m["docs"][d]["tokens"][-1][1] = b"\x81\x80\x80\x80\x80\x00"
    return d


@case(False, "the last token's length varint with a fifth byte above 0x0F (2^32 + 1)")
def varint_fifth_over(m, spans, texts, recs):
    d = last_doc(spans)
    m["docs"][d]["tokens"][-1][1] = b"\x81\x80\x80\x80\x10"
    return d


@case(False, "the section ends inside the last token (its length varint cut)")
def trunc_last_table(m, spans, texts, recs):
    d = last_doc(spans)
    m["docs"][d]["tokens"][-1][1] = b""
    return d


@case(False, "the section ends inside the last document's count")
def trunc_last_count(m, spans, texts, recs):
    d = len(spans) - 1
    m["docs"][d] = {"count": m["docs"][d]["count"][:2], "tokens": []}
    return d


@case(False, "one byte left over after the last table")
def leftover(m, spans, texts, recs):
    m["tail"] = b"\x00"
    return len(spans) - 1


@case(True, "valid v2: the last token 2^31 - 1 codepoints after the previous end (zigzag 2^32 - 2)")
def gap_2p31_minus1(m, spans, texts, recs):
    d = last_doc(spans, 2)
    pe = spans[d][-2][0] + spans[d][-2][1]
    set_start(m, spans, d, len(spans[d]) - 1, pe + (1 << 31) - 1, 1)
    return d


@case(True, "valid v2: the last token 2^31 codepoints after the previous end (zigzag 2^32; audit item 5)")
def gap_2p31(m, spans, texts, recs):
    d = last_doc(spans, 2)
    pe = spans[d][-2][0] + spans[d][-2][1]
    set_start(m, spans, d, len(spans[d]) - 1, pe + (1 << 31), 1)
    return d


@case(True, "valid v2: a token of length 2^31, the next starting where it starts (gap -2^31, zigzag 2^32 - 1)")
def neg_gap_2p31(m, spans, texts, recs):
    d = last_doc(spans, 2)
    k = len(spans[d]) - 2
    m["docs"][d]["tokens"][k][1] = ev(1 << 31)
    m["docs"][d]["tokens"][k + 1][0] = ev(0)
    return d


@case(True, "valid v2: a token of length 2^31 + 1, the next starting where it starts (zigzag 2^32 + 1; audit item 5)")
def neg_gap_2p31_plus1(m, spans, texts, recs):
    d = last_doc(spans, 2)
    k = len(spans[d]) - 2
    m["docs"][d]["tokens"][k][1] = ev((1 << 31) + 1)
    m["docs"][d]["tokens"][k + 1][0] = ev(0)
    return d


@case(True, "valid v2: the last token of a chunk one codepoint past its text (rule 11's case; v2 has no text rule)")
def past_text(m, spans, texts, recs):
    for d in range(len(spans) - 1, -1, -1):
        if spans[d] and spans[d][-1][0] + spans[d][-1][1] == len(texts[d]):
            m["docs"][d]["tokens"][-1][1] = ev(spans[d][-1][1] + 1)
            return d
    raise SystemExit("none")


REMOVED = "edge14.txt"


@case(False, "length 0 in the first token of " + REMOVED + "'s only table; the publish then removes that file (audit item 9)")
def removed_z(m, spans, texts, recs):
    ds = [i for i, r in enumerate(recs) if r["path"].decode() == REMOVED]
    assert len(ds) == 1 and spans[ds[0]], ds
    m["docs"][ds[0]]["tokens"][0][1] = ev(0)
    return ds[0]



@case(False, "the count of " + REMOVED + "'s only table +1, its tokens unchanged; the publish then removes that file (recheck: the plant ck-count-removed)")
def removed_count(m, spans, texts, recs):
    ds = [i for i, r in enumerate(recs) if r["path"].decode() == REMOVED]
    assert len(ds) == 1 and spans[ds[0]], ds
    m["docs"][ds[0]]["count"] = struct.pack("<I", len(spans[ds[0]]) + 1)
    return ds[0]


@case(False, "the last token of " + REMOVED + "'s only table ending at exactly 2^32; the publish then removes that file (recheck: the plant ck-u32-end-removed)")
def removed_end(m, spans, texts, recs):
    ds = [i for i, r in enumerate(recs) if r["path"].decode() == REMOVED]
    assert len(ds) == 1 and spans[ds[0]], ds
    d = ds[0]
    s, l = spans[d][-1]
    set_start(m, spans, d, len(spans[d]) - 1, (1 << 32) - l)
    return d


@case(False, "length 0 in the first token of the section's last table; the publish then removes that document's file (recheck: the plant drop-skip-last)")
def removed_last_z(m, spans, texts, recs):
    d = len(spans) - 1
    assert spans[d], "the last document has no tokens"
    m["docs"][d]["tokens"][0][1] = ev(0)
    return d

@case(False, "the first token's start-delta varint of " + REMOVED + "'s only table written in five bytes with a fifth byte of 0x10 (its value + 2^32); the publish then removes that file (third check: the plant ck-fifth-loose-start)")
def removed_start_fifth(m, spans, texts, recs):
    ds = [i for i, r in enumerate(recs) if r["path"].decode() == REMOVED]
    assert len(ds) == 1 and spans[ds[0]], ds
    d0 = spans[ds[0]][0][0]
    assert d0 < (1 << 28), d0
    m["docs"][ds[0]]["tokens"][0][0] = bytes([(d0 & 0x7F) | 0x80, ((d0 >> 7) & 0x7F) | 0x80, ((d0 >> 14) & 0x7F) | 0x80, ((d0 >> 21) & 0x7F) | 0x80, 0x10])
    return ds[0]

def build(src, out, name, texts_idx):
    if out.exists():
        raise SystemExit(str(out) + " exists")
    lexname, _ = dmg4.manifest_names(src)
    b = (src / lexname).read_bytes()
    dec = v4dec.decode_lexical(b)
    assert dec["magic"] in (b"HYBLEX02", b"HYBLEX03")
    spans = dec["offsets"]
    s5 = b[dec["section5"][0]:dec["section5"][0] + dec["section5"][1]]
    assert encode(model(spans)) == s5, "model does not round-trip"
    _, docname = dmg4.manifest_names(texts_idx)
    recs = v5dec.decode_documents((texts_idx / docname).read_bytes(), True, check_checksum=False)["records"]
    texts = [r["text"].decode("utf-8") for r in recs]
    assert len(recs) == len(spans)
    fn, accepts, note = CASES[name]
    m = model(spans)
    d = fn(m, spans, texts, recs)
    shutil.copytree(src, out)
    dmg4.reseal(out, lexname, encode(m))
    words = sorted({texts[d][s:s + l] for s, l in spans[d] if l >= 2}, key=lambda w: -len(w))[:2]
    print(json.dumps({"case": name, "doc": d, "path": recs[d]["path"].decode(), "words": words,
                      "v2_accepts": accepts, "note": note}, ensure_ascii=False))


if __name__ == "__main__":
    if sys.argv[1] == "list":
        print(" ".join(CASES))
    else:
        build(Path(sys.argv[2]), Path(sys.argv[3]), sys.argv[4], Path(sys.argv[5]))
