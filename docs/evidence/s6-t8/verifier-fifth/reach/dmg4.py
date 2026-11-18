"""S6-T8 verifier: damaged HYBLEX04 (and HYBLEX03 v2-coded) section 5, resealed (lexical XXH3, manifest
lengths, checksum and FNV-1a). Written from docs/lexical-segment-format-v4.md and manifest-format-v2.md.

    dmg4.py make SRC_IDX OUT_IDX CASE      -> writes the damaged copy, prints the case's target doc and queries
    dmg4.py list
The case functions edit a raw model of section 5: docs = [{"count": raw bytes, "tokens": [[byte, gesc, lesc]]}],
plus "tail" bytes after the last document."""
import json, re, shutil, struct, subprocess, sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "dec"))
import v4dec, v5dec

XXH = str(Path(__file__).resolve().parent.parent / "tools" / "xxh")


def ev(v):
    out = bytearray()
    while True:
        x = v & 0x7F
        v >>= 7
        if v:
            out.append(x | 0x80)
        else:
            out.append(x)
            return bytes(out)


def fnv(data):
    h = 0xCBF29CE484222325
    for x in data:
        h = ((h ^ x) * 0x100000001B3) & 0xFFFFFFFFFFFFFFFF
    return h


def zz(g):
    return 2 * g if g >= 0 else -2 * g - 1


def tok_raw(gap, length):
    z = zz(gap)
    G = 15 if z >= 15 else z
    L = 15 if length >= 15 else length
    return [G | (L << 4), ev(z) if G == 15 else b"", ev(length) if L == 15 else b""]


def model_v4(spans_per_doc):
    docs = []
    for toks in spans_per_doc:
        pe = 0
        raw = []
        for s, l in toks:
            raw.append(tok_raw(s - pe, l))
            pe = s + l
        docs.append({"count": ev(len(toks)), "tokens": raw})
    return {"docs": docs, "tail": b""}


def encode_v4(m):
    out = bytearray()
    for d in m["docs"]:
        out += d["count"]
        for b, ge, le in d["tokens"]:
            out.append(b)
            out += ge + le
    return bytes(out) + m["tail"]


def encode_v2(spans_per_doc, count_override=None, tail=b""):
    out = bytearray()
    for i, toks in enumerate(spans_per_doc):
        c = len(toks) if not count_override or i not in count_override else count_override[i]
        out += struct.pack("<I", c)
        ps = 0
        for s, l in toks:
            out += ev(s - ps) + ev(l)
            ps = s
    return bytes(out) + tail


def manifest_names(d):
    m = (d / "MANIFEST").read_bytes()
    return v4dec.content_lexical_name(m), re.search(rb"documents-\d+\.hybseg", m).group(0).decode()


def reseal(out_idx, lexname, new_s5):
    p = out_idx / lexname
    b = bytearray(p.read_bytes())
    magic, flags, ndocs, lens, hl = v4dec.header(b)
    s5 = hl + sum(lens[:4])
    b = b[:s5] + new_s5
    struct.pack_into("<Q", b, 64, len(new_s5))  # offsets bytes (v2: 64 as well)
    p.write_bytes(b)
    ck_off = 80 if hl == 88 else 72
    r = subprocess.run([XXH, str(p), str(ck_off), str(hl)], capture_output=True, text=True, check=True)
    ck = int(r.stderr.strip())
    struct.pack_into("<Q", b, ck_off, ck)
    p.write_bytes(b)
    m = bytearray((out_idx / "MANIFEST").read_bytes())
    assert struct.unpack_from("<H", m, 10)[0] & 0x18 == 0x18
    struct.pack_into("<QQ", m, 60, len(b), ck)
    struct.pack_into("<Q", m, 160, fnv(bytes(m[:160]) + bytes(m[168:])))
    (out_idx / "MANIFEST").write_bytes(m)


CASES = {}


def case(fn):
    CASES[fn.__name__] = fn
    return fn


# Each case: (m, spans, texts) -> (target doc index, expected error). m is the raw v4 model (edit in place).
def last_doc_with(spans, n=1):
    return max(i for i, t in enumerate(spans) if len(t) >= n)


@case
def r1_count_truncated(m, spans, texts):  # the section ends inside the last document's count varint
    d = len(m["docs"]) - 1
    m["docs"][d] = {"count": b"\x80", "tokens": []}
    return d, "OffsetsTruncated"


