#!/usr/bin/env python3
"""Capture the raw `ss_query` output of one library build for a fixed query set.

S2-T3 bar (a): ranking only the matched chunks must not change a single byte
of `ss_query` output. Run this once against the library built from the commit
before the change and once against the library after it, then `cmp` the two
output files (or run with --compare).

    python3 -I scripts/capture_query_outputs.py --lib LIB --searchd SEARCHD \
        --work WORKDIR --out OUT.jsonl
    cmp OUT-before.jsonl OUT-after.jsonl

What is captured (every line: case id, request, then the exact output string
or the error text; the file's sha256 is printed):

* every judged query of fixtures/{judgments,mixed-judgments,semantic-judgments}
  .json and fixtures/tamil/judgments.json, lexical mode, on a snapshot of the
  matching fixture folder built by `searchd index`, at three (top_k,
  candidate_k) depths;
* the semantic fixture again with its real co-occurrence vectors, in lexical,
  vector and hybrid modes (query vectors embedded by the reference model);
* a 1,000-chunk synthetic snapshot WITH vectors (small-integer components, so
  that cosine ties are common; a few chunks carry required labels), 200 random
  1-6 word queries drawn from its vocabulary, in lexical, vector and hybrid
  modes, with default and shallow candidate depths and a path prefix;
* 200 random 1-6 word queries on the 1,000-chunk and the 10,000-chunk
  `scripts/gen_timing_corpus.py` corpora (lexical, as `searchd index` makes
  them), plus the four research-doc timing queries.

The snapshots are built once into --work and reused, so that both runs read
the same bytes. Only the standard library plus this repository's reference
index code is used.
"""

from __future__ import annotations

import argparse
import ctypes
import hashlib
import json
import random
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

DEPTHS = [(10, 100), (5, 5), (100, 10000)]
TIMING_QUERIES = [
    "benico",
    "hybrid retrieval",
    "how does the hybrid retrieval work for a search",
    "the and of to in",
]


class Library:
    def __init__(self, path: str) -> None:
        self.lib = ctypes.CDLL(path)
        lib = self.lib
        lib.ss_open.argtypes = [ctypes.c_char_p]
        lib.ss_open.restype = ctypes.c_void_p
        lib.ss_close.argtypes = [ctypes.c_void_p]
        lib.ss_close.restype = None
        lib.ss_query.argtypes = [
            ctypes.c_void_p,
            ctypes.c_char_p,
            ctypes.POINTER(ctypes.c_float),
            ctypes.c_size_t,
            ctypes.c_size_t,
            ctypes.c_char_p,
        ]
        lib.ss_query.restype = ctypes.c_void_p
        lib.ss_free.argtypes = [ctypes.c_void_p]
        lib.ss_free.restype = None
        lib.ss_last_error.argtypes = []
        lib.ss_last_error.restype = ctypes.c_char_p
        lib.ss_import_json.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_size_t]
        lib.ss_import_json.restype = ctypes.c_int64

    def open(self, directory: Path) -> int:
        handle = self.lib.ss_open(str(directory).encode())
        if not handle:
            raise RuntimeError(f"ss_open({directory}): {self.lib.ss_last_error().decode()}")
        return handle

    def query(self, handle, text: str, vector, top_k: int, options: dict) -> str:
        dims = len(vector)
        array = (ctypes.c_float * dims)(*vector) if dims else None
        pointer = self.lib.ss_query(
            handle, text.encode(), array, dims, top_k, json.dumps(options).encode()
        )
        if not pointer:
            return "ERROR " + self.lib.ss_last_error().decode()
        try:
            return ctypes.string_at(pointer).decode()
        finally:
            self.lib.ss_free(pointer)

    def import_json(self, directory: Path, payload: dict) -> None:
        data = json.dumps(payload, separators=(",", ":")).encode()
        result = self.lib.ss_import_json(str(directory).encode(), data, len(data))
        if result < 1:
            raise RuntimeError(f"ss_import_json: {self.lib.ss_last_error().decode()}")


def run(command: list[str]) -> None:
    subprocess.run(command, check=True, stdout=subprocess.DEVNULL, timeout=600)


