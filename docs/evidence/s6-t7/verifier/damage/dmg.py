#!/usr/bin/env python3
"""S6-T7 verifier: write one damaged copy of an index, every checksum resealed unless the case is about the checksum.

    dmg.py SRC_IDX OUT_DIR CASE        (OUT_DIR must not exist)
    dmg.py list

Written from docs/documents-v5-source-v2-format.md (layouts) and docs/manifest-format-v2.md (the manifest's FNV-1a).
The documents section is re-encoded from its parsed parts (file-table entries, records), the source section from its
parsed parts (records, maps, residual); a case edits a part, then the section's header lengths are recomputed (unless
the case overrides one), the section's XXH3-64 is resealed (tools/xxh), and the manifest's length, checksum and own
FNV-1a are rewritten.
"""
import shutil
import struct
import subprocess
import sys
from pathlib import Path

XXH = str(Path(__file__).resolve().parent.parent / "tools" / "xxh")


def rv(b, at, maxb=10):
    v = s = 0
    for i in range(maxb):
        if at >= len(b):
            raise ValueError("varint past end")
        x = b[at]
        at += 1
        v |= (x & 0x7F) << s
        s += 7
        if not x & 0x80:
            return v, at
    raise ValueError("varint too long")


def ev(v):
    out = bytearray()
    while True:
        x = v & 0x7F
        v >>= 7
        if v:
            out.append(x | 0x80)
        else:
            out.append(x)
            return bytes(out)


def xxh3(path, ck_off, hdr_len):
    r = subprocess.run([XXH, str(path), str(ck_off), str(hdr_len)], capture_output=True, text=True, check=True)
    return int(r.stderr.strip())


def fnv(data):
    h = 0xCBF29CE484222325
    for x in data:
        h = ((h ^ x) * 0x100000001B3) & 0xFFFFFFFFFFFFFFFF
    return h


class Docs:
    """record v5: header fields, entries [shared, suffix, value], records [raw bytes], plus each record's fields."""

    def __init__(self, b):
        self.magic = b[0:8]
        self.version, self.flags, self.doc_count, self.dims, self.file_count = struct.unpack_from("<HHIII", b, 8)
        tb, rb, self.path_bytes = struct.unpack_from("<QQQ", b, 24)
        t = b[56:56 + tb]
        at = 0
        self.entries = []
        prev = b""
        self.paths = []
        while at < len(t):
            sh, at = rv(t, at, 5)
            sl, at = rv(t, at, 5)
            suf = t[at:at + sl]
            at += sl
            val, at = rv(t, at, 5)
            self.entries.append([sh, suf, val])
            prev = prev[:sh] + suf
            self.paths.append(prev)
        r = b[56 + tb:56 + tb + rb]
        self.records = []
        self.rec = []  # parsed: dict(flags, text_off, text_len, start_off, start)
        at = 0
        while at < len(r):
            s0 = at
            fl, at = rv(r, at, 5)
            if fl & 1:
                n, at = rv(r, at, 5)
                at += n
            else:
                at += 10
            tl, at = rv(r, at, 5)
            st_off = at
            start, at = rv(r, at, 5)
            span, at = rv(r, at, 5)
            ch, at = rv(r, at, 5)
            depth, at = rv(r, at, 5)
            hb, at = rv(r, at, 5)
            spl = 0
            if depth > 0:
                spl, at = rv(r, at, 5)
            if fl & 4:
                ll, at = rv(r, at, 5)
                at += ll
            if fl & 2:
                at += 4 * self.dims
            text_off = at - s0
            at += tl + spl
            self.records.append(r[s0:at])
            self.rec.append({"flags": fl, "start": start, "start_off": st_off - s0, "text_off": text_off, "text_len": tl})
        self.over = {}

    def chunk_counts(self):
        return [(e[2] >> 1, e[2] & 1) for e in self.entries]

    def encode(self):
        table = b"".join(ev(sh) + ev(len(suf)) + suf + ev(val) for sh, suf, val in self.entries) if not hasattr(self, "raw_table") else self.raw_table
        recs = b"".join(self.records)
        f = {"table_bytes": len(table), "records_bytes": len(recs), "file_count": len(self.entries),
             "doc_count": len(self.records), "path_bytes": self.path_bytes, "flags": self.flags, "version": self.version}
        f.update(self.over)
        f.pop("records_bytes_fix", None)
        head = self.magic + struct.pack("<HHIIIQQQ", f["version"], f["flags"], f["doc_count"], self.dims, f["file_count"],
                                        f["table_bytes"], f["records_bytes"], f["path_bytes"]) + b"\0" * 8
        return head + table + recs


