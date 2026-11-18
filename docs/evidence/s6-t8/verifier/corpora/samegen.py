"""S6-T8 verifier: compare the current generation's section files of index A with index B's (latest N of each kind).
samegen.py A B -> one line: kind: same|differs"""
import re, sys
from pathlib import Path
a, b = Path(sys.argv[1]), Path(sys.argv[2])
def latest(d):
    out = {}
    for p in d.iterdir():
        m = re.fullmatch(r"([a-z-]+)-(\d+)\.(\w+)", p.name)
        if m:
            k = m.group(1) + "." + m.group(3)
            if k not in out or int(m.group(2)) > out[k][0]:
                out[k] = (int(m.group(2)), p)
    return out
la, lb = latest(a), latest(b)
res = {k: ("same" if la[k][1].read_bytes() == lb[k][1].read_bytes() else "differs") if k in lb else "missing" for k in sorted(la)}
ma, mb = (a / "MANIFEST").read_bytes(), (b / "MANIFEST").read_bytes()
res["manifest_flags"] = "%#x/%#x" % (int.from_bytes(ma[10:12], "little"), int.from_bytes(mb[10:12], "little"))
print(" ".join("%s:%s" % kv for kv in res.items()))
