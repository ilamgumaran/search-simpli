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
   and digits by Unicode category" criterion names. Marks are not
   in this table: they are neither letters nor digits.
   Table 1b, `mark_ranges` (S1-T14), holds General_Category Mn and Mc. The
   analyzer lets a token continue through them (Tamil, Devanagari, Thai ...
   write vowels as marks, so splitting at them cut `கணினி` in two). With
   `--python-marks` the same table is emitted as `src/search_platform/_marks.py`
   for the Python reference tokenizer.
2. `casefold_pairs`: sorted (from, to) codepoint pairs for every codepoint
   whose `str.casefold()` result is a single codepoint different from the
   input. Multi-codepoint casefold expansions (e.g. German sharp s, a
   handful of ligatures) are intentionally out of scope for this simple
   per-codepoint fold; see the analyzer-v2 doc comment in
   `zig/src/analyzer_v2.zig` for the documented limitation.
3. NFC support: `decomposition_pairs` (codepoint -> canonical 2-codepoint
   decomposition, two codepoints or a singleton (stored with b = 0; S1-T15),
   compatibility decompositions with a <tag> excluded),
   `combining_class_pairs` (codepoint -> non-zero canonical combining
   class), and `composition_pairs` ((starter, combiner) -> composed
   codepoint). The composition table is generated empirically: for every
   candidate pair produced by inverting the decomposition table, the pair
   is included only if `unicodedata.normalize('NFC', chr(a) + chr(b)) ==
   chr(composed)` -- which lets Python's own (correct) NFC implementation
   serve as the oracle that naturally excludes the Unicode
   "composition exclusion" set without needing to vendor that list
   separately. Hangul syllable decomposition/composition is algorithmic in
   the Unicode Standard (not data-table driven) and is left out of these
   generated tables; `zig/src/nfc.zig` implements it (S1-T15).

4. The fold table (S5-T4, `fold-groups-v1`, docs/tasks/S5-T4.md ruling 2): for
   every code point c (surrogates excepted) whose fold differs from c, the fold
   `NFKC(casefold(NFKC(c)))` iterated to a fixpoint. With `--python-fold` it is
   emitted as `src/search_platform/_fold.py` for the Python mirror of K
   (`src/search_platform/analyzer_v3.py`), which reads the table and never calls
   `str.casefold` or NFKC at run time. The header records the counts the plan
   states: the code points that change, those not already handled by NFC and a
   simple lowercase map, their UTF-8 bytes, the multi-code-point outputs and the
   longest.
   In `zig/src/unicode_tables.zig` (for `zig/src/fold.zig`) the table holds only
   the code points where the fold differs from what the engine already does:
   NFC of analyzer-v2's simple fold of c (`casefold_pairs`, c itself when
   `str.casefold()` expands). Every other code point folds through that path, and
   NFC of a concatenation depends only on the canonical class of each part, so
   the result is the same. The table is four parallel pieces: the sorted code
   points, an index into the distinct outputs, the outputs' offsets, and their
   UTF-8 bytes in one pool.

Run: `python3 scripts/gen_unicode_tables.py > zig/src/unicode_tables.zig`
No third-party dependencies; stdlib `unicodedata` only.
"""
import sys
import unicodedata

MAX_CODEPOINT = 0x110000
LETTER_DIGIT_CATEGORIES = {"Lu", "Ll", "Lt", "Lm", "Lo", "Nd", "Nl", "No"}
# S1-T14: marks that stay attached to the letter before them (Tamil, Devanagari
# and Thai vowel signs are Mn/Mc). Enclosing marks (Me) are not included.
MARK_CATEGORIES = {"Mn", "Mc"}

# Hangul syllable block: algorithmic in Unicode, not data-table driven.
# Excluded from decomposition/composition generation (documented above).
HANGUL_SYLLABLE_START = 0xAC00
HANGUL_SYLLABLE_END = 0xD7A3


def is_hangul_syllable(cp: int) -> bool:
    return HANGUL_SYLLABLE_START <= cp <= HANGUL_SYLLABLE_END


def gen_letter_digit_ranges(categories=LETTER_DIGIT_CATEGORIES):
    ranges = []
    start = None
    for cp in range(MAX_CODEPOINT):
        cat = unicodedata.category(chr(cp))
        member = cat in categories
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
        # S1-T15: a singleton (one target codepoint, e.g. U+212B ANGSTROM SIGN
        # -> U+00C5, CJK compatibility ideographs) DOES change NFC: the
        # source is replaced by its target. It is stored with b = 0, which no
        # real decomposition uses. (Before S1-T15 these were skipped on the
        # wrong belief that they do not matter.)
        if len(parts) == 1:
            decomposition[cp] = (parts[0], 0)
        elif len(parts) == 2:
            decomposition[cp] = tuple(parts)
    return decomposition, combining


def gen_composition_pairs(decomposition):
    pairs = []
    for composed, (a, b) in decomposition.items():
        if b == 0:
            continue  # singleton: never the result of composing two codepoints
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


def main_python_marks():
    """`--python-marks`: emit src/search_platform/_marks.py (S1-T14)."""
    ranges = gen_letter_digit_ranges(MARK_CATEGORIES)
    out = ['"""Generated file -- do not edit by hand.',
           "",
           f"Produced by scripts/gen_unicode_tables.py --python-marks using Python {sys.version.split()[0]}'s",
           f"`unicodedata` (Unicode {unicodedata.unidata_version}): the {len(ranges)} ranges of General_Category Mn and Mc,",
           "the same table the Zig analyzer uses (`mark_ranges` in zig/src/unicode_tables.zig).",
           "Regenerate: python3 scripts/gen_unicode_tables.py --python-marks > src/search_platform/_marks.py",
           '"""',
           "",
           "MARK_RANGES = (",
           ]
    out.extend(f"    (0x{a:X}, 0x{b:X})," for a, b in ranges)
    out.append(")")
    out.append("")
    print("\n".join(out))


