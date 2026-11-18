"""S6-T8 (the ruling after the Third Verdict): one plant per refusal site of the old-format table code, each removing
or loosening that site only, inside the named function's body. Bounds are loosened by one step (a sixth varint byte
let through, a fifth byte cut to 32 bits instead of refused, an end or a gap one past the bound, the section's end
read as a varint's end); equalities are removed. Each anchor must occur exactly once in its function's body.

    plants_sites.py COPY NAME     plant NAME into the source tree at COPY
    plants_sites.py --list        print the plant names, one per line
"""
import sys
from pathlib import Path

# Readers inserted before checkPairsTable for the per-call-site plants: readVarint with one bound loosened.
READERS = '''/// plant: readVarint with a sixth byte let through
fn readVarintSix(bytes: []const u8, offset: *usize) ?u32 {
    var value: u64 = 0;
    var shift: u6 = 0;
    var at = offset.*;
    while (true) {
        if (at >= bytes.len or shift > 35) return null;
        const byte = bytes[at];
        at += 1;
        value |= @as(u64, byte & 0x7F) << shift;
        if (byte & 0x80 == 0) break;
        shift += 7;
    }
    if (value > std.math.maxInt(u32)) return null;
    offset.* = at;
    return @intCast(value);
}

/// plant: readVarint with the value cut to 32 bits instead of refused
fn readVarintCut(bytes: []const u8, offset: *usize) ?u32 {
    var value: u64 = 0;
    var shift: u6 = 0;
    var at = offset.*;
    while (true) {
        if (at >= bytes.len or shift > 28) return null;
        const byte = bytes[at];
        at += 1;
        value |= @as(u64, byte & 0x7F) << shift;
        if (byte & 0x80 == 0) break;
        shift += 7;
    }
    offset.* = at;
    return @truncate(value);
}

/// plant: readVarint with the end of the bytes read as the varint's end
fn readVarintEnd(bytes: []const u8, offset: *usize) ?u32 {
    var value: u64 = 0;
    var shift: u6 = 0;
    var at = offset.*;
    while (true) {
        if (at >= bytes.len) break;
        if (shift > 28) return null;
        const byte = bytes[at];
        at += 1;
        value |= @as(u64, byte & 0x7F) << shift;
        if (byte & 0x80 == 0) break;
        shift += 7;
    }
    if (value > std.math.maxInt(u32)) return null;
    offset.* = at;
    return @intCast(value);
}

'''

CK = ("postings.zig", "pub fn checkPairsTable(")
TR = ("postings.zig", "pub fn transcodePairsTable(")
RV = ("postings.zig", "pub fn readVarint(")
OB = ("postings.zig", "pub fn oneByteTableEnd(")
SV = ("postings.zig", "fn skipOneVarint(")
WK = ("apply.zig", "fn offsetTableStarts(")
SK = ("apply.zig", "fn skipVarintsChecked(")

SHORT = "    if (bytes.len < at_start or bytes.len - at_start < 4) return error.InvalidPositions;\n"
COUNT = (") != count) return error.InvalidPositions;", ") != count and false) return error.InvalidPositions;")
ZERO = ("if (length == 0 or start + length > std.math.maxInt(u32))", "if (start + length > std.math.maxInt(u32))")
END = ("start + length > std.math.maxInt(u32)) return", "start + length > std.math.maxInt(u32) + 1) return")
LEFT = ("    if (at != end) return error.InvalidPositions;", "    if (at != end and false) return error.InvalidPositions;")

