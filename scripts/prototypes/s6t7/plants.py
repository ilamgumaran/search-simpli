"""Apply one S6-T7 Phase 2 plant to a copy's zig/src. Usage: plant.py <copy> <name>"""
import sys
from pathlib import Path
copy, name = Path(sys.argv[1]), sys.argv[2]
src = copy / "zig" / "src"
PLANTS = {
    # The writer records each nonzero gap one byte short.
    "gap-short": ("source_v2.zig",
        "            try appendVarint(allocator, &records, v);\n            if (v & 1 == 0) {",
        "            try appendVarint(allocator, &records, if (v & 1 == 0 and v >= 2) v - 2 else v);\n            if (v & 1 == 0) {"),
    # The reader's SHA-256 check skipped.
    "sha-skipped": ("source_v2.zig",
        "    if (!std.mem.eql(u8, &digest, &file.sha256)) return source.unavailablePub(allocator, source.sha256_mismatch_name);\n    return .{ .ok = out };",
        "    return .{ .ok = out };"),
    # An overlap emits its chunk's whole text again.
    "overlap-twice": ("source_v2.zig",
        "                @memcpy(out[n..][0 .. text.len - k], text[k..]);\n                n += text.len - k;",
        "                if (text.len > out.len - n) return null;\n                @memcpy(out[n..][0..text.len], text);\n                n += text.len;"),
    # Source record r bound to retained file r + 1 (the last to itself).
    "binding-off-by-one": ("source_v2.zig",
        "    for (retained, files) |rf, *file| {",
        "    for (retained, files, 0..) |rf_own, *file, r| {\n        const rf = if (r + 1 < retained.len) retained[r + 1] else rf_own;"),
    # A residual byte left after the last file's run accepted.
    "leftover-accepted": ("source_v2.zig",
        "    if (residual_at != section.text_length) return error.InvalidFileTable;\n",
        ""),
}
if name == "old-reader-removed":
    for file, old, new in (
        ("source.zig",
         "    const format: u16 = if (std.mem.eql(u8, found_magic, magic)) version else",
         "    const format: u16 = if (std.mem.eql(u8, found_magic, magic)) return error.BadMagic else"),
        ("segment.zig",
         "    if (actual_version == version_v5) return segment_v5.parseHeader(encoded);\n",
         "    if (actual_version == version_v5) return segment_v5.parseHeader(encoded);\n    if (actual_version == 4) return error.UnsupportedVersion;\n"),
    ):
        p = src / file; s = p.read_text(); assert s.count(old) == 1, (file, old); p.write_text(s.replace(old, new))
else:
    file, old, new = PLANTS[name]
    p = src / file; s = p.read_text(); assert s.count(old) == 1, (name, old); p.write_text(s.replace(old, new))
print("planted", name)
