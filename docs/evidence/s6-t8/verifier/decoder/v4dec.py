"""S6-T8 verifier: an independent decoder of the lexical section's highlight offsets (section 5),
written from docs/lexical-segment-format-v4.md alone (and v3/v2 for the header and v2's section 5).
Not the builder's code; written before reading zig/src/postings.zig or scripts/prototypes/.

decode_lexical(buf) -> {"magic", "ndocs", "lengths", "offsets": [[(start, length), ...] per doc]}
Every refusal raises Refused(rule_error_name, detail).
"""
import re
import struct


class Refused(Exception):
    def __init__(self, name, detail=""):
        super().__init__(name + (": " + detail if detail else ""))
        self.name = name


U32 = 1 << 32


def varint(buf, p, end, trunc, over):
    """unsigned LEB128, at most 5 bytes, value < 2^32; a 5th byte above 0x0F is damage."""
    v = 0
    for i in range(5):
        if p >= end:
            raise Refused(trunc, "varint at %d" % p)
        b = buf[p]
        p += 1
        if i == 4 and b > 0x0F:
            raise Refused(over, "fifth byte %#x" % b)
        v |= (b & 0x7F) << (7 * i)
        if not b & 0x80:
            return v, p
    raise Refused(over, "sixth byte")


def unzigzag(z):
    return z // 2 if z % 2 == 0 else -((z + 1) // 2)


def header(buf):
    magic = bytes(buf[0:8])
    if magic == b"HYBLEX02":
        version, flags, ndocs, nterms, npost, avg = struct.unpack_from("<HHIIQI", buf, 8)
        lens = struct.unpack_from("<5Q", buf, 32)
        return magic, flags, ndocs, lens, 80
    if magic in (b"HYBLEX03", b"HYBLEX04"):
        version, flags, ndocs, nterms, npost, avg = struct.unpack_from("<HHIIQI", buf, 8)
        lens = struct.unpack_from("<5Q", buf, 32)
        if magic == b"HYBLEX04":
            if version != 4:
                raise Refused("UnsupportedVersion", str(version))
            if flags != 0x0003:
                raise Refused("UnsupportedFlags", hex(flags))
        return magic, flags, ndocs, lens, 88
    raise Refused("BadMagic", repr(magic))


def doc_lengths(buf, magic, ndocs, start, length):
    out = []
    if magic == b"HYBLEX02":  # v1 layout: u32 per document
        for i in range(ndocs):
            out.append(struct.unpack_from("<I", buf, start + 4 * i)[0])
        return out
    p, end = start, start + length
    for _ in range(ndocs):
        v, p = varint(buf, p, end, "Truncated", "VarintOverflow")
        out.append(v)
    if p != end:
        raise Refused("TrailingData", "section 1")
    return out


def decode_v4_offsets(buf, p, end, lengths, texts_cp=None):
    """section 5 of HYBLEX04, every rule 1..12 in the document's order (11 only when texts_cp given)."""
    docs = []
    for d, dl in enumerate(lengths):
        count, p = varint(buf, p, end, "OffsetsTruncated", "OffsetsVarintOverflow")  # rule 1
        if count != dl:
            raise Refused("OffsetsCountMismatch", "doc %d: %d != %d" % (d, count, dl))  # rule 2
        prev_end = 0
        start = 0
        toks = []
        for t in range(count):
            if p >= end:
                raise Refused("OffsetsTruncated", "doc %d token %d byte" % (d, t))  # rule 3
            byte = buf[p]
            p += 1
            G = byte & 0x0F
            L = byte >> 4
            if G == 15:
                G, p = varint(buf, p, end, "OffsetsTruncated", "OffsetsVarintOverflow")  # rules 4, 5
                if G < 15:
                    raise Refused("OffsetsNonCanonicalEscape", "doc %d token %d gap %d" % (d, t, G))  # rule 6
            if L == 15:
                L, p = varint(buf, p, end, "OffsetsTruncated", "OffsetsVarintOverflow")
                if L < 15:
                    raise Refused("OffsetsNonCanonicalEscape", "doc %d token %d length %d" % (d, t, L))
            if L < 1:
                raise Refused("OffsetsZeroLength", "doc %d token %d" % (d, t))  # rule 7
            prev_start = start
            start = prev_end + unzigzag(G)
            if start < 0:
                raise Refused("OffsetsStartBeforeChunk", "doc %d token %d" % (d, t))  # rule 8
            if start < prev_start:
                raise Refused("OffsetsStartDecreases", "doc %d token %d" % (d, t))  # rule 9
            e = start + L
            if e > U32 - 1:
                raise Refused("OffsetsEndOverflow", "doc %d token %d" % (d, t))  # rule 10
            if texts_cp is not None and e > texts_cp[d]:
                raise Refused("OffsetsPastText", "doc %d token %d end %d > %d" % (d, t, e, texts_cp[d]))  # 11
            prev_end = e
            toks.append((start, L))
        docs.append(toks)
    if p != end:
        raise Refused("OffsetsTrailingData", "%d bytes" % (end - p))  # rule 12
    return docs


def decode_v2_offsets(buf, p, end, lengths, texts_cp=None):
    """v2's section 5: u32 count, then per token varint start delta (from previous start) and varint length."""
    docs = []
    for d, dl in enumerate(lengths):
        if p + 4 > end:
            raise Refused("Truncated", "v2 count")
        count = struct.unpack_from("<I", buf, p)[0]
        p += 4
        if count != dl:
            raise Refused("CountMismatch", "doc %d" % d)
        start = 0
        toks = []
        for t in range(count):
            delta, p = varint(buf, p, end, "Truncated", "VarintOverflow")
            ln, p = varint(buf, p, end, "Truncated", "VarintOverflow")
            start += delta
            if ln < 1:
                raise Refused("ZeroLength")
            if start + ln > U32 - 1:
                raise Refused("EndOverflow")
            if texts_cp is not None and start + ln > texts_cp[d]:
                raise Refused("PastText", "doc %d" % d)
            toks.append((start, ln))
        docs.append(toks)
    if p != end:
        raise Refused("TrailingData", "v2 section 5")
    return docs


def decode_lexical(buf, texts_cp=None):
    magic, flags, ndocs, lens, hl = header(buf)
    if hl + sum(lens) + 8 * 0 != len(buf):
        raise Refused("SizeMismatch", "%d vs %d" % (hl + sum(lens), len(buf)))
    s1 = hl
    s5 = hl + lens[0] + lens[1] + lens[2] + lens[3]
    lengths = doc_lengths(buf, magic, ndocs, s1, lens[0])
    if magic == b"HYBLEX04":
        offs = decode_v4_offsets(buf, s5, s5 + lens[4], lengths, texts_cp)
    elif magic == b"HYBLEX03" and flags & 2 or magic == b"HYBLEX02":
        offs = decode_v2_offsets(buf, s5, s5 + lens[4], lengths, texts_cp)
    else:
        offs = None
    return {"magic": magic, "flags": flags, "ndocs": ndocs, "lengths": lengths, "offsets": offs,
            "section5": (s5, lens[4]), "sizes": lens, "header_len": hl}


def content_lexical_name(manifest_bytes):
    m = re.search(rb"(?<![A-Za-z-])lexical-\d+\.hyblex", manifest_bytes)
    return m.group(0).decode() if m else None
