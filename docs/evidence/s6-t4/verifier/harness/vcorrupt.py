#!/usr/bin/env python3
"""Verifier's corruptions of HYBLEX03 sections (S6-T4), each with the checksum
recomputed, written by an encoder built from the format document (lexdec.py's
decoder is its inverse).

    vcorrupt.py CONTENT_V3 FILENAME_V3 OUTDIR

Writes OUTDIR/<name>.hyblex and OUTDIR/cases.json ({name: {"from": which,
"expect": "refused"|"accepted", "why": ...}}). "accepted" cases are controls
(the unmodified re-encode, which must equal the input byte for byte).
"""
import json
import struct
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import lexdec  # noqa: E402


def varint(v):
    out = bytearray()
    while v >= 0x80:
        out.append((v & 0x7F) | 0x80)
        v >>= 7
    out.append(v)
    return bytes(out)


def common(a, b):
    n = 0
    while n < min(len(a), len(b), 255) and a[n] == b[n]:
        n += 1
    return n


def encode(d, terms=None, shared_override=None, lb_override=None, df_override=None,
           raw_lists=None, flags=None, counts=None, lengths_raw=None, positions=None, offsets=None):
    """terms: list of (term bytes, [(doc, tf)]) in the order to write."""
    if terms is None:
        terms = [(t, d["postings"][t]) for t in d["order"]]
    shared_override = shared_override or {}
    lb_override = lb_override or {}
    df_override = df_override or {}
    raw_lists = raw_lists or {}
    lengths = lengths_raw if lengths_raw is not None else b"".join(varint(x) for x in d["lengths"])
    dictionary = bytearray()
    coded = bytearray()
    prev = b""
    text = 0
    for i, (term, plist) in enumerate(terms):
        if i in raw_lists:
            lst = raw_lists[i]
        else:
            lst = bytearray()
            last = 0
            for k, (doc, tf) in enumerate(plist):
                gap = doc if k == 0 else doc - last
                last = doc
                lst += varint((gap << 1) | (1 if tf == 1 else 0))
                if tf != 1:
                    lst += varint(tf)
        sh = shared_override.get(i, common(prev, term))
        suffix = term[sh:]
        dictionary += varint(sh) + varint(len(suffix)) + suffix
        dictionary += varint(df_override.get(i, len(plist))) + varint(lb_override.get(i, len(lst)))
        coded += lst
        text += len(term)
        prev = term
    pos = d["positions"] if positions is None else positions
    off = d["offsets"] if offsets is None else offsets
    c = dict(doc_count=d["doc_count"], term_count=len(terms), posting_count=sum(len(p) for _, p in terms),
             text=text, avg_bits=d["avg_bits"])
    if counts:
        c.update(counts)
    fl = d["flags"] if flags is None else flags
    header = struct.pack("<8sHHIIQIQQQQQQ", b"HYBLEX03", 3, fl, c["doc_count"], c["term_count"], c["posting_count"],
                         c["avg_bits"], len(lengths), len(dictionary), len(coded), len(pos), len(off), c["text"])
    body = bytes(lengths) + bytes(dictionary) + bytes(coded) + pos + off
    checksum = lexdec.xxh3(header + body)
    return header + struct.pack("<Q", checksum) + body


def reseal(section: bytes) -> bytes:
    """Recompute the checksum of raw bytes (header 0-79, payload from 88)."""
    return section[:80] + struct.pack("<Q", lexdec.xxh3(section[:80] + section[88:])) + section[88:]


