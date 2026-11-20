"""S6-T13 verifier plants: python3 -I vplants.py PLANT ZIG_DIR (a fresh copy of eb53311's zig/; the builder's p1-p5
come from the branch's scripts/prototypes/s6t13/plants.py and are applied by vplant.sh)."""
import sys
from pathlib import Path

plant, zig = sys.argv[1], Path(sys.argv[2])


def edit(rel, old, new):
    p = zig / "src" / rel
    s = p.read_text()
    assert s.count(old) == 1, (plant, rel, old[:70])
    p.write_text(s.replace(old, new))


READ = """    var reader = file.reader(io, &.{});
    const length = reader.interface.readSliceShort(buffer) catch |err| switch (err) {
        error.ReadFailed => return reader.err.?,
    };
"""
if plant == "v1-short-read-ignored":
    edit("snapshot_open.zig", "    return .{ .buffer = buffer, .bytes = buffer[0..length] };",
         "    _ = length;\n    return .{ .buffer = buffer, .bytes = buffer };")
elif plant == "v2-read-by-name":
    edit("snapshot_open.zig", READ, "    const length = (try dir.readFile(io, publication.current_manifest_file, buffer)).len;\n")
elif plant == "v3-scan-documents-only":
    edit("lifecycle.zig", "        const lexical_encoded = try iterable_dir.readFile(io, metadata.lexical_file, lexical_buffer);\n",
         "        const lexical_encoded = iterable_dir.readFile(io, metadata.lexical_file, lexical_buffer) catch |e| switch (e) {\n"
         "            error.FileNotFound => break :blk null,\n            else => return e,\n        };\n")
elif plant == "v4-scan-notfound-mapped":
    edit("lifecycle.zig", "        const documents_encoded = try iterable_dir.readFile(io, metadata.documents_file, documents_buffer);\n",
         "        const documents_encoded = iterable_dir.readFile(io, metadata.documents_file, documents_buffer) catch |e|\n"
         "            return if (e == error.FileNotFound) error.SectionMissing else e;\n")
    edit("lifecycle.zig", "        const lexical_encoded = try iterable_dir.readFile(io, metadata.lexical_file, lexical_buffer);\n",
         "        const lexical_encoded = iterable_dir.readFile(io, metadata.lexical_file, lexical_buffer) catch |e|\n"
         "            return if (e == error.FileNotFound) error.SectionMissing else e;\n")
elif plant == "v5-size-before-handle":
    edit("snapshot_open.zig", """    const file = try dir.openFile(io, publication.current_manifest_file, .{});
    defer file.close(io);
    const stat = try file.stat(io);
""", """    const stat = try dir.statFile(io, publication.current_manifest_file, .{});
    const file = try dir.openFile(io, publication.current_manifest_file, .{});
    defer file.close(io);
""")
elif plant == "v6a-buffer-minus-one":
    edit("snapshot_open.zig", "    const buffer = try allocator.alloc(u8, size);\n", "    const buffer = try allocator.alloc(u8, size -| 1);\n")
elif plant == "v6b-buffer-plus-one":
    edit("snapshot_open.zig", "    const buffer = try allocator.alloc(u8, size);\n", "    const buffer = try allocator.alloc(u8, size + 1);\n")
elif plant == "v7-scan-damaged-as-none":
    edit("lifecycle.zig", "        const metadata = try manifest.decode(manifest_encoded);\n",
         "        const metadata = manifest.decode(manifest_encoded) catch break :blk null;\n")
elif plant == "v8-scan-no-validate":
    edit("lifecycle.zig", "        try manifest.validateSnapshot(metadata, documents_encoded, lexical_encoded);\n",
         "        _ = documents_encoded;\n        _ = lexical_encoded;\n")
elif plant == "v9-reopen-for-read":
    # the size from this handle, the bytes through a second open by name (the read reopens)
    edit("snapshot_open.zig", "    var reader = file.reader(io, &.{});\n",
         "    const again = try dir.openFile(io, publication.current_manifest_file, .{});\n    defer again.close(io);\n"
         "    var reader = again.reader(io, &.{});\n")
elif plant == "none":
    pass
else:
    raise SystemExit("unknown plant " + plant)
print("planted", plant)
