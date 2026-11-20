"""S6-T9 verifier's own plants (not in the builder's plants_sites.py). vplants.py COPY NAME | --list
Each replaces one exact text (which must occur once in the file) in COPY/zig/src."""
import sys
from pathlib import Path

P = {
    "v-trailing-v3": ("incremental_state.zig", "v3: a byte after the payload's last text byte accepted",
                      "if (next_label != labels.len or reader.at != bytes.len) return error.InvalidState;",
                      "if (next_label != labels.len or (!v3 and reader.at != bytes.len)) return error.InvalidState;"),
    "v-S1-no-pending": ("incremental_state.zig", "S1 without bit 3 (pending)",
                        "if (flags & (file_has_size | file_has_sha256 | file_pending) != 0) return error.StateReferenceFlags;",
                        "if (flags & (file_has_size | file_has_sha256) != 0) return error.StateReferenceFlags;"),
    "v-S1-no-sha": ("incremental_state.zig", "S1 without bit 2 (sha256)",
                    "if (flags & (file_has_size | file_has_sha256 | file_pending) != 0) return error.StateReferenceFlags;",
                    "if (flags & (file_has_size | file_pending) != 0) return error.StateReferenceFlags;"),
    "v-S4-first-only": ("incremental_state.zig", "S4 against the first referenced ordinal only",
                        "            last_ref = ordinal;\n", "            if (last_ref == null) last_ref = ordinal;\n"),
    "v-M3-oneway": ("manifest.zig", "M3 one way: a HYBSTA02 state under bit 8 accepted",
                    "if ((header.form == .binary_v3) != value.state_v3) return error.StateSectionVersionMismatch;",
                    "if (header.form == .binary_v3 and !value.state_v3) return error.StateSectionVersionMismatch;"),
    "v-M4-manifest-oneway": ("manifest.zig", "M4 at validateFilenameSections one way: a v3 catalog under bit 9 accepted",
                             "if ((catalog.format_version == segment.version_catalog_v6) != value.catalog_v6) return error.FilenameCatalogVersionMismatch;",
                             "if (catalog.format_version == segment.version_catalog_v6 and !value.catalog_v6) return error.FilenameCatalogVersionMismatch;"),
    "v-M4-load-oneway": ("filename_field.zig", "M4 at loadBytes one way: a v3 catalog under bit 9 accepted",
                         "if ((catalog.format_version == segment.version_catalog_v6) != metadata.catalog_v6) return error.FilenameCatalogVersionMismatch;",
                         "if (catalog.format_version == segment.version_catalog_v6 and !metadata.catalog_v6) return error.FilenameCatalogVersionMismatch;"),
    "v-ref-labels": ("incremental_state.zig", "referenced record: its labels not consumed (the next file gets them)",
                     "            next_label += label_count;\n            continue;\n", "            continue;\n"),
    "v-refers-pending": ("incremental_state.zig", "refers: a pending entry stored as a reference",
                         "    if (entry.status != .indexed) return false;\n    if (last) |l|", "    if (last) |l|"),
    "v-refers-hash": ("incremental_state.zig", "refers: the hash not compared",
                      "    if (!std.mem.eql(u8, entry.hash, &hex)) return false;\n", "    _ = &hex;\n"),
    "v-apply-swallow": ("apply.zig", "the writer: a refused previous state taken as absent (repaired, not refused)",
                        "previous_state = try incremental_state.decodeSectionWith(allocator, bytes, table);",
                        "previous_state = incremental_state.decodeSectionWith(allocator, bytes, table) catch null;"),
    "v-ref-mtime": ("incremental_state.zig", "referenced record: mtime dropped on decode",
                    ".mtime_ms = if (flags & file_has_mtime != 0) @bitCast(read64(record, 8)) else null,",
                    ".mtime_ms = null,"),
}
if sys.argv[1] == "--list":
    for k, v in P.items():
        print(k, "|", v[0], "|", v[1])
    sys.exit()
copy, name = Path(sys.argv[1]), sys.argv[2]
f, _, a, b = P[name]
p = copy / "zig" / "src" / f
s = p.read_text()
assert s.count(a) == 1, (name, s.count(a))
p.write_text(s.replace(a, b))
print("planted", name)
