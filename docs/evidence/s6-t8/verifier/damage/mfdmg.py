"""S6-T8 verifier: manifest bit 7 and HYBLEX04 header damage, resealed. mfdmg.py OUTDIR -> one JSON line per case (head library).
Cases: bit 7 cleared over HYBLEX04; bit 7 set over main's HYBLEX03; bit 5 cleared with bit 7 kept; bit 8 set;
the HYBLEX04 header's version 3 / flags 0x0001 / 0x0007 (lexical checksum and manifest resealed)."""
import ctypes, json, shutil, struct, subprocess, sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent))
import dmg4
V = Path(__file__).resolve().parent.parent
OUT = Path(sys.argv[1]); OUT.mkdir(parents=True, exist_ok=True)

def manifest_flags(d, set_bits=0, clear_bits=0):
    m = bytearray((d / "MANIFEST").read_bytes())
    f = struct.unpack_from("<H", m, 10)[0]
    struct.pack_into("<H", m, 10, (f | set_bits) & ~clear_bits & 0xFFFF)
    struct.pack_into("<Q", m, 160, dmg4.fnv(bytes(m[:160]) + bytes(m[168:])))
    (d / "MANIFEST").write_bytes(m)

def lex_header(d, off, fmt, value):
    lexname, _ = dmg4.manifest_names(d)
    p = d / lexname
    b = bytearray(p.read_bytes())
    struct.pack_into(fmt, b, off, value)
    p.write_bytes(b)
    r = subprocess.run([dmg4.XXH, str(p), "80", "88"], capture_output=True, text=True, check=True)
    ck = int(r.stderr.strip()); struct.pack_into("<Q", b, 80, ck); p.write_bytes(b)
    m = bytearray((d / "MANIFEST").read_bytes())
    struct.pack_into("<QQ", m, 60, len(b), ck)
    struct.pack_into("<Q", m, 160, dmg4.fnv(bytes(m[:160]) + bytes(m[168:])))
    (d / "MANIFEST").write_bytes(m)

H, M = V / "idx.noindex/head/edge", V / "idx.noindex/main/edge"
cases = {
    "bit7_cleared_over_v4": (H, lambda d: manifest_flags(d, clear_bits=0x80)),
    "bit7_set_over_v3": (M, lambda d: manifest_flags(d, set_bits=0x80)),
    "bit5_cleared_bit7_kept": (H, lambda d: manifest_flags(d, clear_bits=0x20)),
    "bit8_set": (H, lambda d: manifest_flags(d, set_bits=0x100)),
    "v4_header_version_3": (H, lambda d: lex_header(d, 8, "<H", 3)),
    "v4_header_flags_0001": (H, lambda d: lex_header(d, 10, "<H", 1)),
    "v4_header_flags_0007": (H, lambda d: lex_header(d, 10, "<H", 7)),
}
lib = str(V / "libs/head/libsearch_simpli.dylib"); searchd = str(V / "bin/head/bin/searchd")
for name, (src, fn) in cases.items():
    d = OUT / name
    shutil.copytree(src, d)
    fn(d)
    code = ("import ctypes,sys; l=ctypes.CDLL(sys.argv[1]); l.ss_open.restype=ctypes.c_void_p; l.ss_open.argtypes=[ctypes.c_char_p];"
            "l.ss_last_error.restype=ctypes.c_char_p; h=l.ss_open(sys.argv[2].encode()); print('OPENED' if h else l.ss_last_error().decode())")
    a = subprocess.run([sys.executable, "-I", "-c", code, lib, str(d)], capture_output=True, text=True)
    c = subprocess.run([searchd, "query", str(d), "lonely", "--json"], capture_output=True, text=True)
    print(json.dumps({"case": name, "ss_open": (a.stdout.strip() or "crash %d" % a.returncode), "cli query": "exit %d %s" % (c.returncode, c.stderr.strip()[-60:])}))
