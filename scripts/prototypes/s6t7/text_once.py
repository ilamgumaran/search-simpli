#!/usr/bin/env python3
"""S6-T7 Phase 1 prototype: the text once (documents record v5, source v2).

Re-encodes an index written by `main` (documents record v4 `HYBSEG01`,
source `HYBSRC01`) into the layouts of
`docs/documents-v5-source-v2-format.md`, decodes the result again with a
decoder written from that document (it shares no state with the encoder),
rebuilds every retained file from its chunks and its residual bytes, and
compares each rebuilt file with the original bytes and its SHA-256. Every
record field the v5 decoder gives back is compared with the v4 record.

    python3 -I text_once.py encode INDEX_DIR OUT_DIR [--json FILE]
    python3 -I text_once.py selftest INDEX_DIR

`encode` writes `documents-v5.bin` and `source-v2.bin` into OUT_DIR (for the
Zig probe beside this file) and prints one JSON object: every part's bytes,
the counts, the rebuild result. The prototype writes each section's checksum
field as zero (Python's standard library has no XXH3-64); the decoder skips
that one check and says so in its output. Sizes are unaffected (the field is
eight bytes either way).

`selftest` builds the two sections for INDEX_DIR and then breaks each rule of
the format document in turn (one copy per rule), and checks that the decoder
refuses every broken copy with the rule's error and accepts the intact one.

Invented corpora only; nothing here reads outside INDEX_DIR. Not part of any
library or the build.
"""

from __future__ import annotations

import hashlib
import json
import struct
import sys
from pathlib import Path

# ------------------------------------------------------------------ varints

MAX_U32 = 0xFFFFFFFF


def put(out: bytearray, value: int) -> None:
    if value < 0 or value > MAX_U32:
        raise ValueError(f"varint out of range: {value}")
    while value >= 0x80:
        out.append((value & 0x7F) | 0x80)
        value >>= 7
    out.append(value)


def put64(out: bytearray, value: int) -> None:
    """A file's byte length: the same LEB128 coding, up to 64 bits."""
    if value < 0 or value >= 1 << 64:
        raise ValueError(f"varint out of range: {value}")
    while value >= 0x80:
        out.append((value & 0x7F) | 0x80)
        value >>= 7
    out.append(value)


def vlen(value: int) -> int:
    n = 1
    while value >= 0x80:
        value >>= 7
        n += 1
    return n


class Refused(Exception):
    """A section the format refuses; `.args[0]` is the error name."""


class Reader:
    """A cursor with the format's varint rule (`postings.readVarint`: at most
    five bytes, value below 2^32) and bounds on every take."""

    def __init__(self, data: bytes, at: int, end: int, error: str):
        self.data, self.at, self.end, self.error = data, at, end, error

    def varint(self) -> int:
        value = shift = 0
        while True:
            if self.at >= self.end or shift > 28:
                raise Refused(self.error)
            byte = self.data[self.at]
            self.at += 1
            value |= (byte & 0x7F) << shift
            if byte < 0x80:
                break
            shift += 7
        if value > MAX_U32:
            raise Refused(self.error)
        return value

    def varint64(self) -> int:
        """At most ten bytes, value below 2^64 (a file's byte length)."""
        value = shift = 0
        while True:
            if self.at >= self.end or shift > 63:
                raise Refused(self.error)
            byte = self.data[self.at]
            self.at += 1
            value |= (byte & 0x7F) << shift
            if byte < 0x80:
                break
            shift += 7
        if value >= 1 << 64:
            raise Refused(self.error)
        return value

    def take(self, n: int) -> bytes:
        if n < 0 or self.at + n > self.end:
            raise Refused(self.error)
        out = self.data[self.at:self.at + n]
        self.at += n
        return out


# ------------------------------------------------------------------ the old formats (main's)