@case
def r1_count_sixth_byte(m, spans, texts):
    d = len(m["docs"]) - 1
    m["docs"][d]["count"] = b"\x80\x80\x80\x80\x80\x00"
    return d, "OffsetsVarintOverflow"


@case
def r1_count_fifth_byte_over(m, spans, texts):
    d = len(m["docs"]) - 1
    m["docs"][d]["count"] = b"\x80\x80\x80\x80\x10"
    return d, "OffsetsVarintOverflow"


@case
def r2_count_plus1_first(m, spans, texts):
    m["docs"][0]["count"] = ev(len(spans[0]) + 1)
    return 0, "OffsetsCountMismatch"


@case
def r2_count_minus1_last(m, spans, texts):
    d = last_doc_with(spans)
    m["docs"][d]["count"] = ev(len(spans[d]) - 1)
    m["docs"][d]["tokens"] = m["docs"][d]["tokens"][:-1]
    return d, "OffsetsCountMismatch"


@case
def r3_last_token_byte_missing(m, spans, texts):
    d = last_doc_with(spans)
    m["docs"][d]["tokens"] = m["docs"][d]["tokens"][:-1]
    for e in m["docs"][d + 1:]:
        assert not e["tokens"]
    return d, "OffsetsTruncated"


def esc_target(m, which):
    for di in range(len(m["docs"]) - 1, -1, -1):
        for ti in range(len(m["docs"][di]["tokens"]) - 1, -1, -1):
            t = m["docs"][di]["tokens"][ti]
            if (which == "g" and t[1]) or (which == "l" and t[2]):
                return di, ti
    raise SystemExit("no escape in " + which)


@case
def r4_gap_escape_overruns(m, spans, texts):  # the last gap escape's varint runs past the section end
    d, t = esc_target(m, "g")
    tok = m["docs"][d]["tokens"]
    tok[t] = [tok[t][0] & 0x0F | 0x10, b"\x8f", b""]  # gap escape, length 1, varint never ends
    m["docs"][d]["tokens"] = tok[:t + 1]
    m["docs"][d]["count"] = ev(len(spans[d]))
    m["docs"] = m["docs"][:d + 1]
    m["tail"] = b""
    return d, "OffsetsTruncated"


@case
def r4_length_escape_overruns(m, spans, texts):
    d, t = esc_target(m, "l")
    tok = m["docs"][d]["tokens"]
    tok[t] = [tok[t][0], tok[t][1], b"\x90"]
    m["docs"][d]["tokens"] = tok[:t + 1]
    m["docs"] = m["docs"][:d + 1]
    return d, "OffsetsTruncated"


@case
def r5_gap_escape_sixth_byte(m, spans, texts):
    d, t = esc_target(m, "g")
    m["docs"][d]["tokens"][t][1] = b"\x90\x80\x80\x80\x80\x00"
    return d, "OffsetsVarintOverflow"


@case
def r5_length_escape_value_2_32(m, spans, texts):
    d, t = esc_target(m, "l")
    m["docs"][d]["tokens"][t][2] = b"\x80\x80\x80\x80\x10"
    return d, "OffsetsVarintOverflow"


@case
def r6_gap_escape_14(m, spans, texts):
    d, t = esc_target(m, "g")
    m["docs"][d]["tokens"][t][1] = ev(14)
    return d, "OffsetsNonCanonicalEscape"


@case
def r6_length_escape_14(m, spans, texts):
    d, t = esc_target(m, "l")
    m["docs"][d]["tokens"][t][2] = ev(14)
    return d, "OffsetsNonCanonicalEscape"


@case
def r6_overlong_escape_accepted(m, spans, texts):  # 15 as 8F 00: valid per the document
    d, t = esc_target(m, "l")
    v = v4dec.varint(m["docs"][d]["tokens"][t][2], 0, 9, "x", "y")[0]
    m["docs"][d]["tokens"][t][2] = bytes([(v & 0x7F) | 0x80]) + bytes([v >> 7]) if v < 16384 else m["docs"][d]["tokens"][t][2]
    return d, None


@case
def r7_zero_length_last(m, spans, texts):
    d = last_doc_with(spans)
    t = m["docs"][d]["tokens"][-1]
    m["docs"][d]["tokens"][-1] = [t[0] & 0x0F, t[1], b""]
    return d, "OffsetsZeroLength"


