# Local knowledge tool protocol

Status: implemented over standard input/output by both the Python reference (`src/search_platform/tool_server.py`) and persisted Zig engine (`zig/src/rpc.zig`, launched with `searchd serve`). Contract 2.0.0 (S3-T4) adds the folder-knowledge methods `find`, `outline`, `read_span`, `list_files`, `roots` and the write method `apply_changes` to the Zig server only; the Python reference keeps the four methods below. Every request shape is in `contracts/tool-request.schema.json` (version 2).

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

Parameters: non-empty `query` (valid UTF-8, so the result's `query` is always a string; the Zig service answers invalid text with a JSON-RPC error, `-32700` or `-32602`, and `ss_query` with `NULL` and "query_text is not valid UTF-8", S2-T11), optional `top_k` from 1–100, optional `candidate_k`, optional `path_prefix`, and optional `retrieval_mode` (`lexical`, `vector`, or `hybrid`). Zig vector/hybrid requests also supply `query_vector` matching the snapshot model/dimensions; Python’s current local providers embed internally. The response reports retrieval and index/model metadata.

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

No parameters (Zig, since 2.0.0: optional `roots`, and `principal_labels` on the raw service). Returns readiness, index/vector versions, creation time, root, file/chunk counts, and skipped source details. The Zig result keeps its v1 fields in order (`ready`, `generation`, `analyzer_id`, `embedding_model_id`, `vector_dimensions`, `documents`, `terms`, `postings`) and adds `files`, `pending`, `truncated`, `roots` (`[{root_id, label, kind, files, documents, pending}]`), `pending_paths`, `has_source`, `has_positions`, `chunkers`; every count is over the server's scope (below), never the whole index.

## Folder-knowledge methods (Zig, contract 2.0.0)

The scope of every request comes from the server's command line: `searchd serve <dir> [--roots a,b] [--labels l1,l2] [--allow-write] [--allow-file-reads]`. A request may name `roots` to narrow the server's roots (never to widen them). Without `--labels` the raw service keeps accepting a request's `principal_labels` (at most 64, each 1–256 bytes without NUL or a line break, no repeats), as it always has for the four methods above; with `--labels`, a request that states them is refused (`-32602`). A file, chunk, term or root outside the scope is indistinguishable from an absent one.

Every result below starts with the same envelope: `request` (echoed with defaults filled in), `generation`, `scope` (`{roots: [visible roots], labels_applied: true}`) and `warnings` (`[{code, message}]`). The results are byte-identical to the C ABI's (`ss_find` …) and to `searchd <command> --json`; `zig/include/search_simpli.h` documents every field.

### `find`

Parameters: `query` (required; a quoted query is a phrase, a trailing `*` a prefix), `mode` (`words` default, `phrase`, `prefix`), `roots`, `path_prefix` (root-relative), `page_size` (1–100, default 20), `cursor` (a previous `next_cursor`). Returns `hits` (`chunk_id`, `root_id`, `path`, `section_path`, `start_line`, `end_line`, `score`, `snippet`, `snippet_start`, `snippet_offsets`, `match_offsets`), `files` (`{root_id, path, hits}` over every page), `exact_match`, `empty`, `coverage`, `truncated`, `next_cursor`, `pending_files`.

```json
{"jsonrpc":"2.0","id":5,"method":"find","params":{"query":"\"count me in\"","roots":["school"],"page_size":5}}
```

### `outline`

Parameters: `root_id`, `path` (both required), `roots`. Returns `front_matter` (or null), `headings` (`level`, `text`, `line`, `end_line`), `lines`, `chunker`.

### `read_span`

Parameters: `root_id`, `path`, `start_line`, `end_line` (required, 1-based inclusive), `context_lines` (0–20, default 0), `roots`. Returns `start_line`, `end_line` (an `end_line` past the file's end is clamped, with the warning `end_line_clamped`), `text`, `context_before`, `context_after` (the original bytes, line terminators included), `byte_exact: true`, `sha256` of `text`. At most 400 lines including context and 256 KiB, else `-32005`.

### `list_files`

Parameters (all optional): `root_id`, `path_prefix` (root-relative), `status` (`indexed` or `pending`), `page_size` (1–1,000, default 100), `cursor`, `roots`. Returns `files` (`root_id`, `path`, `size`, `mtime_ms` (null), `status`, `chunks`, `chunker`), `total`, `next_cursor`.

### `roots`

Parameters: `roots`. Returns `roots` (`root_id`, `label`, `kind`, `files`, `documents`, `pending`).

### `apply_changes` (only with `--allow-write`)

Parameters: the change request itself (`expect_generation`, `roots`, `changes`; `docs/folder-knowledge-implementation.md` §6). Publishes one new generation and returns its report; the server then reads the new generation. Without `--allow-write` the method does not exist (`-32601`). A `file` change is read only with `--allow-file-reads`. A model-facing adapter never exposes this method (FR-23).

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
- `-32602` invalid or unknown parameters (Zig, folder methods: "Invalid params: <reason>", including a malformed or stale cursor and a stale `expect_generation`);
- `-32004` unknown chunk id; since 2.0.0 also an unknown, hidden or not retained file (`outline`, `read_span`), with the same message for all three;
- `-32005` (2.0.0) over a limit: a span over 400 lines or 256 KiB, a generation without retained source bytes or without positions, a prefix over 1,000 terms, a batch over its caps;
- `-32006` (2.0.0) `apply_changes` while another writer holds `WRITER.LOCK`.

The server continues reading after a malformed line.

## Security boundary

- Only content already admitted to the index can be returned.
- No `read_file`, shell, delete, or reindex operation is exposed; `read_span` and `outline` read only bytes the index retained, bounded as above. The one write method, `apply_changes`, exists only when the server was started with `--allow-write`.
- Path-prefix checks happen before ranking and results.
- Unknown parameters are rejected, preventing silent widening through misspellings.
- Retrieved content remains untrusted text and must not redefine agent or system policy.

This is a capability boundary, not a complete authorization system. Multi-user deployment still needs authenticated identities, per-document labels, authorization filtering in both lexical and vector channels, audit logs, and limits on result/prompt size.

## Adapter path

The method semantics are transport-independent and now have both Python and Zig JSON-lines implementations. A later MCP adapter (S3-T6) should publish the same operations (the eight read methods; `apply_changes` only behind its own write flag) and preserve parameter validation, scope behavior, and response bodies.

For the raw Zig service, vector/hybrid calls contain the internal `query_vector`. The LLM-facing `zig_gateway.py` deliberately removes that concern from callers: it accepts the same text parameters as the Python tool, verifies the exact snapshot model at startup, constructs the vector, and forwards the internal request. Caller-supplied vectors are rejected at this trust boundary. See [Query-embedding gateway](query-embedding-gateway.md).

The same boundary owns authorization. Raw Zig search/read/list requests accept bounded internal `principal_labels`; the LLM-facing gateway rejects that field and injects labels derived from trusted configuration. Required document labels filter both ranking channels before component ranks and are rechecked by list/read. Denied and unknown chunk reads share one not-found response. See [Pre-retrieval authorization](authorization.md).