def read_v4(data: bytes) -> tuple[list[dict], int]:
    """HYBSEG01 record v4, every field."""
    assert data[:8] == b"HYBSEG01"
    version, _flags, count, dims, payload = struct.unpack_from("<HHIIQ", data, 8)
    assert version == 4 and 36 + payload == len(data)
    pos, records = 36, []
    for _ in range(count):
        (id_len, path_len, text_len, vec_len, start, end, lab_len, chunker, depth, heading, src,
         sp_len) = struct.unpack_from("<IIIIIIIHHIII", data, pos)
        pos += 44
        rec = {"start": start, "end": end, "chunker": chunker, "depth": depth, "heading": heading, "src": src}
        for key, n in (("id", id_len), ("path", path_len), ("text", text_len), ("labels", lab_len),
                       ("vector", vec_len * 4), ("section_path", sp_len)):
            rec[key] = data[pos:pos + n]
            pos += n
        records.append(rec)
    assert pos == len(data)
    return records, dims


def read_v1_source(data: bytes) -> list[dict]:
    assert data[:8] == b"HYBSRC01"
    _v, _f, count, table, maps_len, text_len = struct.unpack_from("<HHIQQQ", data, 8)
    pos, files = 48, []
    for _ in range(count):
        plen, toff, tlen, lines, moff = struct.unpack_from("<IQQIQ", data, pos)
        sha, enc = data[pos + 32:pos + 64], data[pos + 64]
        pos += 68
        files.append({"path": data[pos:pos + plen], "toff": toff, "tlen": tlen, "lines": lines, "moff": moff,
                      "sha": sha, "encoding": enc})
        pos += plen
    maps = data[pos:pos + maps_len]
    text = data[pos + maps_len:pos + maps_len + text_len]
    for i, f in enumerate(files):
        end = files[i + 1]["moff"] if i + 1 < len(files) else maps_len
        f["map"] = maps[f["moff"]:end]
        f["bytes"] = text[f["toff"]:f["toff"] + f["tlen"]]
    return files


def newest(index: Path, stem: str, suffix: str) -> Path | None:
    found = sorted(index.glob(f"{stem}-*.{suffix}"), key=lambda p: int(p.name[len(stem) + 1:-len(suffix) - 1]))
    return found[-1] if found else None


# ------------------------------------------------------------------ the writer

HEX = set(b"0123456789abcdef")
SHARED_CAP = 255


def is_raw_id(identifier: bytes) -> bool:
    return len(identifier) == 20 and all(c in HEX for c in identifier)


def common(a: bytes, b: bytes) -> int:
    n = min(len(a), len(b))
    i = 0
    while i < n and a[i] == b[i]:
        i += 1
    return i


def chunk_offset(file_bytes: bytes, starts: list[int], line_count: int, rec: dict) -> int | None:
    """Where the chunk's text lies in its file, inside its own lines, or None
    when it is not an exact run of the file's bytes there."""
    lo = starts[rec["start"] - 1] if rec["start"] - 1 < len(starts) else len(file_bytes)
    hi = starts[min(rec["end"], line_count)]
    at = file_bytes.find(rec["text"], lo, hi)
    return at if at >= 0 else None


def line_starts(map_bytes: bytes, count: int) -> list[int]:
    r = Reader(map_bytes, 0, len(map_bytes), "map")
    out, value = [], 0
    for _ in range(count + 1):
        value += read_u64_varint(r)
        out.append(value)
    return out


def read_u64_varint(r: Reader) -> int:
    """The line maps keep v1's coding: unsigned LEB128 of up to 64 bits."""
    value = shift = 0
    while True:
        if r.at >= r.end or shift > 63:
            raise Refused("InvalidLineMap")
        byte = r.data[r.at]
        r.at += 1
        value |= (byte & 0x7F) << shift
        if byte < 0x80:
            return value
        shift += 7


def recipe(offsets: list[int], lengths: list[int], file_length: int) -> tuple[list[int], list[tuple[int, int]], int]:
    """The per-chunk varints (even 2g: a gap of g bytes; odd 2k-1: an overlap
    of k >= 1 bytes) and the file's residual runs (start, end) in order."""
    values, runs, pos = [], [], 0
    for at, length in zip(offsets, lengths):
        if at >= pos:
            values.append(2 * (at - pos))
            if at > pos:
                runs.append((pos, at))
            pos = at + length
        else:
            k = pos - at
            values.append(2 * k - 1)
            pos = max(pos, at + length)
    if pos > file_length:
        raise ValueError("chunk past the end of its file")
    if pos < file_length:
        runs.append((pos, file_length))
    return values, runs, pos