@case
def r7_zero_length_edge14(m, spans, texts):  # recheck, audit item 14: length 0 in edge14.txt's first token (that file is then removed)
    d = next(i for i, r in enumerate(RECORDS) if r["path"] == b"edge14.txt")
    t = m["docs"][d]["tokens"][0]
    m["docs"][d]["tokens"][0] = [t[0] & 0x0F, t[1], b""]
    return d, "OffsetsZeroLength"


@case
def r8_first_token_before_chunk(m, spans, texts):
    d = 0
    t = m["docs"][d]["tokens"][0]
    m["docs"][d]["tokens"][0] = [(t[0] & 0xF0) | 1, b"", t[2]]  # gap -1 at the document's start
    return d, "OffsetsStartBeforeChunk"


@case
def r9_start_decreases_last(m, spans, texts):
    d = last_doc_with(spans, 2)
    s, l = spans[d][-1]
    ps, pl = spans[d][-2]
    newstart = ps - 1  # before the previous start, still >= 0
    if newstart < 0:
        raise SystemExit("previous start 0")
    m["docs"][d]["tokens"][-1] = tok_raw(newstart - (ps + pl), l)
    return d, "OffsetsStartDecreases"


@case
def r10_end_overflow_last(m, spans, texts):  # a length escape that puts the end at 2^32 (gap kept)
    d = last_doc_with(spans)
    s, l = spans[d][-1]
    pe = spans[d][-2][0] + spans[d][-2][1] if len(spans[d]) > 1 else 0
    if s < 1:
        raise SystemExit("start 0")
    m["docs"][d]["tokens"][-1] = tok_raw(s - pe, (1 << 32) - s)
    return d, "OffsetsEndOverflow"


@case
def r10_end_exactly_max_ok_rule11(m, spans, texts):  # end = 2^32-1 passes rule 10, then rule 11 at the hit
    d = last_doc_with(spans)
    s, l = spans[d][-1]
    pe = spans[d][-2][0] + spans[d][-2][1] if len(spans[d]) > 1 else 0
    m["docs"][d]["tokens"][-1] = tok_raw(s - pe, (1 << 32) - 1 - s)
    return d, "OffsetsPastText"


@case
def r8_gap_minus_8_at_start(m, spans, texts):  # zigzag 15 (an escape of exactly 15) on a document's first token
    d = 0
    t = m["docs"][d]["tokens"][0]
    m["docs"][d]["tokens"][0] = [(t[0] & 0xF0) | 15, ev(15), t[2]]
    return d, "OffsetsStartBeforeChunk"


RECORDS = []


@case
def r11_dedup_contained(m, spans, texts):  # a chunk wholly inside its predecessor's overlap: its last token +1 past
    for d in range(1, len(spans)):
        a, b = RECORDS[d - 1], RECORDS[d]
        if a["path"] == b["path"] and b["start"] >= a["start"] and b["end"] <= a["end"] and len(spans[d]) >= 2:
            s, l = spans[d][-1]
            pe = spans[d][-2][0] + spans[d][-2][1]
            m["docs"][d]["tokens"][-1] = tok_raw(s - pe, len(texts[d]) - s + 3)
            return d, "dedup: unchecked, hit dropped"
    raise SystemExit("no contained chunk")


@case
def r11_past_text_by_one_last(m, spans, texts):  # the last token of a document ending at its text's end, +1
    for d in range(len(spans) - 1, -1, -1):
        if spans[d] and spans[d][-1][0] + spans[d][-1][1] == len(texts[d]):
            s, l = spans[d][-1]
            pe = spans[d][-2][0] + spans[d][-2][1] if len(spans[d]) > 1 else 0
            m["docs"][d]["tokens"][-1] = tok_raw(s - pe, l + 1)
            return d, "OffsetsPastText"
    raise SystemExit("no token at a text end")


@case
def r11_start_past_text(m, spans, texts):
    d = last_doc_with(spans)
    s, l = spans[d][-1]
    pe = spans[d][-2][0] + spans[d][-2][1] if len(spans[d]) > 1 else 0
    m["docs"][d]["tokens"][-1] = tok_raw(len(texts[d]) + 5 - pe, l)
    return d, "OffsetsPastText"