class Src:
    def __init__(self, b, docs):
        self.magic = b[0:8]
        self.version, self.flags, self.file_count = struct.unpack_from("<HHI", b, 8)
        rb, mb, xb = struct.unpack_from("<QQQ", b, 16)
        recs = b[48:48 + rb]
        maps = b[48 + rb:48 + rb + mb]
        self.residual = bytearray(b[48 + rb + mb:48 + rb + mb + xb])
        retained = []
        first = 0
        for chunks, ret in docs.chunk_counts():
            if ret:
                retained.append((first, chunks))
            first += chunks
        self.files = []
        at = mat = 0
        for first, chunks in retained:
            s0 = at
            sha = recs[at:at + 32]
            at += 32
            fl, at = rv(recs, at, 5)
            ln, at = rv(recs, at, 10)
            lc, at = rv(recs, at, 5)
            recipe = []
            if not fl & 2:
                cc, at = rv(recs, at, 5)
                for _ in range(cc):
                    v, at = rv(recs, at, 5)
                    recipe.append(v)
            m0 = mat
            for _ in range(lc + 1):
                _, mat = rv(maps, mat, 10)
            lens = [docs.rec[first + i]["text_len"] for i in range(chunks)]
            self.files.append({"sha": bytearray(sha), "flags": fl, "length": ln, "lines": lc, "recipe": recipe,
                               "map": maps[m0:mat], "first": first, "chunks": chunks, "lens": lens,
                               "extra": b""})
        self.over = {}
        self.extra_records = b""
        self.extra_maps = b""

    def residual_len(self, f):
        if f["flags"] & 2:
            return f["length"]
        pos = gaps = 0
        for v, L in zip(f["recipe"], f["lens"]):
            if v % 2 == 0:
                gaps += v // 2
                pos += v // 2 + L
            else:
                k = (v + 1) // 2
                if k < L:
                    pos += L - k
        return gaps + f["length"] - pos

    def record_bytes(self, f):
        out = bytes(f["sha"]) + ev(f["flags"]) + ev(f["length"]) + ev(f["lines"])
        if not f["flags"] & 2:
            out += ev(len(f["recipe"])) + b"".join(ev(v) for v in f["recipe"])
        return out + f["extra"]

    def encode(self):
        recs = b"".join(self.record_bytes(f) for f in self.files) + self.extra_records
        maps = b"".join(f["map"] for f in self.files) + self.extra_maps
        f = {"file_count": len(self.files), "records_bytes": len(recs), "maps_bytes": len(maps), "residual_bytes": len(self.residual)}
        f.update(self.over)
        head = self.magic + struct.pack("<HHIQQQ", self.version, self.flags, f["file_count"], f["records_bytes"],
                                        f["maps_bytes"], f["residual_bytes"]) + b"\0" * 8
        return head + recs + maps + bytes(self.residual)


def seal(path, ck_off, hdr_len):
    b = bytearray(path.read_bytes())
    ck = xxh3(path, ck_off, hdr_len)
    struct.pack_into("<Q", b, ck_off, ck)
    path.write_bytes(b)
    return len(b), ck


def manifest_bind(idx, docs=None, src=None, flags_xor=0):
    m = bytearray((idx / "MANIFEST").read_bytes())
    if docs:
        struct.pack_into("<QQ", m, 44, *docs)
    if src:
        struct.pack_into("<QQ", m, 76, *src)
    if flags_xor:
        m[10] ^= flags_xor
    assert struct.unpack_from("<H", m, 10)[0] & 0x18 == 0x18, "layout with bits 3 and 4 expected"
    struct.pack_into("<Q", m, 160, fnv(bytes(m[:160]) + bytes(m[168:])))
    (idx / "MANIFEST").write_bytes(m)