def build(index: Path) -> dict:
    docs_path = newest(index, "documents", "hybseg")
    src_path = newest(index, "source", "hybsrc")
    records, dims = read_v4(docs_path.read_bytes())
    sources = read_v1_source(src_path.read_bytes()) if src_path else []

    # The file table: every file with a chunk or retained bytes, by path.
    by_path: dict[bytes, dict] = {}
    order: list[bytes] = []
    for k, rec in enumerate(records):
        p = rec["path"]
        if not order or order[-1] != p:
            if p in by_path:
                raise SystemExit("records are not grouped by file")
            by_path[p] = {"path": p, "chunks": 0, "first": k, "source": None}
            order.append(p)
        by_path[p]["chunks"] += 1
    if order != sorted(order):
        raise SystemExit("files of the records are not in path order")
    for s, f in enumerate(sources):
        entry = by_path.setdefault(f["path"], {"path": f["path"], "chunks": 0, "first": None, "source": None})
        entry["source"] = s
    files = [by_path[p] for p in sorted(by_path)]
    first = 0
    for f in files:
        f["first"] = first
        first += f["chunks"]
    # record -> file; check every v4 source_doc_index is what v5 gives back.
    retained_before = 0
    for f in files:
        f["retained"] = f["source"] is not None
        f["source_doc_index"] = retained_before if f["retained"] else 0xFFFFFFFF
        if f["retained"]:
            if f["source"] != retained_before:
                raise SystemExit("source order differs from the file table's")
            retained_before += 1
        for rec in records[f["first"]:f["first"] + f["chunks"]]:
            if rec["src"] != f["source_doc_index"]:
                raise SystemExit("source_doc_index is not the retained ordinal")

    # Documents v5.
    table = bytearray()
    prev = b""
    path_text = 0
    parts = {"header": 56, "file table: shared and suffix length varints": 0, "file table: path suffix bytes": 0,
             "file table: chunk count and retained varint": 0}
    for f in files:
        p = f["path"]
        shared = min(common(prev, p), SHARED_CAP)
        a = len(table)
        put(table, shared)
        put(table, len(p) - shared)
        parts["file table: shared and suffix length varints"] += len(table) - a
        table += p[shared:]
        parts["file table: path suffix bytes"] += len(p) - shared
        a = len(table)
        put(table, (f["chunks"] << 1) | int(f["retained"]))
        parts["file table: chunk count and retained varint"] += len(table) - a
        path_text += len(p)
        prev = p
    recs = bytearray()
    names = ["record flags varint", "chunk ids (10 raw bytes)", "chunk ids inline (length varint and bytes)",
             "text length varint", "start line varint", "line span varint", "chunker index varint",
             "section depth varint", "heading varint", "section path length varint", "labels (length varint and bytes)",
             "vectors", "chunk text", "section paths (heading texts)"]
    for n in names:
        parts[n] = 0
    raw_ids = 0
    for rec in records:
        flags = 0
        raw = is_raw_id(rec["id"])
        if not raw:
            flags |= 1
        if rec["vector"]:
            flags |= 2
        if rec["labels"]:
            flags |= 4

        def field(name: str, value: int) -> None:
            a = len(recs)
            put(recs, value)
            parts[name] += len(recs) - a

        field("record flags varint", flags)
        if raw:
            recs += bytes.fromhex(rec["id"].decode())
            parts["chunk ids (10 raw bytes)"] += 10
            raw_ids += 1
        else:
            a = len(recs)
            put(recs, len(rec["id"]))
            recs += rec["id"]
            parts["chunk ids inline (length varint and bytes)"] += len(recs) - a
        field("text length varint", len(rec["text"]))
        field("start line varint", rec["start"])
        field("line span varint", rec["end"] - rec["start"])
        field("chunker index varint", rec["chunker"])
        field("section depth varint", rec["depth"])
        field("heading varint", 0 if rec["heading"] == 0 else rec["start"] - rec["heading"] + 1)
        if rec["depth"] > 0:
            field("section path length varint", len(rec["section_path"]))
        if rec["labels"]:
            a = len(recs)
            put(recs, len(rec["labels"]))
            recs += rec["labels"]
            parts["labels (length varint and bytes)"] += len(recs) - a
        recs += rec["vector"]
        parts["vectors"] += len(rec["vector"])
        recs += rec["text"]
        parts["chunk text"] += len(rec["text"])
        recs += rec["section_path"]
        parts["section paths (heading texts)"] += len(rec["section_path"])
    header = struct.pack("<8sHHIIIQQQQ", b"HYBSEG01", 5, 1, len(records), dims, len(files), len(table), len(recs),
                         path_text, 0)
    assert len(header) == 56
    documents = bytes(header) + bytes(table) + bytes(recs)
    assert sum(parts.values()) == len(documents)

    # Source v2.
    whole_reasons = {"no chunk": 0, "a chunk not an exact span": 0}
    srecs, maps, residual = bytearray(), bytearray(), bytearray()
    sparts = {"header": 48, "records: sha256": 0, "records: flags varint": 0, "records: text length varint": 0,
              "records: line count varint": 0, "records: chunk count varint": 0, "records: recipe varints": 0,
              "line maps (v1's varints)": 0, "residual: gap bytes of rebuilt files": 0,
              "residual: bytes of files kept whole": 0}
    stats = {"files": len(files), "retained": 0, "rebuilt": 0, "kept_whole": 0, "zero_chunk_retained": 0,
             "empty_files": 0, "overlaps": 0, "contained_chunks": 0, "gaps_nonzero": 0, "raw_ids": raw_ids,
             "inline_ids": len(records) - raw_ids, "kept_whole_bytes": 0, "gap_bytes": 0,
             "max_recipe_varint": 0,
             "hard_cases": {k: {"rebuilt": 0, "kept_whole": 0} for k in (
                 "bom", "no final newline", "cr lf", "lone cr", "other line breaks (vt ff fs gs rs nel ls ps)",
                 "empty")}}
    expected_files = []
    for f in files:
        if not f["retained"]:
            continue
        s = sources[f["source"]]
        body = s["bytes"]
        stats["retained"] += 1
        if not body:
            stats["empty_files"] += 1
        chunk_recs = records[f["first"]:f["first"] + f["chunks"]]
        offsets = None
        if chunk_recs:
            starts = line_starts(s["map"], s["lines"])
            offsets = [chunk_offset(body, starts, s["lines"], r) for r in chunk_recs]
            if any(o is None for o in offsets):
                offsets = None
                whole_reasons["a chunk not an exact span"] += 1
        else:
            stats["zero_chunk_retained"] += 1
            whole_reasons["no chunk"] += 1
        whole = offsets is None
        kind = "kept_whole" if whole else "rebuilt"
        hc = stats["hard_cases"]
        if body.startswith(b"\xef\xbb\xbf"):
            hc["bom"][kind] += 1
        if body and not body.endswith((b"\n", b"\r")):
            hc["no final newline"][kind] += 1
        if b"\r\n" in body:
            hc["cr lf"][kind] += 1
        if body.replace(b"\r\n", b"").find(b"\r") >= 0:
            hc["lone cr"][kind] += 1
        if any(c in body for c in (b"\x0b", b"\x0c", b"\x1c", b"\x1d", b"\x1e", b"\xc2\x85", b"\xe2\x80\xa8",
                                   b"\xe2\x80\xa9")):
            hc["other line breaks (vt ff fs gs rs nel ls ps)"][kind] += 1
        if not body:
            hc["empty"][kind] += 1
        flags = (1 if s["encoding"] == 1 else 0) | (2 if whole else 0)
        srecs += s["sha"]
        sparts["records: sha256"] += 32
        for name, value in (("records: flags varint", flags), ("records: text length varint", len(body)),
                            ("records: line count varint", s["lines"])):
            a = len(srecs)
            (put64 if name == "records: text length varint" else put)(srecs, value)
            sparts[name] += len(srecs) - a
        if whole:
            residual += body
            sparts["residual: bytes of files kept whole"] += len(body)
            stats["kept_whole"] += 1
            stats["kept_whole_bytes"] += len(body)
        else:
            lengths = [len(r["text"]) for r in chunk_recs]
            values, runs, _pos = recipe(offsets, lengths, len(body))
            a = len(srecs)
            put(srecs, len(chunk_recs))
            sparts["records: chunk count varint"] += len(srecs) - a
            a = len(srecs)
            for v in values:
                put(srecs, v)
                stats["max_recipe_varint"] = max(stats["max_recipe_varint"], v)
                if v % 2 == 1:
                    stats["overlaps"] += 1
                elif v:
                    stats["gaps_nonzero"] += 1
            sparts["records: recipe varints"] += len(srecs) - a
            # contained chunks: an overlap at least as long as the chunk
            pos = 0
            for v, length in zip(values, lengths):
                if v % 2 == 0:
                    pos += v // 2 + length
                else:
                    k = (v + 1) // 2
                    if k >= length:
                        stats["contained_chunks"] += 1
                    else:
                        pos += length - k
            for lo, hi in runs:
                residual += body[lo:hi]
                sparts["residual: gap bytes of rebuilt files"] += hi - lo
                stats["gap_bytes"] += hi - lo
            stats["rebuilt"] += 1
        maps += s["map"]
        sparts["line maps (v1's varints)"] += len(s["map"])
        expected_files.append((f["path"], body, s["sha"]))
    sheader = struct.pack("<8sHHIQQQQ", b"HYBSRC02", 2, 1, stats["retained"], len(srecs), len(maps), len(residual), 0)
    assert len(sheader) == 48
    source = bytes(sheader) + bytes(srecs) + bytes(maps) + bytes(residual)
    assert sum(sparts.values()) == len(source)
    stats["kept_whole_reasons"] = whole_reasons
    return {"documents": documents, "source": source if sources else None, "doc_parts": parts, "src_parts": sparts,
            "stats": stats, "records": records, "files": files, "expected": expected_files, "dims": dims,
            "old": {"documents": docs_path.stat().st_size, "source": src_path.stat().st_size if src_path else 0}}


