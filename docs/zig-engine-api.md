# Loaded Zig engine API

Status: implemented in `zig/src/engine.zig`.

## Open

`Engine.open` accepts one already loaded `publication.LoadedSnapshot` plus caller-owned workspaces for:

- decoded documents and citation metadata;
- aligned vectors;
- term entries;
- postings;
- document lengths.

It revalidates manifest/section coherence, decodes `HYBSEG01` and `HYBLEX01`, checks shared document counts, and retains generation, analyzer id, and embedding model id.

All returned slices borrow the manifest, section, and workspace buffers. There is no hidden allocator or global mutable index state.

## Query

`Engine.query` accepts:

- query text;
- a query vector supplied by the model/inference boundary;
- caller-owned dense lexical-score and result workspaces;
- top-k, candidate depth, RRF, and BM25 options.

It scores lexical candidates from persisted postings, exact semantic similarity from persisted vectors, applies independent candidate ranks, fuses with RRF, and returns deterministic ranked results.

## Evidence

`Engine.evidence(result)` joins the ranking explanation with stored chunk content and citation metadata. This narrow evidence object is suitable for a CLI, JSON tool, MCP adapter, or local HTTP service.

## Verified restart path

The integration test performs the complete sequence:

```text
documents + vectors + citations
  -> document/vector segment
  -> postings build
  -> lexical segment
  -> generation manifest
  -> filesystem publication
  -> load current generation
  -> open Engine
  -> BM25 + cosine + RRF query
  -> cited evidence
```

The expected hybrid passage is returned with its path, line span, content, and both component ranks.

## Remaining adapter work

The engine API is synchronous and in-process. `SearchOptions` now carries principal labels that filter persisted document requirements before component ranks. It does not call an embedding model, authenticate the principal, provide label-aware BM25 corpus statistics, or manage a pool of snapshot readers. Those concerns belong around or beneath this persisted query boundary as described in `docs/authorization.md`.

## C ABI (ADR 0002, `docs/tasks/S1-T0.md`)

Status: implemented in `zig/src/abi.zig`; header in `zig/include/search_simpli.h`; conformance harness in `zig/tests/abi_test.c` (`zig build test-abi`).

`abi.zig` is a thin C wrapper around `Engine`/`Service`, not a second implementation: `ss_query`'s JSON is written by the same function the JSON-RPC service uses (`rpc.writeSearchResultValue`), and `ss_evidence`'s per-chunk JSON is written by the same function `read_chunk` uses (`rpc.writeChunkFields`). This is what lets `zig build test-abi` assert its result is byte-for-byte identical to a captured JSON-RPC response for the same request, rather than merely "close." Since contract 1.2.0 (S2-T4) `ss_query` appends `warnings`, `request` and, with `"profile": true`, `profile` after the shared fields (`rpc.writeSearchResultValueWith`, `zig/src/report.zig`); the JSON-RPC response does not carry them, and with those three top-level keys removed the two are byte-identical.

#### What a valid vector is (S2-T13)

A query vector or a stored document vector is valid when every component is finite (no NaN, no infinity) and its L2 norm is a finite `f32`: the sum of squares, accumulated in `f32`, does not overflow, which in practice means a norm below about 1.8e19. The all-zero vector is valid (its cosine is 0). `ss_query` rejects an invalid query vector in `vector` and `hybrid` mode (and in the default, `hybrid`) by returning `NULL` with a one-line `ss_last_error()` message (the JSON-RPC `search_knowledge` answers `-32602` "Invalid params", as for its other vector errors); `ss_import_json` and `searchd import-json` reject a document vector that is invalid with `SS_ERR_INVALID_ARGUMENT` (`VectorNormNotFinite`) and publish nothing. `lexical` mode (and a snapshot with zero vector dimensions) never reads the vector, so it does not validate it and still reports `vector_ignored`. Folder indexing (`searchd index`, `ss_index_folder`) never stores vectors, so it has nothing to check. The cosine itself is overflow-safe: it uses the original `f32` arithmetic whenever the sums of squares, the dot product and the denominator are finite (every ordinary embedding, bit for bit), and recomputes in `f64` otherwise, so a snapshot written before this check never produces a NaN score. This is not a contract change: the rejected inputs never had a defined result.

#### `ss_query` diagnostics (contract 1.2.0)

`warnings` is always present. Per retrieval mode: `query_term_unmatched` and `query_empty_after_analysis` are produced in `lexical` and `hybrid` only (vector mode does not use the words, and no longer looks them up). `query_term_unmatched` carries the analysed query term (lowercased under `ascii-alnum-v1`, folded under `analyzer-v2`), once per distinct term, with one message ("the term was not found in the searched files") whether the word is in no chunk or only in chunks outside `path_prefix` or without the caller's labels, so the report cannot be used to test which hidden files hold a word (`docs/authorization.md`). `vector_ignored` when a vector was passed and `retrieval_mode` is `lexical` or the snapshot has zero vector dimensions. `candidate_depth_cut` only when the cut can change the list: in `hybrid` mode when both channels produced candidates (hybrid on a snapshot without vectors is one channel), or whenever `candidate_k < top_k` (which `ss_query` rejects). Array order: `query_empty_after_analysis`, the unmatched terms in query order, `vector_ignored`, `candidate_depth_cut`. `request` echoes `analyzer_id`, `retrieval_mode`, `top_k`, `candidate_k` and `path_prefix` as used. `profile` (opt-in) gives `tokenize_us` (analysis and term lookup), `score_us` (matching and candidate selection), `rank_us` (fusion and result rows), `serialize_us` (writing the report up to `profile`) and `matched_chunks` (in-scope chunks holding any query term; hidden chunks are not counted); with profile off no clock is read.

