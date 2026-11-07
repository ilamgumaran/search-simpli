#!/usr/bin/env python3
"""Generate K's cross-language golden (S5-T4, fold-groups-v1, docs/tasks/S5-T4.md
ruling 14 and the orchestrator's ruling 11).

K (`src/search_platform/analyzer_v3.py`, F -> A -> S -> T) is written for:
- every analyzer-v2 term (the v2 split with the engine's simple fold, as
  `core._filename_tokenize` gives it) of J2's three roots, of
  `fixtures/family-folder` and of the 10k timing corpus
  (`scripts/gen_timing_corpus.py <dir> 10000`, generated into a temporary
  folder), over file text and every path component;
- every code point of the fold table (`_fold.FOLD`), singly;
- every trap of rulings 2-5, both keep lists and the known misses.

The file lists, for each set, its term count and the SHA-256 of its sorted terms
(newline-joined UTF-8), then `same` (the terms K leaves as they are) and `changed`
(each term with K's terms; an empty list where K leaves nothing), all sorted by
UTF-8 bytes. `zig/src/fold_test.zig` computes K on every listed term and must
equal it byte for byte.

Run: `python3 scripts/gen_analyzer_v3_golden.py > fixtures/analyzer-v3-golden.json`
"""
import hashlib
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "src"))
from search_platform import analyzer_v3 as v3  # noqa: E402
from search_platform import core  # noqa: E402

J2_ROOTS = ("school", "home", "laptop")
TIMING_FILES = 10000

TRAPS = [
    # ruling 2 (F)
    "ｇｏｇｇｌｅｓ", "ﬂute", "１２", "straße", "Straße", "Ⅻ", "x²", "½", "ﬁeld", "ǆ", "İstanbul", "ﬃ",
    # ruling 3 (A)
    "résumé", "resume", "crêpe", "øre", "łódź", "æsop", "frühling", "noël", "naïve", "pâte", "café",
    "đuro", "ħamrun", "ŧest", "ıi", "œuvre", "ά", "việt", "a⃗́",
    # ruling 4 (S)
    "ponies", "ties", "boxes", "classes", "lunches", "potatoes", "shoes", "toes", "tests", "rides",
    "glass", "virus", "tennis", "buses", "caches", "headaches", "movies", "cookies", "leaves", "abs",
    "cafés", "ss", "s" * 49 + "es", "a" * 50 + "s",
    # ruling 5 (T)
    "மரங்கள்", "பழங்கள்", "புத்தகங்கள்", "யானைகள்", "பாடல்கள்", "மரத்தில்", "நூலகத்தில்", "மரத்தின்",
    "கடைக்கு", "பள்ளிக்கு", "தேர்வுக்கு", "பள்ளியில்", "பாட்டியின்", "காலை", "நாளை", "தேர்வு",
    "நாட்கள்", "சொற்கள்", "கடலுக்கு", "வீட்டுக்கு", "கள்", "மக்கு",
]


def terms_of(root: Path) -> set:
    out = set()
    for path in sorted(root.rglob("*")):
        if not path.is_file():
            continue
        out.update(core._filename_tokenize(path.read_text(encoding="utf-8", errors="replace")))
        for part in path.relative_to(root).parts:
            out.update(core._filename_tokenize(part))
    return out


def utf8_sorted(terms) -> list:
    return sorted(terms, key=lambda t: t.encode("utf-8"))


def describe(terms: set) -> dict:
    ordered = utf8_sorted(terms)
    return {"terms": len(ordered),
            "sha256": hashlib.sha256("\n".join(ordered).encode("utf-8")).hexdigest()}


def main() -> None:
    sets = {}
    j2 = set()
    for root in J2_ROOTS:
        j2 |= terms_of(ROOT / "fixtures" / "j2" / root)
    sets["j2"] = j2
    sets["family-folder"] = terms_of(ROOT / "fixtures" / "family-folder")
    scratch = Path(os.environ.get("TMPDIR") or tempfile.gettempdir())
    with tempfile.TemporaryDirectory(dir=scratch) as temporary:
        corpus = Path(temporary) / "timing-10k"
        subprocess.run([sys.executable, str(ROOT / "scripts" / "gen_timing_corpus.py"), str(corpus),
                        str(TIMING_FILES)], check=True, stdout=subprocess.DEVNULL)
        sets["timing-10k"] = terms_of(corpus)
    sets["fold-table"] = {chr(cp) for cp in v3.FOLD}
    traps = set(TRAPS) | set(v3.PLURAL_KEEP) | set(v3.TAMIL_KEEP)
    sets["traps"] = traps
    every = set().union(*sets.values())
    same, changed = [], []
    for term in utf8_sorted(every):
        out = list(v3.key_terms(term))
        if out == [term]:
            same.append(term)
        else:
            changed.append([term, out])
    lines = ["{",
             f'  "policy": {json.dumps(v3.POLICY_ID)},',
             '  "key": "K = F, A, S, T (docs/tasks/S5-T4.md rulings 2-5)",',
             f'  "unicode": {json.dumps(v3.UNICODE_VERSION)},',
             '  "generator": "scripts/gen_analyzer_v3_golden.py",',
             '  "sets": {']
    names = list(sets)
    for i, name in enumerate(names):
        comma = "," if i + 1 < len(names) else ""
        lines.append(f"    {json.dumps(name)}: {json.dumps(describe(sets[name]))}{comma}")
    lines.append("  },")
    lines.append(f'  "count": {{"terms": {len(every)}, "same": {len(same)}, "changed": {len(changed)}}},')
    lines.append('  "same": [')
    lines.extend(f"    {json.dumps(t, ensure_ascii=False)}{',' if i + 1 < len(same) else ''}" for i, t in enumerate(same))
    lines.append("  ],")
    lines.append('  "changed": [')
    lines.extend(f"    {json.dumps(c, ensure_ascii=False)}{',' if i + 1 < len(changed) else ''}"
                 for i, c in enumerate(changed))
    lines.append("  ]")
    lines.append("}")
    sys.stdout.write("\n".join(lines) + "\n")


if __name__ == "__main__":
    main()