# ------------------------------------------------------------------ the reader (from the format document)

DOC_HEADER = 56
SRC_HEADER = 48


def decode_documents(data: bytes, has_source: bool) -> dict:
    """Documents record v5: header, file table, records; every rule of the
    format document's "Validation, documents" list except the checksum."""
    if len(data) < DOC_HEADER:
        raise Refused("Truncated")
    if data[:8] != b"HYBSEG01":
        raise Refused("BadMagic")
    version, flags, doc_count, dims, file_count, table_bytes, rec_bytes, path_text, _checksum = \
        struct.unpack_from("<HHIIIQQQQ", data, 8)
    if version != 5:
        raise Refused("UnsupportedVersion")
    if flags != 1:
        raise Refused("UnsupportedFlags")
    total = DOC_HEADER + table_bytes + rec_bytes
    if len(data) < total:
        raise Refused("Truncated")
    if len(data) > total:
        raise Refused("TrailingData")
    # (checksum: not computed by the prototype)
    # Bounds before allocation.
    if table_bytes < 4 * file_count:
        raise Refused("InvalidFileTable")
    if path_text < file_count or path_text > SHARED_CAP * file_count + table_bytes:
        raise Refused("InvalidFileTable")
    if rec_bytes < 8 * doc_count:
        raise Refused("InvalidRecord")
    # Section 1: the file table.
    r = Reader(data, DOC_HEADER, DOC_HEADER + table_bytes, "InvalidFileTable")
    files, prev, decoded, chunks_total, retained = [], b"", 0, 0, 0
    file_at, record_at = [], []
    for i in range(file_count):
        file_at.append(r.at)
        shared = r.varint()
        if shared > SHARED_CAP or shared > len(prev) or (i == 0 and shared != 0):
            raise Refused("InvalidFileTable")
        suffix_len = r.varint()
        if suffix_len < 1:
            raise Refused("InvalidFileTable")
        suffix = r.take(suffix_len)
        if i > 0:
            if shared < len(prev) and shared < SHARED_CAP:
                if not suffix[0] > prev[shared]:
                    raise Refused("UnsortedPaths")
            elif shared < len(prev):  # shared == 255, prev longer: compare the rest
                if not suffix > prev[shared:]:
                    raise Refused("UnsortedPaths")
        path = prev[:shared] + suffix
        decoded += len(path)
        if decoded > path_text:
            raise Refused("InvalidFileTable")
        cr = r.varint()
        chunks, is_retained = cr >> 1, cr & 1
        if chunks == 0 and not is_retained:
            raise Refused("InvalidFileTable")
        if is_retained and not has_source:
            raise Refused("InvalidFileTable")
        files.append({"path": path, "chunks": chunks, "retained": bool(is_retained), "first": chunks_total,
                      "source_doc_index": retained if is_retained else 0xFFFFFFFF})
        chunks_total += chunks
        retained += is_retained
        if chunks_total > doc_count:
            raise Refused("InvalidFileTable")
        prev = path
    if r.at != r.end:
        raise Refused("TrailingData")
    if decoded != path_text or chunks_total != doc_count:
        raise Refused("InvalidFileTable")
    # Section 2: the records.
    r = Reader(data, DOC_HEADER + table_bytes, total, "InvalidRecord")
    records = []
    file_of = []
    for f in files:
        file_of += [f] * f["chunks"]
    for k in range(doc_count):
        f = file_of[k]
        record_at.append(r.at)
        rflags = r.varint()
        if rflags & ~7:
            raise Refused("UnsupportedFlags")
        if rflags & 1:
            identifier = r.take(r.varint())
        else:
            identifier = r.take(10).hex().encode()
        text_len = r.varint()
        start = r.varint()
        span = r.varint()
        chunker = r.varint()
        depth = r.varint()
        heading_back = r.varint()
        if start < 1 or start + span > MAX_U32 or chunker > 0xFFFF or depth > 0xFFFF:
            raise Refused("InvalidCitation" if start < 1 or start + span > MAX_U32 else "InvalidSection")
        if heading_back > start:
            raise Refused("InvalidSection")
        heading = 0 if heading_back == 0 else start - heading_back + 1
        sp_len = r.varint() if depth > 0 else 0
        labels = b""
        if rflags & 4:
            n = r.varint()
            if n < 1:
                raise Refused("InvalidRequiredLabels")
            labels = r.take(n)
            check_labels(labels)
        vector = b""
        if rflags & 2:
            if dims == 0:
                raise Refused("InvalidVectorDimensions")
            vector = r.take(4 * dims)
        text = r.take(text_len)
        section_path = r.take(sp_len)
        if depth == 0:
            pass
        elif section_path.count(b"\x1f") + 1 != depth:
            raise Refused("InvalidSection")
        if depth != 0 and heading == 0:
            raise Refused("InvalidSection")
        records.append({"id": identifier, "path": f["path"], "text": text, "start": start, "end": start + span,
                        "labels": labels, "vector": vector, "chunker": chunker, "depth": depth,
                        "heading": heading, "src": f["source_doc_index"], "section_path": section_path})
    if r.at != r.end:
        raise Refused("TrailingData")
    return {"files": files, "records": records, "retained": retained, "dims": dims, "file_at": file_at,
            "record_at": record_at}


