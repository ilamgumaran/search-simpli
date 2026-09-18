# Search Simpli

**Search from first principles—from local files and LLM tools to scalable hybrid retrieval in Zig.**

Search Simpli (`search-simpli`) explores one search product with two deliberately different operating modes:

1. **Local knowledge mode** — index files and folders, retrieve cited passages, and hand a compact evidence pack to an LLM acting through a tool or agent.
2. **Search platform mode** — evolve the same contracts into a Zig service with persistent lexical and vector indexes, hybrid ranking, filters, observability, and horizontal scaling.

The important boundary is retrieval versus generation. Search finds and cites evidence. An LLM may synthesize an answer from that evidence, but it must not silently become the source of truth.

## Run the local vertical slice

The prototype has no third-party dependencies and works with Python 3.11+.

```sh
python3 search.py index fixtures/knowledge --out .search/index.json
python3 search.py query .search/index.json "How should hybrid search combine results?"
python3 search.py context .search/index.json "How should hybrid search combine results?"
python3 -m unittest discover -s tests -v
```

Run the same index as a local agent/LLM tool process:

```sh
python3 knowledge_tools.py .search/index.json
```

Compare retrieval modes against relevance judgments:

```sh
python3 evaluate.py .search/index.json fixtures/judgments.json --top-k 1

python3 relevance_smoke.py \
  fixtures/relevance-smoke/corpus \
  fixtures/relevance-smoke/judgments.json \
  --mode lexical --top-k 10 \
  --min-ndcg 1 --min-mrr 1 --min-recall 1 --min-success 1
```

Carry a real files-and-folders snapshot across the language boundary:

```sh
python3 search.py index fixtures/semantic-knowledge --vector-mode cooccurrence --out /tmp/python-index.json
python3 export_zig.py /tmp/python-index.json --generation 1 --out /tmp/zig-snapshot.json
cd zig
zig build run -- import-json /tmp/search-snapshot /tmp/zig-snapshot.json
zig build run -- serve /tmp/search-snapshot
```

Run the LLM/agent-facing gateway so callers send text rather than vectors:

```sh
cd ..
python3 zig_gateway.py /tmp/python-index.json /tmp/search-snapshot
```

The gateway fingerprints the exact trained model, verifies it against Zig `index_status`, embeds vector/hybrid queries, and rejects caller-supplied or mismatched vectors. `embed_query.py` remains a useful diagnostic for inspecting that model boundary directly.

Run the persisted Zig engine as the same style of tool process:

```sh
cd zig
zig build run -- init-demo /tmp/searchd-demo
zig build run -- serve /tmp/searchd-demo
```

`query` is human-readable. `context` emits the JSON evidence envelope intended for a model tool call. Every result includes a stable chunk id, file path, line range, content, and component ranking details.

The safe default is `vector_mode=none`, so hybrid queries behave lexically until a real embedding channel exists. The opt-in `--vector-mode hash` projection exercises vector storage, cosine scoring, and fusion offline; it is **not a semantic embedding model** and has already been observed to reduce relevance. Replace it through the embedding boundary described in [the architecture](docs/architecture.md) before evaluating semantic relevance.

For a dependency-free ground-up semantic experiment, use `--vector-mode cooccurrence`. It trains a PPMI distributional model from the indexed corpus and records its model metadata. It is useful theory made executable, but remains a small-corpus baseline rather than a pretrained neural model.

For the optional local neural path, install `fastembed==0.8.0` in a separate environment and run:

```sh
python3 search.py index ./knowledge --vector-mode neural \
  --model BAAI/bge-small-en-v1.5 \
  --model-cache .search/models \
  --out .search/neural-index.json
```

The base project remains dependency-free. Neural mode uses separate passage/query embeddings, records a runtime/model conformance fingerprint, and fails closed if the query provider does not match the index.

For shared folders, assign required labels by path and configure the tool/gateway principal outside LLM-controlled requests:

```sh
python3 search.py index ./knowledge --access-rules access-rules.json --out .search/index.json
python3 knowledge_tools.py .search/index.json --principal-label tenant:acme
```

The same principal filters lexical candidates, vector candidates, source lists, and chunk reads. Unlabeled documents remain the zero-configuration personal/local option.

Reuse unchanged extraction and vectors while still publishing a complete immutable snapshot:

```sh
python3 search.py index ./knowledge \
  --incremental-from .search/index.previous.json \
  --out .search/index.next.json
```

The build report distinguishes reused, changed, added, deleted, stale, relabeled, and newly embedded work.

Measure the current simple and durable paths before adding scale machinery:

