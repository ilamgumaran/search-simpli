#!/usr/bin/env python3
"""S6-T7 verifier: plant definitions. Each plant: a list of (file under zig/src, old, new); every old string
must occur exactly once in the pristine f99a7cc tree.

    plants.py apply NAME TREE    # patch TREE/zig/src in place (TREE is a fresh git archive of f99a7cc)
    plants.py list
"""
import sys
from pathlib import Path

P = {
    # ---- the six the task requires
    "gap_short": ("writer: every gap written one byte short in the residual area", [
        ("source_v2.zig",
         "                if (gap != 0) try runs.append(allocator, bytes[pos..][0..gap]);\n                residual_bytes += gap;",
         "                if (gap > 1) try runs.append(allocator, bytes[pos..][0 .. gap - 1]);\n                residual_bytes += gap -| 1;")]),
    "sha_skip": ("reader: the SHA-256 compare after a rebuild skipped", [
        ("source_v2.zig",
         "    if (!std.mem.eql(u8, &digest, &file.sha256)) return source.unavailablePub(allocator, source.sha256_mismatch_name);",
         "    if (false and !std.mem.eql(u8, &digest, &file.sha256)) return source.unavailablePub(allocator, source.sha256_mismatch_name);")]),
    "overlap_twice": ("reader: an overlapping (or contained) chunk emitted whole on rebuild (k forced to 0)", [
        ("source_v2.zig",
         "            const k: usize = (@as(usize, v) + 1) / 2;\n            if (k < text.len) {\n                if (text.len - k > out.len - n) return null;",
         "            const k: usize = 0 * ((@as(usize, v) + 1) / 2);\n            if (k < text.len) {\n                if (text.len - k > out.len - n) return null;")]),
    "ordinal_off": ("reader: a record's source ordinal off by one (retained + 1) when decoding record v5", [
        ("segment_v5.zig",
         "        const sdi: u32 = if (item.entry.retained) retained else hybrid.no_source_doc;",
         "        const sdi: u32 = if (item.entry.retained) retained + 1 else hybrid.no_source_doc;")]),
    "old_reader_removed": ("reader: documents record v4 (and older) refused: only v5 decodes", [
        ("segment.zig",
         "    if (actual_version == version_v5) return segment_v5.parseHeader(encoded);\n",
         "    if (actual_version == version_v5) return segment_v5.parseHeader(encoded);\n    if (actual_version != version_v5) return error.UnsupportedVersion;\n")]),
    "residual_leftover": ("reader: a leftover byte after the last gap/tail in the residual area accepted", [
        ("source_v2.zig",
         "    if (residual_at != section.text_length) return error.InvalidFileTable;",
         "    if (residual_at > section.text_length) return error.InvalidFileTable;")]),
    # ---- the verifier's own
    "retained_inverted": ("reader: the file table's retained bit read inverted", [
        ("segment_v5.zig", "        const retained = value & 1 == 1;", "        const retained = value & 1 == 0;")]),
    "prefix_last_off": ("writer: the front-coding prefix length written one short on the last file-table entry (suffix unchanged)", [
        ("segment_v5.zig",
         "    for (files.items) |f| {\n        const shared = @min(commonPrefix(previous, f.path), shared_cap);\n        putVarint(out, &at, shared);",
         "    for (files.items, 0..) |f, fi| {\n        const shared = @min(commonPrefix(previous, f.path), shared_cap);\n        putVarint(out, &at, if (fi + 1 == files.items.len and shared > 0) shared - 1 else shared);")]),
    "flag_unset": ("writer: manifest flag bit 6 not set on a text-once generation", [
        ("manifest.zig", "    if (value.text_once) flags |= flag_text_once;", "    if (false and value.text_once) flags |= flag_text_once;")]),
    "whole_skipped": ("writer: a chunk not found in its lines (CR LF and the like) placed at its line start instead of keeping the file whole", [
        ("source_v2.zig",
         "        const found = std.mem.indexOfPos(u8, bytes[0..hi], lo, chunk.text) orelse return false;",
         "        const found = std.mem.indexOfPos(u8, bytes[0..hi], lo, chunk.text) orelse lo;")]),
    "old_source_written": ("writer: the publish writes HYBSRC01 (source.encodeMarked) under the v2.4 manifest", [
        ("apply.zig",
         "try source_v2.encodeMarked(allocator, retained.items, documents.items, SourceMarks{ .stages = stages })",
         "try source.encodeMarked(allocator, retained.items, SourceMarks{ .stages = stages })")]),
    "parity_v0": ("reader: recipe parity swapped only when v = 0 (gap 0 read as overlap 0)", [
        ("source_v2.zig",
         "        if (v & 1 == 0) {\n            const gap: usize = v / 2;\n            if (gap > residual.len - at",
         "        if (v & 1 == 0 and v != 0) {\n            const gap: usize = v / 2;\n            if (gap > residual.len - at")]),
    "parity_v1": ("reader: recipe parity swapped only when v = 1 (overlap 1 read as gap 0)", [
        ("source_v2.zig",
         "        if (v & 1 == 0) {\n            const gap: usize = v / 2;\n            if (gap > residual.len - at",
         "        if (v & 1 == 0 or v == 1) {\n            const gap: usize = v / 2;\n            if (gap > residual.len - at")]),
    "overlap_bound_removed": ("reader: an overlap larger than the bytes emitted so far accepted by the walk", [
        ("source_v2.zig", "            if (k > pos) return error.InvalidFileTable;", "            if (false and k > pos) return error.InvalidFileTable;")]),
    "table_trailing": ("reader: a leftover byte after the file table's last entry accepted", [
        ("segment_v5.zig",
         "            if (walk.reader.at != walk.reader.bytes.len) return error.TrailingData;",
         "            if (false and walk.reader.at != walk.reader.bytes.len) return error.TrailingData;")]),
    "records_trailing": ("reader: a leftover byte after the last record accepted", [
        ("segment_v5.zig",
         "    if (records.at != encoded.len) return error.TrailingData;\n    return document_output",
         "    if (false and records.at != encoded.len) return error.TrailingData;\n    return document_output")]),
    "contained_pos": ("writer: locate moves pos to the end of every chunk (no max), so a contained chunk moves it back", [
        ("source_v2.zig", "        pos = @max(pos, found + chunk.text.len);", "        pos = found + chunk.text.len;")]),
    "bom_flag_unset": ("writer: the BOM flag never written", [
        ("source_v2.zig", "        if (bom) flags |= flag_bom;", "        if (false and bom) flags |= flag_bom;")]),
    "map_check_skipped": ("reader: the first-read line map and BOM check of a v2 file skipped", [
        ("source_v2.zig", "    if (!section.mapChecked(file)) {", "    if (false and !section.mapChecked(file)) {")]),
    "carry_len_only": ("writer: an update carries the previous v2 record when the chunk lengths match (the text identity check dropped)", [
        ("apply.zig",
         "    for (now, before) |a, b| if (a.text.ptr != b.text.ptr or a.text.len != b.text.len) return false;",
         "    for (now, before) |a, b| if (a.text.len != b.text.len) return false;")]),
    "shared_cap_check": ("reader: a front-coding prefix above 255 accepted", [
        ("segment_v5.zig",
         "        if (shared > shared_cap or shared > walk.previous.len or",
         "        if (shared > walk.previous.len or")]),
}


def apply(name, tree):
    for fname, old, new in P[name][1]:
        p = Path(tree) / "zig" / "src" / fname
        s = p.read_text()
        n = s.count(old)
        if n != 1:
            raise SystemExit(f"{name}: {fname}: expected 1 occurrence, found {n}")
        p.write_text(s.replace(old, new))
    print(f"applied {name}")


if __name__ == "__main__":
    if sys.argv[1] == "list":
        for k, (d, _) in P.items():
            print(f"{k}\t{d}")
    else:
        apply(sys.argv[2], sys.argv[3])
