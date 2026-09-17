#!/usr/bin/env python3
"""Generate zig/src/unicode_tables.zig from Python's built-in Unicode
character database (`unicodedata`), for `analyzer-v2` (S1-T1).

Zig 0.16.0's `std.unicode` (checked directly against the pinned toolchain's
`lib/std/unicode.zig`) only encodes/decodes UTF-8 and UTF-16; it carries no
general-category, case-folding, or normalization data. The task instructions
call for either hand-implemented tables from data std exposes, or "a compact
generated table" -- this script takes the second path, generating Zig source
tables from Python 3's bundled Unicode Character Database. Python 3.9's
`unicodedata` module reports version `unicodedata.unidata_version` below;
that string is also written into the generated file's header comment so the
Unicode version in force is always visible next to the tables it produced.

Three tables are produced:

1. `letter_digit_ranges`: sorted, non-overlapping inclusive [start, end]
   codepoint ranges whose General_Category is one of Lu/Ll/Lt/Lm/Lo (letter)
   or Nd/Nl/No (number) -- i.e. exactly the categories the task's "letters
   and digits by Unicode category" criterion names. Combining marks (Mn/Mc)
   are deliberately excluded: they are neither letters nor digits by
   category, and this also keeps analyzer-v2 tokenization consistent with
   `search_platform.core.tokenize`'s existing `[^\\W_]+` regex, whose `\\w`
   is defined by CPython as alpha-or-numeric-or-underscore, not by
   mark membership (verified interactively: `'\\u0bcd'.isalnum()` is
   `False` for the Tamil virama, category `Mn`).
2. `casefold_pairs`: sorted (from, to) codepoint pairs for every codepoint
   whose `str.casefold()` result is a single codepoint different from the
   input. Multi-codepoint casefold expansions (e.g. German sharp s, a
   handful of ligatures) are intentionally out of scope for this simple
   per-codepoint fold; see the analyzer-v2 doc comment in
   `zig/src/analyzer_v2.zig` for the documented limitation.
3. NFC support: `decomposition_pairs` (codepoint -> canonical 2-codepoint
   decomposition only, compatibility decompositions with a <tag> excluded),
   `combining_class_pairs` (codepoint -> non-zero canonical combining
   class), and `composition_pairs` ((starter, combiner) -> composed
   codepoint). The composition table is generated empirically: for every
   candidate pair produced by inverting the decomposition table, the pair
   is included only if `unicodedata.normalize('NFC', chr(a) + chr(b)) ==
   chr(composed)` -- which lets Python's own (correct) NFC implementation
   serve as the oracle that naturally excludes the Unicode
   "composition exclusion" set without needing to vendor that list
   separately. Hangul syllable decomposition/composition is algorithmic in
   the Unicode Standard (not data-table driven) and is deliberately left
   out of these generated tables; see the same limitation note.

Run: `python3 scripts/gen_unicode_tables.py > zig/src/unicode_tables.zig`
No third-party dependencies; stdlib `unicodedata` only.
"""
import sys
import unicodedata

MAX_CODEPOINT = 0x110000
LETTER_DIGIT_CATEGORIES = {"Lu", "Ll", "Lt", "Lm", "Lo", "Nd", "Nl", "No"}

# Hangul syllable block: algorithmic in Unicode, not data-table driven.
# Excluded from decomposition/composition generation (documented above).
HANGUL_SYLLABLE_START = 0xAC00
HANGUL_SYLLABLE_END = 0xD7A3


def is_hangul_syllable(cp: int) -> bool:
    return HANGUL_SYLLABLE_START <= cp <= HANGUL_SYLLABLE_END


def gen_letter_digit_ranges():
    ranges = []
    start = None
    for cp in range(MAX_CODEPOINT):
        cat = unicodedata.category(chr(cp))
        member = cat in LETTER_DIGIT_CATEGORIES
        if member and start is None:
            start = cp
        elif not member and start is not None:
            ranges.append((start, cp - 1))
            start = None
    if start is not None:
        ranges.append((start, MAX_CODEPOINT - 1))
    return ranges


def gen_casefold_pairs():
    pairs = []
    for cp in range(MAX_CODEPOINT):
        ch = chr(cp)
        folded = ch.casefold()
        if len(folded) == 1 and folded != ch:
            pairs.append((cp, ord(folded)))
    return pairs


def gen_decomposition_and_combining_class():
    decomposition = {}
    combining = {}
    for cp in range(MAX_CODEPOINT):
        if is_hangul_syllable(cp):
            continue
        ch = chr(cp)
        ccc = unicodedata.combining(ch)
        if ccc != 0:
            combining[cp] = ccc
        raw = unicodedata.decomposition(ch)
        if not raw:
            continue
        if raw.startswith("<"):
            continue  # compatibility decomposition; NFC only wants canonical
        parts = [int(p, 16) for p in raw.split(" ")]
        if len(parts) != 2:
            continue  # singleton canonical decompositions do not affect NFC recomposition
        decomposition[cp] = tuple(parts)
    return decomposition, combining


