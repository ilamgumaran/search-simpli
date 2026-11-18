"""S6-T7 Phase 1: break each boundary rule of the text-once format once and
check the prototype's decoder refuses it with the rule's error.

Run through `text_once.py selftest INDEX_DIR`. The index should have, as the
J2 and family corpora do, a file kept whole with no chunk (an empty file), a
file kept whole because a chunk is not an exact span (CR LF), files rebuilt
from overlapping chunks, and files with residual bytes at the end.

Every mutation copies the intact sections, changes the bytes named and, where
the rule is about a length, the header field that would otherwise hide it.
The intact pair must decode and rebuild every file; each broken copy must be
refused with exactly the expected error. Overlong varints are not planted:
the format accepts them (as `postings.readVarint` does).
"""

from __future__ import annotations

import struct
from pathlib import Path

from text_once import DOC_HEADER, SRC_HEADER, Reader, Refused, build, decode_documents, decode_source, rebuild


def run_all(documents: bytes, source: bytes) -> str:
    try:
        docs = decode_documents(documents, True)
        src = decode_source(source, docs)
        for entry in src["files"]:
            rebuild(src, docs, entry)
    except Refused as refused:
        return refused.args[0]
    return "accepted"


def patch(data: bytes, at: int, fmt: str, value: int) -> bytes:
    out = bytearray(data)
    struct.pack_into(fmt, out, at, value)
    return bytes(out)


def bump(data: bytes, at: int, fmt: str, delta: int) -> bytes:
    return patch(data, at, fmt, struct.unpack_from(fmt, data, at)[0] + delta)


def insert(data: bytes, at: int, extra: bytes) -> bytes:
    return data[:at] + extra + data[at:]


def set_byte(data: bytes, at: int, value: int) -> bytes:
    out = bytearray(data)
    out[at] = value
    return bytes(out)


def varint_span(data: bytes, at: int) -> tuple[int, int]:
    """(value, offset after it) of the varint at `at`."""
    r = Reader(data, at, len(data), "x")
    return r.varint(), r.at


def record_fields(data: bytes, at: int, dims: int) -> dict:
    """Offsets of a v5 record's fields."""
    out = {"flags": at}
    flags, at = varint_span(data, at)
    if flags & 1:
        n, at = varint_span(data, at)
        at += n
    else:
        at += 10
    for name in ("text_len", "start", "span", "chunker", "depth", "heading_back"):
        out[name] = at
        value, at = varint_span(data, at)
        out[name + "_value"] = value
    if out["depth_value"] > 0:
        _, at = varint_span(data, at)
    if flags & 4:
        n, at = varint_span(data, at)
        at += n
    if flags & 2:
        at += 4 * dims
    out["text"] = at
    return out


