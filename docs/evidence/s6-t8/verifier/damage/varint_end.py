"""S6-T8 verifier: the document's precedence question: the last document's count as five continuation bytes (80 80 80 80 80)
and then the section's end. My decoder (from the document) says OffsetsVarintOverflow; check4.py shows the library's answer.
varint_end.py SRC_IDX OUT_IDX"""
import shutil, sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent)); sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "dec"))
import dmg4, v4dec
src, out = Path(sys.argv[1]), Path(sys.argv[2])
lexname, _ = dmg4.manifest_names(src)
lex = v4dec.decode_lexical((src / lexname).read_bytes())
m = dmg4.model_v4(lex["offsets"])
m["docs"][-1] = {"count": b"\x80\x80\x80\x80\x80", "tokens": []}
shutil.copytree(src, out)
s5 = dmg4.encode_v4(m)
dmg4.reseal(out, lexname, s5)
try:
    v4dec.decode_v4_offsets(s5, 0, len(s5), lex["lengths"])
except v4dec.Refused as e:
    print("my decoder (from the document):", e.name)