def ensure_index(searchd: str, folder: Path, out: Path) -> Path:
    if not out.exists():
        run([searchd, "index", str(folder), "--out", str(out)])
    return out


def words_of(folder: Path) -> list[str]:
    vocabulary: set[str] = set()
    for path in sorted(folder.rglob("*")):
        if path.is_file():
            vocabulary.update(re.findall(r"[a-z0-9]+", path.read_text(encoding="utf-8").lower()))
    return sorted(vocabulary)


def random_queries(vocabulary: list[str], rng: random.Random, count: int) -> list[str]:
    return [" ".join(rng.choice(vocabulary) for _ in range(rng.randint(1, 6))) for _ in range(count)]


def make_corpus(work: Path, name: str, count: int) -> Path:
    folder = work / name
    if not folder.exists():
        run([sys.executable, str(ROOT / "scripts" / "gen_timing_corpus.py"), str(folder), str(count)])
    return folder


def synthetic_vector_snapshot(lib: Library, work: Path, folder: Path, rng: random.Random):
    """1,000 chunks with 4-d small-integer vectors; returns (snapshot, vocabulary)."""
    snapshot = work / "snap-synthetic-vectors"
    documents = []
    vocabulary: set[str] = set()
    for number, path in enumerate(sorted(p for p in folder.rglob("*") if p.is_file())):
        text = path.read_text(encoding="utf-8")
        vocabulary.update(re.findall(r"[a-z0-9]+", text.lower()))
        documents.append(
            {
                "id": f"c{number:05d}",
                "path": f"{'public' if number % 4 else 'private'}/{path.name}",
                "start_line": 1,
                "end_line": 1 + number % 7,
                "text": text,
                "vector": [float(rng.randint(-1, 2)) for _ in range(4)],
                "required_labels": ["tenant:acme"] if number % 11 == 0 else [],
            }
        )
    # Some chunks with an all-zero vector (cosine is defined as 0 there).
    for document in documents[::97]:
        document["vector"] = [0.0, 0.0, 0.0, 0.0]
    if not snapshot.exists():
        lib.import_json(
            snapshot,
            {
                "format_version": 1,
                "generation": 1,
                "analyzer_id": "ascii-alnum-v1",
                "embedding_model_id": "synthetic-int-v1",
                "documents": documents,
            },
        )
    return snapshot, sorted(vocabulary)