### Functions

| Function | Summary |
|---|---|
| `ss_version()` | Returns `contracts/CONTRACTS_VERSION` (e.g. `"1.2.0"`), baked in at build time via a `build.zig`-generated `build_options` module (`@embedFile` cannot reach outside `zig/`'s module package). |
| `ss_open(dir)` | Opens a published snapshot directory into freshly allocated workspaces; returns an opaque handle or `NULL`. |
| `ss_close(handle)` | Frees a handle's workspaces. |
| `ss_status(handle)` | JSON with the same fields as JSON-RPC `index_status`'s `result`. |
| `ss_query(handle, text, vec, dims, k, opts)` | JSON identical to `search_knowledge`'s `result` for an equivalent request, followed since contract 1.2.0 by `warnings`, `request` and (opt-in) `profile`; see below. `opts` is a JSON object: `retrieval_mode`, `candidate_k`, `path_prefix`, `principal_labels`, `profile` (all optional). |
| `ss_evidence(handle, ids)` | Looks up stored chunks by id (`{"ids": [...], "path_prefix": ..., "principal_labels": [...]}`); returns a JSON array, one entry per id, in `read_chunk`'s shape or `{"chunk_id": "...", "found": false}`. |
| `ss_import_json(dir, bytes)` | Validates and publishes neutral interchange JSON, exactly like `searchd import-json`; returns the generation or a negative `ss_error_code`. `analyzer_id` is `"ascii-alnum-v1"` (ASCII) or, since contract 1.1.0, `"analyzer-v2"` (Unicode; the same index `searchd index` builds from the same chunks). |
| `ss_free(ptr)` | Frees a pointer returned by `ss_status`/`ss_query`/`ss_evidence`. |
| `ss_last_error()` | Thread-local diagnostic string for the most recent failure on the calling thread. |

Every function is documented in full in the header, including exact JSON shapes, bounds (`top_k` 1-100, `candidate_k` up to 10,000), and thread-safety (concurrent reads on one handle are safe; `ss_close` is not).

### Allocation and errors

All memory this module allocates — a handle's internal buffers and every returned JSON string — comes from the C allocator (`malloc`/`free`); `ss_free` is exactly `free()`, with no bookkeeping table. There is no global mutable engine state: `ss_last_error()` is a thread-local diagnostic (like `errno`/`strerror`), not part of any handle. Pointer-returning functions return `NULL` on failure; `ss_import_json` (the one integer-returning function) returns a negative `ss_error_code` (`SS_ERR_INVALID_ARGUMENT`, `SS_ERR_IO`, `SS_ERR_CORRUPT_SNAPSHOT`, `SS_ERR_CAPACITY`, `SS_ERR_OUT_OF_MEMORY`, `SS_ERR_NOT_FOUND`, `SS_ERR_INTERNAL`). Either way, `ss_last_error()` names the reason.

### Library builds (`zig build lib`)

Static and shared `search_simpli` libraries for `aarch64-macos`, `aarch64-linux-android`, and `x86_64-linux`, installed under `zig-out/lib/<target>/`. `aarch64-macos` and `x86_64-linux` link against Zig's own bundled libc; `aarch64-linux-android` has none, so it needs the Android NDK's sysroot, wired in through the `SS_ANDROID_NDK` environment variable (`build.zig`'s `androidLibcFile` writes a `--libc` paths file pointing at `$SS_ANDROID_NDK/toolchains/llvm/prebuilt/<host>/sysroot`, API level 29). Without `SS_ANDROID_NDK` set, the Android artifacts are skipped (with a warning) and the other two targets still build. Measured sizes are in `docs/tasks/S1-T0.md`'s Report.

### C ABI conformance harness (`zig build test-abi`)

`zig/tests/abi_test.c` publishes the same three-document demo as `searchd init-demo` through `ss_import_json`, opens it with `ss_open`, and checks `ss_status`/`ss_query`/`ss_evidence` byte-for-byte against JSON captured from a real `zig build run -- init-demo` + `serve` session (pasted in `docs/tasks/S1-T0.md`'s Report; for `ss_query` that golden is compared after removing the three 1.2.0 keys, and the keys are checked separately), plus several error paths (missing directory, malformed interchange JSON, out-of-range `top_k`, mismatched vector dimensions).

### Dart loader and app bundles (`docs/tasks/S1-T10.md`)

`bindings/dart/search_simpli/lib/src/library_loader.dart` is the only description of how the Dart package finds the library; this paragraph and the package README keep it in step. After the `SEARCH_SIMPLI_LIBRARY_PATH` override (which always wins) and Android's bare-name open, there are two orders. Inside a macOS app (`Platform.resolvedExecutable` sits directly in `*.app/Contents/MacOS/`) only `<executable dir>/../Frameworks/libsearch_simpli.dylib` is tried, as an exact path; no bare name, a missing file is a `StateError` saying the app did not ship the library, and a file that exists but cannot be opened is one saying it was found but could not be opened (with the underlying error). In a development checkout (macOS and Linux) the order is the package-config root's `native/<platform>/` copy, the cwd- and script-relative `native/` candidates, and then the bare name last, as the fallback for a system-installed library (on Linux the order is exact: first `<executable dir>/lib/libsearch_simpli.so`, then the package copy, then the cwd- and script-relative candidates, then the bare name). Inside an app only the shipped copy is ever loaded; in a checkout the package's own copy is preferred, and the bare name is the last fallback. A failed candidate never masks a later one, and the final `StateError` lists every path tried. A sandboxed app must therefore ship the `.dylib` in `Contents/Frameworks`, signed with the app; `tool/bundle_probe.sh` proves this in a real built `.app`, sandbox on and off.