def check_labels(labels: bytes) -> None:
    prev = None
    for label in labels.split(b"\n"):
        if not label or b"\x00" in label or b"\r" in label:
            raise Refused("InvalidRequiredLabels")
        if prev is not None and not prev < label:
            raise Refused("InvalidRequiredLabels")
        prev = label


VALID_PATH_BAD = (b"\x00", b"\n", b"\r")


def valid_path(path: bytes) -> bool:
    if not path or path[:1] == b"/" or any(b in path for b in VALID_PATH_BAD):
        return False
    return all(part not in (b"", b".", b"..") for part in path.split(b"/"))


def decode_source(data: bytes, docs: dict) -> dict:
    """Source v2: header, records (each bound to its file of the documents
    section), line maps, residual area; every structural rule. The per-file
    checks (SHA-256, BOM, line map against the bytes) run in `rebuild`."""
    if len(data) < SRC_HEADER:
        raise Refused("Truncated")
    if data[:8] != b"HYBSRC02":
        raise Refused("BadMagic")
    version, flags, file_count, rec_bytes, map_bytes, res_bytes, _checksum = struct.unpack_from("<HHIQQQQ", data, 8)
    if version != 2:
        raise Refused("UnsupportedVersion")
    if flags != 1:
        raise Refused("UnsupportedFlags")
    total = SRC_HEADER + rec_bytes + map_bytes + res_bytes
    if len(data) < total:
        raise Refused("Truncated")
    if len(data) > total:
        raise Refused("TrailingData")
    if file_count != docs["retained"]:
        raise Refused("SourceFileCountMismatch")
    if rec_bytes < 35 * file_count or map_bytes < file_count:
        raise Refused("InvalidFileTable")
    r = Reader(data, SRC_HEADER, SRC_HEADER + rec_bytes, "InvalidFileTable")
    retained_files = [f for f in docs["files"] if f["retained"]]
    out, res_at, record_at = [], 0, []
    m = Reader(data, SRC_HEADER + rec_bytes, SRC_HEADER + rec_bytes + map_bytes, "InvalidLineMap")
    for f in retained_files:
        if not valid_path(f["path"]):
            raise Refused("InvalidPath")
        record_at.append(r.at)
        sha = r.take(32)
        sflags = r.varint()
        if sflags & ~3:
            raise Refused("InvalidFileTable")
        text_len = r.varint64()
        lines = r.varint()
        whole = bool(sflags & 2)
        if f["chunks"] == 0 and not whole:
            raise Refused("InvalidFileTable")
        values = None
        if whole:
            residual_len = text_len
        else:
            if r.varint() != f["chunks"]:
                raise Refused("InvalidFileTable")
            values = [r.varint() for _ in range(f["chunks"])]
            lengths = [len(rec["text"]) for rec in docs["records"][f["first"]:f["first"] + f["chunks"]]]
            pos = gaps = 0
            for v, length in zip(values, lengths):
                if v % 2 == 0:
                    pos += v // 2 + length
                    gaps += v // 2
                else:
                    k = (v + 1) // 2
                    if k > pos:
                        raise Refused("InvalidFileTable")
                    pos += max(0, length - k)
                if pos > text_len:
                    raise Refused("InvalidFileTable")
            residual_len = gaps + (text_len - pos)
        if res_at + residual_len > res_bytes:
            raise Refused("InvalidFileTable")
        map_at = m.at
        for _ in range(lines + 1):
            read_u64_varint(m)
        out.append({"file": f, "sha": sha, "bom": bool(sflags & 1), "whole": whole, "length": text_len,
                    "lines": lines, "recipe": values, "residual": (res_at, res_at + residual_len),
                    "map": data[map_at:m.at]})
        res_at += residual_len
    if r.at != r.end:
        raise Refused("TrailingData")
    if m.at != m.end:
        raise Refused("InvalidLineMap")
    if res_at != res_bytes:
        raise Refused("InvalidFileTable")
    base = SRC_HEADER + rec_bytes + map_bytes
    return {"files": out, "residual": data[base:base + res_bytes], "record_at": record_at}


