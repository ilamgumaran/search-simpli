"""S6-T7 verifier: an independent decoder of documents record v5 and source section v2,
written from docs/documents-v5-source-v2-format.md alone (and source-section-v1.md for the
line map and line rules it points to). Not the builder's code.

Library use: decode_documents(buf, has_source), decode_source(buf, docs), rebuild(...).
Every refusal raises Refused(name, detail).
"""
import hashlib
import os
import struct
import subprocess

XXH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "tools", "xxh")


class Refused(Exception):
    def __init__(self, name, detail=""):
        super().__init__(name + (": " + detail if detail else ""))
        self.name = name


def xxh3(path, ck_off, hdr_len):
    out = subprocess.run([XXH, path, str(ck_off), str(hdr_len)], capture_output=True, text=True, check=True)
    return int(out.stderr.strip())


class Cursor:
    def __init__(self, buf, start, end, err="InvalidRecord"):
        self.b = buf
        self.p = start
        self.end = end
        self.err = err

    def varint(self, width_bytes, limit_bits, err=None):
        err = err or self.err
        v = 0
        shift = 0
        n = 0
        while True:
            if self.p >= self.end:
                raise Refused(err, "varint runs past the area")
            if n >= width_bytes:
                raise Refused(err, "varint too long")
            byte = self.b[self.p]
            self.p += 1
            n += 1
            v |= (byte & 0x7F) << shift
            shift += 7
            if not byte & 0x80:
                break
        if v >= (1 << limit_bits):
            raise Refused(err, "varint out of range")
        return v

    def u32(self, err=None):
        return self.varint(5, 32, err)

    def u64(self, err=None):
        return self.varint(10, 64, err)

    def take(self, n, err=None):
        err = err or self.err
        if n > self.end - self.p:
            raise Refused(err, "take past the area")
        s = self.b[self.p:self.p + n]
        self.p += n
        return s


# ---------------------------------------------------------------- documents v5

