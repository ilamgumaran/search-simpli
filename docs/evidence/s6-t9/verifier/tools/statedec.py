"""S6-T9 verifier: an independent decoder of the recovery-state section HYBSTA02 / HYBSTA03 and of the file-name catalog
record v3 / v6, written from docs/state-section-format-v2.md, docs/state-section-format-v3.md and
docs/filename-catalog-format-v6.md (with docs/manifest-format-v2.md for the manifest fields), and the S6-T7 verifier's
documents-v5 / source-v2 decoder (dec/v5dec.py) for the source table. Not the builder's code.

    statedec.py compare MAIN_IDX HEAD_IDX     -> decode both states (v2 / v3) and both catalogs (v3 / v6, ids and stems
                                                 derived), compare entry for entry; print a summary line
    statedec.py dump IDX                       -> one line per state entry (JSON)
Library use: manifest(idx), state_records(idx), resolve(...).
"""
import json
import os
import struct
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "dec"))
import v5dec  # noqa: E402


class Refused(Exception):
    pass


def u32(b, o):
    return struct.unpack_from("<I", b, o)[0]


def u64(b, o):
    return struct.unpack_from("<Q", b, o)[0]


def manifest(idx):
    m = open(os.path.join(idx, "MANIFEST"), "rb").read()
    assert m[:8] == b"HYBMAN02"
    flags = struct.unpack_from("<H", m, 10)[0]
    out = {"raw": m, "flags": flags, "generation": u64(m, 12), "docs_bytes": u64(m, 44), "docs_ck": u64(m, 52),
           "src_bytes": u64(m, 76), "src_ck": u64(m, 84)}
    off = 92
    if flags & 8:
        out["cat_off"] = 108
        out["fn_files"] = u32(m, 92)
        off = 140
    if flags & 16:
        out["state_off"] = off
        off += 16
    out["payload_len_off"] = off
    out["ck_off"] = off + 4
    hdr = off + 12
    p = hdr
    strings = []
    while p < len(m):
        n = u32(m, p)
        strings.append(m[p + 4:p + 4 + n].decode())
        p += 4 + n
    out["strings"] = strings
    out["analyzer"] = strings[0]
    out["documents_file"], out["lexical_file"], out["source_file"] = strings[2], strings[3], strings[4]
    if flags & 8:
        out["catalog_file"], out["fn_lexical_file"] = strings[6], strings[7]
    if flags & 16:
        out["state_file"] = strings[-1]
    out["header_len"] = hdr
    return out


def source_table(idx, mf):
    """[(table path bytes, sha256 bytes, text length)] for each HYBSRC02 record, in order (the r-th retained file)."""
    if not mf["source_file"]:
        return None
    sb = open(os.path.join(idx, mf["source_file"]), "rb").read()
    if sb[:8] != b"HYBSRC02":
        return None
    db = open(os.path.join(idx, mf["documents_file"]), "rb").read()
    docs = v5dec.decode_documents(db, True, check_checksum=False)
    src = v5dec.decode_source(sb, docs, check_checksum=False)
    return [(f["file"]["path"], f["sha"], f["len"]) for f in src["files"]]


