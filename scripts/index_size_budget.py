#!/usr/bin/env python3
"""S6-T3: where an index directory's bytes go, and what each remedy would save.

Reads a `searchd` index directory (one generation, the one `MANIFEST` binds)
section by section, by the layouts in the format documents
(`docs/segment-format-v4.md`, `docs/lexical-segment-format-v2.md` and v1,
`docs/source-section-v1.md`, `docs/state-section-format-v2.md`,
`docs/filename-field-format-v1.md`, `docs/manifest-format-v2.md`), and splits
every file into parts. The parts of each file are checked to sum to its size
(`budget` refuses otherwise), so every byte is accounted for.

Commands (each prints a JSON document; `--out FILE` writes it there too):

    python3 -I scripts/index_size_budget.py budget INDEX_DIR [--out FILE]
    python3 -I scripts/index_size_budget.py duplication INDEX_DIR [--out FILE]
    python3 -I scripts/index_size_budget.py candidates INDEX_DIR [--lz4] [--out FILE]
    python3 -I scripts/index_size_budget.py codec-blocks INDEX_DIR --blocks-dir DIR
    python3 -I scripts/index_size_budget.py tables RAW_DIR [--out FILE]

- `budget`: bytes per file and per part; counts (chunks, terms, postings,
  tokens, files).
- `duplication`: text stored more than once, measured: chunk text against
  the source section's bytes (each chunk located in its file's lines by the
  line map), chunk overlap inside the documents section, and the fields the
  state, source, documents and file-name sections share.
- `candidates`: prototype re-encodings of the existing section bytes (no
  engine change): chunk records that refer to source spans, a block-
  compressed source text area (deflate from the standard library, and with
  `--lz4` an LZ4-style block coder written below), tighter dictionary,
  posting, length and position coding, positions left out, a state section
  that refers to the source table. Each candidate's bytes are produced by an
  encoder here and counted, and the span candidate is decoded back and
  compared with every chunk's stored text.

Invented corpora only; nothing here reads outside the index directory.
"""
import argparse
import array
import hashlib
import json
import struct
import sys
import time
import zlib
from pathlib import Path

LE = sys.byteorder == "little"


# ---------------------------------------------------------------- varints

def vlen(value: int) -> int:
    """Bytes of `value` as an unsigned LEB128 varint."""
    return 1 if value < 0x80 else (value.bit_length() + 6) // 7


def put_varint(out: bytearray, value: int) -> None:
    while value >= 0x80:
        out.append((value & 0x7F) | 0x80)
        value >>= 7
    out.append(value)


def read_varint(buf, pos: int):
    result = shift = 0
    while True:
        byte = buf[pos]
        pos += 1
        result |= (byte & 0x7F) << shift
        if byte < 0x80:
            return result, pos
        shift += 7


def u32_array(data: bytes) -> array.array:
    values = array.array("I")
    values.frombytes(data)
    if not LE:
        values.byteswap()
    return values


# ---------------------------------------------------------------- sections

class Budget:
    """Named parts of one file; `check` proves they sum to its size."""

    def __init__(self, name: str, size: int):
        self.name, self.size, self.parts, self.counts = name, size, {}, {}

    def add(self, part: str, nbytes: int) -> None:
        self.parts[part] = self.parts.get(part, 0) + nbytes

    def check(self) -> None:
        total = sum(self.parts.values())
        if total != self.size:
            raise SystemExit(f"{self.name}: parts sum to {total}, file is {self.size}")

    def as_json(self) -> dict:
        return {"file": self.name, "bytes": self.size, "parts": self.parts, "counts": self.counts}


def parse_segment(data: bytes, name: str):
    """HYBSEG01 (record v3 or v4): the budget and the decoded records."""
    if data[:8] != b"HYBSEG01":
        raise SystemExit(f"{name}: not HYBSEG01")
    version, _flags, count, dims, payload = struct.unpack_from("<HHIIQ", data, 8)
    if 36 + payload != len(data):
        raise SystemExit(f"{name}: payload length mismatch")
    b = Budget(name, len(data))
    b.add("header", 36)
    records = []
    pos = 36
    for _ in range(count):
        if version >= 4:
            (id_len, path_len, text_len, vec_len, start, end, lab_len, chunker, depth,
             heading, src_index, sp_len) = struct.unpack_from("<IIIIIIIHHIII", data, pos)
            fixed = 44
            b.add("record lengths (id, path, text, vector, labels, section path: 6 x u32)", 24)
            b.add("record lines (start, end, heading: 3 x u32)", 12)
            b.add("record chunker index and section depth (2 x u16)", 4)
            b.add("record source_doc_index (u32)", 4)
        else:
            id_len, path_len, text_len, vec_len, start, end, lab_len = struct.unpack_from("<IIIIIII", data, pos)
            chunker = depth = heading = 0
            src_index, sp_len = 0xFFFFFFFF, 0
            fixed = 28
            b.add("record lengths (id, path, text, vector, labels: 5 x u32)", 20)
            b.add("record lines (start, end: 2 x u32)", 8)
        pos += fixed
        rid = data[pos:pos + id_len]; pos += id_len
        path = data[pos:pos + path_len]; pos += path_len
        text = data[pos:pos + text_len]; pos += text_len
        pos += lab_len
        pos += vec_len * 4
        section_path = data[pos:pos + sp_len]; pos += sp_len
        b.add("chunk ids (20 hex)", id_len)
        b.add("paths", path_len)
        b.add("chunk text", text_len)
        b.add("required labels", lab_len)
        b.add("vectors", vec_len * 4)
        b.add("section paths (heading texts)", sp_len)
        records.append({"id": rid, "path": path, "text": text, "start": start, "end": end,
                        "src": src_index, "sp_len": sp_len, "lab_len": lab_len,
                        "heading": heading, "chunker": chunker, "depth": depth, "vec": vec_len})
    if pos != len(data):
        raise SystemExit(f"{name}: trailing bytes")
    b.counts = {"record_version": version, "records": count, "vector_dimensions": dims}
    b.check()
    return b, records


