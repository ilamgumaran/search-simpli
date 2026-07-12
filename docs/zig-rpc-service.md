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

The method set matches the Python reference:

- `search_knowledge`
- `read_chunk`
- `list_sources`
- `index_status`

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
- There is no arbitrary file read, shell, write, or reindex RPC.
- Requests are limited to the configured one-megabyte line buffer.

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