```sh
python3 benchmark_scale.py --sizes 100 1000 5000 --dimensions 384
cd zig
zig build -Doptimize=ReleaseFast
./zig-out/bin/searchd benchmark 8000 32 51 hybrid
```

## Standalone

`searchd` also runs with **no Python and no third-party dependencies at
all**: a single static binary indexes a folder of UTF-8 text, markdown, or
source files, chunks and tokenizes it natively in Zig, and serves BM25
queries from the published index (S1-T1, ADR 0002).

Install nothing beyond the binary itself:

```sh
# Build once (see "Binaries" below for prebuilt sizes), then:
searchd index ./my-notes --out .search/native-index
searchd query .search/native-index "how does hybrid ranking work"
searchd query .search/native-index "how does hybrid ranking work" --json
searchd evidence .search/native-index "how does hybrid ranking work" --top-k 3
```

`index` walks the folder (skipping `.git/`, `.search/`, `.zig-cache/`,
`__pycache__/`, `node_modules/`, `zig-out/`, and any dotfile/dotdirectory --
the same rules as the Python reference's `DEFAULT_EXTENSIONS`/
`IGNORED_DIRECTORIES`), chunks each file with the `line-window-v1` chunker
(byte-for-byte identical to `search_platform.core._line_chunks` -- see the
golden conformance test, `zig/src/chunker_test.zig`), and publishes a
lexical-only snapshot (no embeddings; `embedding_model_id` is `"none"`).
`query`/`evidence` then run BM25 against that snapshot. Both commands accept
`--top-k N`; `query` additionally accepts `--json` for machine-readable
output, and `evidence` always emits a JSON evidence envelope (citation,
content, and scores) intended for an LLM tool call.

**Two analyzers**, selected with `--analyzer` at index time and recorded in
the manifest so query time picks the matching tokenizer automatically:

- `analyzer-v1` (default before this task; still available): ASCII-only
  letters and digits, ASCII case folding.
- `analyzer-v2` (default now): Unicode-aware -- NFC normalization, Unicode
  general-category letters (Lu/Ll/Lt/Lm/Lo) and digits (Nd/Nl/No), and
  simple per-codepoint case folding. Tables are generated from Python's own
  `unicodedata` module (Unicode 13.0.0; see `scripts/gen_unicode_tables.py`
  and `zig/src/unicode_tables.zig`), since Zig 0.16's `std.unicode` carries
  no category, case-folding, or normalization data of its own. Tamil is the
  first proven non-Latin corpus: `fixtures/tamil/` has ten invented short
  passages with judged queries, and every one of them retrieves its own
  passage as the top hit end to end through `searchd index`/`query`.

`serve <dir>` is unchanged: JSON-RPC 2.0 requests, one per line, on
stdin/stdout. `serve <dir> --http 127.0.0.1:<port>` additionally accepts the
same JSON-RPC request as an HTTP POST body on a loopback-only address (any
other host is refused) and returns the JSON-RPC response as the HTTP body --
useful for a local tool or browser call without opening a stdio pipe. Both
serving modes, and the RPC `search_knowledge` method behind them, dispatch
query tokenization by the snapshot's recorded analyzer, so `analyzer-v2`
snapshots are queried correctly over RPC and HTTP too, not just through the
`query`/`evidence` CLI commands.

### Binaries

One static binary per platform, built with `zig build -Doptimize=ReleaseSafe
-Dtarget=<target> -p dist/<platform>` from the pinned Zig 0.16.0 toolchain,
no sysroot required (ADR 0002):

| Platform | Target triple | Size |
|---|---|---|
| macOS (Apple Silicon) | `aarch64-macos` | 0.81 MiB (851,080 bytes; ±32 bytes seen between rebuilds, presumably a build-metadata artifact) |
| Linux x86_64 | `x86_64-linux-musl` | 5.05 MiB (5,293,344 bytes; statically linked, confirmed with `file`) |

(This binary calls no libc functions, so plain `x86_64-linux` (glibc) also
comes out statically linked and the same size here — `x86_64-linux-musl` is
recorded as the conventional, unambiguous way to ask Zig for a static Linux
binary in general, not because glibc failed to produce one for this specific
program. See `docs/tasks/S1-T1.md` for the side-by-side check.)

(macOS binaries always link the OS-provided `libSystem.dylib`, which is the
platform's floor for "static" -- there is no fully static executable format
on macOS. The Linux binary has no dynamic dependencies at all.)

