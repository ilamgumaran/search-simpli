"""Plant edits for S6-T13: python3 -I make.py <plant> <zig dir of a scratch copy that has the fix>."""
import sys
from pathlib import Path

plant, zig = sys.argv[1], Path(sys.argv[2])

def edit(rel, old, new):
    p = zig / rel
    s = p.read_text()
    assert s.count(old) == 1, (plant, rel, old[:60])
    p.write_text(s.replace(old, new))

SCAN_NEW_HEAD = "    const current_metadata: ?manifest.Manifest = if (iterable_dir.readFile(io, publication.current_manifest_file, manifest_buffer)) |manifest_encoded| blk: {"
if plant == "p1-scan-old":
    p = zig / "src/lifecycle.zig"; s = p.read_text()
    start = s.index(SCAN_NEW_HEAD); end = s.index("    };\n", start) + len("    };\n")
    s = s[:start] + """    const current: ?publication.LoadedSnapshot = publication.loadCurrent(iterable_dir, io, manifest_buffer, documents_buffer, lexical_buffer) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    const current_metadata: ?manifest.Manifest = if (current) |snapshot| snapshot.metadata else null;
""" + s[end:]
    p.write_text(s)
elif plant == "p2-scan-every-error":
    edit("src/lifecycle.zig", """    } else |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };""", """    } else |err| return err;""")
elif plant == "p3-open-old":
    edit("src/snapshot_open.zig", """    const manifest_read = try readManifest(blocks, io, dir);
    defer blocks.free(manifest_read.buffer);
    const manifest_first = manifest_read.bytes;
""", """    var manifest_file = try dir.openFile(io, publication.current_manifest_file, .{});
    const manifest_stat = try manifest_file.stat(io);
    manifest_file.close(io);
    const manifest_size = std.math.cast(usize, manifest_stat.size) orelse return error.IndexTooLarge;
    const manifest_buffer = try blocks.alloc(u8, manifest_size);
    defer blocks.free(manifest_buffer);
    const manifest_first = try dir.readFile(io, publication.current_manifest_file, manifest_buffer);
""")
elif plant == "p4-opensource-old":
    edit("src/snapshot_open.zig", """    const manifest_encoded = (try readManifest(allocator, io, dir)).bytes;
""", """    var manifest_file = try dir.openFile(io, publication.current_manifest_file, .{});
    const manifest_stat = try manifest_file.stat(io);
    manifest_file.close(io);
    const manifest_size = std.math.cast(usize, manifest_stat.size) orelse return error.IndexTooLarge;
    const manifest_buffer = try allocator.alloc(u8, manifest_size);
    const manifest_encoded = try dir.readFile(io, publication.current_manifest_file, manifest_buffer);
""")
elif plant == "p5-damaged-error":
    edit("src/snapshot_open.zig", "    const layout = try OpenBlock.of(try manifest.decode(manifest_first), manifest_first.len);",
         "    const layout = try OpenBlock.of(manifest.decode(manifest_first) catch return error.ManifestChanged, manifest_first.len);")
else:
    raise SystemExit("unknown plant " + plant)