def files_of(idx):
    d = next(idx.glob("documents-*.hybseg"))
    s = next(iter(idx.glob("source-*.hybsrc")), None)
    return d, s


def first_nonwhole(src, min_chunks=1):
    return next(i for i, f in enumerate(src.files) if not f["flags"] & 2 and f["chunks"] >= min_chunks)


# ---- cases: each takes (docs, src) and edits them; returns which sections changed and options
def c(kind, note):
    def deco(fn):
        CASES[fn.__name__] = (kind, note, fn)
        return fn
    return deco


CASES = {}


@c("docs", "documents header flags 0x0003")
def d_hdr_flags(d, s):
    d.over["flags"] = 3


@c("docs", "documents version 6")
def d_hdr_version6(d, s):
    d.over["version"] = 6


@c("docs", "file count raised past what the table bytes can hold (table bytes / 4 + 1)")
def d_bound_filecount(d, s):
    d.over["file_count"] = len(b"".join(ev(sh) + ev(len(suf)) + suf + ev(val) for sh, suf, val in d.entries)) // 4 + 1


@c("docs", "document count raised past records bytes / 8")
def d_bound_doccount(d, s):
    d.over["doc_count"] = len(b"".join(d.records)) // 8 + 1


@c("docs", "entry 0 with shared = 1")
def d_shared_first(d, s):
    e = d.entries[0]
    e[0], e[1] = 1, e[1][1:]


@c("docs", "entry 1 shared = previous path length + 1 (suffix one shorter)")
def d_shared_gt_prev(d, s):
    e = d.entries[1]
    e[0], e[1] = len(d.paths[0]) + 1, e[1][1:] if len(e[1]) > 1 else e[1]


@c("docs", "shared = 256 on a pair sharing > 256 bytes (suffix one shorter: the decoded path is unchanged)")
def d_shared_256(d, s):
    for i, e in enumerate(d.entries):
        if e[0] == 255 and len(e[1]) > 1:
            e[0], e[1] = 256, e[1][1:]
            return
    raise SystemExit("no entry with shared 255")


@c("docs", "an entry with suffix length 0 (shared = the previous path's length)")
def d_suffix_zero(d, s):
    e = d.entries[1]
    d.path_bytes += len(d.paths[0]) - (e[0] + len(e[1]))
    e[0], e[1] = len(d.paths[0]), b""


@c("docs", "entries 1 and 2 swapped (records left in place)")
def d_unsorted(d, s):
    p = list(d.paths)
    p[1], p[2] = p[2], p[1]
    vals = [e[2] for e in d.entries]
    vals[1], vals[2] = vals[2], vals[1]
    prev = b""
    d.entries = []
    for path, val in zip(p, vals):
        sh = 0
        while sh < min(len(prev), len(path), 255) and prev[sh] == path[sh]:
            sh += 1
        d.entries.append([sh, path[sh:], val])
        prev = path


@c("docs", "a non-canonical entry: shared one short, the byte moved into the suffix")
def d_noncanonical(d, s):
    for i, e in enumerate(d.entries[1:], 1):
        if e[0] > 0:
            e[1] = d.paths[i - 1][e[0] - 1:e[0]] + e[1]
            e[0] -= 1
            return


@c("docs", "header decoded path bytes + 1")
def d_pathbytes_plus1(d, s):
    d.path_bytes += 1


@c("docs", "header decoded path bytes - 1")
def d_pathbytes_minus1(d, s):
    d.path_bytes -= 1


@c("docs", "last entry's chunk count - 1 (the counts no longer sum to the record count; header document count unchanged)")
def d_chunks_short_last(d, s):
    i = max(i for i, e in enumerate(d.entries) if e[2] >> 1 >= 1)
    d.entries[i][2] -= 2


@c("docs", "first entry's chunk count + 1 (sum passes the record count)")
def d_chunks_long_first(d, s):
    d.entries[0][2] += 2


@c("docs", "an entry with chunk count 0 and retained 0 (its records moved to the next entry)")
def d_chunks0_notretained(d, s):
    i = next(i for i, e in enumerate(d.entries[:-1]) if e[2] >> 1 >= 1 and not d.entries[i + 1][2] & 1 == 0)
    n = d.entries[i][2] >> 1
    d.entries[i][2] = 0
    d.entries[i + 1][2] += 2 * n