def main():
    content = Path(sys.argv[1]).read_bytes()
    fname = Path(sys.argv[2]).read_bytes()
    out = Path(sys.argv[3])
    out.mkdir(parents=True, exist_ok=True)
    cases = {}

    def put(name, data, frm, expect, why):
        (out / f"{name}.hyblex").write_bytes(data)
        cases[name] = {"from": frm, "expect": expect, "why": why}

    for label, src in (("content", content), ("filename", fname)):
        d = lexdec.decode(src)
        terms = [(t, d["postings"][t]) for t in d["order"]]
        n = len(terms)
        same = encode(d)
        assert same == src, f"{label}: my encoder does not reproduce the section"
        put(f"{label}-control-reencoded", same, label, "accepted", "unchanged re-encode (equals the input)")
        # 1. a varint that never terminates at the end of section 3 (last list's last byte gets the continuation bit)
        last_list_end = 88 + d["sizes"]["lengths"] + d["sizes"]["dictionary"] + d["sizes"]["postings"]
        b = bytearray(src)
        b[last_list_end - 1] |= 0x80
        put(f"{label}-unterminated-last-varint", reseal(bytes(b)), label, "refused",
            "the last byte of section 3 has its continuation bit set: the last varint runs off its list")
        # every byte of the last list set to 0xFF (a varint of more than five bytes, also unterminated)
        lb_last = len(encode(d, terms=[terms[-1]])) - 88 - len(b"".join(lexdec_varints(d))) if False else None
        # 1b. the last document-length varint unterminated
        b = bytearray(src)
        b[88 + d["sizes"]["lengths"] - 1] |= 0x80
        put(f"{label}-unterminated-last-length", reseal(bytes(b)), label, "refused",
            "the last byte of section 1 has its continuation bit set")
        # 2. a gap that overflows the document count (last posting of the last term at doc_count)
        t, p = terms[-1]
        bad = list(p)
        bad[-1] = (d["doc_count"], bad[-1][1])
        put(f"{label}-gap-past-count", encode(d, terms=terms[:-1] + [(t, bad)]), label, "refused",
            "the last posting's document equals the document count")
        # 2b. a gap so large that previous + gap would pass 2^32 (largest varint gap 2^31-1)
        if len(p) >= 2:
            raw = bytearray()
            last = 0
            for k, (doc, tf) in enumerate(p[:-1]):
                gap = doc if k == 0 else doc - last
                last = doc
                raw += varint((gap << 1) | (1 if tf == 1 else 0)) + (b"" if tf == 1 else varint(tf))
            raw += varint(((2 ** 31 - 1) << 1) | 1)
            put(f"{label}-gap-max", encode(d, raw_lists={n - 1: bytes(raw)}), label, "refused",
                "the last gap is 2^31-1 (document far past the count)")
        # 3. list bytes that disagree with the decoded length (sum kept): term 0 +1, term 1 -1
        put(f"{label}-listbytes-shifted", encode(d, lb_override={0: len(enc_list(p0 := terms[0][1])) + 1,
                                                                  1: len(enc_list(terms[1][1])) - 1}),
            label, "refused", "term 0's list bytes +1 and term 1's -1 (their sum unchanged)")
        # 3a. list bytes moved between two neighbours whose lists are longer than their dfs (sum kept)
        j = next((i for i in range(n - 1) if len(enc_list(terms[i + 1][1])) > len(terms[i + 1][1])), None)
        if j is not None:
            put(f"{label}-listbytes-moved", encode(d, lb_override={j: len(enc_list(terms[j][1])) + 1,
                                                                  j + 1: len(enc_list(terms[j + 1][1])) - 1}),
                label, "refused", f"term {j}'s list bytes +1 and term {j + 1}'s -1 (both still >= df; sum unchanged)")
        # 3b. the last term's list bytes one short, a padding byte left over at the end of section 3
        raw_last = enc_list(terms[-1][1]) + b"\x01"
        put(f"{label}-listbytes-last-short", encode(d, raw_lists={n - 1: raw_last},
                                                      lb_override={n - 1: len(raw_last) - 1}),
            label, "refused", "the last term's list bytes one short of section 3's end (a byte left over)")
        # 3c. the last term's list bytes match but a trailing extra posting byte exists in its list
        put(f"{label}-listbytes-last-extra", encode(d, raw_lists={n - 1: raw_last}), label, "refused",
            "the last list holds a byte after its df postings (list bytes counts it)")
        # 4. a df of zero (a new term with df 0 and no postings)
        newt = terms[0][0] + b"\x00zz"
        z = sorted(terms + [(newt, [])], key=lambda x: x[0])
        put(f"{label}-df-zero", encode(d, terms=z), label, "refused", "a term with df 0 and list bytes 0")
        # 4b. a df of zero on an existing term, its list kept (df sum then short: posting count adjusted)
        put(f"{label}-df-zero-existing", encode(d, df_override={1: 0},
                                                counts={"posting_count": d["posting_count"] - len(terms[1][1])}),
            label, "refused", "term 1's df written as 0, posting count reduced to match the dfs")
        # 5. a dictionary not in sorted order after front-decoding (terms 1 and 2 swapped, shared recomputed)
        sw = list(terms)
        sw[1], sw[2] = sw[2], sw[1]
        put(f"{label}-unsorted-swap", encode(d, terms=sw), label, "refused", "terms 1 and 2 swapped")
        # 5b. a duplicate term (term 2 equal to term 1, df/postings of term 2)
        dup = list(terms)
        dup[2] = (dup[1][0], dup[2][1])
        put(f"{label}-duplicate", encode(d, terms=dup), label, "refused", "term 2 written equal to term 1")
        # 5c. shared shorter than the true common prefix (non-canonical), order still ascending
        idx = next((i for i in range(1, n) if common(terms[i - 1][0], terms[i][0]) >= 1), None)
        if idx is not None:
            put(f"{label}-shared-short", encode(d, shared_override={idx: common(terms[idx - 1][0], terms[idx][0]) - 1}),
                label, "refused", "a shared length one shorter than the true common prefix")
        # 6. shared longer than the previous term
        idx2 = next((i for i in range(1, n) if len(terms[i][0]) > len(terms[i - 1][0]) + 1), None)
        if idx2 is not None:
            put(f"{label}-shared-past-previous", encode(d, shared_override={idx2: len(terms[idx2 - 1][0]) + 1}),
                label, "refused", "a shared length one above the previous term's length")
        # header term text a byte short / long
        put(f"{label}-termtext-short", encode(d, counts={"text": sum(len(t) for t, _ in terms) - 1}), label, "refused",
            "header term-text bytes one short")
        put(f"{label}-termtext-long", encode(d, counts={"text": sum(len(t) for t, _ in terms) + 1}), label, "refused",
            "header term-text bytes one long")
        # tf of 1 stored explicitly (low bit 0, tf varint 1)
        t0, p0 = terms[0]
        raw = bytearray()
        last = 0
        for k, (doc, tf) in enumerate(p0):
            gap = doc if k == 0 else doc - last
            last = doc
            raw += varint(gap << 1) + varint(tf)
        put(f"{label}-tf1-explicit", encode(d, raw_lists={0: bytes(raw)}), label, "refused",
            "term 0's postings each with the low bit clear and an explicit tf (some tf 1)")
        # flags: positions bit flipped
        put(f"{label}-flag1-flipped", encode(d, flags=d["flags"] ^ 2, positions=b"" if d["flags"] & 2 else None,
                                             offsets=b"" if d["flags"] & 2 else None),
            label, "refused", "flags bit 1 flipped (positions sections dropped when it was set)")
        # a non-minimal (overlong) varint for a document length: 1 -> 0x81 0x00 (documented as allowed? recorded)
        if d["lengths"]:
            lr = varint(d["lengths"][0] | 0)  # canonical
            over = bytes([(d["lengths"][0] & 0x7F) | 0x80, d["lengths"][0] >> 7]) if d["lengths"][0] < 0x4000 and len(lr) == 1 else None
            if over:
                rest = b"".join(varint(x) for x in d["lengths"][1:])
                put(f"{label}-overlong-length-varint", encode(d, lengths_raw=over + rest), label, "either",
                    "document 0's length as a two-byte (non-minimal) varint: not ruled out by the document")

    # synthetic long terms: the 255 cap
    base = lexdec.decode(fname)
    one = [(0, 1)]
    a300 = b"a" * 300
    long_terms = [(a300 + b"b", one), (a300 + b"c", one)]
    syn = dict(base)
    syn.update(doc_count=base["doc_count"], lengths=base["lengths"], flags=1, positions=b"", offsets=b"")
    put("long-control", encode(syn, terms=long_terms), "synthetic", "accepted",
        "two terms sharing 300 bytes, shared written as the cap 255")
    put("long-shared-256", encode(syn, terms=long_terms, shared_override={1: 256}), "synthetic", "refused",
        "shared 256 (above the cap), previous term 301 bytes")
    put("long-descending-at-cap", encode(syn, terms=list(reversed(long_terms))), "synthetic", "refused",
        "two terms sharing 300 bytes in descending order, shared at the cap 255")
    put("long-equal-at-cap", encode(syn, terms=[long_terms[0], long_terms[0]]), "synthetic", "refused",
        "two equal 301-byte terms, shared at the cap 255")
    put("long-shared-254", encode(syn, terms=long_terms, shared_override={1: 254}), "synthetic", "refused",
        "shared 254 where the common prefix is 300 (non-canonical, suffix byte equals the previous)")
    (out / "cases.json").write_text(json.dumps(cases, indent=1))
    print(len(cases), "cases")


def enc_list(plist):
    lst = bytearray()
    last = 0
    for k, (doc, tf) in enumerate(plist):
        gap = doc if k == 0 else doc - last
        last = doc
        lst += varint((gap << 1) | (1 if tf == 1 else 0))
        if tf != 1:
            lst += varint(tf)
    return bytes(lst)


def lexdec_varints(d):
    return []


if __name__ == "__main__":
    main()