def rebuild(src: dict, docs: dict, entry: dict) -> bytes:
    """One file's bytes: its chunks' text and its residual bytes, then the
    SHA-256, the BOM flag and the line map checked against them."""
    lo, hi = entry["residual"]
    res = src["residual"][lo:hi]
    if entry["whole"]:
        out = bytes(res)
    else:
        f = entry["file"]
        recs = docs["records"][f["first"]:f["first"] + f["chunks"]]
        buf = bytearray()
        at = 0
        for v, rec in zip(entry["recipe"], recs):
            text = rec["text"]
            if v % 2 == 0:
                g = v // 2
                buf += res[at:at + g]
                at += g
                buf += text
            else:
                k = (v + 1) // 2
                if k < len(text):
                    buf += text[k:]
        buf += res[at:]
        out = bytes(buf)
    if len(out) != entry["length"]:
        raise Refused("SourceFileLengthMismatch")
    if hashlib.sha256(out).digest() != entry["sha"]:
        raise Refused("SourceFileSha256Mismatch")
    if entry["bom"] != out.startswith(b"\xef\xbb\xbf"):
        raise Refused("InvalidLineMap")
    m = Reader(entry["map"], 0, len(entry["map"]), "InvalidLineMap")
    starts, value = [], 0
    for _ in range(entry["lines"] + 1):
        value += read_u64_varint(m)
        starts.append(value)
    if m.at != m.end or starts != line_starts_of(out):
        raise Refused("InvalidLineMap")
    return out


