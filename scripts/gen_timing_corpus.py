#!/usr/bin/env python3
"""Generate an invented-text corpus for the S1-T1 1,000-file `searchd index`
timing measurement. The corpus itself is not committed (generated on demand
into a scratch directory); only this generator is tracked.

Usage: python3 scripts/gen_timing_corpus.py <out_dir> [file_count]
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
WORDS = (
    "system module index chunk analyzer token query document score rank "
    "fusion candidate vector lexical semantic snapshot manifest segment "
    "generation cursor buffer stream reader writer allocator worker thread"
).split()


def make_paragraph(rng: random.Random, topic: str) -> str:
    sentences = []
    for _ in range(rng.randint(3, 6)):
        length = rng.randint(8, 16)
        words = [rng.choice(WORDS) for _ in range(length)]
        sentences.append(" ".join(words).capitalize() + ".")
    return f"# {topic.title()}\n\n" + " ".join(sentences) + "\n"


def main() -> None:
    out_dir = Path(sys.argv[1])
    file_count = int(sys.argv[2]) if len(sys.argv) > 2 else 1000
    out_dir.mkdir(parents=True, exist_ok=True)
    rng = random.Random(20260917)
    for index in range(file_count):
        topic = TOPICS[index % len(TOPICS)]
        subdir = out_dir / f"group-{index // 100:02d}"
        subdir.mkdir(parents=True, exist_ok=True)
        path = subdir / f"doc-{index:05d}.md"
        paragraphs = [make_paragraph(rng, topic) for _ in range(rng.randint(1, 3))]
        path.write_text("\n".join(paragraphs), encoding="utf-8")
    print(f"wrote {file_count} files under {out_dir}")


if __name__ == "__main__":
    main()