Measured on a 1,000-file, ~3.9 MB invented-text corpus with a **24,000-term
guaranteed-distinct vocabulary** (generated with `scripts/gen_timing_corpus.py`,
not committed) -- S1-T3 retired the original generator's ~30-word vocabulary,
which only ever produced 57 distinct terms over 1,000 files and hid a
superlinear-in-vocabulary cost in both `lexical_build.build` and
`lexical_segment.zig`'s duplicate-term check (round-A verdict,
`docs/tasks/S1-T1.md`; both fixed with hash-based dictionaries in S1-T3,
`docs/tasks/S1-T3.md`):

| Operation | Time (`/usr/bin/time -p`, ReleaseSafe) |
|---|---|
| `index` full rebuild, generation 1 (1,000 files, 1,004 documents, 24,057 terms) | 0.12s wall (0.17s on the first, cold-cache run; 0.12s on two subsequent fresh-`--out` runs — S1-T4, `docs/tasks/S1-T4.md` criterion 4 re-measurement) |
| `index` full rebuild re-run into the same `--out` (generation 2 -- see "re-publishing" below) | 0.11s wall |
| `index --update`, no prior `INDEX-STATE.json` (baseline, everything reported `added`) | 0.12s wall |
| `index --update`, one file changed out of 1,000 (999 `unchanged`) | 0.08s wall |
| `index` on this repository's own tree (216 files, 1,462 documents, 14,099 terms) | 0.20s wall |