BREAKS1 = {0x0A, 0x0B, 0x0C, 0x1C, 0x1D, 0x1E}


def line_starts_of(b: bytes) -> list[int]:
    i = 3 if b.startswith(b"\xef\xbb\xbf") else 0
    out, open_line = [], False
    while i < len(b):
        if not open_line:
            out.append(i)
            open_line = True
        c = b[i]
        w = 0
        if c in BREAKS1:
            w = 1
        elif c == 0x0D:
            w = 2 if i + 1 < len(b) and b[i + 1] == 0x0A else 1
        elif c == 0xC2 and i + 1 < len(b) and b[i + 1] == 0x85:
            w = 2
        elif c == 0xE2 and i + 2 < len(b) and b[i + 1] == 0x80 and b[i + 2] in (0xA8, 0xA9):
            w = 3
        if w:
            i += w
            open_line = False
        else:
            i += 1
    out.append(len(b))
    return out


# ------------------------------------------------------------------ commands

def cmd_encode(index: Path, out_dir: Path) -> dict:
    built = build(index)
    out_dir.mkdir(parents=True, exist_ok=True)
    (out_dir / "documents-v5.bin").write_bytes(built["documents"])
    if built["source"] is not None:
        (out_dir / "source-v2.bin").write_bytes(built["source"])
    docs = decode_documents(built["documents"], built["source"] is not None)
    # Every record field back as v4 had it.
    keys = ("id", "path", "text", "start", "end", "labels", "vector", "chunker", "depth", "heading", "src",
            "section_path")
    mismatched = sum(1 for a, b in zip(built["records"], docs["records"]) if any(a[k] != b[k] for k in keys))
    if len(docs["records"]) != len(built["records"]) or mismatched:
        raise SystemExit(f"documents round trip failed: {mismatched} records differ")
    rebuilt = mismatches = whole = 0
    if built["source"] is not None:
        src = decode_source(built["source"], docs)
        for entry, (path, original, sha) in zip(src["files"], built["expected"]):
            got = rebuild(src, docs, entry)
            if entry["file"]["path"] != path or got != original or hashlib.sha256(got).digest() != sha:
                mismatches += 1
            if entry["whole"]:
                whole += 1
            else:
                rebuilt += 1
    st = built["stats"]
    old_total = sum(p.stat().st_size for p in index.iterdir() if p.is_file())
    new_docs, new_src = len(built["documents"]), len(built["source"] or b"")
    table = sum(v for k, v in built["doc_parts"].items() if k.startswith("file table"))
    return {
        "index": index.name,
        "documents_v4": built["old"]["documents"], "documents_v5": new_docs,
        "source_v1": built["old"]["source"], "source_v2": new_src,
        "file_table_bytes": table,
        "index_before": old_total,
        "index_after": old_total - built["old"]["documents"] - built["old"]["source"] + new_docs + new_src,
        "documents_parts": built["doc_parts"], "source_parts": built["src_parts"],
        "stats": st,
        "round_trip": {"records": len(docs["records"]), "record_fields_differing": mismatched,
                       "files_checked": rebuilt + whole, "rebuilt_from_chunks": rebuilt, "kept_whole": whole,
                       "mismatches": mismatches,
                       "checks": "every file rebuilt and compared byte for byte with the v1 section's bytes, "
                                 "its SHA-256, BOM flag and line map; every v5 record field equals v4's"},
        "checksum": "not computed (written as zero; the decoder skips that one check)",
    }


def main(argv: list[str]) -> int:
    if len(argv) >= 4 and argv[1] == "encode":
        result = cmd_encode(Path(argv[2]), Path(argv[3]))
        text = json.dumps(result, indent=1)
        if "--json" in argv:
            Path(argv[argv.index("--json") + 1]).write_text(text + "\n")
        print(text)
        return 0
    if len(argv) == 3 and argv[1] == "selftest":
        from text_once_selftest import run  # noqa: E402 (beside this file)
        return run(Path(argv[2]))
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    sys.exit(main(sys.argv))
