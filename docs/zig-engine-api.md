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

`abi.zig` is a thin C wrapper around `Engine`/`Service`, not a second implementation: `ss_query`'s JSON is written by the same function the JSON-RPC service uses (`rpc.writeSearchResultValue`), and `ss_evidence`'s per-chunk JSON is written by the same function `read_chunk` uses (`rpc.writeChunkFields`). This is what lets `zig build test-abi` assert its result is byte-for-byte identical to a captured JSON-RPC response for the same request, rather than merely "close."

### Functions

| Function | Summary |
|---|---|
| `ss_version()` | Returns `contracts/CONTRACTS_VERSION` (e.g. `"1.0.0"`), baked in at build time via a `build.zig`-generated `build_options` module (`@embedFile` cannot reach outside `zig/`'s module package). |
| `ss_open(dir)` | Opens a published snapshot directory into freshly allocated workspaces; returns an opaque handle or `NULL`. |
| `ss_close(handle)` | Frees a handle's workspaces. |
| `ss_status(handle)` | JSON with the same fields as JSON-RPC `index_status`'s `result`. |
| `ss_query(handle, text, vec, dims, k, opts)` | JSON identical to `search_knowledge`'s `result` for an equivalent request. `opts` is a JSON object: `retrieval_mode`, `candidate_k`, `path_prefix`, `principal_labels` (all optional). |
| `ss_evidence(handle, ids)` | Looks up stored chunks by id (`{"ids": [...], "path_prefix": ..., "principal_labels": [...]}`); returns a JSON array, one entry per id, in `read_chunk`'s shape or `{"chunk_id": "...", "found": false}`. |
| `ss_import_json(dir, bytes)` | Validates and publishes neutral interchange JSON, exactly like `searchd import-json`; returns the generation or a negative `ss_error_code`. |
| `ss_free(ptr)` | Frees a pointer returned by `ss_status`/`ss_query`/`ss_evidence`. |
| `ss_last_error()` | Thread-local diagnostic string for the most recent failure on the calling thread. |

Every function is documented in full in the header, including exact JSON shapes, bounds (`top_k` 1-100, `candidate_k` up to 10,000), and thread-safety (concurrent reads on one handle are safe; `ss_close` is not).

### Allocation and errors

All memory this module allocates — a handle's internal buffers and every returned JSON string — comes from the C allocator (`malloc`/`free`); `ss_free` is exactly `free()`, with no bookkeeping table. There is no global mutable engine state: `ss_last_error()` is a thread-local diagnostic (like `errno`/`strerror`), not part of any handle. Pointer-returning functions return `NULL` on failure; `ss_import_json` (the one integer-returning function) returns a negative `ss_error_code` (`SS_ERR_INVALID_ARGUMENT`, `SS_ERR_IO`, `SS_ERR_CORRUPT_SNAPSHOT`, `SS_ERR_CAPACITY`, `SS_ERR_OUT_OF_MEMORY`, `SS_ERR_NOT_FOUND`, `SS_ERR_INTERNAL`). Either way, `ss_last_error()` names the reason.

### Library builds (`zig build lib`)

Static and shared `search_simpli` libraries for `aarch64-macos`, `aarch64-linux-android`, and `x86_64-linux`, installed under `zig-out/lib/<target>/`. `aarch64-macos` and `x86_64-linux` link against Zig's own bundled libc; `aarch64-linux-android` has none, so it needs the Android NDK's sysroot, wired in through the `SS_ANDROID_NDK` environment variable (`build.zig`'s `androidLibcFile` writes a `--libc` paths file pointing at `$SS_ANDROID_NDK/toolchains/llvm/prebuilt/<host>/sysroot`, API level 29). Without `SS_ANDROID_NDK` set, the Android artifacts are skipped (with a warning) and the other two targets still build. Measured sizes are in `docs/tasks/S1-T0.md`'s Report.

### C ABI conformance harness (`zig build test-abi`)

`zig/tests/abi_test.c` publishes the same three-document demo as `searchd init-demo` through `ss_import_json`, opens it with `ss_open`, and checks `ss_status`/`ss_query`/`ss_evidence` byte-for-byte against JSON captured from a real `zig build run -- init-demo` + `serve` session (pasted in `docs/tasks/S1-T0.md`'s Report), plus several error paths (missing directory, malformed interchange JSON, out-of-range `top_k`, mismatched vector dimensions).
