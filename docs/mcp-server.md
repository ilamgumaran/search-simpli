# The MCP server (`searchd mcp`)

Status: implemented (S3-T6, contract 2.0.0). CAP-19 FR-24, realizing
[CAP-13](requirements/cap-13-mcp-adapter.md). Code: `zig/src/mcp.zig`; the
results come from `zig/src/ops.zig`, the same code the RPC server, the CLI
`--json` and the C ABI answer through.

`searchd mcp` serves one published index to one Model Context Protocol host
over stdio. A desktop agent (or any MCP client) gets the read tools of the
[tool protocol](tool-protocol.md), described by the schemas in
[`contracts/tools/`](../contracts/tools/) ([tool schemas](tool-schemas.md)),
and the indexed files as read-only resources.

## Launching it

```sh
searchd mcp <index-dir> [--roots a,b] [--labels l1,l2] [--baseline] [--allow-write] [--allow-file-reads]
```

A host starts the binary as a child process and talks to it on its stdin and
stdout. A typical host configuration entry (the exact file and key names are
the host's own; the shape below is the common one):

```json
{
  "mcpServers": {
    "family-folder": {
      "command": "/path/to/searchd",
      "args": ["mcp", "/path/to/index", "--roots", "school,home"]
    }
  }
}
```

The index is any directory `searchd index` or `searchd apply` published
(`index` builds one from a folder; `apply` from host-fed changes,
[implementation §6](folder-knowledge-implementation.md)). The server opens
the current generation at start; if it cannot, it prints one line on stderr
and exits 1. It exits 0 when the host closes its stdin.

| Flag | Effect |
| --- | --- |
| `--roots a,b` | Only these roots are visible, to every tool and resource. A call's own `roots` may narrow this, never widen it. Without it, every root. |
| `--labels l1,l2` | The principal's labels: a file whose root or own `required_labels` are not all held is invisible (and indistinguishable from an absent one). Without it, no labels: labelled files are invisible. |
| `--baseline` | CAP-13's read-only baseline: `tools/list` lists exactly `search_knowledge`, `read_chunk`, `list_sources`, `index_status`; no other tool and no resources (the `resources/*` methods are `-32601`). Cannot be combined with `--allow-write`. |
| `--allow-write` | Adds `apply_changes` (host-fed changes, one new generation per call). When `--roots` is given, every root a change names or declares must be one of them. The server reads the new generation before the next message. |
| `--allow-file-reads` | Lets `apply_changes` read `file` changes from disk (only with `--allow-write`); otherwise only `content_base64` changes are accepted. |

A usage error (an unknown flag, `--baseline --allow-write`,
`--allow-file-reads` alone, an empty list item) prints one line on stderr and
exits 2.

## The stdio contract

- **Framing.** Newline-delimited JSON-RPC 2.0, as MCP's stdio transport
  specifies: one message per line, UTF-8, no embedded newline. The server
  writes nothing but protocol messages to stdout; stderr carries only the
  start-up failure above or a fatal I/O error. Blank lines are ignored; a trailing CR
  is tolerated. A line longer than 8 MiB is answered `-32700` (id null) and
  skipped. Batches (a JSON array) are not part of MCP: `-32600`.
- **Protocol revision.** Pinned: **`2025-11-25`** (`mcp.protocol_version`).
  `initialize` answers it whatever revision the client asked for (MCP's
  negotiation: the client disconnects if it cannot use it). The capabilities
  are `tools` (no list changes) and, outside `--baseline`, `resources` (no
  subscriptions, no list changes); `serverInfo` is `search-simpli` with the
  contract version; `instructions` summarize the search → read → cite loop
  ([the skill](../skills/folder-knowledge/SKILL.md) has the full text).
- **Lifecycle.** Before `initialize` only `ping` and `initialize` are
  answered; anything else is `-32600`. A second `initialize` is `-32600`.
  `notifications/initialized` is accepted; `notifications/cancelled` is
  accepted and ignored (each request is answered before the next line is
  read, so nothing is ever in flight); other notifications, and responses a
  client sends, are ignored. Request ids must be strings or integers.
- **Methods.** `initialize`, `ping`, `tools/list`, `tools/call`,
  `resources/list`, `resources/read`, `resources/templates/list`. Any other
  method is `-32601`. `params`, when present, must be an object (`-32602`).

### Tools

`tools/list` returns one page (a `cursor` is refused, `-32602`): the eight
read tools in this order, `search_knowledge`, `read_chunk`, `list_sources`,
`index_status`, `find`, `outline`, `read_span`, `list_files`, then
`apply_changes` with `--allow-write`. Each descriptor has `name`, `title`,
`description`, `inputSchema` (the tool's
`contracts/tools/<tool>.request.schema.json`, the same JSON value, built
into the binary at compile time), `outputSchema` (its `result` schema) and
`annotations` (`readOnlyHint` true and `openWorldHint` false for the reads;
`apply_changes` is destructive).

`tools/call` takes `name` and `arguments` (an object; absent means `{}`).

- **A result** carries the operation's canonical JSON, exactly what
  `searchd serve` returns as `result` for the method of the same name with
  the same params (and what the CLI's `--json` and the C ABI return for the
  folder operations), twice: as `structuredContent`, and serialized in the
  one `text` content block. `isError` is false.
- **A refusal by the operation** (an unknown field, a value out of range, a
  stale cursor, an unknown or hidden file, a span over its limits) is a tool
  result with `isError: true` and one `text` block holding the RPC server's
  error object for the same request, for example
  `{"code":-32602,"message":"Invalid params: unknown field \"bogus\""}`
  (`-32602` invalid, `-32004` not found, `-32005` over a limit, `-32006`
  writer busy, `-32603` internal). No `structuredContent` then.
- **A protocol error** is a JSON-RPC error: an unknown tool, or one the mode
  does not list (`apply_changes` without `--allow-write`, `find` under
  `--baseline`), is `-32602` "Unknown tool: <name>"; a missing `name` or
  non-object `arguments` is `-32602`.
- **The scope is never the caller's** (CAP-13 FR-13): a call whose arguments
  carry `principal_labels` or `query_vector` is refused (`isError`, `-32602`)
  before anything runs. An index with vectors therefore answers
  `search_knowledge` in `lexical` mode only (vector and hybrid need a
  `query_vector`, which a caller may not supply here); the family indexes
  have no vectors, where every mode is lexical.

### Resources

Indexed files whose bytes the index retained, outside `--baseline`:

- `resources/templates/list`: one template, `search://{root_id}/{path}`.
  Both parts are percent-encoded (every byte outside RFC 3986's unreserved
  set; the path keeps its slashes): `school/week 7.md` is
  `search://school/week%207.md`.
- `resources/list`: the visible indexed files with retained bytes, by root
  then path, 100 per page; `nextCursor` is opaque (a stale or malformed one
  is `-32602`). Each entry has `uri`, `name` (the path), `title`
  (`root/path`), `mimeType` (`text/markdown` for `.md`/`.markdown`, else
  `text/plain`) and `size` (the retained bytes).
- `resources/read` `{uri}`: the whole file as one text content, read through
  `read_span`'s limits (one span from line 1 to the last line, no context):
  the original bytes (CRLF, missing final newline and all), except that a
  leading UTF-8 BOM is not part of line 1, as in `read_span`. A file over
  400 lines or 256 KiB is `-32005` naming the limits (read it in spans with
  `read_span`); a hidden, unknown or not retained file is `-32002`
  "Resource not found" alike, with `data: {uri}`; a URI that is not
  `search://{root_id}/{path}` is `-32602`.

## What it never does

- **No network.** stdio only; it opens no socket (the loopback HTTP of
  `searchd serve --http` is not offered here).
- **No model, no generation.** It returns indexed text and citations; it
  never writes an answer (INV-01).
- **No writes without `--allow-write`**, and then only `apply_changes`,
  inside `--roots`; no file is read from disk unless `--allow-file-reads`.
  The read tools and resources read only bytes the index retained.
- **No caller-supplied principal or vector**; no widening of `--roots`.
- **No other operation**: no shell, no file browsing outside the index, no
  prompts, no sampling, no subscriptions.

## The baseline mode

`--baseline` is CAP-13 as first proposed: the four FR-07 operations,
read-only, with the trusted principal from the command line. It is the mode
to give an agent that only needs ranked, cited passages; the default mode
adds CAP-19's exact finding (`find`), document structure (`outline`), exact
spans (`read_span`), the file listing (`list_files`) and the resources.

## Checks

- `tests/mcp_client.py <searchd> <index-dir>`: a standard-library MCP client
  that runs the conformance sequence (handshake, ping, cancellation of
  nothing, `tools/list`, `tools/call` for every tool, resources, a malformed
  line, an unknown method, a refused write) and prints one line per check.
- `tests/test_mcp.py`: the conformance run, the three modes, the schemas,
  parity with `searchd serve` for every fixture judgment and for one request
  per tool with no optional field (100% equal, any mismatch fails), the
  command-line scope, resources, writes and framing.
- `scripts/mcp_overhead.py`: the adapter overhead over the direct Zig call
  and the start-up time (S3-T6's Report has the numbers).
