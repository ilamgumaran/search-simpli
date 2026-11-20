"""S6-T9 verifier: damage one index copy and reseal every checksum (section XXH3, the manifest's recorded section
checksum and length, the manifest's FNV-1a). Written by the verifier from the format documents.
    damage.py V SRC_IDX DST_IDX CASE
The case names are listed in CASES below. DST must not exist; it is an APFS clone of SRC (cp -c)."""
import os, struct, subprocess, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import statedec as sd

V, SRC, DST, CASE = sys.argv[1:5]


def fnv(b):
    h = 0xcbf29ce484222325
    for x in b:
        h = ((h ^ x) * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF
    return h


def xxh(path, ck, hdr):
    p = subprocess.run([f"{V}/tools/xxh", path, str(ck), str(hdr)], capture_output=True, text=True, check=True)
    return int(p.stderr.strip())


def reseal_manifest(m, ck_off):
    m = bytearray(m)
    struct.pack_into("<Q", m, ck_off, fnv(bytes(m[:ck_off]) + bytes(m[ck_off + 8:])))
    return m


def write_section(idx, name, data, ck_off, hdr, mlen_off, mck_off, plen_off):
    p = os.path.join(idx, name)
    data = bytearray(data)
    struct.pack_into("<Q", data, plen_off, len(data) - hdr)
    os.remove(p)  # break the clone link
    open(p, "wb").write(data)
    if struct.unpack_from("<H", data, 10)[0] & 1 or name.endswith(".hybstate"):
        v = xxh(p, ck_off, hdr)
    else:  # header flags bit 0 clear: FNV-1a 64 (main's v3 catalog)
        v = fnv(bytes(data[:ck_off]) + bytes(data[hdr:]))
    struct.pack_into("<Q", data, ck_off, v)
    open(p, "wb").write(data)
    mf = sd.manifest(idx)
    m = bytearray(mf["raw"])
    struct.pack_into("<Q", m, mlen_off, len(data))
    struct.pack_into("<Q", m, mck_off, v)
    write_manifest(idx, reseal_manifest(m, mf["ck_off"]))


def write_manifest(idx, m):
    p = os.path.join(idx, "MANIFEST")
    os.remove(p)
    open(p, "wb").write(m)


def state(idx):
    mf = sd.manifest(idx)
    sec = bytearray(open(os.path.join(idx, mf["state_file"]), "rb").read())
    st = sd.decode_state(bytes(sec), sd.source_table(idx, mf))
    return mf, sec, st


def put_state(idx, mf, sec):
    write_section(idx, mf["state_file"], sec, 24, 32, mf["state_off"], mf["state_off"] + 8, 16)


def catalog(idx):
    mf = sd.manifest(idx)
    return mf, bytearray(open(os.path.join(idx, mf["catalog_file"]), "rb").read())


def put_catalog(idx, mf, cb):
    write_section(idx, mf["catalog_file"], cb, 28, 36, 108, 116, 20)


def cat_records(cb):
    """offset of each record and its seven u32 fields"""
    n = struct.unpack_from("<I", cb, 12)[0]
    p, out = 36, []
    for _ in range(n):
        f = list(struct.unpack_from("<7I", cb, p))
        out.append((p, f))
        p += 28 + f[0] + f[1] + f[2] + f[6] + 4 * f[3]
    return out


def refs(st):
    return [r for r in st["recs"] if r["ref"]]


def set_u32(sec, at, v):
    struct.pack_into("<I", sec, at, v)


def drop_manifest_block(idx, which):
    """remove the state block (16 B) or the file-name block (48 B) and its strings, clear its bit"""
    mf = sd.manifest(idx)
    m = bytearray(mf["raw"])
    flags = mf["flags"]
    strings = list(mf["strings"])
    if which == "state":
        lo, n, bit = mf["state_off"], 16, 16
        strings = strings[:-1]
    else:
        lo, n, bit = 92, 48, 8
        strings = strings[:6] + strings[9:]  # catalog, file-name lexical, field id
    head = m[:lo] + m[lo + n:mf["payload_len_off"]]
    struct.pack_into("<H", head, 10, flags & ~bit)
    payload = b"".join(struct.pack("<I", len(s.encode())) + s.encode() for s in strings)
    ck_off = len(head) + 4
    out = bytearray(head) + struct.pack("<I", len(payload)) + bytes(8) + payload
    return out, ck_off


def flags_manifest(idx, set_bits=0, clear_bits=0):
    mf = sd.manifest(idx)
    m = bytearray(mf["raw"])
    struct.pack_into("<H", m, 10, (mf["flags"] | set_bits) & ~clear_bits)
    write_manifest(idx, reseal_manifest(m, mf["ck_off"]))


def run(case):
    idx = DST
    if case.startswith("S1-"):  # bit 0, 2 or 3 on the middle referenced record
        bit = int(case[3:])
        mf, sec, st = state(idx); r = refs(st)[len(refs(st)) // 2]
        set_u32(sec, r["at"] + 4, r["flags"] | (1 << bit)); put_state(idx, mf, sec)
    elif case in ("S3-count", "S3-max"):  # ordinal = file count, or 0xffffffff, on the last referenced record
        mf, sec, st = state(idx); r = refs(st)[-1]
        n = len(sd.source_table(idx, mf))
        set_u32(sec, r["at"] + 28, n if case == "S3-count" else 0xFFFFFFFF); put_state(idx, mf, sec)
    elif case in ("S4-first", "S4-mid", "S4-last", "S4-down"):
        mf, sec, st = state(idx); rr = refs(st); i = {"S4-first": 1, "S4-mid": len(rr) // 2, "S4-last": len(rr) - 1,
                                                        "S4-down": len(rr) // 2}[case]
        prev = struct.unpack_from("<I", rr[i - 1]["raw"], 28)[0]
        set_u32(sec, rr[i]["at"] + 28, prev if case != "S4-down" else max(prev - 1, 0)); put_state(idx, mf, sec)
    elif case == "S5":  # the middle referenced record's root moved to another root's string index
        mf, sec, st = state(idx); rr = refs(st); r = rr[len(rr) // 2]
        root = struct.unpack_from("<I", r["raw"], 0)[0]
        others = [x for x in rr if struct.unpack_from("<I", x["raw"], 0)[0] != root]
        set_u32(sec, r["at"], struct.unpack_from("<I", others[0]["raw"], 0)[0]); put_state(idx, mf, sec)
    elif case == "count-bound":  # file count raised to the payload's capacity + 1
        mf, sec, st = state(idx); b = sec[32:]
        ns, nr, nl = (struct.unpack_from("<I", b, o)[0] for o in (20, 24, 32))
        cap = (len(b) - 40 - 4 * ns - 24 * nr - 4 * nl) // 36
        set_u32(sec, 32 + 28, cap + 1); put_state(idx, mf, sec)
    elif case == "zero-mtime":  # a referenced record with bit 1 clear and a non-zero mtime (or bit 1 set: chunker check)
        mf, sec, st = state(idx); r = [x for x in refs(st) if not x["flags"] & 2] or None
        if r:
            struct.pack_into("<q", sec, r[0]["at"] + 8, 5); put_state(idx, mf, sec)
        else:  # every record has mtime: chunker non-zero with bit 5 clear, or moved_from length with bit 4 clear
            r = [x for x in refs(st) if not x["flags"] & 16][len(refs(st)) // 2]
            set_u32(sec, r["at"] + 32, 1); put_state(idx, mf, sec)
    elif case == "zero-moved":  # moved_from length non-zero with bit 4 clear
        mf, sec, st = state(idx); r = [x for x in refs(st) if not x["flags"] & 16]
        set_u32(sec, r[len(r) // 2]["at"] + 32, 1); put_state(idx, mf, sec)
    elif case == "zero-reserved":  # the payload header's reserved word at offset 4
        mf, sec, st = state(idx); set_u32(sec, 32 + 4, 1); put_state(idx, mf, sec)
    elif case in ("bit7", "bit31"):
        mf, sec, st = state(idx); r = refs(st)[len(refs(st)) // 2]
        set_u32(sec, r["at"] + 4, r["flags"] | (1 << int(case[3:]))); put_state(idx, mf, sec)
    elif case == "trailing":  # one byte after the payload's last text byte (payload length grows with it)
        mf, sec, st = state(idx); sec += b"\0"; put_state(idx, mf, sec)
    elif case == "hdr-version2":  # HYBSTA03 magic with header version 2
        mf, sec, st = state(idx); struct.pack_into("<H", sec, 8, 2); put_state(idx, mf, sec)
    elif case == "hdr-version4":
        mf, sec, st = state(idx); struct.pack_into("<H", sec, 8, 4); put_state(idx, mf, sec)
    elif case == "M1":
        m, ck = drop_manifest_block(idx, "state"); write_manifest(idx, reseal_manifest(m, ck))
    elif case == "M2":
        m, ck = drop_manifest_block(idx, "filename"); write_manifest(idx, reseal_manifest(m, ck))
    elif case == "M3-clear8":  # HYBSTA03 bound, bit 8 clear
        flags_manifest(idx, clear_bits=1 << 8)
    elif case == "M3-set8":  # on a v2.5 index (main's): bit 8 set over a HYBSTA02 state
        flags_manifest(idx, set_bits=1 << 8)
    elif case == "M4-clear9":
        flags_manifest(idx, clear_bits=1 << 9)
    elif case == "M4-set9":  # on main's index: bit 9 over a v3 catalog
        flags_manifest(idx, set_bits=1 << 9)
    elif case == "bit10":
        flags_manifest(idx, set_bits=1 << 10)
    elif case.startswith("C1-") or case.startswith("C2-"):  # 4 bytes of id or text inserted at record first/mid/last
        mf, cb = catalog(idx); recs = cat_records(cb)
        i = {"first": 0, "mid": len(recs) // 2, "last": len(recs) - 1}[case[3:]]
        at, f = recs[i]
        field = 0 if case.startswith("C1") else 2
        set_u32(cb, at + 4 * field, 4)
        # id bytes go first; text after the path
        ins = at + 28 if field == 0 else at + 28 + f[1]
        cb[ins:ins] = b"abcd"
        put_catalog(idx, mf, cb)
    elif case == "cat-version5":
        mf, cb = catalog(idx); struct.pack_into("<H", cb, 8, 5); put_catalog(idx, mf, cb)
    elif case == "cat-version3":  # v6 records under a v3 header, bit 9 kept
        mf, cb = catalog(idx); struct.pack_into("<H", cb, 8, 3); put_catalog(idx, mf, cb)
    elif case == "docs-version6":
        mf = sd.manifest(idx); p = os.path.join(idx, mf["documents_file"]); db = bytearray(open(p, "rb").read())
        struct.pack_into("<H", db, 8, 6)
        write_section(idx, mf["documents_file"], db, 28, 36, 44, 52, 20)
    elif case == "cat-trailing":
        mf, cb = catalog(idx); cb += b"\0"; put_catalog(idx, mf, cb)
    elif case == "cat-flip":  # a raw byte flipped in the catalog, nothing resealed
        mf = sd.manifest(idx); p = os.path.join(idx, mf["catalog_file"]); cb = bytearray(open(p, "rb").read())
        cb[len(cb) // 2] ^= 1; os.remove(p); open(p, "wb").write(cb)
    elif case == "cat-pathswap":  # resealed: the middle record's path's last byte changed (anchor not found)
        mf, cb = catalog(idx); recs = cat_records(cb); at, f = recs[len(recs) // 2]
        p = at + 28 + f[0] + f[1] - 1; cb[p] = ord("q") if cb[p] != ord("q") else ord("r"); put_catalog(idx, mf, cb)
    elif case == "cat-lines":  # resealed: the middle record's end line + 1 (FilenameCatalogMismatch)
        mf, cb = catalog(idx); recs = cat_records(cb); at, f = recs[len(recs) // 2]
        set_u32(cb, at + 20, f[5] + 1); put_catalog(idx, mf, cb)
    else:
        raise SystemExit("unknown case " + case)


if os.path.exists(DST):
    raise SystemExit(DST + " exists")
subprocess.run(["cp", "-c", "-R", SRC, DST], check=True)
run(CASE)
print("damaged", CASE)