def parse_lexical(data: bytes, name: str):
    """HYBLEX01 or HYBLEX02: the budget and the decoded index."""
    magic = data[:8]
    if magic == b"HYBLEX02":
        (_v, _f, docs, terms, postings, _avg, s1, s2, s3, s4, s5) = struct.unpack_from("<HHIIQIQQQQQ", data, 8)
        header = 80
    elif magic == b"HYBLEX01":
        (_v, _f, docs, terms, postings, _avg, s1, s2, s3) = struct.unpack_from("<HHIIQIQQQ", data, 8)
        s4 = s5 = 0
        header = 64
    else:
        raise SystemExit(f"{name}: not HYBLEX01/02")
    b = Budget(name, len(data))
    b.add("header", header)
    pos = header
    doc_lengths = u32_array(data[pos:pos + s1]); pos += s1
    b.add("1 document lengths (u32 each)", s1)
    dict_start = pos
    term_list, dfs = [], []
    for _ in range(terms):
        tlen, df, _start, _count = struct.unpack_from("<IIQQ", data, pos)
        pos += 24
        term_list.append(data[pos:pos + tlen]); pos += tlen
        dfs.append(df)
    if pos - dict_start != s2:
        raise SystemExit(f"{name}: dictionary length mismatch")
    term_bytes = sum(len(t) for t in term_list)
    b.add("2 dictionary: term length + df (2 x u32)", 8 * terms)
    b.add("2 dictionary: posting start + count (2 x u64)", 16 * terms)
    b.add("2 dictionary: term bytes", term_bytes)
    pairs = u32_array(data[pos:pos + s3]); pos += s3
    b.add("3 postings: document index (u32)", s3 // 2)
    b.add("3 postings: term frequency (u32)", s3 // 2)
    counts = {"documents": docs, "terms": terms, "postings": postings, "tokens": sum(doc_lengths),
              "term_bytes": term_bytes}
    lex = {"doc_lengths": doc_lengths, "terms": term_list, "dfs": dfs, "doc_ids": pairs[0::2],
           "tfs": pairs[1::2], "positions": b"", "offsets": b""}
    if s4:
        # Per posting, its tf ordinals as varints: the first absolute, the
        # rest gaps. No count is stored; the posting's tf gives it.
        region = data[pos:pos + s4]
        ends = [i for i, byte in enumerate(region) if byte < 0x80]
        if len(ends) != sum(lex["tfs"]) or (ends and ends[-1] != len(region) - 1):
            raise SystemExit(f"{name}: positions do not parse")
        first_bytes = 0
        k = 0
        prev_end = -1
        for tf in lex["tfs"]:
            first_bytes += ends[k] - prev_end
            k += tf
            prev_end = ends[k - 1]
        b.add("4 positions: first ordinal per posting (varint)", first_bytes)
        b.add("4 positions: later ordinal gaps (varints)", s4 - first_bytes)
        lex["positions"] = region
        pos += s4
    if s5:
        region = data[pos:pos + s5]
        p = 0
        start_bytes = length_bytes = 0
        for _ in range(docs):
            (n,) = struct.unpack_from("<I", region, p)
            p += 4
            for _ in range(n):
                q = p
                while region[p] >= 0x80:
                    p += 1
                p += 1
                start_bytes += p - q
                q = p
                while region[p] >= 0x80:
                    p += 1
                p += 1
                length_bytes += p - q
        if p != s5:
            raise SystemExit(f"{name}: offsets do not parse")
        b.add("5 offsets: token count per document (u32)", 4 * docs)
        b.add("5 offsets: start gap varints", start_bytes)
        b.add("5 offsets: length varints", length_bytes)
        lex["offsets"] = region
        pos += s5
    if pos != len(data):
        raise SystemExit(f"{name}: trailing bytes")
    b.counts = counts
    b.check()
    return b, lex


def parse_source(data: bytes, name: str):
    if data[:8] != b"HYBSRC01":
        raise SystemExit(f"{name}: not HYBSRC01")
    _v, _f, file_count, table_bytes, map_bytes, text_bytes = struct.unpack_from("<HHIQQQ", data, 8)
    b = Budget(name, len(data))
    b.add("header", 48)
    pos = 48
    files = []
    path_total = 0
    for _ in range(file_count):
        plen, toff, tlen, lines, moff = struct.unpack_from("<IQQIQ", data, pos)
        sha = data[pos + 32:pos + 64]
        encoding = data[pos + 64]
        pos += 68
        path = data[pos:pos + plen]; pos += plen
        path_total += plen
        files.append({"path": path, "toff": toff, "tlen": tlen, "lines": lines, "moff": moff,
                      "sha": sha, "encoding": encoding})
    b.add("file table: offsets, lengths, line count (u32 + 3 x u64 + u32)", 32 * file_count)
    b.add("file table: sha256 (32 bytes)", 32 * file_count)
    b.add("file table: encoding + reserved (4 bytes)", 4 * file_count)
    b.add("file table: paths", path_total)
    if pos != 48 + table_bytes:
        raise SystemExit(f"{name}: table length mismatch")
    maps = data[pos:pos + map_bytes]; pos += map_bytes
    b.add("line maps (varints)", map_bytes)
    text = data[pos:pos + text_bytes]; pos += text_bytes
    b.add("text (original file bytes)", text_bytes)
    if pos != len(data):
        raise SystemExit(f"{name}: trailing bytes")
    b.counts = {"files": file_count, "lines": sum(f["lines"] for f in files)}
    b.check()
    return b, {"files": files, "maps": maps, "text": text}


def parse_state(data: bytes, name: str):
    b = Budget(name, len(data))
    if data[:8] != b"HYBSTA02":
        b.add("JSON payload (HYBSTA01)" if data[:8] == b"HYBSTA01" else "unknown", len(data))
        b.check()
        return b, None
    b.add("header", 32)
    p = 32
    (_sv, _r, _gen, _an, strings, roots, files, label_refs, _r2) = struct.unpack_from("<IIQIIIIII", data, p)
    p += 40
    b.add("payload header", 40)
    lengths = struct.unpack_from(f"<{strings}I", data, p)
    b.add("string table", 4 * strings + sum(lengths))
    p += 4 * strings + sum(lengths)
    b.add("roots (24 bytes each)", 24 * roots)
    p += 24 * roots
    recs = []
    for _ in range(files):
        (root, flags, size, mtime, chunks, chunker, labels, plen, mlen) = struct.unpack_from("<IIQqIIIII", data, p)
        sha = data[p + 44:p + 76]
        recs.append({"size": size, "chunks": chunks, "plen": plen, "mlen": mlen, "sha": sha,
                     "flags": flags})
        p += 76
    b.add("file records: sha256 (32 bytes)", 32 * files)
    b.add("file records: root, flags, size, mtime, chunks, chunker, labels, lengths (44 bytes)", 44 * files)
    b.add("label references", 4 * label_refs)
    p += 4 * label_refs
    paths = []
    for rec in recs:
        paths.append(data[p:p + rec["plen"]])
        p += rec["plen"] + rec["mlen"]
    b.add("paths (and moved_from)", sum(r["plen"] + r["mlen"] for r in recs))
    if p != len(data):
        raise SystemExit(f"{name}: trailing bytes ({p} of {len(data)})")
    b.counts = {"files": files, "strings": strings, "roots": roots}
    b.check()
    return b, {"records": recs, "paths": paths}


def load_index(index: Path) -> dict:
    """Every file of the directory, parsed where its kind is known."""
    manifest = (index / "MANIFEST").read_bytes()
    out = {"budgets": [], "files": {}}
    for path in sorted(index.iterdir()):
        if not path.is_file():
            continue
        data = path.read_bytes()
        name = path.name
        if name.startswith("documents-") and name.endswith(".hybseg"):
            out["documents"] = parse_segment(data, name)
            budget = out["documents"][0]
        elif name.startswith("filenames-") and name.endswith(".hybseg"):
            out["catalog"] = parse_segment(data, name)
            budget = out["catalog"][0]
        elif name.startswith("lexical-") and name.endswith(".hyblex"):
            budget, out["lexical"] = parse_lexical(data, name)
        elif name.startswith("filename-lexical-") and name.endswith(".hyblex"):
            budget, out["filename_lexical"] = parse_lexical(data, name)
        elif name.startswith("source-") and name.endswith(".hybsrc"):
            budget, out["source"] = parse_source(data, name)
        elif name.startswith("state-") and name.endswith(".hybstate"):
            budget, out["state"] = parse_state(data, name)
        else:
            budget = Budget(name, len(data))
            budget.add("whole file", len(data))
        out["budgets"].append(budget)
        out["files"][name] = budget
    if b"documents-1" not in manifest and not any(n.startswith("documents-") for n in out["files"]):
        raise SystemExit("no documents section")
    out["total"] = sum(b.size for b in out["budgets"])
    return out


# ---------------------------------------------------------------- budget

def cmd_budget(index: Path) -> dict:
    loaded = load_index(index)
    return {"index": index.name, "total_bytes": loaded["total"],
            "files": [b.as_json() for b in loaded["budgets"]]}


# ---------------------------------------------------------------- duplication

def line_starts(maps: bytes, f: dict) -> list:
    """Line-start offsets of one file, with its length last (line_count + 1 values)."""
    p = f["moff"]
    value = 0
    out = []
    for _ in range(f["lines"] + 1):
        gap, p = read_varint(maps, p)
        value += gap
        out.append(value)
    return out


def locate_chunks(loaded: dict) -> list:
    """For every chunk record, (file index, byte offset in the file) when its
    text is a contiguous run of its file's bytes inside its own lines, else
    None. Proves the span candidate: the text is recoverable from source."""
    src = loaded["source"]
    files, text, maps = src["files"], src["text"], src["maps"]
    starts_cache = {}
    located = []
    for rec in loaded["documents"][1]:
        i = rec["src"]
        if i == 0xFFFFFFFF or i >= len(files):
            located.append(None)
            continue
        f = files[i]
        if i not in starts_cache:
            starts_cache.clear()
            starts_cache[i] = line_starts(maps, f)
        starts = starts_cache[i]
        body = text[f["toff"]:f["toff"] + f["tlen"]]
        lo = starts[rec["start"] - 1]
        hi = starts[min(rec["end"], f["lines"])]
        at = body.find(rec["text"], lo, hi)
        located.append((i, at) if at >= 0 else None)
    return located


def cmd_duplication(index: Path) -> dict:
    loaded = load_index(index)
    budget_docs, records = loaded["documents"]
    src = loaded.get("source")
    out = {"index": index.name, "total_bytes": loaded["total"]}
    text_bytes = sum(len(r["text"]) for r in records)
    out["chunk_text_bytes"] = text_bytes
    out["source_text_bytes"] = len(src["text"]) if src else 0
    if src:
        located = locate_chunks(loaded)
        in_source = [(r, loc) for r, loc in zip(records, located) if loc is not None]
        out["chunks"] = len(records)
        out["chunks_found_in_source"] = len(in_source)
        out["chunk_text_bytes_found_in_source"] = sum(len(r["text"]) for r, _ in in_source)
        out["chunk_text_bytes_not_found"] = text_bytes - out["chunk_text_bytes_found_in_source"]
        # Overlap: per file, bytes covered by more than one chunk.
        by_file = {}
        for r, (i, at) in in_source:
            by_file.setdefault(i, []).append((at, at + len(r["text"])))
        covered = 0
        for spans in by_file.values():
            spans.sort()
            end = -1
            for a, z in spans:
                if a > end:
                    covered += z - a
                    end = z
                elif z > end:
                    covered += z - end
                    end = z
        out["distinct_file_bytes_covered_by_chunks"] = covered
        out["chunk_overlap_bytes"] = out["chunk_text_bytes_found_in_source"] - covered
        out["source_bytes_not_in_any_chunk"] = len(src["text"]) - covered
    # Paths, ids and hashes held by more than one section.
    paths_docs = sum(len(r["path"]) for r in records)
    distinct_paths = {r["path"] for r in records}
    out["paths"] = {
        "documents (one per chunk)": paths_docs,
        "distinct paths in documents": sum(len(p) for p in distinct_paths),
        "source file table": sum(len(f["path"]) for f in src["files"]) if src else 0,
    }
    state = loaded.get("state")
    if state:
        out["paths"]["state"] = sum(len(p) for p in state["paths"])
        out["state_repeats"] = {
            "sha256 also in source table (32 B per file)": 32 * len(state["records"]),
            "paths also in source table": sum(len(p) for p in state["paths"]),
            "size also source text_length (8 B per file)": 8 * len(state["records"]),
            "chunks count also derivable from documents (4 B per file)": 4 * len(state["records"]),
            "chunker also in documents chunker_index (4 B per file)": 4 * len(state["records"]),
        }
        if src:
            same_sha = sum(1 for rec, f in zip(state["records"], src["files"]) if rec["sha"] == f["sha"])
            out["state_repeats"]["files whose state sha256 equals the source table's"] = same_sha
    if "catalog" in loaded:
        _, cat = loaded["catalog"]
        out["filename_catalog_repeats"] = {
            "paths": sum(len(r["path"]) for r in cat),
            "chunk ids copied from body anchors": sum(len(r["id"]) for r in cat),
            "stems (record text, derivable from paths)": sum(len(r["text"]) for r in cat),
            "records": len(cat),
        }
    lex = loaded["lexical"]
    out["dictionary_redundant"] = {
        "posting count equals df (u64 per term)": 8 * len(lex["terms"]),
        "posting start equals running sum of counts (u64 per term)": 8 * len(lex["terms"]),
    }
    out["section_paths_bytes"] = sum(r["sp_len"] for r in records)
    return out


# ---------------------------------------------------------------- candidates

def _lz4_extra(out: bytearray, value: int) -> None:
    value -= 15
    while value >= 255:
        out.append(255)
        value -= 255
    out.append(value)


def lz4_compress(data: bytes) -> bytes:
    """`data` as one LZ4 block (the LZ4 block format: token, literal-length
    extension, literals, 16-bit offset, match-length extension; greedy, a
    4-byte hash, 64 KiB window, the last five bytes literals). A stand-in for
    a small in-tree codec; `codec-blocks` writes it for the Zig probe, which
    decodes it and compares every byte."""
    n = len(data)
    out = bytearray()
    table = {}
    anchor = 0
    i = 0
    limit = n - 12
    while i < limit:
        key = data[i:i + 4]
        candidate = table.get(key)
        table[key] = i
        if candidate is not None and i - candidate < 65536:
            length = 4
            while i + length < n - 5 and data[candidate + length] == data[i + length]:
                length += 1
            literals = i - anchor
            out.append((min(literals, 15) << 4) | min(length - 4, 15))
            if literals >= 15:
                _lz4_extra(out, literals)
            out += data[anchor:i]
            out += (i - candidate).to_bytes(2, "little")
            if length - 4 >= 15:
                _lz4_extra(out, length - 4)
            for j in range(i + 1, min(i + length, limit)):
                table[data[j:j + 4]] = j
            i += length
            anchor = i
        else:
            i += 1
    literals = n - anchor
    out.append(min(literals, 15) << 4)
    if literals >= 15:
        _lz4_extra(out, literals)
    out += data[anchor:]
    return bytes(out)


def lz4_block_size(data: bytes) -> int:
    return len(lz4_compress(data))


def compress_blocks(text: bytes, block: int, level: int) -> dict:
    """Raw deflate per block; block table 8 B per block (compressed offset u32,
    compressed length u32)."""
    total = 0
    count = 0
    started = time.perf_counter()
    blocks = []
    for at in range(0, len(text), block):
        piece = text[at:at + block]
        c = zlib.compressobj(level, zlib.DEFLATED, -15)
        packed = c.compress(piece) + c.flush()
        blocks.append(packed)
        total += len(packed)
        count += 1
    compress_s = time.perf_counter() - started
    started = time.perf_counter()
    for packed in blocks:
        zlib.decompress(packed, -15)
    decompress_s = time.perf_counter() - started
    return {"block_bytes": block, "level": level, "blocks": count, "compressed": total,
            "block_table": 8 * count, "section_text_after": total + 8 * count,
            "compress_ms": round(compress_s * 1000, 1),
            "decompress_ms_all": round(decompress_s * 1000, 1),
            "decompress_us_per_block": round(decompress_s * 1e6 / max(count, 1), 1)}


def per_file_compress(src: dict, level: int) -> dict:
    total = 0
    text = src["text"]
    for f in src["files"]:
        piece = text[f["toff"]:f["toff"] + f["tlen"]]
        c = zlib.compressobj(level, zlib.DEFLATED, -15)
        total += len(c.compress(piece) + c.flush())
    return {"per_file_level": level, "compressed": total, "file_table_extra": 8 * len(src["files"]),
            "section_text_after": total + 8 * len(src["files"])}


def file_aligned_compress(src: dict, block: int, level: int) -> dict:
    """Raw deflate of blocks that hold whole files: consecutive files are
    packed until the next would pass `block` bytes; a file larger than
    `block` is cut into `block`-sized pieces of its own. A one-file update
    then recompresses only the blocks of the changed file (and its packed
    neighbours). Block table 8 B per block."""
    text = src["text"]
    pieces = []
    current = 0
    start = 0
    for f in src["files"]:
        if f["tlen"] > block:
            if current:
                pieces.append((start, current))
            for at in range(0, f["tlen"], block):
                pieces.append((f["toff"] + at, min(block, f["tlen"] - at)))
            start, current = f["toff"] + f["tlen"], 0
            continue
        if current and current + f["tlen"] > block:
            pieces.append((start, current))
            start, current = f["toff"], 0
        if not current:
            start = f["toff"]
        current += f["tlen"]
    if current:
        pieces.append((start, current))
    if sum(n for _, n in pieces) != len(text):
        raise SystemExit("file-aligned blocks do not cover the text")
    total = 0
    for at, n in pieces:
        c = zlib.compressobj(level, zlib.DEFLATED, -15)
        total += len(c.compress(text[at:at + n]) + c.flush())
    return {"block_bytes": block, "level": level, "blocks": len(pieces), "compressed": total,
            "block_table": 8 * len(pieces), "section_text_after": total + 8 * len(pieces)}


def deflate_size(data: bytes) -> int:
    c = zlib.compressobj(6, zlib.DEFLATED, -15)
    return len(c.compress(bytes(data)) + c.flush())


def lexical_coding(lex: dict, lb: "Budget") -> dict:
    """C1-C6 on one lexical section: each re-encoding's bytes, counted."""
    terms, dfs = lex["terms"], lex["dfs"]
    front = 0
    prev = b""
    for t, df in zip(terms, dfs):
        shared = 0
        limit = min(len(prev), len(t))
        while shared < limit and prev[shared] == t[shared]:
            shared += 1
        front += vlen(shared) + vlen(len(t) - shared) + (len(t) - shared) + vlen(df)
        prev = t
    dict_before = sum(v for k, v in lb.parts.items() if k.startswith("2 "))
    plain_varint_dict = sum(vlen(len(t)) + len(t) + vlen(df) for t, df in zip(terms, dfs))
    gaps = tf_v = folded = 0
    start = 0
    ids, tfs = lex["doc_ids"], lex["tfs"]
    for df in dfs:
        last = -1
        for k in range(start, start + df):
            d = ids[k]
            gap = d - last - 1 if last >= 0 else d
            gaps += vlen(gap)
            last = d
            tf = tfs[k]
            tf_v += vlen(tf)
            folded += vlen((gap << 1) | (1 if tf == 1 else 0)) + (0 if tf == 1 else vlen(tf))
        start += df
    postings_before = 8 * len(ids)
    lengths_before = 4 * len(lex["doc_lengths"])
    lengths_v = sum(vlen(x) for x in lex["doc_lengths"])
    positions_before = len(lex["positions"])
    offsets_before = len(lex["offsets"])
    out = {
        "lexical_before": lb.size,
        "C1 dictionary: front-coded terms + df varint (start, count derived)": {
            "before": dict_before, "after": front, "saved": dict_before - front,
            "without front coding (length + bytes + df varints)": plain_varint_dict},
        "C2 postings: document gap varint + tf varint": {
            "before": postings_before, "after": gaps + tf_v, "saved": postings_before - gaps - tf_v,
            "gap_varint_bytes": gaps, "tf_varint_bytes": tf_v},
        "C2b postings: gap varint with tf==1 folded into its low bit, else + tf varint": {
            "before": postings_before, "after": folded, "saved": postings_before - folded},
        "C3 document lengths as varints": {"before": lengths_before, "after": lengths_v,
                                            "saved": lengths_before - lengths_v},
        "C5 offsets section left out (highlights re-tokenized from the hit text)": {
            "before": offsets_before, "saved": offsets_before},
        "C6 positions and offsets both left out (no phrase find)": {
            "before": positions_before + offsets_before, "saved": positions_before + offsets_before},
        "deflate of each part (reference: what redundancy is left)": {
            "postings": deflate_size(lex["doc_ids"].tobytes()) + deflate_size(lex["tfs"].tobytes()),
            "positions": deflate_size(lex["positions"]) if positions_before else 0,
            "offsets": deflate_size(lex["offsets"]) if offsets_before else 0,
        },
    }
    c_saved = (dict_before - front) + (postings_before - folded) + (lengths_before - lengths_v)
    out["C1+C2b+C3 saved"] = c_saved
    out["C1+C2b+C3+C5 saved"] = c_saved + offsets_before
    return out


def cmd_candidates(index: Path, lz4: bool) -> dict:
    loaded = load_index(index)
    total = loaded["total"]
    out = {"index": index.name, "total_bytes": total, "candidates": {}}
    cand = out["candidates"]
    docs_budget, records = loaded["documents"]
    src = loaded.get("source")
    n = len(records)

    # A. Chunk records refer to source spans.
    if src:
        located = locate_chunks(loaded)
        # Round trip: rebuild every span-referenced chunk's text from the source.
        text = src["text"]
        for r, loc in zip(records, located):
            if loc is None:
                continue
            f = src["files"][loc[0]]
            start = f["toff"] + loc[1]
            if text[start:start + len(r["text"])] != r["text"]:
                raise SystemExit("span round trip failed")
        spanned = [(r, loc) for r, loc in zip(records, located) if loc is not None]
        text_saved = sum(len(r["text"]) for r, _ in spanned)
        a1 = docs_budget.size - text_saved + 4 * n
        path_saved = sum(len(r["path"]) for r, _ in spanned)
        a2 = a1 - path_saved
        a3 = a2 - 10 * n
        # A4: every fixed field as a varint (the ten u32 fields and two u16,
        # plus the new span offset), text length kept as the span length.
        fixed_varint = 0
        for r, loc in zip(records, located):
            fields = [len(r["id"]) // 2, 0 if loc else len(r["path"]), len(r["text"]), r["vec"],
                      r["start"], r["end"] - r["start"], r["lab_len"], r["chunker"], r["depth"],
                      r["heading"], r["src"] if r["src"] != 0xFFFFFFFF else 0, r["sp_len"],
                      loc[1] if loc else 0]
            fixed_varint += sum(vlen(v) for v in fields)
        a4 = a3 - (48 * n) + fixed_varint
        cand["A chunk text as source spans"] = {
            "documents_before": docs_budget.size,
            "chunks_spanned": len(spanned), "chunks_inline": n - len(spanned),
            "A1 text replaced by a u32 span offset": a1,
            "A2 + path dropped (from the source table)": a2,
            "A3 + chunk id as 10 raw bytes": a3,
            "A4 + fixed fields as varints": a4,
            "saved_A1": docs_budget.size - a1, "saved_A1_to_A4": docs_budget.size - a4,
            "round_trip": "every spanned chunk's text rebuilt from the source equals the stored text",
        }

    # B. Source text block-compressed.
    if src:
        text = src["text"]
        rows = [compress_blocks(text, block, 6) for block in (16384, 65536, 262144)]
        rows.append(compress_blocks(text, 65536, 1))
        rows.append(compress_blocks(text, 65536, 9))
        b = {"text_before": len(text), "deflate": rows, "per_file": per_file_compress(src, 6),
             "file_aligned_64k": file_aligned_compress(src, 65536, 6),
             "file_aligned_16k": file_aligned_compress(src, 16384, 6)}
        if lz4:
            started = time.perf_counter()
            lz = sum(lz4_block_size(text[at:at + 65536]) for at in range(0, len(text), 65536))
            blocks = (len(text) + 65535) // 65536
            b["lz4_style_64k"] = {"compressed": lz, "block_table": 8 * blocks,
                                  "section_text_after": lz + 8 * blocks,
                                  "python_seconds": round(time.perf_counter() - started, 1)}
        cand["B source text block-compressed"] = b

    # C. Lexical coding.
    lex = loaded["lexical"]
    lb = loaded["files"][next(k for k in loaded["files"] if k.startswith("lexical-"))]
    cand["C lexical coding"] = lexical_coding(lex, lb)
    if "filename_lexical" in loaded:
        fb = loaded["files"][next(k for k in loaded["files"] if k.startswith("filename-lexical-"))]
        cand["F2 filename lexical section, same coding"] = lexical_coding(loaded["filename_lexical"], fb)

    # D. State that refers to the source table.
    state = loaded.get("state")
    if state and src:
        recs = state["records"]
        # Paths, sha256 and size are the source table's for every file that
        # has source bytes (matched by path in the same sorted order).
        src_by_path = {f["path"]: f for f in src["files"]}
        shared = [(r, p) for r, p in zip(recs, state["paths"])
                  if p in src_by_path and src_by_path[p]["sha"] == r["sha"]]
        saved = sum(32 + len(p) + 8 for _, p in shared)
        sb = loaded["files"][next(k for k in loaded["files"] if k.startswith("state-"))]
        cand["D state refers to the source table"] = {
            "state_before": sb.size, "files_shared": len(shared), "files": len(recs),
            "saved (sha256 + path + size per shared file)": saved,
            "deflate of the whole state section (reference)": deflate_size(
                (index / sb.name).read_bytes())}

    # E. Filename catalog without the stems and ids it can derive.
    if "catalog" in loaded:
        cb, cat = loaded["catalog"]
        derivable = sum(len(r["text"]) + len(r["id"]) for r in cat)
        cand["F filename catalog without derivable bytes"] = {
            "catalog_before": cb.size,
            "saved (stem text and copied chunk ids)": derivable,
            "note": "a catalog record could be (body anchor ordinal) only; paths, stems, "
                    "ids, lines and labels are the anchor chunk's"}
    return out


def cmd_codec_blocks(index: Path, out_dir: Path) -> dict:
    """Write the source text area (`plain.bin`) and its 64 KiB blocks
    (`blocks.bin`: per block u32 plain length, u32 deflate length, u32 LZ4
    length, the raw-deflate bytes (zlib level 6), the LZ4 bytes) for the Zig
    probe in `scripts/prototypes/s6t3/`."""
    loaded = load_index(index)
    text = loaded["source"]["text"]
    out_dir.mkdir(parents=True, exist_ok=True)
    blob = bytearray()
    deflated = lz = 0
    for at in range(0, len(text), 65536):
        piece = text[at:at + 65536]
        c = zlib.compressobj(6, zlib.DEFLATED, -15)
        d = c.compress(piece) + c.flush()
        z = lz4_compress(piece)
        blob += struct.pack("<III", len(piece), len(d), len(z)) + d + z
        deflated += len(d)
        lz += len(z)
    (out_dir / "plain.bin").write_bytes(text)
    (out_dir / "blocks.bin").write_bytes(bytes(blob))
    # postings.bin: u32 term count, u32 posting count, u32 document count,
    # the df of every term (u32), today's 8-byte postings, then the same
    # postings as C2b (per term: gap varint with tf == 1 in its low bit, a tf
    # varint when tf > 1), for the Zig probe's open-time decode comparison.
    lex = loaded["lexical"]
    ids, tfs, dfs = lex["doc_ids"], lex["tfs"], lex["dfs"]
    folded = bytearray()
    at = 0
    for df in dfs:
        last = -1
        for k in range(at, at + df):
            gap = ids[k] - last - 1 if last >= 0 else ids[k]
            last = ids[k]
            put_varint(folded, (gap << 1) | (1 if tfs[k] == 1 else 0))
            if tfs[k] != 1:
                put_varint(folded, tfs[k])
        at += df
    fixed = bytearray()
    for d, t in zip(ids, tfs):
        fixed += struct.pack("<II", d, t)
    head = struct.pack("<III", len(dfs), len(ids), len(lex["doc_lengths"]))
    (out_dir / "postings.bin").write_bytes(head + struct.pack(f"<{len(dfs)}I", *dfs) + bytes(fixed) + bytes(folded))
    return {"index": index.name, "plain": len(text), "deflate": deflated, "lz4": lz,
            "blocks": (len(text) + 65535) // 65536, "postings_fixed": len(fixed),
            "postings_c2b": len(folded)}


CORPORA = ["timing-1k", "timing-10k", "prose-1k", "prose-10k", "tamil-1k", "tamil-10k", "fixtures", "family"]
SECTION_ORDER = ["documents", "lexical", "source", "state", "filenames", "filename-lexical", "MANIFEST", "INDEX-STATE.json"]


def _kind(name: str) -> str:
    for kind in ("filename-lexical", "filenames", "documents", "lexical", "source", "state"):
        if name.startswith(kind + "-"):
            return kind
    return name


def _sections(budget: dict) -> dict:
    out = {}
    for f in budget["files"]:
        if f["bytes"] or f["file"] != "WRITER.LOCK":
            out[_kind(f["file"])] = out.get(_kind(f["file"]), 0) + f["bytes"]
    out.pop("WRITER.LOCK", None)
    return out


def _n(value) -> str:
    return f"{value:,}"


def _r(value: float) -> str:
    return f"{value:.2f}"


def cmd_tables(raw: Path) -> str:
    """The Markdown tables of docs/evidence/s6-t3/tables.md from the raw JSON."""
    lines = []
    load = lambda kind, corpus: json.loads((raw / f"{kind}-{corpus}.json").read_text(encoding="utf-8"))
    rows = {}
    for corpus in CORPORA:
        b, bf = load("budget", corpus), load("budget", corpus + "-fn")
        d, c = load("duplication", corpus + "-fn"), load("candidates", corpus + "-fn")
        src = next(f for f in bf["files"] if _kind(f["file"]) == "source")
        lex = next(f for f in bf["files"] if _kind(f["file"]) == "lexical")
        rows[corpus] = {"b": b, "bf": bf, "d": d, "c": c["candidates"], "files": src["counts"]["files"],
                        "corpus": src["parts"]["text (original file bytes)"], "lex": lex["counts"]}
        plain, fn = _sections(b), _sections(bf)
        for kind in ("documents", "lexical", "source", "state"):
            if plain[kind] != fn[kind]:
                raise SystemExit(f"{corpus}: {kind} differs with the file-name channel")

    lines += ["## 1. Corpora", "",
              "| Corpus | Files | Corpus bytes | Chunks | Distinct terms | Postings | Tokens |",
              "| --- | ---: | ---: | ---: | ---: | ---: | ---: |"]
    for corpus, r in rows.items():
        x = r["lex"]
        lines.append(f"| {corpus} | {_n(r['files'])} | {_n(r['corpus'])} | {_n(x['documents'])} | "
                     f"{_n(x['terms'])} | {_n(x['postings'])} | {_n(x['tokens'])} |")
    lines += ["", "## 2. Index size against corpus size, one generation", "",
              "| Corpus | Corpus bytes | Index bytes | Ratio | Index bytes with the file-name channel | Ratio |",
              "| --- | ---: | ---: | ---: | ---: | ---: |"]
    for corpus, r in rows.items():
        t, tf = r["b"]["total_bytes"], r["bf"]["total_bytes"]
        lines.append(f"| {corpus} | {_n(r['corpus'])} | {_n(t)} | {_r(t / r['corpus'])} | {_n(tf)} | "
                     f"{_r(tf / r['corpus'])} |")
    lines += ["", "## 3. Bytes per section file (file-name channel on)", "",
              "| Corpus | " + " | ".join(SECTION_ORDER) + " | Total |",
              "| --- | " + " | ".join("---:" for _ in SECTION_ORDER) + " | ---: |"]
    for corpus, r in rows.items():
        s = _sections(r["bf"])
        lines.append(f"| {corpus} | " + " | ".join(_n(s.get(k, 0)) for k in SECTION_ORDER)
                     + f" | {_n(r['bf']['total_bytes'])} |")
    lines += ["", "Shares of the index:", "",
              "| Corpus | " + " | ".join(SECTION_ORDER[:6]) + " |",
              "| --- | " + " | ".join("---:" for _ in SECTION_ORDER[:6]) + " |"]
    for corpus, r in rows.items():
        s = _sections(r["bf"])
        t = r["bf"]["total_bytes"]
        lines.append(f"| {corpus} | " + " | ".join(f"{100 * s.get(k, 0) / t:.1f} %" for k in SECTION_ORDER[:6]) + " |")

    lines += ["", "## 4. Inside each section (file-name channel on)", "",
              "Every row's parts sum to the file's size (`index_size_budget.py budget` refuses otherwise).", ""]
    for corpus, r in rows.items():
        lines += [f"### {corpus}", "", "| File | Part | Bytes | Share of file | Share of index |",
                  "| --- | --- | ---: | ---: | ---: |"]
        t = r["bf"]["total_bytes"]
        for f in sorted(r["bf"]["files"], key=lambda f: SECTION_ORDER.index(_kind(f["file"]))
                        if _kind(f["file"]) in SECTION_ORDER else 99):
            if f["file"] == "WRITER.LOCK":
                continue
            for part, nbytes in f["parts"].items():
                share = f"{100 * nbytes / f['bytes']:.1f} %" if f["bytes"] else "-"
                lines.append(f"| {f['file']} | {part} | {_n(nbytes)} | {share} | {100 * nbytes / t:.2f} % |")
            lines.append(f"| {f['file']} | **total** | **{_n(f['bytes'])}** | 100 % | {100 * f['bytes'] / t:.2f} % |")
        lines.append("")

    lines += ["## 5. Text stored more than once (measured)", "",
              "| Corpus | Corpus bytes | Chunk text | Source text | Chunks found as exact source spans | Chunk bytes not found | Chunk overlap bytes | Source bytes in no chunk |",
              "| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |"]
    for corpus, r in rows.items():
        d = r["d"]
        lines.append(f"| {corpus} | {_n(r['corpus'])} | {_n(d['chunk_text_bytes'])} | {_n(d['source_text_bytes'])} | "
                     f"{_n(d['chunks_found_in_source'])} of {_n(d['chunks'])} | {_n(d['chunk_text_bytes_not_found'])} | "
                     f"{_n(d['chunk_overlap_bytes'])} | {_n(d['source_bytes_not_in_any_chunk'])} |")
    lines += ["", "Other fields held by more than one section (file-name channel on):", "",
              "| Corpus | Paths in documents (per chunk) | Paths in source table | Paths in state | Paths in file-name catalog | sha256 in state and source (each) | Chunk ids copied into the catalog | Stems in the catalog | Dictionary count + start (derivable) | Section paths |",
              "| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |"]
    for corpus, r in rows.items():
        d = r["d"]
        st = d.get("state_repeats", {})
        cat = d.get("filename_catalog_repeats", {})
        dr = d["dictionary_redundant"]
        lines.append(f"| {corpus} | {_n(d['paths']['documents (one per chunk)'])} | {_n(d['paths']['source file table'])} | "
                     f"{_n(d['paths'].get('state', 0))} | {_n(cat.get('paths', 0))} | "
                     f"{_n(st.get('sha256 also in source table (32 B per file)', 0))} | "
                     f"{_n(cat.get('chunk ids copied from body anchors', 0))} | "
                     f"{_n(cat.get('stems (record text, derivable from paths)', 0))} | "
                     f"{_n(sum(dr.values()))} | {_n(d['section_paths_bytes'])} |")

    lines += ["", "## 6. Candidates: bytes saved, measured on prototype re-encodings (file-name channel on)", "",
              "| Corpus | A1 text as spans | A1-A4 records | B source deflate 64 KiB | C1 dictionary | C2b postings | C3 lengths | C5 offsets out | C6 positions + offsets out | D state | F catalog | F2 file-name lexical |",
              "| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |"]
    for corpus, r in rows.items():
        c = r["c"]
        a = c["A chunk text as source spans"]
        bsec = c["B source text block-compressed"]
        d64 = next(x for x in bsec["deflate"] if x["block_bytes"] == 65536 and x["level"] == 6)
        l = c["C lexical coding"]
        f2 = c.get("F2 filename lexical section, same coding", {}).get("C1+C2b+C3 saved", 0)
        lines.append(" | ".join([
            f"| {corpus}", _n(a["saved_A1"]), _n(a["saved_A1_to_A4"]),
            _n(bsec["text_before"] - d64["section_text_after"]),
            _n(l["C1 dictionary: front-coded terms + df varint (start, count derived)"]["saved"]),
            _n(l["C2b postings: gap varint with tf==1 folded into its low bit, else + tf varint"]["saved"]),
            _n(l["C3 document lengths as varints"]["saved"]),
            _n(l["C5 offsets section left out (highlights re-tokenized from the hit text)"]["saved"]),
            _n(l["C6 positions and offsets both left out (no phrase find)"]["saved"]),
            _n(c["D state refers to the source table"]["saved (sha256 + path + size per shared file)"]),
            _n(c["F filename catalog without derivable bytes"]["saved (stem text and copied chunk ids)"]),
            _n(f2)]) + " |")
    lines += ["", "Source text area under each codec (bytes after, block table included):", "",
              "| Corpus | Text | deflate 16 KiB L6 | deflate 64 KiB L1 | deflate 64 KiB L6 | deflate 64 KiB L9 | deflate 256 KiB L6 | deflate per file L6 | deflate file-aligned 16 KiB L6 | deflate file-aligned 64 KiB L6 | LZ4-style 64 KiB |",
              "| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |"]
    for corpus, r in rows.items():
        bsec = r["c"]["B source text block-compressed"]
        pick = lambda blk, lvl: next(x for x in bsec["deflate"] if x["block_bytes"] == blk and x["level"] == lvl)["section_text_after"]
        lines.append(f"| {corpus} | {_n(bsec['text_before'])} | {_n(pick(16384, 6))} | {_n(pick(65536, 1))} | "
                     f"{_n(pick(65536, 6))} | {_n(pick(65536, 9))} | {_n(pick(262144, 6))} | "
                     f"{_n(bsec['per_file']['section_text_after'])} | {_n(bsec['file_aligned_16k']['section_text_after'])} | "
                     f"{_n(bsec['file_aligned_64k']['section_text_after'])} | {_n(bsec['lz4_style_64k']['section_text_after'])} |")

    lines += ["", "## 7. Projection: the recommended steps applied in order (measured savings, summed)", "",
              "Each step's saving is its measured re-encoding above; the steps touch different bytes, so they add.",
              "Ratio = index bytes / corpus bytes.", "",
              "| Corpus | Today | 1. lexical coding (C1, C2b, C3) | 2. + chunk spans (A1-A4) | 3. + offsets out (C5) | 4. + state, catalog (D, F, F2) | 5. + source deflate 64 KiB (B) |",
              "| --- | ---: | ---: | ---: | ---: | ---: | ---: |"]
    for channel in ("off", "on"):
        for corpus, r in rows.items():
            c = r["c"]
            l = c["C lexical coding"]
            bsec = c["B source text block-compressed"]
            d64 = next(x for x in bsec["deflate"] if x["block_bytes"] == 65536 and x["level"] == 6)
            total = (r["bf"] if channel == "on" else r["b"])["total_bytes"]
            steps = [total]
            steps.append(steps[-1] - l["C1+C2b+C3 saved"])
            steps.append(steps[-1] - c["A chunk text as source spans"]["saved_A1_to_A4"])
            steps.append(steps[-1] - l["C5 offsets section left out (highlights re-tokenized from the hit text)"]["saved"])
            four = c["D state refers to the source table"]["saved (sha256 + path + size per shared file)"]
            if channel == "on":
                four += (c["F filename catalog without derivable bytes"]["saved (stem text and copied chunk ids)"]
                         + c["F2 filename lexical section, same coding"]["C1+C2b+C3 saved"])
            steps.append(steps[-1] - four)
            steps.append(steps[-1] - (bsec["text_before"] - d64["section_text_after"]))
            cells = [f"{_n(v)} ({_r(v / r['corpus'])})" for v in steps]
            lines.append(f"| {corpus} (channel {channel}) | " + " | ".join(cells) + " |")
    return "\n".join(lines) + "\n"


def main(argv: list) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("command", choices=("budget", "duplication", "candidates", "codec-blocks", "tables"))
    parser.add_argument("index", type=Path, help="an index directory (tables: the raw JSON directory)")
    parser.add_argument("--out", type=Path)
    parser.add_argument("--lz4", action="store_true")
    parser.add_argument("--blocks-dir", type=Path, help="codec-blocks: where to write")
    args = parser.parse_args(argv[1:])
    if args.command == "budget":
        result = cmd_budget(args.index)
    elif args.command == "duplication":
        result = cmd_duplication(args.index)
    elif args.command == "candidates":
        result = cmd_candidates(args.index, args.lz4)
    elif args.command == "codec-blocks":
        result = cmd_codec_blocks(args.index, args.blocks_dir)
    else:
        text = cmd_tables(args.index)
        if args.out:
            args.out.write_text(text, encoding="utf-8")
        print(text, end="")
        return 0
    text = json.dumps(result, indent=1, default=str)
    if args.out:
        args.out.write_text(text + "\n", encoding="utf-8")
    print(text)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