**The two earlier "warm run" figures in this table were never genuine
second/third runs**: `searchd index` used to fail every re-run into an
existing `--out` directory with a bare `PathAlreadyExists` (S1-T1 non-blocking
finding 1), so the old 0.08s/0.08s captions were coincidentally-correct
numbers from a *failure*, not a rebuild. S1-T3 fixes re-publishing (see
"Re-publishing into an existing directory" below), so every row above is a
real, complete run. See `docs/tasks/S1-T3.md` for the exact commands and full
pasted output, including the five-step incremental-mutation demonstration.
The full-rebuild figure was re-measured for S1-T4 (`docs/tasks/S1-T4.md`
criterion 4): the previously recorded 0.30s did not reproduce on this
machine against the corpus this same generator now produces (0.12-0.17s
across three fresh runs); the S1-T3 tester's own independent re-run found
the same thing (0.12-0.13s, "consistent with a warm page cache" against the
builder's originally reported 0.30s) — see `docs/tasks/S1-T3.md`'s Verdict.

### Re-publishing into an existing directory

`searchd index <folder> --out <dir>` run again with the same `--out`
publishes the *next* generation instead of failing (S1-T3): it picks the
smallest unused generation number in `<dir>` rather than always defaulting to
1. Pass `--generation N` explicitly to override this.

### Incremental updates

`searchd index <folder> --out <dir> --update` only re-reads and re-chunks
files whose content actually changed since the last run (a persisted SHA-256
per file, `<dir>/INDEX-STATE.json`), tombstones deleted files, and prints a
JSON report:

```sh
searchd index ./my-notes --out .search/native-index --update
# {"generation":2,"analyzer_id":"analyzer-v2","added":0,"changed":1,
#  "removed":0,"unchanged":11,"budget_exhausted":0,"too_large":0,
#  "unreadable":0,"too_large_paths":[],"unreadable_paths":[],
#  "documents":12,"terms":233,"postings":410}
```

`--max-file-bytes`/`--max-total-bytes` cap, respectively, one file's size
(over the cap: tombstoned, named in `too_large_paths`) and the total bytes
read in one `--update` run (files left over count as `budget_exhausted`,
default 10 MiB / 512 MiB). An empty folder, or a folder whose last
indexable file was just deleted, publishes an empty generation instead of
failing. See `docs/tasks/S1-T3.md`, `docs/tasks/S1-T4.md`, and
`docs/incremental-indexing.md` for the full design and test results.

## Measured status

Performance and relevance baselines were recorded locally on 2026-07-12; the
Python validation count was refreshed on 2026-07-31. These are diagnostic
baselines, not production capacity promises.

| Area | Result |
|---|---|
| Automated validation | 67/67 Python tests and the dependency-free graded relevance smoke pass; the latest recorded pinned-toolchain Zig run remains 57/57 |
| WANDS sampled lexical relevance (10,000 products, 47 queries) | nDCG@10 0.6866; MRR@10 0.8574; success@10 0.9149; macro recall@10 0.0528 |
| WANDS sampled neural comparison (500 products, 11 queries) | nDCG@10: lexical 0.4176, BGE vector 0.4550, equal-RRF hybrid 0.4287; neural build 313.4 s |
| Mixed-domain success@1 (20 authored queries) | BM25 0.60; PPMI vector 0.70; BGE vector 0.90; equal-RRF BGE hybrid 0.85 |
| Python build, 5,000 small one-chunk files | No vectors: 591.6 ms and 3.31 MB JSON |
| Python synthetic 384-d build, 5,000 chunks | Full: 4.54 s and 10.98 MB JSON; unchanged: 2.02 s and zero embedding calls |
| Zig hybrid query, 8,000 exhaustive 32-d candidates | p50 0.417 ms; p95 0.456 ms after the ranking fix |
| Zig ranking improvement at 8,000 candidates | p50 174.6 ms to 0.417 ms, about 418x |
| Zig hybrid query, 32,000 exhaustive 32-d candidates | p50 1.69 ms; p95 2.13 ms |

The Python vector benchmark uses a synthetic provider, so it measures indexing, vector movement, reuse, and serialization—not neural inference. The Zig query benchmark uses equal-score synthetic documents and 32 dimensions. See [the scale benchmark](docs/scale-benchmark.md) and raw [Python](benchmarks/python-scale-2026-07-12.json) / [Zig](benchmarks/zig-ranking-scale-2026-07-12.json) results for methodology and limitations.

## Direction

- [Start here / resume a session — the journey](docs/journey/README.md)
- [Documentation index](docs/README.md)
- [Requirements register (all requirements in one place)](docs/requirements/README.md)
- [Capability process (how to add a new capability)](docs/capability-process.md)
- [Improvement board (shared human + agent backlog)](IMPROVEMENT-BOARD.md)
- [The learning loop: search that improves from use](docs/learning-loop.md)
- [Objective, specification, and prompts for recreating Search Simpli](docs/recreation/README.md)
- [Use-case library and contribution template](docs/use-cases/README.md)
- [Architecture and option comparison](docs/architecture.md)
- [Search and answer theory](docs/theory.md)
- [Experiment-driven roadmap](docs/roadmap.md)
- [Experiment ledger](EXPERIMENTS.md)
- [Continuation state](PROJECT-STATE.md)
- [Shared search tool schema](contracts/search-tool.schema.json)
- [Why Zig and where it belongs](docs/decisions/0001-zig-engine-boundary.md)
- [Zig in-memory hybrid engine](zig/README.md)
- [Immutable Zig segment format v1](docs/segment-format-v1.md)
- [Citation-bearing Zig segment format v2](docs/segment-format-v2.md)
- [Authorization-bearing Zig segment format v3](docs/segment-format-v3.md)
- [Immutable Zig lexical segment format v1](docs/lexical-segment-format-v1.md)
- [Generation manifest format v1](docs/manifest-format-v1.md)
- [Atomic publication and recovery protocol](docs/publication-recovery.md)
- [Writer locking and conservative generation lifecycle](docs/generation-lifecycle.md)
- [Loaded Zig engine query/evidence API](docs/zig-engine-api.md)
- [Live Zig JSON-RPC tool service](docs/zig-rpc-service.md)
- [Inverted postings design and verified invariants](docs/postings-design.md)
- [Local LLM/agent tool protocol](docs/tool-protocol.md)
- [Judged-query evaluation and first observed regression](docs/evaluation.md)
- [Product-search relevance benchmark, WANDS adapter, and smoke gate](docs/relevance-benchmark.md)
- [Recorded WANDS 10k lexical relevance run](benchmarks/wands-10k-lexical-2026-07-12.json)
- [Recorded WANDS 500-product neural/hybrid run](benchmarks/wands-500-neural-hybrid-2026-07-12.json)
- [Ground-up PPMI distributional semantic baseline](docs/cooccurrence-semantics.md)
- [Python-to-Zig indexing and query-model bridge](docs/python-zig-bridge.md)
- [Automatic query-embedding gateway and scale options](docs/query-embedding-gateway.md)
- [Local neural embedding provider and measured comparison](docs/neural-embedding-provider.md)
- [Recorded mixed-domain diagnostic benchmark](benchmarks/mixed-diagnostic-2026-07-11.json)
- [Pre-retrieval authorization theory, implementation, and limits](docs/authorization.md)
- [Incremental reuse and full/delta publication options](docs/incremental-indexing.md)
- [Measured Python indexing and Zig query scaling](docs/scale-benchmark.md)
- [Recorded Python files/folders scale run](benchmarks/python-scale-2026-07-12.json)
- [Recorded Zig ranking before/after run](benchmarks/zig-ranking-scale-2026-07-12.json)

The Python prototype is a behavioral reference, not intended to become the production server. Its JSON contract and ranking tests are the pieces worth preserving.
