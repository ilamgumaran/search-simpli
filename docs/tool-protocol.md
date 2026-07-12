# Local knowledge tool protocol

Status: implemented over standard input/output by both the Python reference (`src/search_platform/tool_server.py`) and persisted Zig engine (`zig/src/rpc.zig`, launched with `searchd serve`).

## Purpose

The process turns one immutable local index into a narrow read-only capability that an LLM wrapper, skill, or agent can call. It does not give the model arbitrary filesystem access.

Transport is newline-delimited JSON-RPC 2.0: one request object per input line and one response object per output line. Standard input/output keeps the first integration local and dependency-free. An MCP or HTTP adapter can map to the same methods later.

## Start

```sh
python3 search.py index fixtures/knowledge --out .search/index.json
python3 knowledge_tools.py .search/index.json
```

## Methods

### `search_knowledge`

Parameters: non-empty `query`, optional `top_k` from 1–100, optional `candidate_k`, optional `path_prefix`, and optional `retrieval_mode` (`lexical`, `vector`, or `hybrid`). Zig vector/hybrid requests also supply `query_vector` matching the snapshot model/dimensions; Python’s current local providers embed internally. The response reports retrieval and index/model metadata.

```json
{"jsonrpc":"2.0","id":1,"method":"search_knowledge","params":{"query":"how are ranks fused?","top_k":5,"path_prefix":"guides/"}}
```

Returns the shared evidence envelope: stable chunk ids, paths, line spans, passages, component ranks/scores, and an answer policy requiring citations and an explicit response when evidence is insufficient.

### `read_chunk`

Parameters: `chunk_id` returned by search and optional `path_prefix`. It returns the authoritative indexed content and citation only when the chunk remains inside the requested scope. Out-of-scope ids return the same not-found error as unknown ids, avoiding an existence leak.

```json
{"jsonrpc":"2.0","id":2,"method":"read_chunk","params":{"chunk_id":"f12e2d743e1352172c4c"}}
```

### `list_sources`

Parameters: optional `path_prefix`. Returns sorted source paths and their chunk counts, without dumping content.

### `index_status`

No parameters. Returns readiness, index/vector versions, creation time, root, file/chunk counts, and skipped source details.

## Intended agent loop

1. Call `index_status` when freshness or availability matters.
2. Call `search_knowledge` with the user’s question and the narrowest appropriate path scope.
3. If evidence is ambiguous, refine the search or call `read_chunk` on a promising result.
4. Generate an answer using only supporting evidence, cite path and lines, and say when the index is insufficient.

The model chooses operations; the tool process owns retrieval, scoping, and authoritative content.

## Errors

Responses use JSON-RPC error objects:

- `-32700` malformed JSON;
- `-32600` invalid request envelope;
- `-32601` unknown method;
- `-32602` invalid or unknown parameters;
- `-32004` unknown chunk id.

The server continues reading after a malformed line.

## Security boundary

- Only content already admitted to the index can be returned.
- No `read_file`, shell, write, delete, or reindex operation is exposed.
- Path-prefix checks happen before ranking and results.
- Unknown parameters are rejected, preventing silent widening through misspellings.
- Retrieved content remains untrusted text and must not redefine agent or system policy.

This is a capability boundary, not a complete authorization system. Multi-user deployment still needs authenticated identities, per-document labels, authorization filtering in both lexical and vector channels, audit logs, and limits on result/prompt size.

## Adapter path

The method semantics are transport-independent and now have both Python and Zig JSON-lines implementations. A later MCP adapter should publish the same four operations and preserve parameter validation, scope behavior, and response bodies.

For the raw Zig service, vector/hybrid calls contain the internal `query_vector`. The LLM-facing `zig_gateway.py` deliberately removes that concern from callers: it accepts the same text parameters as the Python tool, verifies the exact snapshot model at startup, constructs the vector, and forwards the internal request. Caller-supplied vectors are rejected at this trust boundary. See [Query-embedding gateway](query-embedding-gateway.md).

The same boundary owns authorization. Raw Zig search/read/list requests accept bounded internal `principal_labels`; the LLM-facing gateway rejects that field and injects labels derived from trusted configuration. Required document labels filter both ranking channels before component ranks and are rechecked by list/read. Denied and unknown chunk reads share one not-found response. See [Pre-retrieval authorization](authorization.md).
