"""S6-T8 verifier (third check): plants on c15fe2a (bb92ae5's F3 tests). The three missed plants of the Second Verdict
(plants2.py's definitions, unchanged), four new ones on the removed-table check, and one broken assertion in a new
test. Each anchor must occur once. plants3.py COPY NAME"""
import sys, importlib.util
from pathlib import Path
here = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("plants2defs", here / "plants2.py")
copy, name = Path(sys.argv[1]), sys.argv[2]
src = copy / "zig" / "src"
# plants2.py plants on import with its own argv; read its table without running it
text = (here / "plants2.py").read_text().split("\nfor f, old, new in P[name]:")[0]
ns = {}
exec(compile(text.replace("copy, name = Path(sys.argv[1]), sys.argv[2]", "copy, name = None, None").replace('src = copy / "zig" / "src"', "src = None"), "plants2.py", "exec"), ns)
P = {k: ns["P"][k] for k in ("ck-count-removed", "ck-u32-end-removed", "drop-skip-last", "ck-zero-removed")}
DROP = ns["DROP"]
CK_HEAD = "pub fn checkPairsTable(offsets: []const u8, at_start: usize, end: usize, count: u32) error{InvalidPositions}!void {\n"
LOOSE = ("/// verifier plant: readVarint with the fifth-byte bound loosened (the value cut to 32 bits, not refused)\n"
         "fn readVarintLoose(bytes: []const u8, offset: *usize) ?u32 {\n    var value: u64 = 0;\n    var shift: u6 = 0;\n"
         "    var at = offset.*;\n    while (true) {\n        if (at >= bytes.len or shift > 28) return null;\n"
         "        const byte = bytes[at];\n        at += 1;\n        value |= @as(u64, byte & 0x7F) << shift;\n"
         "        if (byte & 0x80 == 0) break;\n        shift += 7;\n    }\n    offset.* = at;\n    return @truncate(value);\n}\n\n")
CK_START = "        start += readVarint(bytes, &at) orelse return error.InvalidPositions;\n        const length = readVarint(bytes, &at) orelse return error.InvalidPositions;\n        if (length == 0 or start + length > std.math.maxInt(u32)) return error.InvalidPositions;\n    }\n    if (at != end) return error.InvalidPositions;\n}\n"
GEN = "    try std.testing.expectEqual(@as(u64, 1), metadata.generation);\n    try std.testing.expect(!metadata.lexical_v4);\n}\n\nfn expectDroppedDamageRefusedEverywhere"
P.update({
    # the removed-table check skipped for the section's FIRST table
    "drop-skip-first": [("apply.zig", DROP, DROP.replace("if (!carried.isSet(old))", "if (!carried.isSet(old) and old != 0)"))],
    # the fifth-byte bound loosened in checkPairsTable only, on the length read
    "ck-fifth-loose-length": [("postings.zig", CK_HEAD, LOOSE + CK_HEAD),
                              ("postings.zig", CK_START, CK_START.replace("const length = readVarint(", "const length = readVarintLoose("))],
    # the same, on the start-delta read only
    "ck-fifth-loose-start": [("postings.zig", CK_HEAD, LOOSE + CK_HEAD),
                             ("postings.zig", CK_START, CK_START.replace("start += readVarint(", "start += readVarintLoose("))],
    # one assertion of the new tests broken: generation 1 expected as 2
    "test-gen-broken": [("compat_s6t8_test.zig", GEN, GEN.replace("@as(u64, 1), metadata.generation", "@as(u64, 2), metadata.generation"))],
})
for f, old, new in P[name]:
    p = src / f
    s = p.read_text()
    assert s.count(old) == 1, (name, f, s.count(old))
    assert old != new, name
    p.write_text(s.replace(old, new))
print("planted", name)
