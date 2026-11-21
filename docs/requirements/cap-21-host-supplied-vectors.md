# CAP-21 — Host-supplied vectors for a `searchd`-built index

Status: Proposed · future option · drafted by [S6-T6](../tasks/S6-T6.md) (item E
of the [objective plan](../plans/2026-11-16-objective-plan.md)) on `main` at
`1c15b19`. **Not approved.** It changes the wire, the C ABI and the index format,
and the maintainer has not read it. Nothing here is built.

## In short

- **The gap.** The engine stores vectors, scores them exactly and fuses them with
  BM25 by rank, but only an index imported from the Python reference can hold
  them. An index written by `searchd index`, `searchd apply`, `ss_index_folder`
  or `ss_apply_changes` holds none, so a folder the engine indexed itself is
  lexical only.
- **What this proposes.** The host application runs the embedding model; the
  engine never does. After an `apply` publishes the lexical generation, the host
  asks the engine which chunks have no vector, embeds their text, and sends the
  vectors back in a second publish (option (a), *two-phase*, recommended in
  [§B](#b-how-the-host-learns-the-chunks-the-hard-question)). Every vector set is
  bound to one model identity per generation, which the engine checks on every
  query vector.
- **What it costs.** A second full generation write per embedding round, and
  vector bytes that at 384 dimensions in `float32` are about as large as today's
  whole index on the 10,000-file timing corpus (computed in
  [§D](#d-format-and-size)). A separate, lazily loaded vector section keeps
  lexical queries' memory and the phone's 64 MiB bound unchanged.
- **What it does not change.** Lexical results, the import path, the MCP rule
  that a model caller never supplies a vector, and the direct `search` command,
  which stays lexical only.
- **Before it is built,** a semantic slice must exist in the judged fixture and
  show, through the import path that already works, that hybrid ranking helps
  ([§F](#f-what-is-measured-before-it-is-called-done)). That measurement is what
  earns the complexity (INV-09).

Statements about today's code cite a file and a function and were checked against
`main` at `1c15b19`. Statements marked *confirmed by running* were reproduced on
a Debug build of that commit (S6-T6 Report) and again on a `ReleaseSmall` build
by the verifier (S6-T6 Verdict). Numbers are *computed* from figures
recorded by earlier tasks, and say so.

## 1. Proposal

- **Problem / what should be possible:** a host that indexes folders with the
  engine (`apply`) can add semantic matches to that index, with vectors from a
  model the host runs, and query it in hybrid mode, without going through the
  Python reference.
- **Who it serves:** human user (a question in other words than the file's still
  finds it) · agent user (an LLM's paraphrased query finds the passage) · app
  developer (one engine for keyword and semantic search on a phone or a desktop,
  with the model of their choice) · contributor (one write path for vectors,
  shared by every interface).
- **HIO tie:** the seam. The engine keeps doing the inorganic work it is good at
  (exact scan, fusion, citation, scope); the host decides which model's notion of
  "similar" it trusts, and the engine refuses to mix two notions.
- **One-line success notion:** on a judged semantic slice, an index built by
  `apply` with host-supplied vectors ranks paraphrased questions' answers higher
  than the same index in lexical mode, with no loss on the control slice and no
  query ever scored against vectors of another model.

## 2. Motivating use case(s)

- Primary use case: [`UC-001`](../use-cases/uc-001-personal-files.md) (personal
  files; its acceptance already names "semantic retrieval handles paraphrases and
  vocabulary mismatch").
- Other affected use cases: [`UC-007`](../use-cases/uc-007-family-folders-on-a-phone.md)
  (a phone app is the host that would run a small model and feed the index),
  [`UC-002`](../use-cases/uc-002-codebase-agent.md) (an agent's query rarely uses
  the file's own words).
- No new use case is written: the questions that need semantic matches are to be
  authored as a judged slice ([§F](#f-what-is-measured-before-it-is-called-done)),
  which is the measurable form the process asks for.

## A. What the engine does with vectors today

### A1. Where a vector is stored

There is no separate vector section. A vector is a field of each chunk record in
the documents section (`HYBSEG01`, [segment format v4](../segment-format-v4.md)):
`u32 vector_length` in the fixed part and `vector_length × f32` after the
labels.

- `zig/src/core/segment.zig` `vectorDimensions`: a record's vector is either empty or
  of the one length all non-empty vectors share; a second length is
  `VectorDimensionsInconsistent`. The header stores that length
  (`writeVersion`, the `dimensions` field).
- `segment.zig` `decodeInspected`: a record whose `vector_length` is neither 0
  nor the header's dimensions is `InvalidVectorDimensions`; the floats are copied
  out of the section into a caller-owned `f32` array.
- So **partial coverage is already legal in the format**: some records may carry
  a vector and others none. The import path accepts it (A3, *confirmed by
  running*).
- Values are stored as `f32` only. There is no other element type.

### A2. What the manifest says about vectors

`zig/src/core/manifest.zig` `Manifest` has two vector fields and no more:

- `embedding_model_id`: a string. `validateIdentifier` checks only that it is
  non-empty and holds no NUL, CR or LF. Nothing reads its meaning.
- `vector_dimensions`: copied from the documents section header by
  `sectionFields`; `validateSnapshotHeaders` refuses a section whose header
  disagrees (`VectorDimensionMismatch`).

The manifest records **no normalisation, no element type and no identity
version**. The specification's FR-04 says "every vector index records model id,
dimensions, normalization, and semantic status"; that holds for the Python
reference's index, not for the Zig manifest.

The manifest flags (`manifest.zig`, `known_flags_v2`) are bits 1, 2, 4, 8, 16
(`has_source`, `has_positions`, `xxh3_sections`, `filename_sections`,
`state_section`). `decodeV2` refuses any other bit with `UnsupportedFlags`, which
is how v2.1 and v2.2 made older readers refuse newer indexes. The manifest's
`meta` JSON is parsed by `parseMeta` with `ignore_unknown_fields = true`, so a
field added there would be **silently ignored** by an older reader.

### A3. The import path (the one way vectors get in)

`zig/src/core/importer.zig` `importJsonKeeping`, shared by `searchd import-json`
(`zig/src/interfaces/main.zig`) and `ss_import_json` (`zig/src/interfaces/abi.zig` `importImpl`). The
payload is [`contracts/snapshot-interchange.schema.json`](../../contracts/snapshot-interchange.schema.json)
(CON-03), written by the Python reference (`src/search_platform/interchange.py`).

- Every non-empty vector must pass `scoring.isValidVector` (S2-T13) or the import
  is `VectorNormNotFinite` before any file is written.
- All non-empty vectors must share one length (`VectorDimensionsInconsistent`).
- `embedding_model_id` must be `"none"` exactly when no document has a vector
  (`EmbeddingMetadataMismatch`).
- It writes record v3 (`segment.encode`) and a v1 manifest (`manifest.create`):
  no source section, no positions, no recovery state.

*Confirmed by running:* a three-document import with vectors `[1,0]`, `[0,1]` and
`[]` publishes `vector_dimensions=2`; `index_status` reports
`embedding_model_id` and `vector_dimensions` 2.

### A4. The folder writer writes no vectors

`searchd index` (`zig/src/core/indexer.zig` `indexFolder`) builds a batch and calls
`apply.applyBatch`; `searchd apply`, `ss_apply_changes` and JSON-RPC
`apply_changes` go through `apply.applyChanges`. Both end in
`zig/src/core/apply.zig` `buildGeneration`:

- a freshly chunked file's records are appended with `.vector = &.{}`;
- an unchanged file's records are copied whole from the previous generation
  (`var document = engine.documents[old_index]`), **vector included**;
- the manifest is written with `.vector_dimensions = 0` and
  `.embedding_model_id = "none"` regardless.

*Confirmed by running:* `searchd apply` adding one file to the imported snapshot
of A3 publishes nothing and exits 1 with `VectorDimensionMismatch`, raised by
`manifest.validateSnapshotHeaders` from `publication.publishWithExtrasRecorded`:
the carried records still hold 2-dimensional vectors while the new manifest says
0. The index stays at generation 1 and keeps answering. The failure is
fail-closed, but by accident: nothing names it.

The CLI's help says so for `index`: "`index` never produces vectors
(`embedding_model_id` "none"); its snapshots only support lexical (BM25)
queries" (`zig/src/interfaces/cli.zig`, the usage text).

### A5. How an open holds vectors

`zig/src/core/snapshot_open.zig` `OpenBlock.of` reserves `document_count ×
vector_dimensions` floats in the open's one block, and `loadEngine` reads the
whole documents section into the same block. `Engine.openWith`
(`zig/src/core/engine.zig`) decodes the vectors from the section into the reserved
floats. An open therefore holds **every vector twice** (inside the section bytes
and in the decoded array), and holds them for every query, lexical or not.

### A6. How a query vector arrives, per surface

| Surface | Where | What happens |
| --- | --- | --- |
| C ABI `ss_query` | `abi.zig` `ss_query`, `queryImpl` | `query_vector` + `dims`. Lexical mode, or a snapshot with 0 dimensions: ignored, reported as `vector_ignored` (`lexical_mode` / `no_vectors_in_snapshot`, `report.zig` `VectorIgnored`). Otherwise the length must equal the snapshot's dimensions (`VectorDimensionMismatch`) and the vector must pass `isValidVector` (`VectorNormNotFinite`). |
| JSON-RPC `search_knowledge` | `ops.zig` `parseSearch`, `queryVector` | `query_vector` array. Required for `vector` and `hybrid` when the index has vectors; must hold exactly `vector_dimensions` finite numbers with a valid norm, else `-32602`. Lexical mode and 0-dimension indexes ignore it. |
| MCP `search_knowledge` | `mcp.zig` `runTool` | `query_vector` is refused (`-32602`, "not accepted over MCP (CAP-13: no caller-supplied vectors)"). |
| CLI `query`, `evidence`, `search` | `cli.zig` `answerQuery`, `answerEvidence`, through the core's `engine.queryOneShot` (S6-T18) | Always lexical (`retrieval_mode = .lexical`, an empty vector); there is no vector argument. |
| Dart `SearchSimpli.query` | `bindings/dart/search_simpli/lib/src/search_simpli_base.dart` | `queryVector` (`List<double>`) is copied to a `Float` array and passed to `ss_query`. |
| Python gateway | `src/search_platform/zig_gateway.py` `EmbeddingGateway` | Refuses a caller's `query_vector`, embeds the query text itself, and forwards the vector to the engine's JSON-RPC. |

*Confirmed by running* on the imported snapshot of A3 (it has vectors), with no
query vector and the default mode (`hybrid`):

- `serve`: `-32602` "query_vector must hold 2 finite numbers for hybrid retrieval";
- `ss_query`: `NULL`, `ss_query: VectorDimensionMismatch`;
- `mcp`: the same `-32602` as a tool error. An MCP client can never supply the
  vector, so on an index with vectors its default search always fails; it must
  ask for `lexical` explicitly;
- `searchd query`: answers, lexically.

Today this never bites, because no `searchd`-built index has vectors. It would
bite every existing caller the day one does (FR-30 below).

### A7. What identity is checked, and where

- **In the engine: dimensions only.** At open, the manifest's dimensions must
  equal the documents section's (`validateSnapshotHeaders`). At query, the query
  vector's length must equal them (A6). No query carries a model id, and the
  engine compares no model id with anything.
- **Outside the engine: the Python gateway.** `EmbeddingGateway.__init__` reads
  `index_status` and refuses to start unless `embedding_model_id` and
  `vector_dimensions` equal the Python index's embedding metadata
  ([query-embedding gateway](../query-embedding-gateway.md), "Exact model
  identity"). The neural provider's model id is an exact conformance identity
  (runtime version, model family, a hash of fixed probe vectors;
  [neural provider](../neural-embedding-provider.md), "Reproducible model
  identity").
- A host calling `ss_query` directly today can pass a vector from any model of
  the right length, and it is scored.

### A8. How hybrid fusion picks candidates

`zig/src/core/hybrid.zig` `searchSparseTraced` (reached from `Engine.queryTraced`):

- **Lexical channel:** the postings source yields matched chunks; each in scope
  (`inScope`: root mask, path prefix, all required labels) with a positive score
  enters a bounded top `candidate_k` (`BoundedTop`).
- **Semantic channel:** runs only when the mode is not `lexical` and the query
  vector is non-empty. It is an **exact scan** of every in-scope document:
  `semanticScore` is the cosine (`scoring.cosineSimilarity`), or 0 when the
  document has no vector; a score that is not positive is dropped; the rest
  enter a bounded top `candidate_k`.
- **Fusion:** the union of both candidate lists, reciprocal rank fusion with
  `rrf_k = 60` (`scoring.reciprocalRankContribution`), ties broken by document
  index (`fusedBefore`), then `top_k`.
- The dense path `searchWithLexicalScores` is kept as the reference; a test
  (`"sparse ranking equals the dense reference on random tie-heavy inputs"`)
  holds them equal, including documents with no vector.

*Confirmed by running:* on the A3 snapshot, a hybrid query with `[1,0]` returns
the chunk without a vector (it matched lexically) with `"vector":{"rank":null,"score":0}`,
and nothing in the response says that one of the three chunks had no vector.

### A9. What S2-T13 enforces on values

`scoring.isValidVector`: every component finite and the `f32` sum of squares
finite (a norm below about 1.8e19); all zeros is valid. Enforced on query vectors
at `ss_query` (`queryImpl`) and JSON-RPC (`ops.queryVector`), and on stored
vectors at import (`importer.importJsonKeeping`). Lexical mode does not read the
vector and does not check it. `scoring.cosineSimilarity` keeps the original `f32`
loop and falls back to `f64` only when a sum overflows, so scores are finite and
bit-identical for every valid vector ([S2-T13](../tasks/S2-T13.md)).

### A10. The rules that bind any change here

- **INV-03:** authorization filters both channels before ranks. Today the
  semantic loop skips out-of-scope documents before scoring (A8).
- **INV-04:** model identity, dimensions, normalisation and chunker identity are
  index data; re-embedding is a migration.
- **INV-05:** exact scan stays the correctness oracle if approximate search is
  added. Nothing here adds approximate search.
- **INV-06:** the base mode runs without third-party packages. The engine runs no
  model; the host does.
- **INV-07:** formats versioned, bounded, checksummed, with explicit backward
  compatibility.
- **INV-08:** deterministic order for equal scores (document index).
- **INV-09:** complexity earned by measurement.
- **The embedding boundary.** CAP-13's FR-13 and CFT-08: an MCP caller never
  supplies a vector. The gateway rejects a caller's `query_vector`. The
  specification (§4, *Search request*) puts the "internal query vector only below
  the gateway boundary". This proposal keeps that line: a **host** is below the
  boundary (it holds the write capability and the model, as the gateway does);
  a **model caller** is above it and still never sends a vector.

## B. How the host learns the chunks (the hard question)

The engine chunks (`chunker.chunkForPath`: `line-window-v1` and `md-section-v1`,
1,600 characters, 3 overlap lines) and names each chunk
`sha256(path \0 start \0 end \0 text)` cut to 20 hex digits (`chunker.chunkId`).
The host has the model. Something has to carry chunk text out and vectors back.
Three ways, then the recommendation.

The costs below use the timing 10k corpus (19,959 chunks, about 2 per file,
[index-size](../index-size.md)) and a full generation of 32,281,645 B
(recorded by S6-T3; every publish writes complete sections). "Vectors" means a
384-dimensional `f32` set at full coverage in the section proposed in §D:
30,659,519 B plus a header (computed; rows 30,657,024 B and the coverage bitmap
2,495 B). Bytes per publish with vectors: 62,941,244 B (computed, assuming the
section header of about 80 bytes proposed in §D).

### (a) Two-phase: lexical first, vectors after

1. The host calls `apply` as today. It publishes generation G: every chunk is
   indexed lexically; chunks of unchanged files keep their vectors (A4 already
   copies them); new and re-chunked chunks have none.
2. The host lists G's chunks without a vector (new read operation
   `list_unembedded`: chunk id, a SHA-256 of the text, the text, the citation;
   paged, bound to G like `list_files`).
3. The host embeds the texts with its model.
4. The host sends `{expect_generation: G, embedding: <identity>, vectors:
   [{chunk_id, vector}]}` with no file changes. The engine publishes G+1: G's
   chunks, the vectors attached.

- **Calls for a one-file update:** 3 (apply, one list page, attach) and 2
  publishes. Initial build of 10k files: 1 apply, 20 list pages of 1,000, and
  one attach (or a few, if the host attaches in batches).
- **Memory:** the writer holds the previous generation, as `apply` does today,
  plus one batch of vectors (2 chunks × 1,536 B for a one-file update; 30.7 MB
  for an initial attach of every chunk at once, computed). The host holds one
  page of texts and its model, not the engine's build.
- **Bytes written:** two full generations per embedding round: 125,882,488 B
  for a one-file update with 384-d `f32` vectors, against 32,281,645 B today
  (computed). After the D2 steps the same is 89,889,900 B (computed from the
  D2-4 projection, 14,285,351 B). A host that attaches once after a burst of
  edits pays phase 2 once per burst.
- **One-file update:** the file's old chunks drop out, its new chunks are
  listed, the host embeds about 2 texts. Chunks of other files carry their
  vectors untouched.
- **Chunker change:** `apply` re-chunks a file whose recorded chunker differs
  (`applyParsed`: a file is carried only when its hash *and* chunker id match),
  so its chunks come back without vectors and appear in the list. The host needs
  no chunker knowledge; it heals by itself.
- **Model change:** the attach names another identity than G's; refused (§C).
- **Partial coverage:** normal between the phases, and legal (A1). A hybrid
  query ranks the semantic channel over the chunks that have vectors; the others
  can still match lexically. Proposed: the response says how many in-scope chunks
  had a vector (FR-30), counted over the visible scope only.
- **Crash between phases:** G is a complete, valid, published generation with
  lower coverage. Nothing to repair. On restart the host lists again and
  attaches. If the attach was published but the host did not learn of it, its
  retry fails `stale: generation is G+1` (the existing `expect_generation`
  check), and the list comes back empty.
- **Lexical freshness:** never waits for the model.

### (b) A callback or pull interface during `apply`

The engine calls the host back (`embed(texts) -> vectors`) while building G,
before publishing it, and publishes one generation with vectors.

- **Calls for a one-file update:** 1 (plus one callback); 1 publish. Bytes:
  62,941,244 B (computed), half of (a).
- **Surfaces:** the C ABI can take a function pointer. JSON-RPC over HTTP
  cannot call the client back; over stdio it would need server-to-client
  requests, which `rpc.zig` does not have. In Dart a native-to-Dart callback runs
  synchronously on the isolate that made the call, while a phone's model is
  usually reached asynchronously (a platform channel): a blocking wait inside the
  callback is a deadlock risk. MCP and the CLI have no place for it.
- **Memory:** the engine's whole build and the host's model are alive in the
  same process at the same time (on a phone, the expensive moment).
- **Writer lock:** held for the whole embedding time (seconds to minutes for an
  initial build), so every other writer waits on the model.
- **Failure:** an error or a hang inside the callback fails or stalls the
  apply; nothing is published, the lexical update is lost with it. A crash loses
  every vector computed so far unless the host caches them.
- **Chunker and model change:** as (a), since the engine still chunks.
- **Partial coverage:** none by design, unless the callback may decline, which
  brings back (a)'s reporting.

### (c) The host chunks with a published chunker identity

The host reproduces the engine's chunker, computes chunk ids itself, embeds, and
sends `vectors` keyed by chunk id inside the same `apply`. One publish.

- **Calls:** 1; 1 publish; bytes as (b).
- **One-file update:** the host chunks the changed file itself, embeds its
  chunks (about 2) and sends their vectors with the change; the lexical update
  waits for the model.
- **Memory:** the engine holds the previous generation and the request's
  vectors, as (b) without the callback; the host holds the file's chunks and its
  model, outside the engine's build.
- **What the host must carry:** a byte-exact port of `line-window-v1` and
  `md-section-v1` (CRLF, byte order marks, Setext headings, front matter, the
  1,600-character windows and 3-line overlap) in Dart, Swift, Kotlin or whatever
  the host is written in, kept in lockstep with every engine release. Chunk
  goldens exist (`fixtures/chunk-golden.json`, `fixtures/chunk-golden-md.json`)
  but only the Python reference is held to them.
- **Chunker change:** an engine upgrade with a new chunker silently invalidates
  every key a stale host computes. Keyed by id the failure is safe (no vector
  lands on the wrong chunk) but coverage drops to zero for changed files until
  the host ships a new port. This is the same gap that keeps CFT-09 blocked
  (chunker identity does not travel through the interface).
- **Model change:** as (a): vectors under another identity are refused (§C).
- **A variant, (c′):** the engine exposes its chunker as a pure call (bytes in,
  chunk ids and texts out) so the host does not port it, then sends vectors in
  the same `apply`. No lockstep problem, one publish, but the host chunks every
  changed file twice and the lexical update waits for the model.
- **Crash:** atomic; embedding work lost unless cached.
- **Partial coverage:** a chunk with no matching key has no vector; same report
  as (a).

### Recommendation: (a), two-phase

1. It works on every surface with the request and response shapes they already
   have: C ABI, JSON-RPC (stdio and HTTP), Dart, the CLI. (b) does not.
2. The host never reimplements the chunker, and a chunker change heals itself.
   (c) puts a byte-exact port in every host.
3. Lexical search never waits for the model, and a crash at any point leaves a
   valid index whose only defect is lower coverage, reported.
4. A phone can attach when it is idle or charging; coverage tells the app how far
   it got.
5. Unchanged chunks keep their vectors with no host work, because `apply`
   already carries the records.

Its cost is the second generation write per embedding round, double what (b) or
(c) write. Three things bound it: the host batches attaches; D2-5 makes two
generations the default to keep (03-next), so disk holds two generations, not
an ever-growing chain; and the delta sections already filed in 03-next remove
the full rewrite for both phases. The build task measures the write cost
([§F](#f-what-is-measured-before-it-is-called-done)). (c′) can be added later
without a format change, because the attach request and the stored vectors are
the same; it should be added only if that measurement says the second write is
the binding cost (INV-09).

**Keying.** The wire key is the chunk id the list returned, exact within a
generation. Inside the writer, a re-chunked file's new chunk whose text is byte
for byte the text of one of that file's (or its move source's) previous chunks
keeps that chunk's vector, so an edit to one section of a Markdown file does not
send the other sections back to the host. The list carries a SHA-256 of each text
so a host can deduplicate equal texts across files before embedding.

## C. Model identity

**What is bound.** One embedding identity per generation:

```json
{"model_id": "example-embedder-384-v1", "dimensions": 384,
 "normalization": "l2", "element": "f32", "identity_version": 1}
```

- `model_id`: the host's exact identity for the model *and* its runtime, in the
  spirit of the neural provider's conformance id (A7). The engine compares it as
  bytes; it does not parse it.
- `dimensions`: as today.
- `normalization`: `"l2"` or `"none"`. With `"l2"`, the engine refuses a stored
  or query vector whose norm is off 1 by more than 1e-3 (a likely wrong
  pipeline). Scoring stays the cosine of A8, bit for bit, either way.
- `element`: `"f32"` in this version (§D).
- `identity_version`: the version of this identity record's shape.

**Where it is stored.** `model_id` stays in the manifest's existing
`embedding_model_id` and the dimensions in `vector_dimensions`. The whole
identity is written in the vector section's header and, as a canonical JSON
string, in the manifest's payload, so `index_status` can report it without
reading vectors. The manifest marks the binding with a new flag, so a reader that
does not know it refuses the index (A2) instead of answering with the identity
unchecked. Putting the identity in `meta` instead would be ignored by an older
reader and is not proposed.

**What the engine refuses.**

- A query vector whose request names another `model_id`, or another length, or
  (with `"l2"`) another norm: `EmbeddingIdentityMismatch` (`ss_query`: `NULL`
  with the message; JSON-RPC: `-32602`). On an index whose identity was bound by
  this capability the request **must** name the identity; on an imported index
  it may, and is checked when it does.
- An attach whose identity differs from the generation's: the whole request is
  refused, nothing published. Mixed identities in one generation therefore cannot
  exist: one identity per generation, every vector written under it.
- An attach to a generation with no vectors yet sets the identity.

**A model change without a window of wrong answers.** "Wrong" means a query
vector of model A scored against document vectors of model B. The identity check
on every query makes that impossible in every case. Two ways to change model:

1. *Recommended:* a migration into a separate index directory: `apply` the same
   roots into a new directory, attach
   vectors from model B until coverage is complete, then the host closes the old
   handle, opens the new one and switches its query embedder in the same step.
   The old index answers with model A throughout; there is no window, only the
   disk of two indexes for the duration.
2. *In place:* an attach with `replace_identity: true` publishes a generation
   with model B's identity and no vectors but the attached ones. From that
   generation on, model A's query vectors are refused, and hybrid queries with
   model B's vectors rank over partial coverage until the host finishes. No wrong
   answers, but a window of reduced semantic recall. Proposed as an open question
   (O-7), not for the first build.

## D. Format and size

**Does the existing vector field serve?** For correctness of `f32` vectors with
partial coverage, yes (A1). It does not serve this capability well:

- it has nowhere for the identity beyond a free-form model string (A2);
- an open holds every vector twice and for every query, lexical included (A5);
- it is inside the documents section, whose record coding D2-2 is about to change
  ([index-size](../index-size.md), step 2), so vectors would tie E to D2;
- it has no element type, so `int8` would need a records version anyway.

**Proposed: a separate vector section**, `vectors-N.hybvec`, magic `HYBVEC01`,
version 1, bound by manifest v2.3 (flag bit 32, header length and checksum as
the state section's are bound, payload file name and the canonical identity
string). Its header (about 80 bytes): version, checksum kind, row count (the
generation's document count), dimensions, element type, normalisation, covered
count, a SHA-256 of the canonical identity, payload length, checksum. Its payload:
a coverage bitmap (one bit per chunk, in document order) then the covered rows,
packed, 4-byte aligned. Folder writers keep writing `vector_length = 0` in the
records. Readers:

- an open does not read the section; the first query that has a query vector
  loads it into one aligned block (as the source and file-name sections load at
  first use, `scope.Loads`), and the rows become the documents' vectors, so
  `hybrid.zig` is unchanged;
- lexical operations never load it, so NFR-13's measured peaks for them do not
  move;
- a generation with both inline record vectors and a vector section is refused.
- Imported snapshots keep their inline vectors and v1 manifests, unchanged.
  `apply` over an imported snapshot with vectors refuses up front with a named
  error and a migration note, instead of today's accidental
  `VectorDimensionMismatch` (A4).

**Bytes per chunk.** `f32`: 4 × dimensions. `int8` (symmetric, one `f32` scale
per row, *not proposed for version 1*): dimensions + 4.

| Element, dimensions | Bytes per chunk |
| --- | ---: |
| `f32`, 384 | 1,536 |
| `f32`, 768 | 3,072 |
| `int8`, 384 | 388 |
| `int8`, 768 | 772 |

**On the three 10k corpora,** full coverage, rows only (computed from the chunk
counts S6-T3 recorded: timing 19,959, prose 18,766, Tamil 19,946; the bitmap adds
2,346–2,495 B; "× corpus" is against each corpus's bytes, "% of today" against
its whole index with the file-name channel, "% of D2" against the D2-4
projection):

| Corpus | `f32` 384 | `f32` 768 | `int8` 384 | `int8` 768 |
| --- | ---: | ---: | ---: | ---: |
| timing 10k | 30,657,024 B (4.22 × corpus; 95 % of today; 215 % of D2) | 61,314,048 B (8.43 ×) | 7,744,092 B (1.07 ×; 24 %; 54 %) | 15,408,348 B (2.12 ×) |
| prose 10k | 28,824,576 B (1.67 ×; 41 %; 92 %) | 57,649,152 B (3.34 ×) | 7,281,208 B (0.42 ×; 10 %; 23 %) | 14,487,352 B (0.84 ×) |
| Tamil 10k | 30,637,056 B (1.11 ×; 41 %; 87 %) | 61,274,112 B (2.21 ×) | 7,739,048 B (0.28 ×; 10 %; 22 %) | 15,398,312 B (0.56 ×) |

Index ÷ corpus with vectors added (computed): timing 10k today 4.44 → 8.66 with
`f32` 384, 5.51 with `int8` 384; after D2 1.97 → 6.18 and 3.03. Prose 10k today
4.05 → 5.72 and 4.47; after D2 1.82 → 3.49 and 2.24. Tamil 10k today 2.66 →
3.77 and 2.94; after D2 1.27 → 2.38 and 1.55.

**How this sits with D2.** Vectors at 384 dimensions in `f32` are about as large
as everything D2 is working to remove, and more than the whole D2 index on the
timing corpus. D2's ratios describe a lexical index; a semantic index should be
reported separately (index ÷ corpus with and without the vector section) so D2's
targets stay meaningful. A separate section keeps the two independent: D2 can
change the records without touching vectors, and E can ship before, between or
after D2's steps.

**Memory, computed against the recorded open.** S4-T9 recorded the 10k open at
33,567,893 B (on a corpus of the timing corpus's shape, not its bytes; assumed
here to have about the timing corpus's 19,959 chunks). NFR-13's cap is
67,108,864 B. The figures add the vector rows only (the section's bitmap and
header, about 2.6 KB, are left out).

| Vectors | Inline today (two copies in the open) | Proposed section, loaded once at the first vector query |
| --- | ---: | ---: |
| `f32` 384 | 94,881,941 B, over the cap | 64,224,917 B, 2.9 MB under the cap before the query's own work |
| `f32` 768 | 156,195,989 B | 94,881,941 B, over the cap |
| `int8` 384 | 49,056,077 B | 41,311,985 B |
| `int8` 768 | 64,384,589 B | 48,976,241 B |

So on a phone at 10,000 files, `f32` at 384 dimensions sits at the cap and 768
does not fit. That is a computed case for `int8` (or a smaller model, or a file
limit) on phones, but the roadmap's rule stands: quantise only when memory is the
binding constraint and the recall loss is measured acceptable. Version 1 is `f32`
with the element field in place; `int8` is a second element type decided by the
build task's measurements (O-4).

**On the wire,** JSON text costs about 11 bytes per component against 4 in binary
(an assumption: a shortest round-trip `f32` and a comma): an initial attach of
19,959 chunks at 384 dimensions is about 84 MB of JSON against 30.7 MB of floats
(computed). Hence a binary C ABI call (§E).

## E. Surfaces (proposals)

| Interface | Proposed | Kind |
| --- | --- | --- |
| JSON-RPC `apply_changes` (with `--allow-write`) | Optional `embedding` (identity) and `vectors` (`[{chunk_id, vector}]`) in the request; `changes` may be empty when `vectors` is given; optional `replace_identity` only if O-7 is accepted. Result gains `vectors_attached`, `vectors_unmatched`, `vector_coverage`. | Additive; contracts minor (2.8.0) |
| JSON-RPC `list_unembedded` (with `--allow-write`) | New method: `{page_size?, cursor?, roots?}` → `{generation, chunks: [{chunk_id, root_id, path, start_line, end_line, text_sha256, text}], next_cursor}`; through the caller's scope, like `read_chunk`. | New method; contracts minor |
| C ABI | `ss_list_unembedded(handle, request_json)` returning the same JSON; `ss_apply_vectors(dir_path, request_json, const float *rows, size_t row_count, size_t dims)` with the identity, `expect_generation` and `row_count` chunk ids in `request_json`, rows as binary. `ss_apply_changes` unchanged. | New functions; header additions |
| Query vector, `ss_query` | `options_json` gains `embedding_model_id`; required on an index bound by this capability, checked when present on an imported one. | Additive |
| Query vector, JSON-RPC `search_knowledge` | `embedding_model_id` beside the existing `query_vector`, same rule. | Additive |
| MCP | No vector, ever (CAP-13). `apply_changes` over MCP does not take `vectors`; `list_unembedded` is not an MCP tool. On an index with vectors, `search_knowledge` in its default mode answers lexically with a warning (FR-30) instead of today's refusal (A6). | Behaviour change on an error path; contracts minor |
| Query response | `ss_query` warnings gain `query_vector_missing` (hybrid with no vector on an index with vectors) and `vectors_partial` (`covered`, `in_scope`, visible scope only). `index_status` gains `embedding` (the identity) and `vector_coverage`. JSON-RPC `search_knowledge` carries no warnings today and gains none. | Additive |
| CLI | `searchd list-unembedded <dir> [--page-size N] [--cursor C] [--json]`; `searchd apply <dir> --vectors <file>` (a JSON file with the identity and `{chunk_id, vector}` lines). `query`, `evidence` and the direct `search` stay lexical only: the CLI runs no model and `search` has no host and writes nothing. | New command and flag |
| Dart | `SearchSimpli.listUnembedded(...)`, `SearchSimpli.applyVectors(dirPath, identity, chunkIds, Float32List rows, {expectGeneration})`, `query(..., embeddingModelId:)`, and the new status and warning fields. | Additive; Dart minor |
| Interchange (CON-03), `import-json` | Unchanged. | — |
| Index format | Manifest v2.3 (flag 32, vector binding); vector section `HYBVEC01` v1. Older readers refuse a v2.3 manifest that sets the flag (`UnsupportedFlags`); indexes without vectors are written exactly as today. | Format minor, versioned |

Which need a contracts minor version: all JSON additions above, together, as one
2.8.0. Nothing removes or renames a field. The one behaviour that changes on an
existing request is FR-30's: a default-mode request with no vector against an
index with vectors used to be refused and would answer lexically with a warning.
Today no `searchd`-built index has vectors, so only imported snapshots see that
change.

## F. What is measured before it is called done

*Added by the S6-T6 verifier: the links above pointed at this section, which the
draft did not have. It gathers what §B, §D and §9 already state.*

- **What J2 has and lacks.** J2 (`fixtures/j2`, 290 judged queries over three
  roots) measures where keyword search loses to spelling and word form: control,
  misspelling, morphology, accent, Tamil, title, phrase and verb-form slices, a
  precision-control slice and named negatives ([J2's README](../../fixtures/j2/README.md)).
  It has **no** paraphrase or vocabulary-mismatch slice, and `scripts/j2_run.py`
  asks `search_knowledge` for `lexical` only, so nothing in it can show a vector
  helping. The only semantic evidence is the 20-query mixed diagnostic
  ([evaluation](../evaluation.md)), which is diagnostic, not a gate. Needed: the
  semantic slice of §9 step 0, and a hybrid run of J2's existing slices to show
  that control and negatives do not move.
- **Read cost:** hybrid query p50 and p95 at 10,000 files, 384 and 768
  dimensions, against lexical on the same index (§9). Nothing here is timed.
- **Write cost:** phase 1 and phase 2 time and bytes of a one-file update at 10k,
  and an initial attach of every chunk (§B computes the bytes, not the time).
- **Memory:** the open and the first vector query's peak at 10k and 15k files
  under the NFR-13 allocator (§D computes the rows only).
- **The bars a build task carries:** §9 (relevance threshold `pending`, set from
  the tuning half; control success@1 stays 1.000; negatives within a `pending`
  tolerance; lexical outputs byte-identical; identity refusals with plants; the
  crash hook; hidden-versus-absent parity).
- **Out of scope:** the dependency-free native provider (the PPMI baseline in the
  engine), a later question (O-10).

## 3. Functional requirements (new or changed)

| ID | Requirement (testable) | New / changes | Traces to |
|---|---|---|---|
| FR-27 | A writer-capable host attaches vectors to the current generation's chunks by chunk id under one embedding identity, publishing exactly one new generation atomically (`expect_generation` checked); an attach naming another identity, an unknown chunk id, a wrong length or an invalid vector (S2-T13 rule; norm within 1e-3 of 1 when `l2`) refuses the whole request and publishes nothing; `apply` carries the vectors of unchanged chunks and of re-chunked chunks whose text is unchanged, drops the rest, and writes the generation's identity instead of `"none"`; `apply` over an imported snapshot with vectors is refused with a named error. | new | UC-001, UC-007 |
| FR-28 | `list_unembedded` returns, page by page and bound to one generation, every chunk of the caller's scope that has no vector (chunk id, root, path, lines, text SHA-256, text); it exists only for a writer-capable caller and never lists a chunk outside the caller's roots and labels. | new | UC-001, UC-007 |
| FR-29 | Each generation binds at most one embedding identity (model id, dimensions, normalisation, element type, identity version) in its vector section and manifest; a query vector is scored only when its request names that model id and its length (and, for `l2`, norm) match; mismatches are refused; a model change is a migration into a separate index directory. | new (makes FR-04's identity rule enforceable in the engine) | UC-001, UC-002 |
| FR-30 | On an index with vectors, a `hybrid` request with no query vector answers lexically and reports `query_vector_missing`; a `vector` request with none is still refused; a request with a vector reports how many in-scope chunks had one (`vectors_partial`), counted over the visible scope only. | new (changes today's refusal, A6) | UC-001, UC-002 |

## 4. Non-functional impact

| ID | Requirement / impact | Target or constraint |
|---|---|---|
| NFR-16 | Vectors live in their own versioned, checksummed section, loaded only by a query that carries a query vector; an index without vectors is written byte for byte as today; lexical operations' memory and answers do not change when a vector section is present; the vector section's bytes, load memory and query and attach cost are stated by measurement before the capability moves past Proposed. | Lexical outputs byte-identical with and without the section (capture and J2); NFR-13 lexical peaks unchanged; vector costs recorded, thresholds `pending` (§9) |
| NFR-13 | Under pressure: 384-d `f32` vectors at 10k files are computed at about the 64 MiB cap once loaded (§D). | Lexical operations unchanged by NFR-16; the vector query's own bound is a build-task decision (O-4) |
| NFR-12 | Under pressure: two-phase doubles the writes of an embedding round, and vectors enlarge every generation. | Unchanged for `apply` without vectors; the attach's cost measured (§F) |
| NFR-01 / INV-06 | No dependency: the engine runs no model. | Zig standard library only |

## 5. Contracts touched (CON)

- New or changed schemas under `contracts/`: `contracts/tools/apply_changes.request.schema.json`
  and `.result` (CON-02 family, additive fields); a new
  `contracts/tools/list_unembedded.request.schema.json` and `.result`;
  `search_knowledge` request (`embedding_model_id`) and result, `index_status`
  result (`embedding`, `vector_coverage`); CON-01 (`contracts/search-tool.schema.json`)
  gains the two warning kinds. CON-03 (interchange) and CON-04 (embedding
  provider) unchanged; the identity object of §C uses CON-04's metadata names
  where they overlap (`model_id`, `dimensions`, `normalization`).
- Backward-compatibility plan: contracts 2.7.0 → 2.8.0, additive; header and Dart
  additive; manifest v2.3 refused by older readers only when the vector flag is
  set; indexes without vectors unchanged; imported snapshots read as today.

## 6. Invariant compliance (INV)

- INV-01 retrieval≠generation: complies. Vectors are a ranking feature; the
  evidence envelope is unchanged.
- INV-02 stable identity and citation: complies. Chunk ids and citations are the
  writer's, unchanged; vectors attach to them.
- INV-03 pre-rank authorization: complies by design. The semantic channel keeps
  skipping out-of-scope chunks before scoring (A8); `list_unembedded` and the
  coverage counts go through the caller's scope; tests must show hidden and
  absent chunks are indistinguishable in both.
- INV-04 identity as index data: this capability is what makes it true for
  `searchd`-built indexes (FR-29); re-embedding is a migration (§C).
- INV-05 exact scan: unchanged; no approximate search is added.
- INV-06 dependency-free base: complies; no model in the engine.
- INV-07 versioned/checksummed formats: a new versioned, checksummed section and
  a manifest minor version with an explicit refusal by older readers (§D).
- INV-08 deterministic ordering: unchanged (document index breaks ties).
- INV-09 complexity earned by measurement: **not yet met**. The 20-query mixed
  diagnostic (neural vector success@1 0.90 against BM25 0.60, with an equal-RRF
  regression, [evaluation](../evaluation.md)) is diagnostic, and J2 has no
  semantic slice. CFT-24 keeps this blocked until §F's step 0 is measured.
- INV-10 tests execute; docs distinguish implemented/observed/hypothesis/future:
  this document marks what was confirmed by running and what is computed.
- INV-11: N/A.

## 7. Register updates (fill when consolidating — step 4)

- Capability catalog row (CAP-21): added, `Proposed`.
- FR/NFR index rows added: FR-27, FR-28, FR-29, FR-30, NFR-16 (and their rows in
  the specification's proposed-requirements appendix).
- Contracts rows added: none (the schemas above extend CON-01, CON-02 and their
  tool schemas; no new CON id).

## 8. Conflict check (step 5 — required)

| CFT | Between | Tension | Resolution | Status |
|---|---|---|---|---|
| CFT-24 | CAP-21 ↔ INV-09 | A new section, two operations and an identity check are added before any judged evidence that host-supplied vectors improve ranking on this engine; the only evidence is a 20-query diagnostic that also showed a fusion regression. | Blocked until §F step 0: a J2 semantic slice, measured through the existing import path, shows hybrid beating lexical on its held-out half without a control rank-1 loss. Rollback is free: an index without the vector flag is today's index. | Blocked |
| CFT-25 | CAP-21 ↔ CAP-13 / FR-13 | MCP never takes a vector, so on an index with vectors MCP's default search is refused today (A6); vectors would make that the normal case. | MCP stays text-only; FR-30 makes a vector-less hybrid request answer lexically with a warning. Semantic search over MCP needs a gateway that embeds, outside the engine. | Resolved (design) |
| CFT-26 | CAP-21 ↔ INV-04 | Host-supplied vectors could be scored against query vectors of another model, since the engine checks only dimensions today (A7). | One identity per generation, bound in the section and manifest, named by every query vector and every attach, refused on mismatch; model change by migration (FR-29, §C). | Resolved (design) |
| CFT-27 | CAP-21 ↔ NFR-13 | 384-d `f32` vectors at 10k files are computed at the 64 MiB cap once loaded; 768-d over it (§D). | Scope: the section is loaded only by vector queries, so lexical operations keep NFR-13 as measured; the vector query's bound and `int8` are decided on the build task's measurements (O-4). | Resolved (scope) |
| CFT-28 | CAP-21 ↔ NFR-12 / CAP-19 FR-20 | Two-phase writes two full generations per embedding round, and vectors enlarge each one (§B). | Scope: `apply` without vectors is unchanged; the attach's write cost is measured and stated; batching, D2-5 and delta sections bound it. | Resolved (scope) |

## 8b. Dependencies

- Capabilities and datasets this one depends on: CAP-03 (semantic retrieval),
  CAP-04 (hybrid fusion), CAP-10 (durable snapshots), CAP-19 FR-20 (host-fed
  changes and atomic publication), CAP-11 (the J2 fixture), CAP-13 (the MCP
  boundary).
- Is any acceptance criterion dependent on an unbuilt capability or dataset? Yes:
  the J2 **semantic slice** does not exist. Every relevance criterion below is
  `pending` until it does, and the capability is **not build-ready**.
- Related, not a dependency: D2 (index size) and delta sections; D2-5 (two
  generations kept by default) should land first, because two-phase doubles the
  generations an update leaves.

## 9. Acceptance gate (step 6 — decidable before building)

- **Step 0, before any build (INV-09):** author a J2 semantic slice (paraphrase
  and vocabulary-mismatch questions; a tuning half and a held-out half; the
  generator asserts that no content word of a question occurs in its graded
  answer, as J2's checks keep every other miss real) and run it through the path
  that works today: the Python reference exports J2 with vectors from one pinned
  384-d model, `searchd import-json` imports it, `serve` answers hybrid with that
  model's query vectors. Metric: success@1 and MRR@10 per slice, hybrid against
  lexical on the same snapshot. Decision rule: the held-out semantic slice
  improves by at least a threshold (`pending`: set by the maintainer from the
  tuning half), control success@1 stays 1.000, and the negatives' misleading-first
  rate does not rise beyond a tolerance (`pending`); otherwise CAP-21 is not
  built and fusion (board F-01) comes first.
- **Primary metric after the build:** the same slice through `apply`,
  `list_unembedded` and an attach equals step 0's per-query metrics, every
  difference explained by a chunk boundary (the folder path chunks in Zig, the
  import path in Python).
- **Lexical unchanged:** `scripts/capture_query_outputs.py` and the J2 gate
  byte-identical on indexes without vectors; lexical-mode outputs on an index
  with vectors byte-identical to the same index without them; tolerance zero.
- **Identity:** refusal tests for a wrong model id, length and (with `l2`)
  norm, at `ss_query`, JSON-RPC and the attach; an attach with a second identity
  publishes nothing; plants (each check removed) fail their tests.
- **Coverage and crash:** a test hook fails between the two phases; generation G
  answers hybrid with `vectors_partial`; listing and attaching after it complete
  coverage; a repeated attach is refused as stale.
- **Unanswerable / negative behaviour:** J2's negative sets in hybrid mode,
  reported beside lexical (threshold `pending`, step 0).
- **Citation-support behaviour:** unchanged envelope.
- **Freshness:** after phase 1 every changed file is searchable lexically; after
  phase 2 semantically.
- **Performance / scale (recorded, thresholds `pending`):** hybrid query p50 and
  p95 at 10,000 files (about 20,000 chunks) at 384 and 768 dimensions, `ReleaseSmall`,
  five runs, against lexical on the same index; the open and the first vector
  query's peak at 10k and 15k files under the NFR-13 allocator; one-file update
  phase 1 and phase 2 time and bytes written at 10k; an initial attach of every
  chunk.
- **Security / isolation tests:** `list_unembedded` and the coverage counts with
  roots and labels: a hidden chunk and an absent chunk give the same answer.
- **Judged fixture / benchmark artifact:** `fixtures/j2` plus the semantic slice;
  `scripts/j2_run.py`, `scripts/j2_gate.py`; the 10k timing, prose and Tamil
  corpora of S6-T3.
- **`pending` criteria:** every relevance threshold (prerequisite: the semantic
  slice and step 0's run), the latency and memory bounds for vector queries
  (prerequisite: the build task's measurements and O-4).

## 10. Evidence plan (step 8)

- Tests to add: segment and manifest round trips and refusals for the vector
  section; attach, list and carry in `apply_test.zig`; identity refusals at the
  C ABI (`zig/tests/abi_test.c`), JSON-RPC and Dart; FR-30's warning; the crash
  hook; hidden-versus-absent parity; NFR-13 lexical peaks with a vector section
  present.
- `EXPERIMENTS.md` entry planned: step 0 (hypothesis: host vectors from one small
  model improve paraphrase questions without hurting the control slice; setup,
  observation, limits).
- `PROJECT-STATE.md` update: when built.
- How status advances: Proposed → Diagnostic (built, measured on J2 and the
  generated corpora) → Validated only on a representative user-derived judged set
  (roadmap Phase 1's exit check).

## 11. Open decisions

Each with the recommendation drafted in S6-T6 (the orchestrator and the
maintainer may change it).

| # | Decision | Recommended |
| --- | --- | --- |
| O-1 | How the host learns the chunks: (a), (b) or (c). | (a) two-phase (§B). |
| O-2 | Wire key for vectors. | Chunk id; inside the writer, reuse by exact text within a re-chunked file; the list carries a text SHA-256 for host-side de-duplication. |
| O-3 | Vectors inline in the records or in a separate section. | Separate `HYBVEC01` section, manifest v2.3 flag, loaded at the first vector query (§D). |
| O-4 | `int8` in version 1? | No: `f32` with the element field; `int8` as element type 2 only after the build task measures memory at 10k/15k and the recall loss on the semantic slice. Until then a phone host uses a 384-d model. |
| O-5 | A `hybrid` request with no vector on an index with vectors: refuse (today) or answer lexically with a warning. | Answer lexically with `query_vector_missing`; `vector` mode still refuses (FR-30). Without it, MCP's default search breaks on every index with vectors. |
| O-6 | Must a query vector name the model id? | Yes on indexes bound by this capability; optional and checked on imported ones, so existing callers keep working. |
| O-7 | Model change in place (`replace_identity`) or only by a new directory. | New directory only in the first build; in place later if a host needs it. |
| O-8 | Vectors over JSON-RPC as JSON arrays. | Yes (simple, host-side only); binary rows on the C ABI and Dart. |
| O-9 | Order against D2. | Independent of D2's format steps (separate section); after D2-5 (two generations kept by default). |
| O-10 | The dependency-free native provider (the PPMI baseline in the engine). | Out of scope here; a later question, asked only after the host-supplied path is measured on the judged set (plan item E). |

- Owner: the maintainer.
- Evidence needed: §9 step 0 for O-1 to O-6 being worth building at all; the
  build task's measurements for O-4.

## 12. Maintainer approval (step 6b — required before build)

- Approver: none. Drafted by S6-T6's builder; an agent may not approve its own
  draft.
- Date: —
- Commit: —
- Status: Pending approval
