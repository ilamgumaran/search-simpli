#!/usr/bin/env python3
"""Generate R's cross-language golden (S5-T5, fold-groups-v2, docs/tasks/S5-T5.md
Phase 1 ruling 7; docs/fold-groups-v2.md).

R (`src/search_platform/verb_forms.py`) is written for the same term sets as K's
golden (`scripts/gen_analyzer_v3_golden.py`): every analyzer-v2 term of J2's three
roots, of `fixtures/family-folder` and of the 10k timing corpus (generated into a
temporary folder), over file text and every path component; and R's traps.

For every term, in UTF-8 byte order, one line `term TAB bases TAB forms LF` (the
bases and the forms each joined by one space, empty when R does not apply) is
hashed into `digest.sha256`; `digest` also counts the terms, those R applies to and
the forms (R's exact lookups). The terms of J2, the family folder and the traps are
also listed in full: `listed` holds each one R applies to with its bases and forms,
`off` each one it does not. `zig/src/verb_forms_test.zig` computes R on every term
and must equal both, byte for byte.

Run: `python3 scripts/gen_verb_forms_golden.py > fixtures/verb-forms-golden.json`
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
from search_platform import verb_forms as r  # noqa: E402

J2_ROOTS = ("school", "home", "laptop")
TIMING_FILES = 10000

TRAPS = [
    # the -ing and -ed remainders: length, the vowel (y counts), undoubling (not l, s, z)
    "hopping", "hoping", "hoped", "hopped", "hop", "hope", "running", "sing", "bring", "thing",
    "string", "spring", "king", "ring", "feed", "need", "bleed", "red", "bed", "shed", "sled",
    "flying", "trying", "spying", "rhythm", "fizzing", "spelling", "missed", "buzzed", "rolled",
    "dancing", "cycled", "shopping", "knitting", "swimming", "planned", "stirring", "dripped",
    # -ied (five letters at least) and the consonant-y relatives
    "tidied", "buried", "cried", "died", "lied", "tied", "studied", "carried", "tidy", "play",
    "played", "enjoy", "stay",
    # S before R, and words S keeps
    "boxes", "dresses", "potatoes", "ponies", "glass", "tennis", "bus", "buses", "series",
    # F and A before R
    "Painting", "PAINTED", "ｐａｉｎｔｉｎｇ", "café", "naïve", "straße", "ﬁxing", "œuvre",
    # R off: length, digits, two pieces, not Latin a-z
    "aaa", "aaaa", "a" * 49, "a" * 50, "a" * 46 + "ing", "a" * 47 + "ing", "ab1d", "x²", "½",
    "løve", "mañana", "பாடல்கள்", "ing", "ed", "ied", "eing", "ying",
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
    sets["traps"] = set(TRAPS)
    every = set().union(*sets.values())
    digest = hashlib.sha256()
    applies = lookups = 0
    for term in utf8_sorted(every):
        bases, forms = r.bases(term), r.forms(term)
        applies += 1 if bases else 0
        lookups += len(forms)
        digest.update(f"{term}\t{' '.join(bases)}\t{' '.join(forms)}\n".encode("utf-8"))
    shown = sets["j2"] | sets["family-folder"] | sets["traps"]
    listed, off = [], []
    for term in utf8_sorted(shown):
        bases = r.bases(term)
        if bases:
            listed.append([term, bases, r.forms(term)])
        else:
            off.append(term)
    lines = ["{",
             '  "policy": "fold-groups-v2",',
             '  "rule": "R (docs/fold-groups-v2.md; docs/tasks/S5-T5-prototype.md, R restated)",',
             f'  "unicode": {json.dumps(v3.UNICODE_VERSION)},',
             '  "generator": "scripts/gen_verb_forms_golden.py",',
             '  "sets": {']
    names = list(sets)
    for i, name in enumerate(names):
        comma = "," if i + 1 < len(names) else ""
        lines.append(f"    {json.dumps(name)}: {json.dumps(describe(sets[name]))}{comma}")
    lines.append("  },")
    lines.append(f'  "digest": {{"terms": {len(every)}, "applies": {applies}, "lookups": {lookups}, '
                 f'"sha256": "{digest.hexdigest()}"}},')
    lines.append(f'  "count": {{"listed": {len(listed)}, "off": {len(off)}}},')
    lines.append('  "listed": [')
    lines.extend(f"    {json.dumps(row, ensure_ascii=False)}{',' if i + 1 < len(listed) else ''}"
                 for i, row in enumerate(listed))
    lines.append("  ],")
    lines.append('  "off": [')
    lines.extend(f"    {json.dumps(t, ensure_ascii=False)}{',' if i + 1 < len(off) else ''}" for i, t in enumerate(off))
    lines.append("  ]")
    lines.append("}")
    sys.stdout.write("\n".join(lines) + "\n")


if __name__ == "__main__":
    main()
