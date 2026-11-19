"""S6-T8 verifier (fifth check): apply.offsetTableStarts' v4 walk (postings.oneByteTableEnd) in Python over a damaged
index's section 5: where it ends, or the table where it runs out. walk4.py INDEXDIR UNDAMAGED_INDEXDIR (document lengths from the undamaged copy)"""
import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent))
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "dec"))
import dmg4, v4dec
d = Path(sys.argv[1])
lexname, _ = dmg4.manifest_names(d)
b = (d / lexname).read_bytes()
magic, flags, ndocs, lens, hl = v4dec.header(b)
s = hl + sum(lens[:4])
sec = b[s:s + lens[4]] if len(lens) > 4 else b[s:]
g = Path(sys.argv[2])
gb = (g / dmg4.manifest_names(g)[0]).read_bytes()
lengths = [len(t) for t in v4dec.decode_lexical(gb)["offsets"]]
def skip(at):
    while True:
        if at >= len(sec):
            return None
        c = sec[at]; at += 1
        if c & 0x80 == 0:
            return at
at = 0
for i, length in enumerate(lengths):
    at = skip(at)
    if at is None:
        print("null at table", i, "(count)"); sys.exit()
    for _ in range(length):
        if at >= len(sec):
            print("null at table", i, "(token)"); sys.exit()
        c = sec[at]; at += 1
        for esc in ((c & 0x0F) == 15, (c >> 4) == 15):
            if esc:
                at = skip(at)
                if at is None:
                    print("null at table", i, "(escape)"); sys.exit()
print("walk ends at", at, "of", len(sec), "->", "end check refuses" if at != len(sec) else "end check passes")
