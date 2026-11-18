"""S6-T7 verifier: decode each head-written index with v5dec.py, rebuild every retained file,
compare with the corpus bytes on disk and with the stored SHA-256.
Usage: check_corpora.py IDXROOT CORPORA_ROOT FIXTURES_ROOT [corpus ...]"""
import hashlib
import json
import os
import struct
import sys
from collections import Counter
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import v5dec  # noqa: E402

idxroot, corpora, fixtures = map(Path, sys.argv[1:4])
names = sys.argv[4:] or ["j2", "fixtures", "family", "timing-10k", "prose-10k", "tamil-10k"]


def disk_path(corpus, rel):
    rel = rel.decode("utf-8")
    if corpus in ("timing-10k", "prose-10k", "tamil-10k", "edge"):
        return corpora / corpus / rel
    if corpus == "fixtures":
        return fixtures / rel
    if corpus == "family":
        return fixtures / "family-folder" / rel
    root, _, rest = rel.partition("/")
    return fixtures / "j2" / root / rest


def corpus_files(corpus):
    base = {"fixtures": fixtures, "family": fixtures / "family-folder"}.get(corpus)
    if corpus in ("timing-10k", "prose-10k", "tamil-10k", "edge"):
        base = corpora / corpus
    if corpus == "j2":
        out = set()
        for root in ("school", "home", "laptop"):
            for p in (fixtures / "j2" / root).rglob("*"):
                if p.is_file():
                    out.add(root + "/" + p.relative_to(fixtures / "j2" / root).as_posix())
        return out
    return {p.relative_to(base).as_posix() for p in base.rglob("*") if p.is_file()}


report = {}
for corpus in names:
    d = idxroot / corpus
    man = (d / "MANIFEST").read_bytes()
    mflags = struct.unpack_from("<H", man, 10)[0]
    mdocs = struct.unpack_from("<I", man, 20)[0]
    dlen, dck = struct.unpack_from("<QQ", man, 44)
    slen, sck = struct.unpack_from("<QQ", man, 76)
    gens = sorted(int(p.name.split("-")[1].split(".")[0]) for p in d.glob("documents-*.hybseg"))
    g = gens[-1]
    dp, sp = d / f"documents-{g}.hybseg", d / f"source-{g}.hybsrc"
    db, sb = dp.read_bytes(), sp.read_bytes()
    docs = v5dec.decode_documents(db, True, str(dp))
    src = v5dec.decode_source(sb, docs, str(sp))
    st = Counter()
    st["manifest_bit6"] = int(bool(mflags & 0x40))
    st["manifest_docs_eq"] = int(mdocs == docs["ndocs"])
    st["manifest_doc_binding"] = int(dlen == len(db) and dck == docs["checksum"])
    st["manifest_src_binding"] = int(slen == len(sb) and sck == src["checksum"])
    st["files_in_table"] = len(docs["files"])
    st["records"] = docs["ndocs"]
    st["path_bytes"] = sum(len(f["path"]) for f in docs["files"])
    raw_ids = sum(1 for r in docs["records"] if len(r["id"]) == 20)
    st["raw_ids_20hex"] = raw_ids
    mism = []
    for s in src["files"]:
        f = s["file"]
        out = v5dec.rebuild(sb, docs, s)
        disk = disk_path(corpus, f["path"]).read_bytes()
        st["retained_checked"] += 1
        if out != disk or hashlib.sha256(disk).digest() != s["sha"]:
            mism.append(f["path"].decode())
        if s["whole"]:
            st["kept_whole"] += 1
            if f["n"] == 0:
                st["whole_no_chunk"] += 1
            if len(disk) == 0:
                st["whole_empty"] += 1
            if b"\r\n" in disk:
                st["whole_crlf"] += 1
            elif b"\r" in disk:
                st["whole_lone_cr"] += 1
        else:
            st["rebuilt_from_chunks"] += 1
            for j, v in enumerate(s["recipe"]):
                if v % 2 == 1:
                    st["overlaps"] += 1
                    if (v + 1) // 2 >= len(docs["records"][f["first"] + j]["text"]):
                        st["contained"] += 1
            if not disk.endswith((b"\n", b"\r")) and disk:
                st["rebuilt_no_final_newline"] += 1
        if s["bom"]:
            st["bom"] += 1
        st["residual_bytes"] += s["res_len"]
    table_paths = {f["path"].decode() for f in docs["files"]}
    on_disk = corpus_files(corpus)
    st["mismatches"] = len(mism)
    st["table_eq_disk_set"] = int(table_paths == on_disk)
    st["disk_files"] = len(on_disk)
    report[corpus] = {"stats": dict(st), "mismatch_paths": mism[:20],
                      "missing_from_table": sorted(on_disk - table_paths)[:20]}
    print(corpus, json.dumps(dict(st)), flush=True)
json.dump(report, sys.stdout if False else open(os.environ.get("OUT", "/dev/null"), "w"), indent=1)
