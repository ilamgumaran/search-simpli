#!/usr/bin/env python3
"""Generate an invented-text corpus for `searchd index` timing measurements.
The corpus itself is not committed (generated on demand into a scratch
directory); only this generator is tracked.

S1-T3 (docs/tasks/S1-T3.md criterion 4) replaces the original ~30-word
vocabulary this script used (S1-T1): that corpus only ever produced 57
distinct terms over 1,000 files, which hid `lexical_build.build`'s
superlinear-in-vocabulary cost entirely (round-A verdict, `docs/tasks/S1-T1.md`).
This version deterministically constructs a >=20,000-term vocabulary from
consonant-vowel syllable triples and *guarantees* every vocabulary word
appears at least once across the corpus (see `build_vocabulary` and the
per-file quota below), so "N distinct terms" is a proven property of the
output, not a hopeful one.

Usage: python3 scripts/gen_timing_corpus.py <out_dir> [file_count] [vocabulary_size]
"""
import random
import sys
from pathlib import Path

TOPICS = [
    "hybrid retrieval", "hash tables", "garbage collection", "type systems",
    "distributed consensus", "operating system schedulers", "compilers",
    "database indexing", "network protocols", "cryptographic hashing",
    "unicode normalization", "search ranking", "concurrency primitives",
    "memory allocators", "build systems", "static analysis",
]

# Open consonant-vowel syllables, combined three at a time (see
# `build_vocabulary`) to deterministically enumerate a pool of distinct
# pseudo-word terms far larger than any vocabulary size this script is
# asked for (22 consonants x 5 vowels = 110 syllables; 110**3 > 1.3M
# possible triples).
_CONSONANTS = [
    "b", "c", "d", "f", "g", "h", "j", "k", "l", "m", "n", "p", "r", "s", "t",
    "v", "w", "z", "sh", "ch", "th", "wh",
]
_VOWELS = ["a", "e", "i", "o", "u"]
_SYLLABLES = [c + v for c in _CONSONANTS for v in _VOWELS]  # 110 syllables

DEFAULT_VOCABULARY_SIZE = 24_000

# Common short function words mixed in at low term-count cost (a handful of
# distinct words, drawn frequently) so generated text reads more like real
# prose without diluting the guaranteed vocabulary coverage below.
COMMON_WORDS = (
    "the a an of and to in for with by is are that this it as from on be "
    "was were has have will can not"
).split()


def build_vocabulary(size: int) -> list[str]:
    """`size` distinct pseudo-word terms, built by treating each index as a
    base-110 number over `_SYLLABLES` (a bijection for index < 110**3), so
    the first `size` indices are guaranteed distinct without a dedup loop.
    """
    if size > len(_SYLLABLES) ** 3:
        raise ValueError(f"vocabulary_size {size} exceeds the syllable pool's capacity")
    base = len(_SYLLABLES)
    vocabulary = []
    for index in range(size):
        a = _SYLLABLES[index % base]
        b = _SYLLABLES[(index // base) % base]
        c = _SYLLABLES[(index // (base * base)) % base]
        vocabulary.append(c + b + a)
    return vocabulary


def make_paragraph(rng: random.Random, topic: str, vocabulary: list[str]) -> str:
    sentences = []
    for _ in range(rng.randint(3, 6)):
        length = rng.randint(8, 16)
        words = []
        for _ in range(length):
            if rng.random() < 0.35:
                words.append(rng.choice(COMMON_WORDS))
            else:
                words.append(rng.choice(vocabulary))
        sentences.append(" ".join(words).capitalize() + ".")
    return f"# {topic.title()}\n\n" + " ".join(sentences) + "\n"


def main() -> None:
    out_dir = Path(sys.argv[1])
    file_count = int(sys.argv[2]) if len(sys.argv) > 2 else 1000
    vocabulary_size = int(sys.argv[3]) if len(sys.argv) > 3 else DEFAULT_VOCABULARY_SIZE
    out_dir.mkdir(parents=True, exist_ok=True)
    rng = random.Random(20260917)

    vocabulary = build_vocabulary(vocabulary_size)
    shuffled = list(vocabulary)
    rng.shuffle(shuffled)

    # Guarantee every vocabulary word is used at least once -- partition the
    # shuffled vocabulary into per-file quotas up front. Each file's random
    # paragraphs (below) draw further words from the whole vocabulary with
    # replacement (realistic Zipfian repetition); the quota sentence is what
    # makes "the corpus has >=vocabulary_size distinct terms" a guarantee
    # rather than a probabilistic hope.
    per_file_quota: list[list[str]] = [[] for _ in range(file_count)]
    for i, word in enumerate(vocabulary):
        per_file_quota[i % file_count].append(word)

    for index in range(file_count):
        topic = TOPICS[index % len(TOPICS)]
        subdir = out_dir / f"group-{index // 100:02d}"
        subdir.mkdir(parents=True, exist_ok=True)
        path = subdir / f"doc-{index:05d}.md"
        paragraphs = [make_paragraph(rng, topic, vocabulary) for _ in range(rng.randint(1, 3))]
        quota_sentence = " ".join(per_file_quota[index]) + ".\n" if per_file_quota[index] else ""
        path.write_text("\n".join(paragraphs) + "\n" + quota_sentence, encoding="utf-8")

    print(
        f"wrote {file_count} files under {out_dir} "
        f"with a {vocabulary_size}-term guaranteed-distinct vocabulary"
    )


if __name__ == "__main__":
    main()