@c("docs", "one byte left over after the file table's last entry")
def d_table_leftover(d, s):
    d.raw_table = b"".join(ev(sh) + ev(len(suf)) + suf + ev(val) for sh, suf, val in d.entries) + b"\x00"


@c("docs", "the file table's last byte dropped (the last entry's value varint cut)")
def d_table_last_cut(d, s):
    d.raw_table = b"".join(ev(sh) + ev(len(suf)) + suf + ev(val) for sh, suf, val in d.entries)[:-1]


@c("docs", "the last entry's value varint given a continuation bit at the end of the area (overruns)")
def d_table_varint_overrun(d, s):
    t = bytearray(b"".join(ev(sh) + ev(len(suf)) + suf + ev(val) for sh, suf, val in d.entries))
    t[-1] |= 0x80
    d.raw_table = bytes(t)


@c("docs", "one byte left over after the last record")
def d_records_leftover(d, s):
    d.records[-1] += b"\x00"


@c("docs", "the last record's last byte dropped")
def d_records_last_cut(d, s):
    d.records[-1] = d.records[-1][:-1]


@c("docs", "the first record's flags with bit 3")
def d_record_flags(d, s):
    r = bytearray(d.records[0])
    r[0] |= 8
    d.records[0] = bytes(r)


@c("docs", "the first record's start line 0")
def d_record_start0(d, s):
    r = d.records[0]
    o = d.rec[0]["start_off"]
    _, end = rv(r, o, 5)
    d.records[0] = r[:o] + b"\x00" + r[end:]


@c("docs", "the first record's flags as a 6-byte u32 varint")
def d_varint_overlong(d, s):
    r = d.records[0]
    d.records[0] = bytes([r[0] | 0x80, 0x80, 0x80, 0x80, 0x80, 0x00]) + r[1:]


@c("docs", "the last record's text length + 1 (its text and path run one past the area)")
def d_last_take_overrun(d, s):
    r = d.records[-1]
    rec = d.rec[-1]
    # re-find text length varint: just after the id
    at = 0
    fl, at = rv(r, at, 5)
    if fl & 1:
        n, at = rv(r, at, 5)
        at += n
    else:
        at += 10
    tl, end = rv(r, at, 5)
    d.records[-1] = r[:at] + ev(tl + 1) + r[end:]


@c("docs", "retained bit set on a file while the manifest binds no source section (a no-source index)")
def d_retained_nosource(d, s):
    i = next(i for i, e in enumerate(d.entries) if not e[2] & 1)
    d.entries[i][2] |= 1


@c("docs", "one byte after the last record inside the bound section: header lengths unchanged, manifest length and both checksums resealed")
def d_trailing_bound(d, s):
    d.over["records_bytes"] = len(b"".join(d.records))
    d.records[-1] += b"\x00"
    d.over["records_bytes_fix"] = True


@c("docs", "document count raised past records bytes / 8, in the header and the manifest")
def d_bound_doccount_m(d, s):
    d.over["doc_count"] = len(b"".join(d.records)) // 8 + 1
    d.manifest_doc_count = d.over["doc_count"]


@c("manifest", "manifest bit 6 cleared over a v5 documents section")
def m_bit6_clear(d, s):
    pass


@c("manifest", "manifest bit 6 set over v4 documents and HYBSRC01 (main's index)")
def m_bit6_on_v4(d, s):
    pass


@c("docs-raw", "the documents section one byte short (header unchanged)")
def d_truncated(d, s):
    pass


@c("docs-raw", "one byte appended to the documents section (header unchanged)")
def d_trailing_file(d, s):
    pass


@c("docs-raw", "one record byte flipped, checksum not resealed")
def d_checksum(d, s):
    pass


@c("src", "source header file count + 1")
def s_count_plus1(d, s):
    s.over["file_count"] = len(s.files) + 1


@c("src", "source records bytes lowered below 35 x file count")
def s_bound_records(d, s):
    s.over["file_count"] = len(s.files)
    s.files_short = True


@c("src", "a record with flag bit 2 (unknown)")
def s_flags_unknown(d, s):
    s.files[0]["flags"] |= 4