def decode_documents(buf, has_source, path_for_checksum=None, check_checksum=True):
    if len(buf) < 56:
        raise Refused("Truncated")
    if buf[0:8] != b"HYBSEG01":
        raise Refused("BadMagic")
    version, flags, ndocs, dims, nfiles = struct.unpack_from("<HHIII", buf, 8)
    if version != 5:
        raise Refused("UnsupportedVersion", str(version))
    if flags != 1:
        raise Refused("UnsupportedFlags")
    table_bytes, records_bytes, path_bytes, checksum = struct.unpack_from("<QQQQ", buf, 24)
    total = 56 + table_bytes + records_bytes
    if total >= 1 << 64:
        raise Refused("SizeOverflow")
    if total > len(buf):
        raise Refused("Truncated")
    if total < len(buf):
        raise Refused("TrailingData")
    if check_checksum:
        if xxh3(path_for_checksum, 48, 56) != checksum:
            raise Refused("ChecksumMismatch")
    if table_bytes < 4 * nfiles:
        raise Refused("InvalidFileTable", "bound: table bytes")
    if path_bytes < nfiles or path_bytes > 255 * nfiles + table_bytes:
        raise Refused("InvalidFileTable", "bound: decoded path bytes")
    if records_bytes < 8 * ndocs:
        raise Refused("InvalidRecord", "bound: records bytes")
    # file table
    c = Cursor(buf, 56, 56 + table_bytes, "InvalidFileTable")
    files = []
    prev = b""
    path_sum = 0
    chunk_sum = 0
    retained_seen = 0
    for i in range(nfiles):
        shared = c.u32()
        if shared > 255 or shared > len(prev) or (i == 0 and shared != 0):
            raise Refused("InvalidFileTable", f"shared {shared} at entry {i}")
        slen = c.u32()
        if slen < 1:
            raise Refused("InvalidFileTable", "empty suffix")
        suffix = c.take(slen)
        path = prev[:shared] + suffix
        if i > 0:
            if shared < len(prev) and shared < 255:
                if not suffix[0] > prev[shared]:
                    raise Refused("UnsortedPaths", f"entry {i}")
            elif shared == len(prev):
                pass  # strict extension
            else:  # shared == 255 < len(prev)
                if not path[255:] > prev[255:]:
                    raise Refused("UnsortedPaths", f"entry {i} (255 cap)")
        path_sum += len(path)
        if path_sum > path_bytes:
            raise Refused("InvalidFileTable", "decoded path bytes passed")
        cr = c.u32()
        nchunks, retained = cr >> 1, cr & 1
        if chunk_sum + nchunks > ndocs:
            raise Refused("InvalidFileTable", "chunk sum passes document count")
        if nchunks == 0 and retained == 0:
            raise Refused("InvalidFileTable", "zero chunks, not retained")
        if retained and not has_source:
            raise Refused("InvalidFileTable", "retained without a source section")
        files.append({"path": path, "first": chunk_sum, "n": nchunks, "retained": retained,
                      "ordinal": retained_seen if retained else 0xFFFFFFFF})
        chunk_sum += nchunks
        retained_seen += retained
        prev = path
    if c.p != c.end:
        raise Refused("TrailingData", "file table")
    if path_sum != path_bytes:
        raise Refused("InvalidFileTable", "decoded path bytes total")
    if chunk_sum != ndocs:
        raise Refused("InvalidFileTable", "chunk counts total")
    # records
    r = Cursor(buf, 56 + table_bytes, total, "InvalidRecord")
    recs = []
    fi = 0
    for d in range(ndocs):
        while files[fi]["first"] + files[fi]["n"] <= d:
            fi += 1
        f = files[fi]
        fl = r.u32()
        if fl & ~0x7:
            raise Refused("UnsupportedFlags", f"record {d}")
        if fl & 1:
            idlen = r.u32()
            rid = bytes(r.take(idlen))
        else:
            rid = r.take(10).hex().encode()
        tlen = r.u32()
        start = r.u32()
        span = r.u32()
        chunker = r.u32()
        depth = r.u32()
        hback = r.u32()
        if start < 1 or start + span >= 1 << 32:
            raise Refused("InvalidCitation", f"record {d}")
        if chunker > 65535 or depth > 65535 or hback > start:
            raise Refused("InvalidSection", f"record {d}")
        if depth > 0 and hback < 1:
            raise Refused("InvalidSection", f"record {d}: depth without heading")
        splen = r.u32() if depth > 0 else 0
        labels = b""
        if fl & 4:
            ll = r.u32()
            if ll < 1:
                raise Refused("InvalidRequiredLabels", f"record {d}")
            labels = bytes(r.take(ll))
            parts = labels.split(b"\n")
            if any(p == b"" or b"\0" in p or b"\r" in p for p in parts) or any(
                    not parts[k] < parts[k + 1] for k in range(len(parts) - 1)):
                raise Refused("InvalidRequiredLabels", f"record {d}")
        vec = None
        if fl & 2:
            if dims == 0:
                raise Refused("InvalidVectorDimensions", f"record {d}")
            vec = bytes(r.take(4 * dims))
        text = bytes(r.take(tlen))
        spath = bytes(r.take(splen))
        if depth > 0 and spath.count(b"\x1f") != depth - 1:
            raise Refused("InvalidSection", f"record {d}: section path entries")
        recs.append({"id": rid, "text": text, "start": start, "end": start + span,
                     "heading": 0 if hback == 0 else start - hback + 1, "chunker": chunker,
                     "depth": depth, "section": spath, "labels": labels, "vector": vec,
                     "path": f["path"], "sdi": f["ordinal"], "file": fi})
    if r.p != r.end:
        raise Refused("TrailingData", "records")
    return {"ndocs": ndocs, "dims": dims, "files": files, "records": recs,
            "retained": retained_seen, "checksum": checksum}


# ---------------------------------------------------------------- source v2

def valid_path(p):
    # v1's rule (source-section-v1.md): no leading '/', no '.' or '..' part, no NUL/CR/LF.
    if not p or p.startswith(b"/") or any(ch in p for ch in (b"\0", b"\r", b"\n")):
        return False
    return all(part not in (b".", b"..") for part in p.split(b"/"))


