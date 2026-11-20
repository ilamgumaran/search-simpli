"""S6-T9 (ruling 7a, 7b): one plant per refusal site in the new and changed code, and the by-one plants of every
numeric bound. Each plant changes one site inside the named function's body: an equality or a check removed (or its
error swapped for another rule's), a bound moved by one step either way. Each anchor must occur exactly once in that
function's body (or, with replace_all, at least once).

    plants_sites.py COPY NAME     plant NAME into the source tree at COPY
    plants_sites.py --list        print the plant names, one per line

Names: s-* a refusal site removed or loosened; b-* a bound moved by one step (b-*-loose lets one more through,
b-*-tight refuses the value at the bound). Not part of any library.
"""
import sys
from pathlib import Path

IS = ("incremental_state.zig", "pub fn decodeBinaryWith(")
REL = ("incremental_state.zig", "pub fn relativeOf(")
ENC = ("incremental_state.zig", "pub fn encodeBinaryRefs(")
REF = ("incremental_state.zig", "pub fn refers(")
TAB = ("incremental_state.zig", "pub fn sourceTableOf(")
SS = ("state_section.zig", "pub fn inspect(")
MF = ("manifest.zig", "fn validateFields(")
MS = ("manifest.zig", "pub fn validateState(")
MFN = ("manifest.zig", "pub fn validateFilenameSections(")
FL = ("filename_field.zig", "pub fn loadBytes(")
VC = ("filename_field.zig", "fn validateCarried(")
SD = ("segment.zig", "pub fn decodeInspected(")
SC = ("segment.zig", "pub fn inspectCatalog(")
SI = ("segment.zig", "pub fn inspect(")
AP = ("apply.zig", "fn applyParsed(")

LEAST = "const least_record: u128 = if (v3) binary_ref_length else binary_file_length;"
HEADROOM = "if (binary_ref_length > bytes.len - reader.at - records_length) return error.InvalidState;"
LENGTH = "if (length > bytes.len - reader.at - records_length) return error.InvalidState;"
KNOWN = "const known: u32 = if (v3) file_known_flags_v3 else file_known_flags;"
LABEL = "const label_count = read32(record, 24);\n            if (label_count > labels.len - next_label) return error.InvalidState;"
ROOT = "const root_id = try stringAt(strings, read32(record, 0));"
CHUNKER = "try stringAt(strings, read32(record, 20))"
MTIME0 = "if (flags & file_has_mtime == 0 and read64(record, 8) != 0) return error.InvalidState;"
CHUNKER0 = "if (flags & file_has_chunker == 0 and read32(record, 20) != 0) return error.InvalidState;"
MOVED0 = "if (flags & file_has_moved_from == 0 and read32(record, 32) != 0) return error.InvalidState;"
S1 = "if (flags & (file_has_size | file_has_sha256 | file_pending) != 0) return error.StateReferenceFlags;"
S2 = "table orelse return error.StateReferenceWithoutSource;"
S3 = "if (ordinal >= source_table.count()) return error.StateReferenceOutOfRange;"
S4 = "if (last_ref) |previous| if (ordinal <= previous) return error.StateReferenceOrder;"
S5 = "relativeOf(root_id, target.path) orelse return error.StateReferencePath;"

