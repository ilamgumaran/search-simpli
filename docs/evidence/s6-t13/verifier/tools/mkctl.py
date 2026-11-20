"""S6-T13 verifier: a placement control = main's tree plus never-run code (a function called under a branch never
true at run time: an input of 2^50 bytes or more).   python3 -I mkctl.py SRC_ZIG_DIR PLACE NBLOCKS
PLACE  a: snapshot_open.loadEngine, right after the MANIFEST buffer is allocated (beside the changed read; every open)
       b: lexical_segment.inspect, at its start (every open, another file)"""
import sys
from pathlib import Path

src, place, n = Path(sys.argv[1]), sys.argv[2], int(sys.argv[3])


def block(i):
    return (f"    {{\n        var k{i}: usize = {i % 3};\n"
            f"        while (k{i} + {2 + i % 4} < bytes.len) : (k{i} += {1 + i % 2}) {{\n"
            f"            acc = (acc *% {0x100000001b3 + 6 * i}) ^ (@as(u64, bytes[k{i}]) << {1 + i % 5});\n"
            f"            if (bytes[k{i} + 1] == {(i * 41) % 253}) acc +%= @as(u64, k{i}) *% {5 + 4 * i};\n"
            f"        }}\n    }}\n")


fn = ("/// S6-T13 verifier placement control: never called at run time.\n"
      "pub fn verifierControl(bytes: []const u8, seed: u64) u64 {\n    var acc: u64 = seed;\n"
      + "".join(block(i) for i in range(n)) + "    return acc;\n}\n\n")
big = "(@as(usize, 1) << 50)"
spots = {
    "a": ("snapshot_open.zig", "/// The manifest and the document and lexical sections, each section's\n",
          "    const manifest_read = try blocks.alloc(u8, manifest_size);\n",
          f"    if (manifest_size >= {big} and verifierControl(manifest_read, 5) == 9) return error.IndexTooLarge;\n"),
    "b": ("lexical_segment.zig", "pub fn inspect(encoded: []const u8) DecodeError!Header {\n",
          "pub fn inspect(encoded: []const u8) DecodeError!Header {\n",
          f"    if (encoded.len >= {big} and verifierControl(encoded, 3) == 9) return error.Truncated;\n"),
}
name, before, after, call = spots[place]
p = src / "src" / name
s = p.read_text()
assert s.count(before) == 1 and s.count(after) == 1, name
s = s.replace(after, after + call)
s = s.replace(before, fn + before)
p.write_text(s)
print(f"control {place}: {n} blocks in {name}")