def fold_code_point(cp: int) -> str:
    """`NFKC(casefold(NFKC(c)))` iterated to a fixpoint (one more round is never needed
    in Unicode 13.0.0; the loop stops on a repeat)."""
    out = chr(cp)
    for _ in range(8):
        nxt = unicodedata.normalize("NFKC", unicodedata.normalize("NFKC", out).casefold())
        if nxt == out:
            return out
        out = nxt
    raise SystemExit(f"fold of U+{cp:04X} has no fixpoint in 8 rounds")


def gen_fold_table():
    """Every code point whose fold differs from itself, with the fold."""
    table = []
    for cp in range(MAX_CODEPOINT):
        if 0xD800 <= cp <= 0xDFFF:
            continue
        folded = fold_code_point(cp)
        if folded != chr(cp):
            table.append((cp, folded))
    return table


def fold_table_counts(table):
    """The plan's counts (docs/tasks/S5-T4-prototype.md): `new` are the entries a
    simple lowercase map over NFD, then NFC, does not already give."""
    def simple_lower(ch: str) -> str:
        lowered = ch.lower()
        return lowered if len(lowered) == 1 else ch
    new = [(cp, f) for cp, f in table
           if f != unicodedata.normalize("NFC", "".join(simple_lower(c) for c in unicodedata.normalize("NFD", chr(cp))))]
    return {"changed": len(table), "new": len(new), "new_utf8_bytes": sum(len(f.encode("utf-8")) for _, f in new),
            "multi": sum(1 for _, f in table if len(f) > 1), "longest": max(len(f) for _, f in table)}


def gen_zig_fold_table(table):
    """The fold table's Zig form (see the module docstring, item 4): the entries whose
    fold differs from NFC of analyzer-v2's simple fold, the outputs deduplicated."""
    fold = dict(table)

    def v2_fold(ch: str) -> str:
        folded = ch.casefold()
        return folded if len(folded) == 1 else ch

    entries = []
    for cp in range(MAX_CODEPOINT):
        if 0xD800 <= cp <= 0xDFFF:
            continue
        target = fold.get(cp, chr(cp))
        if target != unicodedata.normalize("NFC", v2_fold(chr(cp))):
            entries.append((cp, target))
    outputs = sorted({target for _, target in entries}, key=lambda s: s.encode("utf-8"))
    index = {target: i for i, target in enumerate(outputs)}
    offsets, pool = [], bytearray()
    for target in outputs:
        offsets.append(len(pool))
        pool.extend(target.encode("utf-8"))
    offsets.append(len(pool))
    if len(pool) > 0xFFFF or len(outputs) > 0xFFFF:
        raise SystemExit("fold pool does not fit u16 offsets")
    return entries, [index[target] for _, target in entries], offsets, bytes(pool)


def fmt_numbers(values, per_line=12, hexadecimal=True):
    lines = []
    for i in range(0, len(values), per_line):
        chunk = values[i:i + per_line]
        lines.append("    " + " ".join((f"0x{v:X}," if hexadecimal else f"{v},") for v in chunk))
    return "\n".join(lines)


def fmt_pool(pool: bytes, per_line=24):
    lines = []
    for i in range(0, len(pool), per_line):
        lines.append('    "' + "".join(f"\\x{b:02x}" for b in pool[i:i + per_line]) + '" ++')
    lines.append('    ""')
    return "\n".join(lines)


