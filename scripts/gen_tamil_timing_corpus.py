#!/usr/bin/env python3
"""Generate a Tamil-heavy invented corpus for fold-groups-v1 timing (S5-T4).

The sibling of `scripts/gen_timing_corpus.py`, with the same file layout
(`group-NN/doc-NNNNN.md`, a heading, one to three paragraphs of three to six
sentences of 8 to 16 words, and a quota sentence that guarantees every
vocabulary form appears). The corpus is not committed; only this generator is.

**The rule.** Every word is invented: a stem is three open Tamil syllables
(one of 18 consonants with the inherent vowel or one of eight vowel signs),
built in a fixed order from its index, so the first `stems` indices are
distinct without a dedup loop. Stems alternate between two classes, and each
class carries the suffix forms that fold-groups-v1's T stage (docs/
fold-groups-v1.md) strips, seven forms in all:

- an *m-stem* (even index) ends in `ம்`; its forms are the stem, the plural
  `-ங்கள்`, the locative `-த்தில்` and the genitive `-த்தின்` (each replacing
  the final `ம்`);
- a *vowel stem* (odd index) ends in `ி` or `ை` on its last syllable; its forms
  are the stem, the plural `-கள்`, the dative `-க்கு`, the locative `-யில்` and
  the genitive `-யின்`.

So every inflected form's key is its stem, and the key map holds one entry
per inflected form. A paragraph draws 35 % of its words from the first 30
stems (the corpus's "common words") and the rest from every form, so the
vocabulary is Zipf-free but every stem has frequent and rare forms.

Usage: python3 scripts/gen_tamil_timing_corpus.py <out_dir> [file_count] [stems]
"""
import random
import sys
from pathlib import Path

CONSONANTS = ["க", "ச", "ட", "த", "ப", "ற", "ங", "ஞ", "ண", "ந", "ம", "ன", "ய", "ர", "ல", "வ", "ழ", "ள"]
# The inherent vowel (no sign) and eight vowel signs.
SIGNS = ["", "ா", "ி", "ீ", "ு", "ூ", "ெ", "ே", "ை"]
SYLLABLES = [c + s for c in CONSONANTS for s in SIGNS]  # 162 syllables
VOWEL_ENDS = ["ி", "ை"]

M_SUFFIXES = ["ங்கள்", "த்தில்", "த்தின்"]
VOWEL_SUFFIXES = ["கள்", "க்கு", "யில்", "யின்"]

DEFAULT_STEMS = 4800


def stem(index: int) -> str:
    base = len(SYLLABLES)
    a = SYLLABLES[index % base]
    b = SYLLABLES[(index // base) % base]
    if index % 2 == 0:
        return a + b + CONSONANTS[(index // 2) % len(CONSONANTS)] + "ம்"
    return a + b + CONSONANTS[(index // 2) % len(CONSONANTS)] + VOWEL_ENDS[(index // 2) % 2]


def forms(index: int) -> list[str]:
    word = stem(index)
    if index % 2 == 0:
        root = word[: -len("ம்")]
        return [word] + [root + suffix for suffix in M_SUFFIXES]
    return [word] + [word + suffix for suffix in VOWEL_SUFFIXES]


def main() -> None:
    out_dir = Path(sys.argv[1])
    file_count = int(sys.argv[2]) if len(sys.argv) > 2 else 1000
    stems = int(sys.argv[3]) if len(sys.argv) > 3 else DEFAULT_STEMS
    if stems > len(SYLLABLES) ** 2:
        raise ValueError(f"stems {stems} exceeds the syllable pool's capacity")
    out_dir.mkdir(parents=True, exist_ok=True)
    rng = random.Random(20261107)

    vocabulary = [form for index in range(stems) for form in forms(index)]
    common = [stem(index) for index in range(min(30, stems))]
    headings = [stem(index) + " " + stem(index + 1) for index in range(0, min(32, stems - 1), 2)]

    quota: list[list[str]] = [[] for _ in range(file_count)]
    for i, word in enumerate(vocabulary):
        quota[i % file_count].append(word)

    for index in range(file_count):
        subdir = out_dir / f"group-{index // 100:02d}"
        subdir.mkdir(parents=True, exist_ok=True)
        paragraphs = []
        for _ in range(rng.randint(1, 3)):
            sentences = []
            for _ in range(rng.randint(3, 6)):
                words = [rng.choice(common) if rng.random() < 0.35 else rng.choice(vocabulary)
                         for _ in range(rng.randint(8, 16))]
                sentences.append(" ".join(words) + ".")
            paragraphs.append(f"# {headings[index % len(headings)]}\n\n" + " ".join(sentences) + "\n")
        tail = " ".join(quota[index]) + ".\n" if quota[index] else ""
        (subdir / f"doc-{index:05d}.md").write_text("\n".join(paragraphs) + "\n" + tail, encoding="utf-8")

    print(f"wrote {file_count} files under {out_dir}: {stems} invented stems, {len(vocabulary)} forms")


if __name__ == "__main__":
    main()