def run(index: Path) -> int:
    built = build(index)
    D, S = built["documents"], built["source"]
    docs = decode_documents(D, True)
    src = decode_source(S, docs)
    dims = docs["dims"]
    retained = [f for f in docs["files"] if f["retained"]]
    entries = src["files"]
    rec_bytes = struct.unpack_from("<Q", S, 16)[0]
    map_bytes = struct.unpack_from("<Q", S, 24)[0]
    table_bytes = struct.unpack_from("<Q", D, 24)[0]
    doc_end = len(D)
    last_file_at = docs["file_at"][-1]
    last_rec = record_fields(D, docs["record_at"][-1], dims)
    # The last rebuilt file, its last chunk, and the zero-chunk file.
    last_rebuilt = max(i for i, e in enumerate(entries) if not e["whole"])
    rebuilt_file = entries[last_rebuilt]["file"]
    rebuilt_rec = record_fields(D, docs["record_at"][rebuilt_file["first"] + rebuilt_file["chunks"] - 1], dims)
    zero = next(i for i, e in enumerate(entries) if e["file"]["chunks"] == 0)
    first_overlap = next(i for i, e in enumerate(entries) if e["recipe"] and any(v % 2 for v in e["recipe"]))

    def src_rec(i: int) -> dict:
        at = src["record_at"][i]
        out = {"sha": at, "flags": at + 32}
        _, a = varint_span(S, at + 32)
        out["length"] = a
        _, a = varint_span(S, a)
        out["lines"] = a
        _, a = varint_span(S, a)
        out["chunk_count"] = a
        if not entries[i]["whole"]:
            _, a = varint_span(S, a)
            out["recipe"] = a
        return out

    last_src = src_rec(len(entries) - 1)
    lr = src_rec(last_rebuilt)
    ov = src_rec(first_overlap)
    res_start = SRC_HEADER + rec_bytes + map_bytes
    lo, hi = entries[last_rebuilt]["residual"]
    k_of_first_overlap = next(j for j, v in enumerate(entries[first_overlap]["recipe"]) if v % 2)
    ofile = entries[first_overlap]["file"]
    pos_before = 0
    for v, rec in zip(entries[first_overlap]["recipe"][:k_of_first_overlap],
                      docs["records"][ofile["first"]:ofile["first"] + ofile["chunks"]]):
        pos_before = pos_before + v // 2 + len(rec["text"]) if v % 2 == 0 else \
            pos_before + max(0, len(rec["text"]) - (v + 1) // 2)

    cases: list[tuple[str, bytes, bytes, str]] = [
        ("intact", D, S, "accepted"),
        # documents: header
        ("documents: magic", set_byte(D, 7, ord("2")), S, "BadMagic"),
        ("documents: version 4", patch(D, 8, "<H", 4), S, "UnsupportedVersion"),
        ("documents: flags 0 (XXH3 required)", patch(D, 10, "<H", 0), S, "UnsupportedFlags"),
        ("documents: flags bit 1", patch(D, 10, "<H", 3), S, "UnsupportedFlags"),
        ("documents: last byte cut", D[:-1], S, "Truncated"),
        ("documents: one byte after the records", D + b"\x00", S, "TrailingData"),
        # documents: the file table
        ("file table: one byte after the last entry (table length +1)",
         bump(insert(D, DOC_HEADER + table_bytes, b"\x00"), 24, "<Q", 1), S, "TrailingData"),
        ("file table: one entry fewer (file count -1)", bump(D, 20, "<I", -1), S, "TrailingData"),
        ("file table: one entry more (file count +1)", bump(D, 20, "<I", 1), S, "InvalidFileTable"),
        ("file table: decoded path bytes +1", bump(D, 40, "<Q", 1), S, "InvalidFileTable"),
        ("file table: decoded path bytes -1", bump(D, 40, "<Q", -1), S, "InvalidFileTable"),
        ("file table: document count -1 (last file's chunks overrun)", bump(D, 12, "<I", -1), S, "InvalidFileTable"),
        ("file table: document count +1 (chunks fall short)", bump(D, 12, "<I", 1), S, "InvalidFileTable"),
        ("file table: last entry's suffix sorts before the previous path",
         set_byte(D, varint_span(D, varint_span(D, last_file_at)[1])[1], 0x01), S, "UnsortedPaths"),
        ("file table: first entry shares a prefix", set_byte(D, docs["file_at"][0], 1), S, "InvalidFileTable"),
        ("file table: last entry not retained", D[:last_file_at] + _flip_retained(D, last_file_at) + b"", S,
         "SourceFileCountMismatch"),
        ("file table: retained with no source section", D, None, "InvalidFileTable"),
        # documents: the records
        ("records: one byte after the last record (records length +1)", bump(D + b"\x00", 32, "<Q", 1), S,
         "TrailingData"),
        ("records: last record flags bit 3", set_byte(D, last_rec["flags"], D[last_rec["flags"]] | 8), S,
         "UnsupportedFlags"),
        ("records: last record start line 0", set_byte(D, last_rec["start"], 0), S, "InvalidCitation"),
        ("records: last record heading after its start",
         set_byte(D, last_rec["heading_back"], last_rec["start_value"] + 1), S, "InvalidSection"),
        ("records: last text byte of a rebuilt file's last chunk changed",
         set_byte(D, rebuilt_rec["text"], D[rebuilt_rec["text"]] ^ 0x20), S, "SourceFileSha256Mismatch"),
        # source: header
        ("source: magic v1", set_byte(S, 7, ord("1")), D, "BadMagic"),
        ("source: version 1", patch(S, 8, "<H", 1), D, "UnsupportedVersion"),
        ("source: flags 0", patch(S, 10, "<H", 0), D, "UnsupportedFlags"),
        ("source: last byte cut", S[:-1], D, "Truncated"),
        ("source: one byte after the residual area", S + b"\x00", D, "TrailingData"),
        ("source: file count +1", bump(S, 12, "<I", 1), D, "SourceFileCountMismatch"),
        # source: records
        ("source records: one byte after the last record (records length +1)",
         bump(insert(S, SRC_HEADER + rec_bytes, b"\x00"), 16, "<Q", 1), D, "TrailingData"),
        ("source records: last record flags bit 2", set_byte(S, last_src["flags"], S[last_src["flags"]] | 4), D,
         "InvalidFileTable"),
        ("source records: zero-chunk file not kept whole",
         set_byte(S, src_rec(zero)["flags"], S[src_rec(zero)["flags"]] & ~2), D, "InvalidFileTable"),
        ("source records: chunk count differs from the documents'",
         set_byte(S, lr["chunk_count"], S[lr["chunk_count"]] + 1), D, "InvalidFileTable"),
        ("source records: first recipe value an overlap at position 0", set_byte(S, lr["recipe"], 1), D,
         "InvalidFileTable"),
        ("source records: an overlap longer than the bytes emitted",
         _overlap_too_long(S, ov["recipe"], k_of_first_overlap, pos_before, rec_bytes), D, "InvalidFileTable"),
        ("source records: last SHA-256 byte changed", set_byte(S, last_src["sha"] + 31, S[last_src["sha"] + 31] ^ 1),
         D, "SourceFileSha256Mismatch"),
        ("source records: BOM flag set on a file without one",
         set_byte(S, lr["flags"], S[lr["flags"]] ^ 1), D, "InvalidLineMap"),
        # source: line maps
        ("line maps: one byte after the last map (maps length +1)",
         bump(insert(S, SRC_HEADER + rec_bytes + map_bytes, b"\x00"), 24, "<Q", 1), D, "InvalidLineMap"),
        ("line maps: last map one varint short (maps length -1)",
         bump(S[:SRC_HEADER + rec_bytes + map_bytes - 1] + S[SRC_HEADER + rec_bytes + map_bytes:], 24, "<Q", -1), D,
         "InvalidLineMap"),
        # source: residual area
        ("residual: one byte left over (residual length +1)", bump(S + b"\x00", 32, "<Q", 1), D, "InvalidFileTable"),
        ("residual: last byte missing (residual length -1)", bump(S[:-1], 32, "<Q", -1), D, "InvalidFileTable"),
        ("residual: a gap byte of the last rebuilt file changed",
         set_byte(S, res_start + hi - 1, S[res_start + hi - 1] ^ 0x01), D, "SourceFileSha256Mismatch"),
    ]
    failed = 0
    for name, a, b, expected in cases:
        if name.startswith("source") or name.startswith("line maps") or name.startswith("residual"):
            documents, source = b, a
        else:
            documents, source = a, b
        if source is None:
            try:
                decode_documents(documents, False)
                got = "accepted"
            except Refused as refused:
                got = refused.args[0]
        else:
            got = run_all(documents, source)
        ok = got == expected
        failed += not ok
        print(f"{'ok  ' if ok else 'FAIL'} {name}: {got}" + ("" if ok else f" (expected {expected})"))
    print(f"{len(cases)} cases, {failed} failed")
    return 1 if failed else 0


def _flip_retained(data: bytes, entry_at: int) -> bytes:
    """The last file entry with its retained bit cleared (the varint keeps
    its length), followed by the rest of the section."""
    _, at = varint_span(data, entry_at)
    n, at = varint_span(data, at)
    at += n
    value, end = varint_span(data, at)
    out = bytearray(data[entry_at:])
    rel = at - entry_at
    assert value & 1, "last entry: expected a retained file"
    out[rel] &= 0xFE  # bit 0 of the value is bit 0 of the varint's first byte
    return bytes(out)


def _overlap_too_long(data: bytes, recipe_at: int, index: int, pos: int, rec_bytes: int) -> bytes:
    """The `index`-th recipe value of a record replaced by an overlap of
    `pos + 1` bytes, one more than the bytes emitted before it (the varint is
    re-encoded and the records length adjusted)."""
    from text_once import put
    at = recipe_at
    for _ in range(index):
        _, at = varint_span(data, at)
    _, end = varint_span(data, at)
    new = bytearray()
    put(new, 2 * (pos + 1) - 1)
    out = data[:at] + bytes(new) + data[end:]
    return patch(out, 16, "<Q", rec_bytes + len(new) - (end - at))