@c("src", "a file with 0 chunks not kept whole")
def s_chunk0_notwhole(d, s):
    f = next(f for f in s.files if f["chunks"] == 0)
    f["flags"] &= ~2
    f["recipe"] = []


@c("src", "a record's chunk count + 1 (one more recipe value)")
def s_chunkcount(d, s):
    f = s.files[first_nonwhole(s)]
    f["recipe"].append(0)


@c("src", "a gap so large the position passes the file's length")
def s_recipe_pos_past(d, s):
    f = s.files[first_nonwhole(s)]
    f["recipe"][0] = 2 * (f["length"] + 1)


@c("src", "the last record's last recipe varint given a continuation bit at the end of the records area")
def s_recipe_varint_overrun(d, s):
    i = max(i for i, f in enumerate(s.files) if not f["flags"] & 2 and f["chunks"] >= 1)
    if i != len(s.files) - 1:
        raise SystemExit("last record is kept whole; case needs a different index")
    s.raw_last_cont = True


@c("src", "the first chunk an overlap (k = 1 > pos = 0)")
def s_overlap_first(d, s):
    f = s.files[first_nonwhole(s)]
    f["recipe"][0] = 1


@c("src", "a later chunk's overlap k = pos + 1")
def s_overlap_gt_pos(d, s):
    i = first_nonwhole(s, 2)
    f = s.files[i]
    pos = 0
    v = f["recipe"][0]
    pos = v // 2 + f["lens"][0] if v % 2 == 0 else 0
    f["recipe"][1] = 2 * (pos + 1) - 1


