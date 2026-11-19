"""S6-T8 verifier: section 5 cut inside a 16-token block: the blocks index's last document (40 tokens) keeps only its
first CUT tokens (its count left at 40), the section, its checksum and the manifest resealed.
cutblocks.py SRC_IDX OUT_PREFIX CUT..."""
import shutil, sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent)); sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "dec"))
import dmg4, v4dec
src = Path(sys.argv[1])
lexname, _ = dmg4.manifest_names(src)
spans = v4dec.decode_lexical((src / lexname).read_bytes())["offsets"]
d = len(spans) - 1
print("last doc tokens", len(spans[d]))
for cut in map(int, sys.argv[3:]):
    mm = dmg4.model_v4(spans)
    mm["docs"][d]["tokens"] = mm["docs"][d]["tokens"][:cut]
    out = Path(sys.argv[2] + "-%d" % cut)
    shutil.copytree(src, out)
    dmg4.reseal(out, lexname, dmg4.encode_v4(mm))
    print(out.name)