P = {
    # ---- state HYBSTA03 (incremental_state.decodeBinaryWith and helpers)
    "s-count-bound": ("the count bound: a v3 file needs 36 bytes", [(IS, LEAST, LEAST.replace("if (v3) binary_ref_length", "if (v3) 0"), False)]),
    "b-count-bound-loose": ("the count bound, 35 bytes a file", [(IS, LEAST, LEAST.replace("if (v3) binary_ref_length", "if (v3) binary_ref_length - 1"), False)]),
    "b-count-bound-tight": ("the count bound, 37 bytes a file", [(IS, LEAST, LEAST.replace("if (v3) binary_ref_length", "if (v3) binary_ref_length + 1"), False)]),
    "s-walk-headroom": ("the walk: 36 bytes left before a record's flags are read", [(IS, HEADROOM, "", False)]),
    "b-walk-headroom-loose": ("the walk headroom, 35 bytes", [(IS, HEADROOM, HEADROOM.replace("binary_ref_length >", "binary_ref_length - 1 >"), False)]),
    "b-walk-headroom-tight": ("the walk headroom, 37 bytes", [(IS, HEADROOM, HEADROOM.replace("binary_ref_length >", "binary_ref_length + 1 >"), False)]),
    "s-walk-length": ("the walk: the record's own length left", [(IS, LENGTH, "", False)]),
    "b-walk-length-loose": ("the walk length, one byte short let through", [(IS, LENGTH, LENGTH.replace("if (length >", "if (length - 1 >"), False)]),
    "b-walk-length-tight": ("the walk length, the exact length refused", [(IS, LENGTH, LENGTH.replace("if (length >", "if (length >="), False)]),
    "s-v3-unknown-flag": ("v3: bit 7 taken as known", [(IS, KNOWN, KNOWN.replace("if (v3) file_known_flags_v3", "if (v3) file_known_flags_v3 | 0x80"), False)]),
    "s-v2-bit6": ("v2: bit 6 (source_ref) taken as known", [(IS, KNOWN, KNOWN.replace("else file_known_flags;", "else file_known_flags_v3;"), False)]),
    "s-ref-label-count": ("referenced record: label count past the references", [(IS, LABEL, LABEL.replace("if (label_count >", "if (false and label_count >"), False)]),
    "b-ref-label-count-tight": ("referenced record: label count at the references left refused", [(IS, LABEL, LABEL.replace("if (label_count >", "if (label_count >="), False)]),
    "b-ref-label-count-loose": ("referenced record: label count one past let through", [(IS, LABEL, LABEL.replace("if (label_count > labels.len - next_label)", "if (label_count > labels.len - next_label + 1)"), False)]),
    "s-ref-root-index": ("referenced record: root string index clamped instead of refused", [(IS, ROOT, "const root_id = strings[@min(read32(record, 0), strings.len - 1)];", False)]),
    "s-ref-chunker-index": ("referenced record: chunker string index clamped instead of refused", [(IS, CHUNKER, "strings[@min(read32(record, 20), strings.len - 1)]", False)]),
    "s-ref-zero-mtime": ("referenced record: mtime bytes without its flag", [(IS, MTIME0, "", False)]),
    "s-ref-zero-chunker": ("referenced record: chunker bytes without its flag", [(IS, CHUNKER0, "", False)]),
    "s-ref-zero-moved": ("referenced record: moved_from length without its flag", [(IS, MOVED0, "", False)]),
    "s-S1": ("S1 StateReferenceFlags removed", [(IS, S1, "", False)]),
    "s-S2": ("S2 StateReferenceWithoutSource as S1's error", [(IS, S2, "table orelse return error.StateReferenceFlags;", False)]),
    "s-S3": ("S3 StateReferenceOutOfRange removed", [(IS, S3, "", False)]),
    "b-S3-loose": ("S3 the ordinal equal to the count let through", [(IS, S3, S3.replace(">=", ">"), False)]),
    "b-S3-tight": ("S3 the last ordinal refused", [(IS, S3, S3.replace("ordinal >= source_table.count()", "ordinal + 1 >= source_table.count()"), False)]),
    "s-S4": ("S4 StateReferenceOrder removed", [(IS, S4, "", False)]),
    "b-S4-loose": ("S4 an equal ordinal let through", [(IS, S4, S4.replace("ordinal <= previous", "ordinal < previous"), False)]),
    "b-S4-tight": ("S4 the next ordinal refused (previous + 1)", [(IS, S4, S4.replace("ordinal <= previous", "ordinal <= previous + 1"), False)]),
    "s-S5": ("S5 StateReferencePath: the whole table path taken", [(IS, S5, "relativeOf(root_id, target.path) orelse target.path;", False)]),
    "b-S5-prefix-loose": ("relativeOf: an empty relative path let through", [(REL, "path.len <= root_id.len + 1", "path.len < root_id.len + 1", False)]),
    "b-S5-prefix-tight": ("relativeOf: a one-byte relative path refused", [(REL, "path.len <= root_id.len + 1", "path.len <= root_id.len + 2", False)]),
    "s-S5-separator": ("relativeOf: the '/' after the root id not checked", [(REL, " or path[root_id.len] != '/'", "", False)]),
    "s-encode-refs-length": ("encodeBinaryRefs: a list of the wrong length", [(ENC, "if (refs.len != 0 and refs.len != state.files.len) return error.InvalidState;\n", "", False)]),
    "b-refers-order": ("the writer: an equal ordinal offered as a reference", [(REF, "if (r.ordinal <= l) return false;", "if (r.ordinal < l) return false;", False)]),
    "s-section-v3-version": ("HYBSTA03 header version not checked", [(SS, "!= versionOf(form)) return error.UnsupportedVersion;", "!= versionOf(form) and form != .binary_v3) return error.UnsupportedVersion;", False)]),
    # ---- the pointer's source table (incremental_state.sourceTableOf)
    "s-table-doc-length": ("pointer: documents length against the manifest", [(TAB, "if (documents_encoded.len != metadata.documents_bytes) return error.InvalidState;\n", "", False)]),
    "s-table-doc-checksum": ("pointer: documents checksum against the manifest", [(TAB, "header.checksum != metadata.documents_checksum or ", "", False)]),
    "s-table-doc-version": ("pointer: documents record version 5", [(TAB, " or header.format_version != segment.version_v5", "", False)]),
    "s-table-src-length": ("pointer: source length against the manifest", [(TAB, "if (source_encoded.len != metadata.source_bytes) return error.InvalidState;\n", "", False)]),
    "s-table-src-checksum": ("pointer: source checksum against the manifest", [(TAB, "source_header.checksum != metadata.source_checksum or ", "", False)]),
    "s-table-src-format": ("pointer: source format HYBSRC02", [(TAB, " or source_header.format != source_v2.version", "", False)]),
    "s-writer-v1-source": ("writer: a v1 previous source taken as a table", [(AP, "if (s.v2 != null) .{ .section = s } else null", ".{ .section = s }", False)]),
    # ---- manifest v2.6
    "s-M1": ("M1 StateVersionFlagWithoutSection removed", [(MF, "if (value.state_v3 and value.state == null) return error.StateVersionFlagWithoutSection;\n", "", False)]),
    "s-M2": ("M2 CatalogVersionFlagWithoutSection removed", [(MF, "if (value.catalog_v6 and value.filename == null) return error.CatalogVersionFlagWithoutSection;\n", "", False)]),
    "s-M3": ("M3 StateSectionVersionMismatch removed", [(MS, "if ((header.form == .binary_v3) != value.state_v3) return error.StateSectionVersionMismatch;\n", "", False)]),
    "s-M4-manifest": ("M4 at validateFilenameSections removed", [(MFN, "if ((catalog.format_version == segment.version_catalog_v6) != value.catalog_v6) return error.FilenameCatalogVersionMismatch;\n", "", False)]),
    "s-M4-load": ("M4 at filename_field.loadBytes removed", [(FL, "if ((catalog.format_version == segment.version_catalog_v6) != metadata.catalog_v6) return error.FilenameCatalogVersionMismatch;\n", "", False)]),
    # ---- catalog record v6
    "s-C1": ("C1 FilenameCatalogIdPresent removed", [(SD, "if (id_length != 0) return error.FilenameCatalogIdPresent;\n", "", False)]),
    "s-C2": ("C2 FilenameCatalogTextPresent removed", [(SD, "if (text_length != 0) return error.FilenameCatalogTextPresent;\n", "", False)]),
    "s-catalog-v5": ("inspectCatalog: record v5 (documents) accepted", [(SC, "if (actual_version == version_catalog_v6) return", "if (actual_version == version_catalog_v6 or actual_version == version_v5) return", False)]),
    "s-documents-v6": ("inspect: record v6 (catalog) accepted as documents", [(SI, "if (actual_version == version_v5) return segment_v5.parseHeader(encoded);", "if (actual_version == version_v5) return segment_v5.parseHeader(encoded);\n    if (actual_version == version_catalog_v6) return inspectFixed(encoded, actual_version);", False)]),
    "s-carried-inspect": ("validateCarried: the built catalog read with the documents inspect", [(VC, "segment.inspectCatalog(built.catalog)", "segment.inspect(built.catalog)", False)]),
    # ---- ruling 7(d): one assertion broken in each new test file (the test must fail, so the file runs)
    "d-state-v3-test": ("state_v3_test.zig: the worked example's payload length 238 -> 239",
                        [(("state_v3_test.zig", 'test "S6-T9 state v3: the worked example of the format document, byte for byte" {'),
                          "expectEqual(@as(usize, 238), payload.len)", "expectEqual(@as(usize, 239), payload.len)", False)]),
    "d-compat-s6t9-test": ("compat_s6t9_test.zig: the fixture's new flags bits compared with bit 8 only",
                           [(("compat_s6t9_test.zig", 'test "S6-T9: the committed v2.6 fixture is this writer\'s output, and a library before v2.6 refuses it at the flags" {'),
                             "expectEqual(manifest.flag_state_v3 | manifest.flag_catalog_v6,", "expectEqual(manifest.flag_state_v3,", False)]),
}


def body_span(text, header):
    start = text.index(header)
    assert text.count(header) == 1, header
    end = text.index("\n}\n", start) + 3
    return start, end


def plant(copy, name):
    src = copy / "zig" / "src"
    _, edits = P[name]
    for (file, header), old, new, replace_all in edits:
        path = src / file
        text = path.read_text()
        start, end = body_span(text, header)
        body = text[start:end]
        n = body.count(old)
        assert n == 1 or (replace_all and n > 1), (name, header, old, n)
        new_body = body.replace(old, new)
        assert new_body != body, name
        path.write_text(text[:start] + new_body + text[end:])
    print("planted", name)


if __name__ == "__main__":
    if sys.argv[1:] == ["--list"]:
        print("\n".join(P))
    elif sys.argv[1:2] == ["--describe"]:
        for n, (d, _) in P.items():
            print(f"{n}\t{d}")
    else:
        plant(Path(sys.argv[1]), sys.argv[2])
