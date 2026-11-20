"""S6-T9 verifier: a control build = main's tree plus one never-run function of NBLOCKS inert loops, placed in one of
five spots and called at the top of its host function under a branch never true at run time (an input of 2^50 bytes
or more). Written by the verifier (after the S6-T8 verifier's mkplaced.py); not the builder's script.
  mkctl.py SRC_ZIG_DIR PLACE NBLOCKS
PLACE:
  q  postings.zig, before lookupExact; called from lookupExact (every content query and find: the hot query path)
  o  segment.zig, before inspect; called from inspect (every open: the documents header; the head changed inspect)
  f  filename_field.zig, before decodeInspected; called from it (the first file-name or both query: where the head
     derives ids and stems)
  m  manifest.zig, before decodeV2; called from decodeV2 (every open and every write; the head added bits 8 and 9)
  s  incremental_state.zig, before decodeBinary; called from it (every writer's state decode: the planning path)
"""
import sys
from pathlib import Path

src, place, n = Path(sys.argv[1]), sys.argv[2], int(sys.argv[3])


def block(i):
    a, step, mul, sh, c, m2 = 1 + i % 5, 1 + i % 3, 2654435761 + 2 * i, i % 7, (i * 37) % 251, 3 + 2 * i
    return f"""    {{
        var acc{i}: u64 = {1000 + i};
        var j{i}: usize = at_start;
        while (j{i} + {a} < bytes.len) : (j{i} += {step}) {{
            acc{i} = (acc{i} *% {mul}) ^ ((@as(u64, bytes[j{i}]) << {sh}) +% bytes[j{i} + {a}]);
            if (bytes[j{i}] == {c}) acc{i} +%= @as(u64, j{i}) *% {m2};
        }}
        if (acc{i} == {7000003 + i}) return @intCast(acc{i} % (bytes.len + 1));
        total +%= @intCast(acc{i} & 0xff);
    }}
"""


fn = ("/// verifier control (S6-T9): never called at run time.\n"
      "pub fn verifierControl(bytes: []const u8, at_start: usize) usize {\n    var total: usize = at_start;\n"
      + "".join(block(i) for i in range(n)) + "    return total;\n}\n\n")
never = "(@as(usize, 1) << 50)"
spots = {
    "q": ("postings.zig", "pub fn lookupExact(index: Index, term: []const u8) ?usize {\n",
          f"    if (term.len >= {never} and verifierControl(term, index.terms.len) == 7) return null;\n"),
    "o": ("segment.zig", "pub fn inspect(encoded: []const u8) DecodeError!Header {\n",
          f"    if (encoded.len >= {never} and verifierControl(encoded, 0) == 7) return error.Truncated;\n"),
    "f": ("filename_field.zig",
          "fn decodeInspected(allocator: std.mem.Allocator, body_docs: []const hybrid.Document, body_index: postings.Index, catalog_encoded: []const u8, ch: segment.Header, lexical_encoded: []const u8, lh: lexical_segment.Header) !Decoded {\n",
          f"    if (catalog_encoded.len >= {never} and verifierControl(catalog_encoded, lexical_encoded.len) == 7) return error.FilenameCatalogMismatch;\n"),
    "m": ("manifest.zig", "fn decodeV2(encoded: []const u8) ManifestError!Manifest {\n",
          f"    if (encoded.len >= {never} and verifierControl(encoded, 0) == 7) return error.UnsupportedVersion;\n"),
    "s": ("incremental_state.zig", "pub fn decodeBinary(allocator: std.mem.Allocator, bytes: []const u8) LoadError!State {\n",
          f"    if (bytes.len >= {never} and verifierControl(bytes, 0) == 7) return error.InvalidState;\n"),
}
name, anchor, call = spots[place]
p = src / "src" / name
s = p.read_text()
assert s.count(anchor) == 1, f"anchor in {name}"
# the doc comment above the host function stays attached to it: put the control before that comment block
i = s.index(anchor)
j = i
lines_before = s[:i].split("\n")
k = len(lines_before) - 1  # the (empty) piece after the last newline
while k > 0 and lines_before[k - 1].lstrip().startswith("///"):
    k -= 1
insert_at = len("\n".join(lines_before[:k])) + (1 if k > 0 else 0)
s = s[:insert_at] + fn + s[insert_at:]
s = s.replace(anchor, anchor + call)
p.write_text(s)
print(f"control {place}: {n} blocks in {name}")