def gen_composition_pairs(decomposition):
    pairs = []
    for composed, (a, b) in decomposition.items():
        if is_hangul_syllable(a) or is_hangul_syllable(b):
            continue
        candidate = chr(a) + chr(b)
        normalized = unicodedata.normalize("NFC", candidate)
        if normalized == chr(composed):
            pairs.append((a, b, composed))
    pairs.sort()
    return pairs


def fmt_ranges(ranges):
    lines = []
    for start, end in ranges:
        lines.append(f"    .{{ .start = 0x{start:X}, .end = 0x{end:X} }},")
    return "\n".join(lines)


def fmt_pairs2(pairs, field_a="from", field_b="to"):
    lines = []
    for a, b in pairs:
        lines.append(f"    .{{ .{field_a} = 0x{a:X}, .{field_b} = 0x{b:X} }},")
    return "\n".join(lines)


def fmt_triples(triples):
    lines = []
    for a, b, c in triples:
        lines.append(f"    .{{ .a = 0x{a:X}, .b = 0x{b:X}, .composed = 0x{c:X} }},")
    return "\n".join(lines)


def main():
    unidata_version = unicodedata.unidata_version
    python_version = sys.version.split()[0]

    letter_digit_ranges = gen_letter_digit_ranges()
    casefold_pairs = gen_casefold_pairs()
    decomposition, combining = gen_decomposition_and_combining_class()
    composition_pairs = gen_composition_pairs(decomposition)

    decomposition_pairs = sorted(decomposition.items())
    combining_pairs = sorted(combining.items())

    out = []
    out.append("//! Generated file -- do not edit by hand.")
    out.append(f"//! Produced by scripts/gen_unicode_tables.py using Python {python_version}'s")
    out.append(f"//! `unicodedata` module, Unicode Character Database version {unidata_version}.")
    out.append("//! Regenerate with: python3 scripts/gen_unicode_tables.py > zig/src/unicode_tables.zig")
    out.append("//!")
    out.append(f"//! unicode_version = \"{unidata_version}\"")
    out.append("")
    out.append(f'pub const unicode_version = "{unidata_version}";')
    out.append("")
    out.append("pub const CodepointRange = struct { start: u21, end: u21 };")
    out.append("pub const CasefoldPair = struct { from: u21, to: u21 };")
    out.append("pub const DecompositionPair = struct { from: u21, a: u21, b: u21 };")
    out.append("pub const CombiningClassPair = struct { codepoint: u21, ccc: u8 };")
    out.append("pub const CompositionTriple = struct { a: u21, b: u21, composed: u21 };")
    out.append("")
    out.append(f"/// {len(letter_digit_ranges)} ranges covering Unicode General_Category")
    out.append("/// Lu, Ll, Lt, Lm, Lo (letter) and Nd, Nl, No (number).")
    out.append("pub const letter_digit_ranges = [_]CodepointRange{")
    out.append(fmt_ranges(letter_digit_ranges))
    out.append("};")
    out.append("")
    out.append(f"/// {len(casefold_pairs)} single-codepoint simple case-fold exceptions")
    out.append("/// (str.casefold() results that are themselves single codepoints).")
    out.append("pub const casefold_pairs = [_]CasefoldPair{")
    out.append(fmt_pairs2(casefold_pairs))
    out.append("};")
    out.append("")
    out.append(f"/// {len(decomposition_pairs)} canonical (non-compatibility) two-codepoint")
    out.append("/// decompositions, sorted by `from`. Hangul syllables excluded (algorithmic).")
    out.append("pub const decomposition_pairs = [_]DecompositionPair{")
    out.append("\n".join(
        f"    .{{ .from = 0x{cp:X}, .a = 0x{a:X}, .b = 0x{b:X} }}," for cp, (a, b) in decomposition_pairs
    ))
    out.append("};")
    out.append("")
    out.append(f"/// {len(combining_pairs)} codepoints with non-zero canonical combining class.")
    out.append("pub const combining_class_pairs = [_]CombiningClassPair{")
    out.append("\n".join(
        f"    .{{ .codepoint = 0x{cp:X}, .ccc = {ccc} }}," for cp, ccc in combining_pairs
    ))
    out.append("};")
    out.append("")
    out.append(f"/// {len(composition_pairs)} canonical composition pairs, empirically derived")
    out.append("/// (see script docstring): (a, b) -> composed only where Python's own")
    out.append("/// `unicodedata.normalize('NFC', chr(a) + chr(b))` agrees, which excludes")
    out.append("/// the Unicode composition-exclusion set without vendoring it separately.")
    out.append("pub const composition_pairs = [_]CompositionTriple{")
    out.append(fmt_triples(composition_pairs))
    out.append("};")
    out.append("")
    print("\n".join(out))


if __name__ == "__main__":
    main()