def semantic_fixture_snapshot(lib: Library, work: Path):
    from src.search_platform.core import build_index, embed_query
    from src.search_platform.interchange import build_interchange

    snapshot = work / "snap-semantic-vectors"
    index = build_index(ROOT / "fixtures" / "semantic-knowledge", vector_mode="cooccurrence")
    if not snapshot.exists():
        lib.import_json(snapshot, build_interchange(index))
    return snapshot, (lambda text: [float(x) for x in embed_query(index, text, None)])


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--lib", required=True)
    parser.add_argument("--searchd", required=True)
    parser.add_argument("--work", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--seed", type=int, default=20261008)
    parser.add_argument("--random-queries", type=int, default=200)
    parser.add_argument(
        "--profile",
        action="store_true",
        help='send "profile": true with every query (timings differ run to run: '
        "compare with the profile object cut, see S2-T13)",
    )
    args = parser.parse_args()
    args.work.mkdir(parents=True, exist_ok=True)
    rng = random.Random(args.seed)
    lib = Library(args.lib)
    lines: list[dict] = []

    def record(label: str, handle, text: str, vector, top_k: int, options: dict) -> None:
        if args.profile:
            options = dict(options, profile=True)
        lines.append(
            {
                "case": label,
                "query": text,
                "vector": vector,
                "top_k": top_k,
                "options": options,
                "output": lib.query(handle, text, vector, top_k, options),
            }
        )

    # 1. Judged fixture queries (lexical snapshots built by searchd index).
    fixtures = [
        ("knowledge", "knowledge", "judgments.json"),
        ("mixed-knowledge", "mixed-knowledge", "mixed-judgments.json"),
        ("semantic-knowledge", "semantic-knowledge", "semantic-judgments.json"),
        ("tamil", "tamil/passages", "tamil/judgments.json"),
    ]
    for name, folder, judgments in fixtures:
        snapshot = ensure_index(args.searchd, ROOT / "fixtures" / folder, args.work / f"snap-{name}")
        handle = lib.open(snapshot)
        for judged in json.loads((ROOT / "fixtures" / judgments).read_text(encoding="utf-8"))["queries"]:
            for top_k, candidate_k in DEPTHS:
                options = {"retrieval_mode": "lexical", "candidate_k": candidate_k}
                if judged.get("path_prefix"):
                    options["path_prefix"] = judged["path_prefix"]
                record(f"judged:{name}:{judged['id']}:{top_k}/{candidate_k}", handle, judged["query"], [], top_k, options)
        lib.lib.ss_close(handle)

    # 2. The semantic fixture with its real vectors, all three modes.
    snapshot, embed = semantic_fixture_snapshot(lib, args.work)
    handle = lib.open(snapshot)
    judged_queries = json.loads((ROOT / "fixtures" / "semantic-judgments.json").read_text(encoding="utf-8"))["queries"]
    for judged in judged_queries:
        vector = embed(judged["query"])
        for mode in ("lexical", "vector", "hybrid"):
            for top_k, candidate_k in DEPTHS:
                options = {"retrieval_mode": mode, "candidate_k": candidate_k}
                record(f"semantic:{judged['id']}:{mode}:{top_k}/{candidate_k}", handle, judged["query"], vector, top_k, options)
                if judged.get("path_prefix"):
                    options = dict(options, path_prefix=judged["path_prefix"])
                    record(f"semantic-prefix:{judged['id']}:{mode}:{top_k}/{candidate_k}", handle, judged["query"], vector, top_k, options)
    lib.lib.ss_close(handle)

    # 3. Synthetic 1,000-chunk snapshot with tie-heavy vectors.
    folder_1k = make_corpus(args.work, "c1k", 1000)
    snapshot, vocabulary = synthetic_vector_snapshot(lib, args.work, folder_1k, rng)
    handle = lib.open(snapshot)
    for number, text in enumerate(random_queries(vocabulary, rng, args.random_queries)):
        vector = [float(rng.randint(-1, 2)) for _ in range(4)]
        for mode in ("lexical", "vector", "hybrid"):
            for top_k, candidate_k in ((10, 100), (3, 7)):
                options = {"retrieval_mode": mode, "candidate_k": candidate_k}
                record(f"synthetic-vectors:{number}:{mode}:{top_k}/{candidate_k}", handle, text, vector, top_k, options)
        options = {"retrieval_mode": "hybrid", "path_prefix": "public/", "principal_labels": ["tenant:acme"] if number % 2 else []}
        record(f"synthetic-vectors:{number}:scoped", handle, text, vector, 10, options)
    lib.lib.ss_close(handle)

    # 4. Random queries on the lexical 1k and 10k timing corpora.
    for name, count in (("c1k", 1000), ("c10k", 10000)):
        folder = make_corpus(args.work, name, count)
        snapshot = ensure_index(args.searchd, folder, args.work / f"snap-{name}")
        handle = lib.open(snapshot)
        queries = TIMING_QUERIES + random_queries(words_of(folder), rng, args.random_queries)
        for number, text in enumerate(queries):
            for mode, top_k, candidate_k in (("lexical", 5, 100), ("hybrid", 10, 100), ("lexical", 10, 10)):
                options = {"retrieval_mode": mode, "candidate_k": candidate_k}
                record(f"random:{name}:{number}:{mode}:{top_k}/{candidate_k}", handle, text, [], top_k, options)
        lib.lib.ss_close(handle)

    with args.out.open("w", encoding="utf-8") as stream:
        for line in lines:
            stream.write(json.dumps(line, ensure_ascii=False, sort_keys=True) + "\n")
    digest = hashlib.sha256(args.out.read_bytes()).hexdigest()
    errors = sum(1 for line in lines if line["output"].startswith("ERROR"))
    results = sum(len(json.loads(l["output"])["results"]) for l in lines if not l["output"].startswith("ERROR"))
    print(f"captured {len(lines)} queries ({errors} error outputs, {results} result rows) sha256={digest}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