def decode_state(sec, table):
    """Entries of a HYBSTA02 / HYBSTA03 section, and each file record's offset and form (for the damage tool)."""
    magic = sec[:8]
    v3 = magic == b"HYBSTA03"
    if magic not in (b"HYBSTA02", b"HYBSTA03"):
        raise Refused("magic " + repr(magic))
    if struct.unpack_from("<H", sec, 8)[0] != (3 if v3 else 2):
        raise Refused("UnsupportedVersion")
    plen = u64(sec, 16)
    b = sec[32:]
    if len(b) != plen:
        raise Refused("Truncated/TrailingData")
    if u32(b, 0) != 2 or u32(b, 4) != 0 or u32(b, 36) != 0:
        raise Refused("InvalidState header")
    gen, an, ns, nr, nf, nl = u64(b, 8), u32(b, 16), u32(b, 20), u32(b, 24), u32(b, 28), u32(b, 32)
    least = 36 if v3 else 76
    if 4 * ns + 24 * nr + least * nf + 4 * nl > len(b) - 40:
        raise Refused("InvalidState count bound")
    p = 40
    lens = [u32(b, p + 4 * i) for i in range(ns)]
    p += 4 * ns
    strings = []
    for n in lens:
        strings.append(b[p:p + n].decode("utf-8"))
        p += n

    def s(i):
        if i >= ns:
            raise Refused("InvalidState string index")
        return strings[i]
    roots = []
    for i in range(nr):
        o = p + 24 * i
        roots.append({"root_id": s(u32(b, o)), "label": s(u32(b, o + 4)), "kind": s(u32(b, o + 8)),
                      "origin": s(u32(b, o + 12)), "flags": u32(b, o + 16), "nlabels": u32(b, o + 20)})
    p += 24 * nr
    recs = []
    for i in range(nf):
        fl = u32(b, p + 4)
        ref = bool(fl & 64) if v3 else False
        L = 36 if ref else 76
        if p + L > len(b):
            raise Refused("InvalidState record past end")
        recs.append({"at": 32 + p, "ref": ref, "raw": b[p:p + L], "flags": fl})
        p += L
    labels = [s(u32(b, p + 4 * i)) for i in range(nl)]
    p += 4 * nl
    li = 0
    for r in roots:
        r["required_labels"] = labels[li:li + r["nlabels"]]
        li += r["nlabels"]
    entries = []
    last = None
    for rec in recs:
        r, fl = rec["raw"], rec["flags"]
        if fl & ~((1 << 7) - 1 if v3 else (1 << 6) - 1):
            raise Refused("InvalidState unknown flag")
        if rec["ref"]:
            root, mtime, chunks, chunker, nlab, ordinal, mlen = (u32(r, 0), struct.unpack_from("<q", r, 8)[0], u32(r, 16),
                                                                  u32(r, 20), u32(r, 24), u32(r, 28), u32(r, 32))
            if fl & 0b1101:
                raise Refused("StateReferenceFlags")
            if table is None:
                raise Refused("StateReferenceWithoutSource")
            if ordinal >= len(table):
                raise Refused("StateReferenceOutOfRange")
            if last is not None and ordinal <= last:
                raise Refused("StateReferenceOrder")
            last = ordinal
            tpath, sha, tlen = table[ordinal]
            rid = s(root)
            if rid == "r-legacy":
                path = tpath.decode()
            else:
                pre = (rid + "/").encode()
                if not (tpath.startswith(pre) and len(tpath) > len(pre)):
                    raise Refused("StateReferencePath")
                path = tpath[len(pre):].decode()
            moved = None
            if fl & 16:
                moved = b[p:p + mlen].decode()
                p += mlen
            e = {"root_id": rid, "path": path, "size": tlen, "sha256": sha.hex(), "pending": False,
                 "mtime_ms": mtime if fl & 2 else None, "chunks": chunks, "chunker": s(chunker) if fl & 32 else None,
                 "moved_from": moved, "required_labels": labels[li:li + nlab], "ordinal": ordinal}
        else:
            root, size, mtime, chunks, chunker, nlab, plen_, mlen = (u32(r, 0), u64(r, 8), struct.unpack_from("<q", r, 16)[0],
                                                                     u32(r, 24), u32(r, 28), u32(r, 32), u32(r, 36), u32(r, 40))
            path = b[p:p + plen_].decode()
            p += plen_
            moved = None
            if fl & 16:
                moved = b[p:p + mlen].decode()
                p += mlen
            e = {"root_id": s(root), "path": path, "size": size if fl & 1 else None,
                 "sha256": r[44:76].hex() if fl & 4 else None, "pending": bool(fl & 8),
                 "mtime_ms": mtime if fl & 2 else None, "chunks": chunks, "chunker": s(chunker) if fl & 32 else None,
                 "moved_from": moved, "required_labels": labels[li:li + nlab], "ordinal": None}
        li += e["required_labels"].__len__()
        entries.append(e)
    if p != len(b):
        raise Refused("InvalidState payload end")
    return {"v3": v3, "generation": gen, "analyzer": s(an), "roots": roots, "entries": entries, "recs": recs}