# name: (site, [(function, old, new, replace_all)], needs_readers)
P = {
    # checkPairsTable: the tables of the documents the first publish removes
    "ck-short-removed": ("ck: fewer than 4 bytes for the count", [(CK, SHORT, "", False)], False),
    "ck-count-removed": ("ck: count != document length", [(CK, *COUNT, False)], False),
    "ck-start-sixth-loose": ("ck: start delta, sixth byte", [(CK, "start += readVarint(", "start += readVarintSix(", False)], True),
    "ck-start-fifth-loose": ("ck: start delta, fifth byte above 0x0F", [(CK, "start += readVarint(", "start += readVarintCut(", False)], True),
    "ck-length-sixth-loose": ("ck: length, sixth byte", [(CK, "const length = readVarint(", "const length = readVarintSix(", False)], True),
    "ck-length-fifth-loose": ("ck: length, fifth byte above 0x0F", [(CK, "const length = readVarint(", "const length = readVarintCut(", False)], True),
    "ck-trunc-loose": ("ck: a varint cut off by the table's end", [(CK, "readVarint(", "readVarintEnd(", True)], True),
    "ck-zero-removed": ("ck: length == 0", [(CK, *ZERO, False)], False),
    "ck-end-loose": ("ck: start + length > 2^32 - 1", [(CK, *END, False)], False),
    "ck-leftover-removed": ("ck: at != end", [(CK, *LEFT, False)], False),
    # transcodePairsTable: the carried tables of the first publish
    "tr-short-removed": ("tr: fewer than 4 bytes for the count", [(TR, SHORT, "", False)], False),
    "tr-count-removed": ("tr: count != document length", [(TR, *COUNT, False)], False),
    "tr-start-sixth-loose": ("tr: start delta, sixth byte", [(TR, "delta = readVarint(", "delta = readVarintSix(", False)], True),
    "tr-start-fifth-loose": ("tr: start delta, fifth byte above 0x0F", [(TR, "delta = readVarint(", "delta = readVarintCut(", False)], True),
    "tr-length-sixth-loose": ("tr: length, sixth byte", [(TR, "length = readVarint(", "length = readVarintSix(", False)], True),
    "tr-length-fifth-loose": ("tr: length, fifth byte above 0x0F", [(TR, "length = readVarint(", "length = readVarintCut(", False)], True),
    "tr-trunc-loose": ("tr: a varint cut off by the table's end", [(TR, "readVarint(", "readVarintEnd(", True)], True),
    "tr-zero-removed": ("tr: length == 0", [(TR, *ZERO, False)], False),
    "tr-end-loose": ("tr: start + length > 2^32 - 1", [(TR, *END, False)], False),
    "tr-gap-loose": ("tr: zigzag gap > 2^32 - 1 (GapNotRepresentable)",
                     [(TR, "if (z > std.math.maxInt(u32)) return", "if (z > std.math.maxInt(u32) + 1) return", False)], False),
    "tr-leftover-removed": ("tr: at != end", [(TR, *LEFT, False)], False),
    # readVarint itself (shared by both, and by every other varint reader of the library)
    "rv-sixth-loose": ("readVarint: sixth byte", [(RV, "if (at >= bytes.len or shift > 28) return null;",
                                                  "if (at >= bytes.len or shift > 35) return null;", False)], False),
    "rv-fifth-loose": ("readVarint: fifth byte above 0x0F",
                       [(RV, "    if (value > std.math.maxInt(u32)) return null;\n    offset.* = at;\n    return @intCast(value);",
                         "    offset.* = at;\n    return @truncate(value);", False)], False),
    "rv-trunc-loose": ("readVarint: the bytes' end inside a varint",
                       [(RV, "        if (at >= bytes.len or shift > 28) return null;\n",
                         "        if (at >= bytes.len) break;\n        if (shift > 28) return null;\n", False)], False),
    # oneByteTableEnd and skipOneVarint: the walk of a v4 previous generation (a later update)
    "ob-count-loose": ("ob: section ends inside the count varint",
                       [(OB, "var at = skipOneVarint(bytes, at_start) orelse return null;",
                         "var at = skipOneVarint(bytes, at_start) orelse bytes.len;", False)], False),
    "ob-token-bound-loose": ("ob: section ends before a token byte",
                             [(OB, "        if (at >= bytes.len) return null;", "        if (at > bytes.len) return null;", False)], False),
    "ob-gap-escape-loose": ("ob: section ends inside a gap escape",
                            [(OB, "if (byte & 0x0F == offsets_escape) at = skipOneVarint(bytes, at) orelse return null;",
                              "if (byte & 0x0F == offsets_escape) at = skipOneVarint(bytes, at) orelse bytes.len;", False)], False),
    "ob-length-escape-loose": ("ob: section ends inside a length escape",
                               [(OB, "if (byte >> 4 == offsets_escape) at = skipOneVarint(bytes, at) orelse return null;",
                                 "if (byte >> 4 == offsets_escape) at = skipOneVarint(bytes, at) orelse bytes.len;", False)], False),
    "sv-end-loose": ("skipOneVarint: the bytes' end read as the varint's end",
                     [(SV, "    }\n    return null;\n}", "    }\n    return at;\n}", False)], False),
    # apply.offsetTableStarts and skipVarintsChecked: the walk of a v2 previous generation, before either function
    "wk-short-removed": ("walk: fewer than 4 bytes for a v2 count",
                         [(WK, "                if (offsets.len - at < 4) return error.InvalidLexicalSection;\n", "", False)], False),
    "wk-varints-loose": ("walk: section ends inside a v2 table's varints",
                         [(SK, "orelse error.InvalidLexicalSection;", "orelse bytes.len;", False)], False),
    "wk-leftover-removed": ("walk: bytes after the last table",
                            [(WK, "    if (at != offsets.len) return error.InvalidLexicalSection;",
                              "    if (at != offsets.len and false) return error.InvalidLexicalSection;", False)], False),
}


def body_span(text, header):
    start = text.index(header)
    assert text.count(header) == 1, header
    end = text.index("\n}\n", start) + 3
    return start, end


def plant(copy, name):
    src = copy / "zig" / "src"
    _, edits, needs_readers = P[name]
    for (file, header), old, new, replace_all in edits:
        path = src / file
        text = path.read_text()
        start, end = body_span(text, header)
        body = text[start:end]
        n = body.count(old)
        assert n == 1 or (replace_all and n > 1), (name, header, old, n)
        new_body = body.replace(old, new)
        assert new_body != body, name
        text = text[:start] + new_body + text[end:]
        if needs_readers:
            at = text.index(CK[1])
            text = text[:at] + READERS + text[at:]
        path.write_text(text)
    print("planted", name)


if __name__ == "__main__":
    if sys.argv[1:] == ["--list"]:
        print("\n".join(P))
    else:
        plant(Path(sys.argv[1]), sys.argv[2])
