"""S6-T9 verifier: compare the current generation of two indexes file by file (by role, from the manifests).
gencmp.py A B -> per role: same / differs; and whether the MANIFESTs are byte-identical."""
import os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import statedec as sd
a, b = sys.argv[1:3]
ma, mb = sd.manifest(a), sd.manifest(b)
roles = {"documents": 2, "lexical": 3, "source": 4, "meta": 5, "catalog": 6, "fn_lexical": 7, "field": 8, "state": 9}
out = []
for r, i in roles.items():
    fa, fb = ma["strings"][i], mb["strings"][i]
    if r in ("meta", "field"):
        out.append(f"{r} {'same' if fa == fb else 'DIFFERS'}"); continue
    da, db = open(os.path.join(a, fa), "rb").read(), open(os.path.join(b, fb), "rb").read()
    out.append(f"{r} {'same' if da == db else 'DIFFERS'}")
print(os.path.basename(os.path.dirname(a.rstrip('/'))), os.path.basename(os.path.dirname(b.rstrip('/'))), os.path.basename(a.rstrip('/')),
      "gen", ma["generation"], mb["generation"], "flags", hex(ma["flags"]), hex(mb["flags"]), "MANIFEST", "same" if ma["raw"] == mb["raw"] else "DIFFERS", "|", ", ".join(out))