def stem(path):
    last = path.rsplit("/", 1)[-1]
    return last.rsplit(".", 1)[0] if "." in last else last


def decode_catalog(idx, mf):
    """Catalog entries (path, start, end, labels, id, text): v3 stored, v6 derived from the body anchor."""
    cb = open(os.path.join(idx, mf["catalog_file"]), "rb").read()
    version = struct.unpack_from("<H", cb, 8)[0]
    n = u32(cb, 12)
    p = 36
    out = []
    for _ in range(n):
        idl, pl, tl, vl, sl, el, ll = struct.unpack_from("<7I", cb, p)
        p += 28
        if version == 6 and (idl or tl):
            raise Refused("C1/C2")
        cid = cb[p:p + idl]; p += idl
        path = cb[p:p + pl].decode(); p += pl
        text = cb[p:p + tl].decode(); p += tl
        lab = cb[p:p + ll]; p += ll
        p += 4 * vl
        out.append({"path": path, "start": sl, "end": el, "labels": lab.hex(), "id": cid.hex(), "text": text})
    if version == 6:
        db = open(os.path.join(idx, mf["documents_file"]), "rb").read()
        docs = v5dec.decode_documents(db, bool(mf["flags"] & 1), check_checksum=False)
        best = {}
        for rec in docs["records"]:
            key = (rec["start"], rec["end"], rec["id"])
            path = rec["path"].decode() if isinstance(rec["path"], bytes) else rec["path"]
            if path not in best or key < best[path][0]:
                best[path] = (key, rec)
        for e in out:
            key, rec = best[e["path"]]
            if (rec["start"], rec["end"]) != (e["start"], e["end"]):
                raise Refused("FilenameCatalogMismatch lines")
            e["id"] = rec["id"].hex() if isinstance(rec["id"], bytes) else rec["id"]
            e["text"] = stem(e["path"])
    return version, out


def load(idx):
    mf = manifest(idx)
    sec = open(os.path.join(idx, mf["state_file"]), "rb").read()
    return mf, decode_state(sec, source_table(idx, mf))


def strip(e):
    return {k: v for k, v in e.items() if k != "ordinal"}


def main():
    cmd = sys.argv[1]
    if cmd == "dump":
        mf, st = load(sys.argv[2])
        for e in st["entries"]:
            print(json.dumps(e))
        return
    if cmd == "compare":
        a, b = sys.argv[2], sys.argv[3]
        ma, sa = load(a)
        mb, sb = load(b)
        diff = sum(1 for x, y in zip(sa["entries"], sb["entries"]) if strip(x) != strip(y))
        diff += abs(len(sa["entries"]) - len(sb["entries"]))
        refs = sum(1 for e in sb["entries"] if e["ordinal"] is not None)
        same_roots = sa["roots"] == sb["roots"] and sa["generation"] == sb["generation"] and sa["analyzer"] == sb["analyzer"]
        line = (f"{os.path.basename(a.rstrip('/'))}: state {'v3' if sa['v3'] else 'v2'} -> {'v3' if sb['v3'] else 'v2'}, "
                f"entries {len(sa['entries'])} / {len(sb['entries'])}, referenced {refs}, entries differing {diff}, "
                f"roots/generation/analyzer equal {same_roots}")
        if ma["flags"] & 8:
            va, ca = decode_catalog(a, ma)
            vb, cb = decode_catalog(b, mb)
            cd = sum(1 for x, y in zip(ca, cb) if x != y) + abs(len(ca) - len(cb))
            line += f"; catalog v{va} -> v{vb}, entries {len(ca)} / {len(cb)}, differing {cd}"
        print(line)


if __name__ == "__main__":
    main()