def decode_source(buf, docs, path_for_checksum=None, check_checksum=True):
    if len(buf) < 48:
        raise Refused("Truncated")
    if buf[0:8] != b"HYBSRC02":
        raise Refused("BadMagic")
    version, flags, nfiles = struct.unpack_from("<HHI", buf, 8)
    if version != 2:
        raise Refused("UnsupportedVersion")
    if flags != 1:
        raise Refused("UnsupportedFlags")
    rec_bytes, map_bytes, res_bytes, checksum = struct.unpack_from("<QQQQ", buf, 16)
    total = 48 + rec_bytes + map_bytes + res_bytes
    if total >= 1 << 64:
        raise Refused("SizeOverflow")
    if total > len(buf):
        raise Refused("Truncated")
    if total < len(buf):
        raise Refused("TrailingData")
    if check_checksum and xxh3(path_for_checksum, 40, 48) != checksum:
        raise Refused("ChecksumMismatch")
    if nfiles != docs["retained"]:
        raise Refused("SourceFileCountMismatch")
    if rec_bytes < 35 * nfiles or map_bytes < nfiles:
        raise Refused("InvalidFileTable", "bounds")
    retained_files = [f for f in docs["files"] if f["retained"]]
    rc = Cursor(buf, 48, 48 + rec_bytes, "InvalidFileTable")
    mc = Cursor(buf, 48 + rec_bytes, 48 + rec_bytes + map_bytes, "InvalidLineMap")
    res_base = 48 + rec_bytes + map_bytes
    res_at = 0
    out = []
    for ri, f in enumerate(retained_files):
        if not valid_path(f["path"]):
            raise Refused("InvalidPath", f["path"].decode("utf-8", "replace"))
        sha = bytes(rc.take(32))
        fl = rc.u32()
        if fl & ~0x3:
            raise Refused("InvalidFileTable", "source flags")
        tlen = rc.u64()
        lines = rc.u32()
        whole = bool(fl & 2)
        if f["n"] == 0 and not whole:
            raise Refused("InvalidFileTable", "zero chunks not whole")
        recipe = []
        if whole:
            residual = tlen
        else:
            cc = rc.u32()
            if cc != f["n"]:
                raise Refused("InvalidFileTable", "chunk count")
            pos = 0
            gaps = 0
            for j in range(cc):
                v = rc.u32()
                L = len(docs["records"][f["first"] + j]["text"])
                if v % 2 == 0:
                    g = v // 2
                    pos += g + L
                    gaps += g
                else:
                    k = (v + 1) // 2
                    if k > pos:
                        raise Refused("InvalidFileTable", "overlap past pos")
                    if k < L:
                        pos += L - k
                if pos > tlen:
                    raise Refused("InvalidFileTable", "pos past text length")
                recipe.append(v)
            residual = gaps + (tlen - pos)
        if res_at + residual > res_bytes:
            raise Refused("InvalidFileTable", "residual run past the area")
        mstart = mc.p
        vals = [mc.u64() for _ in range(lines + 1)]
        out.append({"file": f, "sha": sha, "bom": bool(fl & 1), "whole": whole, "len": tlen,
                    "lines": lines, "recipe": recipe, "res_start": res_base + res_at,
                    "res_len": residual, "map": vals, "map_at": mstart})
        res_at += residual
    if rc.p != rc.end:
        raise Refused("TrailingData", "source records")
    if mc.p != mc.end:
        raise Refused("InvalidLineMap", "maps left over")
    if res_at != res_bytes:
        raise Refused("InvalidFileTable", "residual total")
    return {"files": out, "checksum": checksum}


SINGLE_BREAKS = {0x0A, 0x0B, 0x0C, 0x0D, 0x1C, 0x1D, 0x1E}


def line_starts(data):
    """v1's map values: line 1's start, each later line start, the file length (absolute)."""
    off = 3 if data.startswith(b"\xef\xbb\xbf") else 0
    if off == len(data):
        return [len(data)]
    starts = [off]
    i = off
    n = len(data)
    while i < n:
        b = data[i]
        brk = 0
        if b == 0x0D:
            brk = 2 if i + 1 < n and data[i + 1] == 0x0A else 1
        elif b in SINGLE_BREAKS:
            brk = 1
        elif b == 0xC2 and i + 1 < n and data[i + 1] == 0x85:
            brk = 2
        elif b == 0xE2 and i + 2 < n and data[i + 1] == 0x80 and data[i + 2] in (0xA8, 0xA9):
            brk = 3
        if brk:
            i += brk
            if i < n:
                starts.append(i)
        else:
            i += 1
    starts.append(n)
    return starts


def rebuild(buf, docs, s):
    run = buf[s["res_start"]:s["res_start"] + s["res_len"]]
    f = s["file"]
    if s["whole"]:
        out = bytes(run)
    else:
        parts = []
        at = 0
        for j, v in enumerate(s["recipe"]):
            t = docs["records"][f["first"] + j]["text"]
            if v % 2 == 0:
                g = v // 2
                parts.append(run[at:at + g])
                at += g
                parts.append(t)
            else:
                k = (v + 1) // 2
                if k < len(t):
                    parts.append(t[k:])
        parts.append(run[at:])
        out = b"".join(bytes(p) for p in parts)
    if len(out) != s["len"]:
        raise Refused("SourceFileLengthMismatch", f["path"].decode("utf-8", "replace"))
    if hashlib.sha256(out).digest() != s["sha"]:
        raise Refused("SourceFileSha256Mismatch", f["path"].decode("utf-8", "replace"))
    if s["bom"] != out.startswith(b"\xef\xbb\xbf"):
        raise Refused("InvalidLineMap", "bom")
    absolute = []
    acc = 0
    for k, v in enumerate(s["map"]):
        acc = v if k == 0 else acc + v
        absolute.append(acc)
    if absolute != line_starts(out):
        raise Refused("InvalidLineMap", f["path"].decode("utf-8", "replace"))
    return out
