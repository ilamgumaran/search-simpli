#!/usr/bin/env python3
"""S6-T7 verifier (rework): index files that start with a byte-order mark with the head library (ss_index_folder)
and print each record's chunk text and each source record's bom/whole flags (decoder/v5dec.py).
bomcheck.py LIB DECODER_DIR WORKDIR"""
import ctypes, sys
from pathlib import Path
lib, dec, work = sys.argv[1], sys.argv[2], Path(sys.argv[3])
sys.path.insert(0, dec)
import v5dec
B = b"\xef\xbb\xbf"
files = {"a-bom-only.txt": B, "b-bom-nl.txt": B + b"\n", "c-bom-space.txt": B + b" \n", "d-bom-x.txt": B + b"x\n",
         "e-bom-bom.txt": B + B + b"x\n", "f-bom-only.md": B, "g-bom-nl-x.md": B + b"\n\nx\n"}
(work / "in").mkdir(parents=True, exist_ok=True); (work / "out").mkdir(parents=True, exist_ok=True)
for k, v in files.items(): (work / "in" / k).write_bytes(v)
l = ctypes.CDLL(lib)
l.ss_index_folder.restype = ctypes.c_void_p; l.ss_index_folder.argtypes = [ctypes.c_char_p] * 3
l.ss_last_error.restype = ctypes.c_char_p
assert l.ss_index_folder(str(work / "out").encode(), str(work / "in").encode(), b"{}"), l.ss_last_error()
d = work / "out"
g = sorted(int(p.name.split("-")[1].split(".")[0]) for p in d.glob("documents-*.hybseg"))[-1]
docs = v5dec.decode_documents((d / f"documents-{g}.hybseg").read_bytes(), True, check_checksum=False)
src = v5dec.decode_source((d / f"source-{g}.hybsrc").read_bytes(), docs, check_checksum=False)
ret = [f for f in docs["files"] if f["retained"]]
for f, s in zip(ret, src["files"]):
    recs = [r for r in docs["records"] if r["path"] == f["path"]]
    print(f["path"].decode(), "bytes", files[f["path"].decode()].hex(), "| bom", int(s["bom"]), "whole", int(s["whole"]),
          "recipe", s["recipe"], "| chunks", [(r["start"], r["end"], r["text"].hex()) for r in recs])