@case
def r12_leftover_byte(m, spans, texts):
    m["tail"] = b"\x00"
    return len(m["docs"]) - 1, "OffsetsTrailingData"


@case
def r12_leftover_token_in_last(m, spans, texts):  # a whole extra token after the last document's last
    d = len(m["docs"]) - 1
    m["tail"] = b"\x11"
    return d, "OffsetsTrailingData"


@case
def r12_inner_byte_after_first(m, spans, texts):  # fifth check: one 0x00 after the first table (read as table 2's count)
    m["docs"][1]["count"] = b"\x00" + m["docs"][1]["count"]
    return 1, "OffsetsCountMismatch"


@case
def r12_inner_byte_after_mid(m, spans, texts):  # fifth check: one 0x00 after a middle table with tokens
    k = next(i for i in range(len(spans) // 2, len(spans) - 1) if spans[i] and spans[i + 1])
    m["docs"][k + 1]["count"] = b"\x00" + m["docs"][k + 1]["count"]
    return k + 1, "OffsetsCountMismatch"


def build(src, out, name):
    if out.exists():
        raise SystemExit(str(out) + " exists")
    shutil.copytree(src, out)
    lexname, docname = manifest_names(out)
    b = (out / lexname).read_bytes()
    dec = v4dec.decode_lexical(b)
    docs = v5dec.decode_documents((out / docname).read_bytes(), True, check_checksum=False)
    texts = [r["text"].decode("utf-8") for r in docs["records"]]
    RECORDS[:] = docs["records"]
    spans = dec["offsets"]
    if name.startswith("v2_"):
        d, exp, s5 = V2CASES[name](spans, texts)
    else:
        assert dec["magic"] == b"HYBLEX04"
        m = model_v4(spans)
        assert encode_v4(m) == b[dec["section5"][0]:dec["section5"][0] + dec["section5"][1]], "model does not round-trip"
        d, exp = CASES[name](m, spans, texts)
        s5 = encode_v4(m)
    reseal(out, lexname, s5)
    toks = spans[d]
    words = ([texts[d][toks[-1][0]:toks[-1][0] + toks[-1][1]]] if name == "r11_dedup_contained" else []) + sorted({texts[d][s:s + l] for s, l in toks if l >= 2}, key=lambda w: -len(w))[:3]
    print(json.dumps({"case": name, "doc": d, "path": docs["records"][d]["path"].decode("utf-8", "replace"),
                      "expected": exp, "words": words}, ensure_ascii=False))


# v2-coded (HYBLEX03 under main) cases for the transcode
V2CASES = {}


def v2case(fn):
    V2CASES[fn.__name__] = fn
    return fn


@v2case
def v2_zero_length(spans, texts):
    d = last_doc_with(spans)
    sp = [list(t) for t in spans]
    sp[d] = list(sp[d])
    s, l = sp[d][-1]
    sp[d][-1] = (s, 0)
    return d, "ZeroLength(v2)", encode_v2(sp)


@v2case
def v2_past_text(spans, texts):
    for d in range(len(spans) - 1, -1, -1):
        if spans[d] and spans[d][-1][0] + spans[d][-1][1] == len(texts[d]):
            sp = [list(t) for t in spans]
            s, l = sp[d][-1]
            sp[d][-1] = (s, l + 1)
            return d, "past text", encode_v2(sp)


@v2case
def v2_count_plus1_last(spans, texts):
    d = last_doc_with(spans)
    return d, "count", encode_v2(spans, {d: len(spans[d]) + 1})


@v2case
def v2_leftover(spans, texts):
    return len(spans) - 1, "trailing", encode_v2(spans, tail=b"\x00")


@v2case
def v2_max_varints(spans, texts):  # largest legal v2 start delta: end exactly 2^32-1 on the last token
    d = last_doc_with(spans)
    sp = [list(t) for t in spans]
    s, l = sp[d][-1]
    sp[d][-1] = ((1 << 32) - 2, 1)
    return d, "past text (end 2^32-1)", encode_v2(sp)


if __name__ == "__main__":
    if sys.argv[1] == "list":
        print(" ".join(list(CASES) + list(V2CASES)))
    else:
        build(Path(sys.argv[2]), Path(sys.argv[3]), sys.argv[4])