@c("src", "a later chunk's overlap larger than the previous chunk but <= pos (no walk rule; the SHA-256 must refuse)")
def s_overlap_gt_prev_le_pos(d, s):
    for i, f in enumerate(s.files):
        if f["flags"] & 2 or f["chunks"] < 3:
            continue
        pos = 0
        for j, (v, L) in enumerate(zip(f["recipe"], f["lens"])):
            if j >= 2 and pos > f["lens"][j - 1] + 1:
                k = f["lens"][j - 1] + 1
                old_k_emit = (L - ((v + 1) // 2)) if v % 2 else None
                f["recipe"][j] = 2 * k - 1
                # keep the residual/tail consistent: the walk's residual length changes with the emitted bytes
                return
            if v % 2 == 0:
                pos += v // 2 + L
            else:
                k = (v + 1) // 2
                if k < L:
                    pos += L - k
    raise SystemExit("no file with 3 chunks")


@c("src", "an overlap k > pos on a later chunk with the record's length lowered by k, so the residual total still adds up (only the k > pos rule refuses it in the walk)")
def s_overlap_isolated(d, s):
    for f in s.files:
        if f["flags"] & 2 or f["chunks"] < 2:
            continue
        pos = 0
        for j, (v, L) in enumerate(zip(f["recipe"], f["lens"])):
            if j >= 1 and v % 2 == 0 and L > pos + 1:
                k = pos + 1
                f["recipe"][j] = 2 * k - 1
                f["length"] -= k
                return
            if v % 2 == 0:
                pos += v // 2 + L
            else:
                kk = (v + 1) // 2
                if kk < L:
                    pos += L - kk
    raise SystemExit("no candidate")


@c("src", "one byte left over in the residual area")
def s_residual_leftover(d, s):
    s.residual += b"\x00"


@c("src", "the residual area's last byte dropped")
def s_residual_short(d, s):
    del s.residual[-1]


@c("src", "one byte left over after the last record")
def s_records_leftover(d, s):
    s.extra_records = b"\x00"


@c("src", "one varint left over after the last map")
def s_maps_leftover(d, s):
    s.extra_maps = b"\x00"


@c("src", "the last map's last varint dropped")
def s_maps_last_cut(d, s):
    f = s.files[-1]
    f["map"] = f["map"][:-1]


@c("src", "one byte of the residual area flipped (a gap or tail byte of the first file with residual bytes)")
def s_sha_residual(d, s):
    off = 0
    for f in s.files:
        n = s.residual_len(f)
        if n > 0:
            s.residual[off] ^= 0x01
            s.damaged_file = f
            return
    raise SystemExit("no residual")


@c("src", "a record's stored SHA-256 with one bit flipped")
def s_sha_record(d, s):
    s.files[0]["sha"][0] ^= 0x01


@c("both", "one byte of a chunk's text flipped in the documents section (a rebuilt file, not kept whole)")
def s_sha_chunktext(d, s):
    f = s.files[first_nonwhole(s)]
    r = bytearray(d.records[f["first"]])
    o = d.rec[f["first"]]["text_off"]
    r[o] ^= 0x01 if r[o] != 0x0A else 0x00
    if r[o] == 0x0A:
        r[o + 1] ^= 0x01
    d.records[f["first"]] = bytes(r)


@c("src", "the BOM flag set on a file without a BOM")
def s_bom_flag(d, s):
    f = next(f for f in s.files if not f["flags"] & 1 and f["length"] >= 3)
    f["flags"] |= 1


@c("src", "a line map's second value + 1")
def s_map_value(d, s):
    f = next(f for f in s.files if f["lines"] >= 2)
    m = f["map"]
    _, a = rv(m, 0, 10)
    v, b = rv(m, a, 10)
    f["map"] = m[:a] + ev(v + 1) + m[b:]


@c("src", "a record's length + 1")
def s_length_plus1(d, s):
    s.files[first_nonwhole(s)]["length"] += 1


@c("src", "a rebuilt file's record marked kept whole (its recipe dropped)")
def s_whole_flag_set(d, s):
    f = s.files[first_nonwhole(s)]
    f["flags"] |= 2
    f["recipe"] = []


@c("src-raw", "one source byte flipped, checksum not resealed")
def s_checksum(d, s):
    pass


def main():
    if sys.argv[1] == "list":
        for k, (kind, note, _) in CASES.items():
            print(f"{k}\t{kind}\t{note}")
        return
    src_idx, out, case = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3]
    kind, note, fn = CASES[case]
    shutil.copytree(src_idx, out)
    (out / "WRITER.LOCK").unlink(missing_ok=True)
    dpath, spath = files_of(out)
    if kind == "manifest":
        manifest_bind(out, flags_xor=0x40)
        return
    if kind == "docs-raw":
        b = bytearray(dpath.read_bytes())
        if case == "d_truncated":
            b = b[:-1]
        elif case == "d_trailing_file":
            b += b"\x00"
        else:
            b[-1] ^= 0x01
        dpath.write_bytes(b)
        return
    if kind == "src-raw":
        b = bytearray(spath.read_bytes())
        b[-1] ^= 0x01
        spath.write_bytes(b)
        return
    d = Docs(dpath.read_bytes())
    assert d.encode()[:48] == dpath.read_bytes()[:48] and d.encode()[56:] == dpath.read_bytes()[56:], "docs re-encode differs"
    s = Src(spath.read_bytes(), d) if spath else None
    if s:
        assert s.encode()[:40] == spath.read_bytes()[:40] and s.encode()[48:] == spath.read_bytes()[48:], "src re-encode differs"
    fn(d, s)
    if kind in ("docs", "both"):
        dpath.write_bytes(d.encode())
        if hasattr(d, "manifest_doc_count"):
            m = bytearray((out / "MANIFEST").read_bytes())
            struct.pack_into("<I", m, 20, d.manifest_doc_count)
            (out / "MANIFEST").write_bytes(m)
        manifest_bind(out, docs=seal(dpath, 48, 56))
    if kind in ("src", "both"):
        b = s.encode()
        if getattr(s, "files_short", False):
            struct.pack_into("<Q", bytearray(b), 16, 0)
            bb = bytearray(b)
            # records bytes declared below 35 x count: move the deficit to the maps count so the total still matches
            rb, mb = struct.unpack_from("<QQ", bb, 16)
            new_rb = 35 * len(s.files) - 1
            struct.pack_into("<QQ", bb, 16, new_rb, mb + (rb - new_rb))
            b = bytes(bb)
        if getattr(s, "raw_last_cont", False):
            # the records area ends with the last recipe varint: set its continuation bit
            bb = bytearray(b)
            rb = struct.unpack_from("<Q", bb, 16)[0]
            bb[48 + rb - 1] |= 0x80
            b = bytes(bb)
        spath.write_bytes(b)
        manifest_bind(out, src=seal(spath, 40, 48))


main()
