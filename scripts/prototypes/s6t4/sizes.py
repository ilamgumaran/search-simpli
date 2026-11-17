#!/usr/bin/env python3
"""S6-T4 Phase 1: section sizes of v2 and v3 indexes of the same files.

    python3 -I sizes.py V2_INDEX_DIR V3_INDEX_DIR

Reads each index's newest `lexical-N.hyblex` and `filename-lexical-N.hyblex`
headers (HYBLEX01, HYBLEX02 or the prototype's HYBLEX03) and prints one JSON
object: every section's bytes in both formats, the whole index's bytes, and
for v3 the bytes the dictionary spends on its per-term coded-postings length
(the field a lazy reader needs, `pbytes`). For a first-seen (HYBLEX01)
file-name dictionary it also front-codes that order, as S6-T3's F2 measured,
against the sorted order v3 writes. Not part of any library or the build.
"""

from __future__ import annotations

import json
import struct
import sys
from pathlib import Path


def varint(data: bytes, at: int) -> tuple[int, int]:
    value = shift = 0
    while True:
        byte = data[at]
        at += 1
        value |= (byte & 0x7F) << shift
        if byte < 0x80:
            return value, at
        shift += 7


def varint_len(value: int) -> int:
    n = 1
    while value >= 0x80:
        value >>= 7
        n += 1
    return n


def header(data: bytes) -> dict:
    magic = data[:8].decode()
    version, flags, docs, terms, posts = struct.unpack_from("<HHIIQ", data, 8)
    if magic == "HYBLEX01":
        lengths, dictionary, postings = struct.unpack_from("<QQQ", data, 32)
        return {"magic": magic, "header": 64, "documents": docs, "terms": terms, "postings": posts,
                "lengths": lengths, "dictionary": dictionary, "postings_bytes": postings, "positions": 0, "offsets": 0}
    lengths, dictionary, postings, positions, offsets = struct.unpack_from("<QQQQQ", data, 32)
    out = {"magic": magic, "header": 80 if magic == "HYBLEX02" else 88, "documents": docs, "terms": terms,
           "postings": posts, "lengths": lengths, "dictionary": dictionary, "postings_bytes": postings,
           "positions": positions, "offsets": offsets}
    if magic == "HYBLEX03":
        out["term_text"] = struct.unpack_from("<Q", data, 72)[0]
    return out


def v1_terms(data: bytes, h: dict) -> list[bytes]:
    at = h["header"] + h["lengths"]
    end = at + h["dictionary"]
    terms = []
    while at < end:
        length = struct.unpack_from("<I", data, at)[0]
        at += 24
        terms.append(data[at:at + length])
        at += length
    return terms


def front_coded_text(terms: list[bytes]) -> int:
    """Bytes of the shared-prefix and suffix-length varints plus suffixes."""
    total = 0
    previous = b""
    for term in terms:
        shared = 0
        while shared < min(len(previous), len(term)) and previous[shared] == term[shared]:
            shared += 1
        total += varint_len(shared) + varint_len(len(term) - shared) + len(term) - shared
        previous = term
    return total


def v3_pbytes(data: bytes, h: dict) -> int:
    at = h["header"] + h["lengths"]
    end = at + h["dictionary"]
    spent = 0
    while at < end:
        _, at = varint(data, at)
        suffix, at = varint(data, at)
        at += suffix
        _, at = varint(data, at)
        before = at
        _, at = varint(data, at)
        spent += at - before
    return spent


def newest(directory: Path, stem: str) -> Path | None:
    found = sorted(directory.glob(f"{stem}-*.hyblex"), key=lambda p: int(p.stem.rsplit("-", 1)[1]))
    return found[-1] if found else None


def main() -> int:
    v2_dir, v3_dir = Path(sys.argv[1]), Path(sys.argv[2])
    out = {"corpus": v2_dir.name}
    for stem in ("lexical", "filename-lexical"):
        row = {}
        for label, directory in (("v2", v2_dir), ("v3", v3_dir)):
            path = newest(directory, stem)
            if path is None:
                continue
            data = path.read_bytes()
            h = header(data)
            h["file_bytes"] = len(data)
            if h["magic"] == "HYBLEX03":
                h["pbytes_field"] = v3_pbytes(data, h)
            if h["magic"] == "HYBLEX01":
                terms = v1_terms(data, h)
                h["front_coded_text_first_seen"] = front_coded_text(terms)
                h["front_coded_text_sorted"] = front_coded_text(sorted(terms))
            row[label] = h
        out[stem] = row
    for label, directory in (("v2", v2_dir), ("v3", v3_dir)):
        out[f"index_bytes_{label}"] = sum(p.stat().st_size for p in directory.iterdir() if p.is_file())
    print(json.dumps(out, indent=1))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