def main_python_fold():
    """`--python-fold`: emit src/search_platform/_fold.py (S5-T4)."""
    table = gen_fold_table()
    counts = fold_table_counts(table)
    out = ['"""Generated file -- do not edit by hand.',
           "",
           f"Produced by scripts/gen_unicode_tables.py --python-fold using Python {sys.version.split()[0]}'s",
           f"`unicodedata` (Unicode {unicodedata.unidata_version}): K's fold table (S5-T4, fold-groups-v1, ruling 2",
           "of docs/tasks/S5-T4.md). For each code point c whose fold differs from c, the fold",
           "NFKC(casefold(NFKC(c))) iterated to a fixpoint. Read by src/search_platform/analyzer_v3.py.",
           f"{counts['changed']:,} code points change; {counts['new']:,} of them are not already given by NFC and a",
           f"simple lowercase map, with {counts['new_utf8_bytes']:,} bytes of UTF-8 output; {counts['multi']:,} map to more",
           f"than one code point; the longest maps to {counts['longest']}.",
           "Regenerate: python3 scripts/gen_unicode_tables.py --python-fold > src/search_platform/_fold.py",
           '"""',
           "",
           f'UNICODE_VERSION = "{unicodedata.unidata_version}"',
           "",
           "FOLD = {",
           ]
    out.extend(f"    0x{cp:X}: {ascii(folded)}," for cp, folded in table)
    out.append("}")
    out.append("")
    print("\n".join(out))


def main():
    if "--python-marks" in sys.argv[1:]:
        main_python_marks()
        return
    if "--python-fold" in sys.argv[1:]:
        main_python_fold()
        return
    unidata_version = unicodedata.unidata_version
    python_version = sys.version.split()[0]

    letter_digit_ranges = gen_letter_digit_ranges()
    mark_ranges = gen_letter_digit_ranges(MARK_CATEGORIES)
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
    out.append(f"/// {len(mark_ranges)} ranges covering Unicode General_Category Mn and Mc")
    out.append("/// (S1-T14: marks that stay attached to the letter before them).")
    out.append("pub const mark_ranges = [_]CodepointRange{")
    out.append(fmt_ranges(mark_ranges))
    out.append("};")
    out.append("")
    out.append(f"/// {len(casefold_pairs)} single-codepoint simple case-fold exceptions")
    out.append("/// (str.casefold() results that are themselves single codepoints).")
    out.append("pub const casefold_pairs = [_]CasefoldPair{")
    out.append(fmt_pairs2(casefold_pairs))
    out.append("};")
    out.append("")
    out.append(f"/// {len(decomposition_pairs)} canonical (non-compatibility) decompositions, sorted by")
    out.append("/// `from`: two-codepoint ones, and singletons with `b == 0` (S1-T15).")
    out.append("/// Hangul syllables excluded (algorithmic; see nfc.zig).")
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
    fold_table = gen_fold_table()
    counts = fold_table_counts(fold_table)
    entries, targets, offsets, pool = gen_zig_fold_table(fold_table)
    out.append(f"/// K's fold table (S5-T4, fold-groups-v1, docs/tasks/S5-T4.md ruling 2), for")
    out.append("/// `fold.zig`: NFKC(casefold(NFKC(c))) iterated to a fixpoint. "
               f"{counts['changed']:,} code points change;")
    out.append(f"/// these {len(entries):,} are the ones where that differs from NFC of analyzer-v2's simple")
    out.append("/// fold (`casefold_pairs`); every other code point takes that path (see the")
    out.append(f"/// generator's docstring). {len(offsets) - 1:,} distinct outputs, {len(pool):,} bytes of UTF-8.")
    out.append("/// `fold_from` is sorted; `fold_to[i]` indexes `fold_offsets`, and output k is")
    out.append("/// `fold_pool[fold_offsets[k]..fold_offsets[k + 1]]`.")
    out.append(f"pub const fold_from = [{len(entries)}]u21{{")
    out.append(fmt_numbers([cp for cp, _ in entries]))
    out.append("};")
    out.append("")
    out.append(f"pub const fold_to = [{len(targets)}]u16{{")
    out.append(fmt_numbers(targets, per_line=16, hexadecimal=False))
    out.append("};")
    out.append("")
    out.append(f"pub const fold_offsets = [{len(offsets)}]u16{{")
    out.append(fmt_numbers(offsets, per_line=16, hexadecimal=False))
    out.append("};")
    out.append("")
    out.append("pub const fold_pool: []const u8 =")
    out.append(fmt_pool(pool) + ";")
    out.append("")
    print("\n".join(out))


if __name__ == "__main__":
    main()
