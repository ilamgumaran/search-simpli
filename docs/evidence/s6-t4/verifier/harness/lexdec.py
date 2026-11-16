#!/usr/bin/env python3
"""Verifier's decoder for lexical sections HYBLEX01/02/03, written from the
format documents only (lexical-segment-format-v1.md, -v2.md, -v3.md), not from
the Zig code. Checksums are checked through the xxh3 helper (a Zig program
using std.hash.XxHash3, seed 0) when XXH3 is flagged.

    lexdec.py dump SECTION            -> summary JSON
    lexdec.py compare A B             -> compare decoded content of two sections
    lexdec.py validate SECTION        -> exit 0 if every v3 rule holds, 3 if not
"""
import json
import struct
import subprocess
import sys
import os

import ctypes
_X = ctypes.CDLL(os.path.join(os.path.dirname(os.path.abspath(__file__)), "libxxh3lib.dylib"))
_X.vxxh3.argtypes = [ctypes.c_char_p, ctypes.c_size_t]
_X.vxxh3.restype = ctypes.c_uint64


class Damage(Exception):
    pass


def xxh3(data: bytes) -> int:
    return _X.vxxh3(data, len(data))


def fnv1a64(data: bytes) -> int:
    h = 0xcbf29ce484222325
    for b in data:
        h ^= b
        h = (h * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF
    return h


def read_varint(buf: bytes, pos: int, end: int):
    value = 0
    shift = 0
    for i in range(5):
        if pos >= end:
            raise Damage("varint runs past its section")
        b = buf[pos]
        pos += 1
        if i == 4 and b > 0x0F:
            raise Damage("fifth varint byte above 0x0F")
        value |= (b & 0x7F) << shift
        if b & 0x80 == 0:
            return value, pos
        shift += 7
    raise Damage("varint has a sixth byte")


def decode(data: bytes, check_sum=True):
    magic = data[:8]
    if magic == b"HYBLEX01":
        return decode_v1(data, check_sum)
    if magic == b"HYBLEX02":
        return decode_v2(data, check_sum)
    if magic == b"HYBLEX03":
        return decode_v3(data, check_sum)
    raise Damage("unknown magic %r" % magic)


def _fixed_sections_v1(data, doc_count, term_count, posting_count, base, len_bytes, dict_bytes, post_bytes):
    p = base
    if len_bytes != doc_count * 4:
        raise Damage("v1 lengths bytes")
    lengths = list(struct.unpack_from("<%dI" % doc_count, data, p))
    p += len_bytes
    dend = p + dict_bytes
    terms = []
    while p < dend:
        tlen, df, start, count = struct.unpack_from("<IIQQ", data, p)
        p += 24
        term = data[p:p + tlen]
        p += tlen
        if tlen == 0 or df != count:
            raise Damage("v1 term record")
        terms.append((term, df, start, count))
    if p != dend or len(terms) != term_count:
        raise Damage("v1 dictionary")
    if post_bytes != posting_count * 8:
        raise Damage("v1 postings bytes")
    raw = list(struct.iter_unpack("<II", data[p:p + post_bytes]))
    p += post_bytes
    postings = {}
    order = []
    for term, df, start, count in terms:
        lst = raw[start:start + count]
        if len(lst) != count:
            raise Damage("range")
        prev = -1
        for d, tf in lst:
            if d <= prev or d >= doc_count or tf == 0:
                raise Damage("v1 posting")
            prev = d
        if term in postings:
            raise Damage("duplicate term")
        postings[term] = [tuple(x) for x in lst]
        order.append(term)
    return lengths, order, postings, p


def decode_v1(data, check_sum):
    (magic, version, flags, doc_count, term_count, posting_count, avg_bits,
     len_bytes, dict_bytes, post_bytes, checksum) = struct.unpack_from("<8sHHIIQIQQQQ", data, 0)
    if version != 1 or flags != 0:
        raise Damage("v1 version/flags")
    if 64 + len_bytes + dict_bytes + post_bytes != len(data):
        raise Damage("v1 size")
    if check_sum and fnv1a64(data[:56] + data[64:]) != checksum:
        raise Damage("v1 checksum")
    lengths, order, postings, p = _fixed_sections_v1(data, doc_count, term_count, posting_count, 64,
                                                      len_bytes, dict_bytes, post_bytes)
    return dict(magic="HYBLEX01", flags=flags, doc_count=doc_count, term_count=term_count,
                posting_count=posting_count, avg_bits=avg_bits, lengths=lengths, order=order,
                postings=postings, positions=b"", offsets=b"",
                sizes=dict(header=64, lengths=len_bytes, dictionary=dict_bytes, postings=post_bytes))


def decode_v2(data, check_sum):
    (magic, version, flags, doc_count, term_count, posting_count, avg_bits,
     len_bytes, dict_bytes, post_bytes, pos_bytes, off_bytes, checksum) = struct.unpack_from(
        "<8sHHIIQIQQQQQQ", data, 0)
    if version != 2 or flags & ~1:
        raise Damage("v2 version/flags")
    if 80 + len_bytes + dict_bytes + post_bytes + pos_bytes + off_bytes != len(data):
        raise Damage("v2 size")
    covered = data[:72] + data[80:]
    if check_sum:
        got = xxh3(covered) if flags & 1 else fnv1a64(covered)
        if got != checksum:
            raise Damage("v2 checksum")
    lengths, order, postings, p = _fixed_sections_v1(data, doc_count, term_count, posting_count, 80,
                                                      len_bytes, dict_bytes, post_bytes)
    if order != sorted(order) or len(set(order)) != len(order):
        raise Damage("v2 unsorted")
    positions = data[p:p + pos_bytes]
    p += pos_bytes
    offsets = data[p:p + off_bytes]
    return dict(magic="HYBLEX02", flags=flags, doc_count=doc_count, term_count=term_count,
                posting_count=posting_count, avg_bits=avg_bits, lengths=lengths, order=order,
                postings=postings, positions=positions, offsets=offsets,
                sizes=dict(header=80, lengths=len_bytes, dictionary=dict_bytes, postings=post_bytes,
                           positions=pos_bytes, offsets=off_bytes))


def decode_v3(data, check_sum):
    if len(data) < 88:
        raise Damage("Truncated header")
    (magic, version, flags, doc_count, term_count, posting_count, avg_bits,
     len_bytes, dict_bytes, post_bytes, pos_bytes, off_bytes, text_bytes, checksum) = struct.unpack_from(
        "<8sHHIIQIQQQQQQQ", data, 0)
    # 1. header
    if version != 3:
        raise Damage("version")
    if not flags & 1 or flags & ~3:
        raise Damage("flags")
    total = 88 + len_bytes + dict_bytes + post_bytes + pos_bytes + off_bytes
    if total != len(data):
        raise Damage("Truncated" if total > len(data) else "TrailingData")
    # 2. checksum
    if check_sum and xxh3(data[:80] + data[88:]) != checksum:
        raise Damage("checksum")
    # 3. bounds
    avg = struct.unpack("<f", struct.pack("<I", avg_bits))[0]
    if not (avg == avg and avg != float("inf") and avg >= 0):
        raise Damage("average length")
    if doc_count >= 2 ** 31:
        raise Damage("document count")
    if not (doc_count <= len_bytes <= 5 * doc_count):
        raise Damage("length bytes bound")
    if post_bytes < posting_count:
        raise Damage("postings bytes bound")
    if dict_bytes < 5 * term_count:
        raise Damage("dictionary bytes bound")
    if text_bytes < term_count:
        raise Damage("term text bound")
    if posting_count < term_count:
        raise Damage("posting count bound")
    if text_bytes > 255 * term_count + dict_bytes:
        raise Damage("term text above cap bound")
    has_pos = bool(flags & 2)
    if not has_pos and (pos_bytes or off_bytes):
        raise Damage("positions without flag")
    # 4. section 1
    p = 88
    end = p + len_bytes
    lengths = []
    for _ in range(doc_count):
        v, p = read_varint(data, p, end)
        lengths.append(v)
    if p != end:
        raise Damage("length bytes left over")
    # 5. section 2
    dend = p + dict_bytes
    order = []
    meta = []
    prev = b""
    text_total = 0
    df_sum = 0
    lb_sum = 0
    for i in range(term_count):
        shared, p = read_varint(data, p, dend)
        slen, p = read_varint(data, p, dend)
        if i == 0 and shared != 0:
            raise Damage("first shared nonzero")
        if shared > 255 or shared > len(prev):
            raise Damage("shared too long")
        if slen < 1:
            raise Damage("empty suffix")
        if p + slen > dend:
            raise Damage("suffix past dictionary")
        suffix = data[p:p + slen]
        p += slen
        term = prev[:shared] + suffix
        if i > 0:
            if shared < len(prev) and shared < 255:
                if not suffix[0] > prev[shared]:
                    raise Damage("order/canonical")
            # always: strictly ascending
            if not term > prev:
                raise Damage("not ascending")
        text_total += len(term)
        if text_total > text_bytes:
            raise Damage("term text passes header")
        df, p = read_varint(data, p, dend)
        lb, p = read_varint(data, p, dend)
        if not (1 <= df <= doc_count):
            raise Damage("df")
        if lb < df:
            raise Damage("list bytes < df")
        df_sum += df
        lb_sum += lb
        order.append(term)
        meta.append((df, lb))
        prev = term
    if p != dend:
        raise Damage("dictionary bytes left over")
    if text_total != text_bytes:
        raise Damage("term text != header")
    if df_sum != posting_count:
        raise Damage("df sum")
    if lb_sum != post_bytes:
        raise Damage("list bytes sum")
    # 6. section 3
    postings = {}
    for term, (df, lb) in zip(order, meta):
        lend = p + lb
        lst = []
        doc = -1
        for k in range(df):
            v, p = read_varint(data, p, lend)
            gap = v >> 1
            if k == 0:
                d = gap
            else:
                if gap < 1:
                    raise Damage("zero gap")
                d = doc + gap
            if d >= doc_count:
                raise Damage("document past count")
            if v & 1:
                tf = 1
            else:
                tf, p = read_varint(data, p, lend)
                if tf < 2:
                    raise Damage("stored tf < 2")
            lst.append((d, tf))
            doc = d
        if p != lend:
            raise Damage("list bytes disagree")
        postings[term] = lst
    positions = data[p:p + pos_bytes]
    p += pos_bytes
    offsets = data[p:p + off_bytes]
    p += off_bytes
    return dict(magic="HYBLEX03", flags=flags, doc_count=doc_count, term_count=term_count,
                posting_count=posting_count, avg_bits=avg_bits, lengths=lengths, order=order,
                postings=postings, positions=positions, offsets=offsets,
                sizes=dict(header=88, lengths=len_bytes, dictionary=dict_bytes, postings=post_bytes,
                           positions=pos_bytes, offsets=off_bytes, term_text=text_bytes))


def compare(a, b):
    diffs = []
    for k in ("doc_count", "term_count", "posting_count", "avg_bits", "lengths", "positions", "offsets"):
        if a[k] != b[k]:
            diffs.append(k)
    if set(a["order"]) != set(b["order"]):
        diffs.append("term set")
    for t in a["order"]:
        if a["postings"].get(t) != b["postings"].get(t):
            diffs.append("postings of %r" % t)
            break
    return diffs


def main():
    cmd = sys.argv[1]
    if cmd == "dump":
        d = decode(open(sys.argv[2], "rb").read())
        print(json.dumps(dict(magic=d["magic"], flags=d["flags"], doc_count=d["doc_count"],
                              term_count=d["term_count"], posting_count=d["posting_count"],
                              sizes=d["sizes"])))
    elif cmd == "compare":
        a = decode(open(sys.argv[2], "rb").read())
        b = decode(open(sys.argv[3], "rb").read())
        diffs = compare(a, b)
        print(json.dumps(dict(a=a["magic"], b=b["magic"], terms=a["term_count"], postings=a["posting_count"],
                              docs=a["doc_count"], diffs=diffs)))
        sys.exit(1 if diffs else 0)
    elif cmd == "validate":
        try:
            decode(open(sys.argv[2], "rb").read())
        except Damage as e:
            print("refused:", e)
            sys.exit(3)
        print("accepted")


if __name__ == "__main__":
    main()
