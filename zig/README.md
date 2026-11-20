# Zig engine seed

This directory begins the production engine path without pretending the durable engine already exists. The current allocation-free, in-memory core includes:

- versioned ASCII and Unicode-aware analysis (native folder indexing defaults to analyzer-v2);
- corpus-level BM25 scoring;
- exact cosine scoring for supplied vectors;
- independent lexical and semantic ranks;
- reciprocal-rank fusion with component explanations;
- deterministic top-k results and explicit dimension/workspace errors.
- a versioned, checksummed immutable document/vector segment codec;
- golden tests proving hybrid results survive a segment round trip.
- an in-memory inverted term dictionary and postings index whose BM25 and hybrid results match the scan oracle;
- an integrated segment → decode → postings → hybrid golden test.
- a versioned checksummed `HYBLEX01` lexical segment whose decoded postings preserve BM25 and hybrid results without re-tokenizing text.
- a `HYBMAN01` generation manifest that cross-validates both immutable sections and pins analyzer/model ids;
- filesystem-backed atomic publication and load: synced immutable generation files become visible only through replacement of `MANIFEST`.
- advisory single-writer leasing plus conservative current/orphan generation scanning.
- backward-readable v3 document records with persisted source path/line citations and required access labels;
- a loaded `Engine` API that queries persisted postings/vectors and returns cited evidence.
- a live newline-delimited JSON-RPC tool service with search/read/list/status and an explicit query-vector boundary.
- a validated neutral-JSON importer that constructs and atomically publishes document/vector and lexical sections produced from the Python file indexer.
- pre-rank lexical/vector authorization, filtered source/read operations, and bounded allocation-free principal parsing.

Pinned validation toolchain: Zig 0.16.0.

```sh
cd zig
zig build test
zig build run -- --help
zig build run -- demo
zig build -Doptimize=ReleaseFast
./zig-out/bin/searchd benchmark 8000 32 51 hybrid
zig build run -- import-json /tmp/search-snapshot /tmp/zig-snapshot.json
zig build run -- serve /tmp/search-snapshot
```

The sources sit in one folder per layer ([docs/layers.md](../docs/layers.md)):
`src/core/` (the module `core`), `src/ops/` (the module `operations`, which imports
`core`), `src/interfaces/` (`main.zig` is `searchd`, `abi.zig` the C ABI libraries) and
`src/tests/` (the tests, benchmarks and tools that cross layers). `zig build test` runs
one step per folder and the `fastmem` step.

A benchmark or tool of `src/core/` runs on its own, from the repository root:

```sh
zig run -OReleaseFast zig/src/core/find_bench.zig -- INDEX_DIR [MODE ...]
zig run -OReleaseFast zig/src/core/nfc_bench.zig -- FILE [RUNS]
zig run -OReleaseFast zig/src/core/nfc_dump.zig -- IN OUT
```

A benchmark of `src/tests/` imports the modules, so name them (`-lc` where the
benchmark's own usage line has it; `scripts/mcp_overhead.py` builds this command):

```sh
zig run -lc -OReleaseSmall --dep core --dep operations -Mroot=zig/src/tests/fold_bench.zig \
  --dep core -Moperations=zig/src/ops/operations.zig -Mcore=zig/src/core/core.zig -- INDEX
```

The same form runs `filename_bench.zig`, `fuzzy_bench.zig`, `title_field_bench.zig` and
`mcp_bench.zig` (without `-lc`) with their own arguments.

Use the pinned Zig 0.16.0 toolchain. Native Linux CI runs the engine, ABI and Python CLI suites; macOS/iOS shipped-library verification remains a separate platform step. The Python behavioral tests remain the cross-language baseline.

The search core uses caller-owned slices rather than allocating. Channel ranks and final RRF ordering use deterministic in-place `O(n log n)` sorts; the persistent postings path avoids scanning non-matching lexical documents while exhaustive vectors remain the correctness baseline. `benchmark` measures the real postings + vector + fusion path and reports total plus lexical/ranking stage percentiles.

Opt-in `--filename-index` and `--search-field filename|both` add separate filename and content match sections with actual terms and source citations. See the [implementation handoff](../docs/tasks/directory-filename-implementation.md). Body-only defaults remain unchanged. Source contract is 1.3.0; bundled libraries await the genuine Mac/iOS rebuild.

Current limitations: quoted queries do not enforce phrase order, and the raw Zig service expects query embeddings from its caller. `zig_gateway.py` provides the intended text-only tool surface with exact model-fingerprint validation. Both dependency-free PPMI and local FastEmbed/BGE 384-dimensional snapshots have been imported and queried, but the neural evidence is still diagnostic rather than production-ready.

Next modules should be introduced in this order:

1. preserve versioned analyzer compatibility; evaluate full-casefold parity separately from the already implemented analyzer-v2 NFC/simple-fold path;
2. add platform-specific directory sync, reader leases/epochs, rollback policy, and generation-safe garbage collection;
3. connect gateway labels to authenticated identities and decide label-aware BM25 versus separate tenant indexes;
4. evolve `postings.zig` into a sorted dictionary, compressed posting blocks, and BM25 top-k pruning.
