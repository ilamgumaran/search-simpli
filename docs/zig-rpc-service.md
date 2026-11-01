# Zig JSON-RPC search service

Status: implemented in `zig/src/service.zig`, `zig/src/rpc.zig`, and the `searchd serve` command.

## Live persistent demo

With Zig 0.16.0:

```sh
cd zig
zig build run -- init-demo /tmp/searchd-demo
printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"index_status","params":{}}' \
  '{"jsonrpc":"2.0","id":2,"method":"search_knowledge","params":{"query":"BM25 ranking","retrieval_mode":"lexical","path_prefix":"guides/","top_k":1}}' \
  '{"jsonrpc":"2.0","id":3,"method":"search_knowledge","params":{"query":"hybrid ranking","retrieval_mode":"hybrid","path_prefix":"guides/","query_vector":[1,0],"candidate_k":2,"top_k":1}}' \
  | zig build run -- serve /tmp/searchd-demo
```

`init-demo` exercises the real writer lease, immutable section encoders, manifest, and atomic publisher. `serve` opens `MANIFEST`, allocates bounded workspaces from declared counts, validates and decodes both sections, then serves newline-delimited JSON-RPC 2.0 on standard input/output.

## Methods

The first four match the Python reference:

- `search_knowledge`
- `read_chunk`
- `list_sources`
- `index_status`

Contract 2.0.0 (S3-T4) adds the folder-knowledge methods `find`, `outline`, `read_span`, `list_files`, `roots`, and `apply_changes` only under `serve --allow-write` (`docs/tool-protocol.md` has every parameter; `contracts/tool-request.schema.json` version 2 every request shape). Their results are produced by `zig/src/ops.zig`, the same code the C ABI and `searchd <command> --json` use, so the three are byte-identical (the parity tests: `tests/test_folder_surfaces.py` for the CLI and the server, `bindings/dart/search_simpli/test/parity_test.dart` for all three with the Dart binding).

```sh
searchd apply /tmp/folders --changes changes.json
printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"roots","params":{}}' \
  '{"jsonrpc":"2.0","id":2,"method":"find","params":{"query":"tide table","page_size":3}}' \
  | searchd serve /tmp/folders --roots school,home
```

### Scope from the command line

`serve <dir> [--roots a,b] [--labels l1,l2] [--allow-write] [--allow-file-reads]`. `--roots` bounds every request's roots (a request's `roots` narrows them, never widens them); `--labels` are the trusted principal labels, and once given a request may not state `principal_labels` (`-32602`). Without `--labels` the raw service keeps accepting a request's `principal_labels`, bounded as before (at most 64, 1–256 bytes each, no NUL or line break, no repeats). `index_status` counts over that scope only (S3-T3's whole-index counts are gone); `read_chunk` and `list_sources` go through it too, and `search_knowledge` takes the scoped path when roots are named.

### Writes

`apply_changes` publishes one new generation into the served directory under `WRITER.LOCK` and, when it succeeds, the server reopens the index before the next request, so reads see the new generation. Another writer holding the lock answers `-32006`; a stale `expect_generation` `-32602` "Invalid params: stale: generation is M"; `file` changes need `--allow-file-reads`.

Responses preserve the common evidence contract: chunk id, path/line citation, content, fused score, component ranks/scores, index generation/analyzer/model metadata, and the grounding policy.

## Search parameters

| Parameter | Meaning |
|---|---|
| `query` | required query text |
| `retrieval_mode` | `lexical`, `vector`, or `hybrid`; default `hybrid` |
| `query_vector` | required for vector/hybrid when the snapshot has vector dimensions |
| `top_k` | final result count, 1–100; default 5 |
| `candidate_k` | maximum candidates retained independently from each channel, at least `top_k`, at most 10,000; default 100 |
| `path_prefix` | optional path scope applied before lexical/semantic ranks |

Candidate depth is visible because it affects fusion. In the three-document demo, admitting a weak semantic rank 3 can narrowly help a lexical result; `candidate_k: 2` excludes that tail contribution and returns the document supported near the top of both channels.

## Query embedding boundary

The service never invents or silently hashes a query vector. A caller or sidecar must embed the query using the model id reported by `index_status`, then supply exactly the recorded dimensions. Missing, nonnumeric, nonfinite, or wrong-sized vectors return JSON-RPC `-32602`.

Lexical mode needs no vector. A snapshot with zero vector dimensions safely reduces hybrid behavior to lexical retrieval.

This keeps model inference replaceable and prevents the Zig index format from depending on one neural runtime.

## Scope and security

- Path scope is applied before component rank assignment.
- `read_chunk` accepts the same optional path prefix; out-of-scope ids are indistinguishable from unknown ids.
- Unknown methods and parameters are rejected.
- There is no arbitrary file read, shell, or reindex RPC; the one write (`apply_changes`) exists only with `--allow-write`.
- Requests are limited to the configured one-megabyte line buffer (an `apply_changes` batch larger than that goes through `searchd apply` or the C ABI instead). Over `--http`, the response buffer grows as needed (a `read_span` answer can hold 256 KiB).

Path prefix remains a caller-selected scope rather than authorization. Persisted document labels now filter both vector and lexical candidates, and raw search/read/list methods accept bounded internal principal labels. The LLM-facing gateway injects configured labels and rejects caller forgery. Authentication, identity-derived labels, label-aware lexical statistics or tenant isolation, and audit logs still remain.

## Runtime ownership

The process allocates section bytes and engine workspaces once from manifest-declared counts. Each request uses those fixed arrays plus a short-lived parsing arena. The current loop is single-threaded, which avoids workspace races and creates a clear baseline for later reader pools.

## Remaining production work

- plug in a real query-embedding sidecar/provider;
- authenticated identity-to-label derivation and filter-aware statistics or tenant isolation;
- request/result size and deadline policy beyond the line limit;
- structured logs, metrics, and tracing;
- concurrent read workers with snapshot-safe workspaces;
- MCP or HTTP framing if stdin/stdout is not the chosen deployment surface.


## Opt-in filename field (source contract 1.3.0)

`search_knowledge.params.search_field` accepts `content` (default), `filename`
or `both`. Filename modes require explicit lexical retrieval and a snapshot
built with `--filename-index`; body-only snapshots return rebuild guidance.
New results include the two `match_sections` with actual terms and separate
filename/content citations. Default content responses retain their original
shape. Source/native package status and examples are in the
[implementation handoff](tasks/directory-filename-implementation.md).
