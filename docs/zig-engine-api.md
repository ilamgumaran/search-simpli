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
