# CAP-19 — Folder knowledge: exact finding, document structure, several roots, host-fed changes, one tool surface for models, apps and MCP

Status: Diagnostic · implemented (S3-T1 to S3-T7 verified 2026-10-31, S3-T8 hand-off; approved for build 2026-10-31 by the owner). Evidence below; NFR-13 stays Proposed.

> Run through the [capability process](../capability-process.md), steps 1–6.
> Review amendments recorded; acceptance evidence and approval pending; implementation is a later step
> ([plan](../plans/folder-knowledge-plan.md)).

## 1. Proposal

- **Problem / what should be possible:** A person points the engine at whole
  folders they already keep (iCloud Drive, a phone, a laptop) and gets three
  things from one index: (a) a traditional search box — words, exact phrases,
  prefixes, the part of a document that says something, with highlighted
  snippets; (b) ranked, cited passages a language model can answer from
  accurately, with document structure in the citation (`file › Heading ›
  Subheading · lines`); (c) the same operations as tools a model app can call,
  as a skill it can read, and as an MCP server a desktop agent can plug in.
  Today the engine ranks line-window chunks over one root with BM25 and cites
  lines; it has no positions (so no phrase matching or positional highlighting), no document
  structure, one root per index, no way to take files from a host that cannot
  give it paths, and no MCP server.
- **Who it serves:** families and individuals with folders of notes (UC-001,
  UC-007); model apps that must answer from those folders without guessing;
  plain apps that need a search box; MCP agents (UC-004).
- **HIO tie:** use-side, organic — the engine's own output becomes the whole
  retrieval partnership: find, read, cite; the model only writes.
- **One-line success notion:** on a fixture family folder, the ten questions of
  UC-007 are answered with exact phrase hits, section-path citations and
  byte-exact spans, through the direct API, the tool schemas and MCP alike,
  with semantically equal canonical result payloads.

## 2. Motivating use case(s)

- Primary: [`UC-007`](../use-cases/uc-007-family-folders-on-a-phone.md)
- Also serves: UC-001 (personal files), UC-004 (MCP external agent), UC-002
  (codebase agent: prefix and phrase help code too)

## 3. Functional requirements (new or changed)

| ID | Requirement (testable) | New / changes | Traces to |
|---|---|---|---|
| FR-17 | **Positional postings.** The lexical segment stores, per term per chunk, the ordered token ordinals plus start/end codepoint offsets into original chunk text. Queries gain three modes: `words` (all analyzed query terms required, then BM25 order; existing `search_knowledge` behavior unchanged), `phrase` (all terms adjacent in order, after the analyzer; a filter, then BM25 order), `prefix` (earlier query terms required literally; final term expands against visible vocabulary only, bounded to 1,000 expansions, else `CAPACITY`). Results carry `match_offsets: [[start,end],…]` as zero-based half-open Unicode codepoint ranges into `content`; snippets carry their start offset in content and a `snippet` (≤ 240 codepoints around the best window) built by the engine. | New | UC-007 q1–q3, q10 |
| FR-18 | **Markdown structure.** A chunker `md-section-v1`: front matter (`---` … `---` at the top) is parsed into string metadata and excluded from the body; ATX (`#`) and Setext headings open sections; a chunk never crosses a heading; inside a section `line-window-v1` applies; a fenced code block is kept in one chunk when it fits `max_chars`. Each chunk records `section_path: [h1, h2, …]` and `heading_line`. Files that are not Markdown keep `line-window-v1`. The chunker id and parameters are recorded per file and validated through interchange, manifest and status (closes the CFT-09 prerequisite named in CAP-15) and a chunk's citation gains `section_path`. `outline(path)` returns the headings with their line ranges. | New; manifest v2 | UC-007 q4, q6, q7, q9 |
| FR-19 | **Several roots.** An index holds N roots `{root_id, label, kind: local \| icloud \| host, required_labels}`. A chunk's path is `root_id/relative/path`. Each root can be added, re-indexed or removed without touching another root's chunks; removing a root removes its terms, its statistics and its state. Root requirements add to existing document required labels. Trusted principal labels filter before ranking and gate every read/list/status/resource; requested roots and paths only narrow authorization. Native pre-rank label filtering already exists; visible-scope statistics remain new work. | New; INDEX-STATE v2 | UC-007 q13, folder life |
| FR-20 | **Host-fed changes.** `apply_changes(changes_json)` takes `[{op: add \| change \| remove \| move \| pending, root_id, path, size, mtime, sha256?, bytes? \| file?, moved_from?}]`. With `bytes` the engine never opens a path (phones); with `file` it reads the path (desktop). `pending` records a file by name only (not yet downloaded) and `index_status` counts it; a later `add` replaces it. `move` keeps the chunk text and section data and re-keys the ids. The report keeps today's fields and adds `pending`, `moved`. Mutation schema details and atomic recovery rules are blocking acceptance items below. A whole-folder `index_folder` remains for desktop roots and is expressed as a sequence of changes internally. | New | UC-007 q11, q12; corpus |
| FR-21 | **Rename detection.** When one change batch removes a path and adds a path whose `sha256` equals the removed file's, the engine records a `move` (chunk ids re-keyed, no re-chunk) and reports it as `moved`, not as `removed + added`. Two live files with equal content are both indexed (no de-duplication by content). | New | UC-007 q12 |
| FR-22 | **Traditional operations.** `find(query, mode, roots?, path_prefix?, page, page_size ≤ 100)` → hits as in FR-17 plus per-file counts `{path, hits}`; `outline(path)`; `read_span(path, start_line, end_line, context_lines ≤ 20)` → exact lines, byte-exact with retained original source text, including line endings; inclusive 1-based ranges, bounded to 400 total lines including context and an explicit response byte cap; `list_files(root_id?, path_prefix?, kind?, page)`. All four are available over the C ABI, the Dart binding, the CLI and the RPC server. | New | UC-007 q1–q5 |
| FR-23 | **One tool surface.** The tool contracts gain `find`, `outline`, `read_span`, `list_files`, `apply_changes` (write; off by default) beside `search_knowledge`, `read_chunk`, `list_sources`, `index_status`; each has a JSON Schema in `contracts/tools/<name>.schema.json` (request and result) that adapters wrap into provider-specific tool descriptors; request and result schemas stay distinct. `evidence` adds `neighbours: {prev, next}` (the adjacent chunks of the same file) and `section_path`. A skill document `skills/folder-knowledge/SKILL.md` tells a model app when to use which tool and how to cite. | Changes FR-07; new | UC-007 flow |
| FR-24 | **MCP server.** `searchd mcp <index-dir> [--roots a,b] [--allow-write]` speaks MCP over stdio (JSON-RPC 2.0 with MCP's initialize / tools/list / tools/call / resources/list / resources/read). Tools are exactly FR-23's read set (the write tool only with `--allow-write`); resources are the indexed files, read-only and bounded by `read_span`'s limits. Canonical result payloads are semantically equal to RPC after stripping transport envelopes; serialization may differ. Pin an MCP revision and test negotiation, initialized notification, newline framing, pagination, errors and protocol-only stdout. Inject trusted principal context; reject caller-supplied principals/vectors. Writes require both `--allow-write` and host-authorized root/path access. Realizes CAP-13 with the wider tool set; stdio first, loopback HTTP later if measured useful. | Realizes CAP-13 | UC-004, UC-007 |
| FR-25 | **Accuracy support.** A `find` or `search_knowledge` result says `exact_match: true` when a phrase hit exists, `coverage: {files, sections}` (distinct files and sections among the top results) and `empty: true` with no hits, with generation, scope, truncation and authorized pending/error counts. `exact_match` is null when the phrase predicate was not evaluated. Empty pages or retrieval misses do not prove corpus absence; say "I found no matching indexed passages in the selected folders." This does not implement CAP-14 answerability. | New | UC-007 q8 |

## 4. Non-functional impact

| ID | Requirement | Measured how |
|---|---|---|
| NFR-10 | Phrase query p50 ≤ 5 ms and words query p50 ≤ 1 ms at 10k chunks on the macOS benchmark machine; `find` paging uses generation-bound cursors; stale cursors fail explicitly. Page size does not bound scoring work. | `searchd benchmark --mode phrase` before and after |
| NFR-11 | The positional lexical segment is at most 2.5× today's `HYBLEX01` size for the 10k-file benchmark corpus; positions are delta-coded varints. | segment sizes in the benchmark report |
| NFR-12 | Indexing 10k files (5,000 Markdown) ≤ 3 s wall and ≤ 300 MB peak on the benchmark machine; `apply_changes` of one changed file in a 10k index ≤ 200 ms in a `ReleaseSmall` build (tightened 2026-11-01 by S4-T1 ruling 2 after XXH3 section checksums landed: measured 154–158 ms `ReleaseSmall`, 88–91 ms `ReleaseFast`, five runs each; before it, from 2026-10-31 (S3-T3 Post-build ruling 2) the bound applied to `ReleaseFast` only, measured then 163 ms `ReleaseFast` and 215 ms `ReleaseSmall`) (the lexical rebuild may stay whole-index until a delta design is measured to be worth it, INV-09). | `searchd benchmark --apply` |
| NFR-13 | All new operations run inside caller-owned bounded workspaces on phones (NFR-04); `read_span` and `outline` never load more than one file; `find` never returns more than `page_size` snippets per call. | Zig tests with a 64 MiB arena cap |
| NFR-14 | The MCP server and the Zig engine stay free of third-party packages (INV-06); the MCP conformance client used in tests is standard-library Python. | CI job |

## 5. Contracts touched (CON)

- `MANIFEST` v2: adds `chunker_id` per section, `roots[]`, keeps v1 readable.
- `lexical-N.hyblex` v2 (`HYBLEX02`): positions; a v1 segment is readable with
  `phrase` answering `CAPACITY: positions absent` until re-indexed.
- `INDEX-STATE.json` v2: per file `root_id`, `mtime`, `status: indexed | pending | too_large | unreadable`, `moved_from`.
- `contracts/tool-request` v2 and `contracts/tools/*.schema.json`: the FR-23 set.
- `CONTRACTS_VERSION` → 2.0.0 (a major: new methods, new result fields; old
  requests keep working).
- C ABI: `ss_find`, `ss_outline`, `ss_read_span`, `ss_list_files`,
  `ss_apply_changes`, `ss_roots`; existing ten functions unchanged.

## 6. Invariant compliance (INV)

- INV-01: no generation anywhere; the skill document tells the model app what
  the engine will and will not do.
- INV-02: every hit carries `root_id/path`, lines, chunk id and, for Markdown,
  `section_path`.
- INV-03: roots and labels filter before ranking in the native path (extending existing native and Python label filtering); the authorization doc's known leaks (global BM25
  statistics, `index_status` counts, timing) are re-measured per root, and
  per-root statistics alone do not isolate labels within a root. Visible-scope BM25 statistics, prefix vocabulary and counts are required; timing is measured and disclosed, not promised constant.
- INV-04/INV-07: chunker id in the manifest; all formats versioned, bounded,
  checksummed; v1 segments readable.
- INV-06: Zig and standard-library Python only.
- INV-08: deterministic ordering; phrase hits order by BM25 then path then
  start line.
- INV-09: positions and roots are measured before and after (NFR-10..NFR-14) with
  a rollback (the v1 reader stays).
- INV-10: every claim in this document is "proposed" until the plan's tasks
  record measurements.

## 7. Register updates (fill when consolidating — step 4)

- Add CAP-19, FR-17..FR-25, NFR-10..NFR-14, CON changes above; mark CAP-13 as
  realized by FR-24 when it lands; keep CFT-09 blocked until interchange → manifest → status chunker validation and migration tests land.

## 8. Conflict check (step 5 — required)

- **CAP-15 (structure-aware chunking) said "prose keeps line windows".** FR-18
  changes that for Markdown only, by a new chunker id in the manifest, so an
  index says which chunker made it; `line-window-v1` stays the default and the
  golden fixtures stay byte-for-byte. The consumer app's own Dart port of
  `line-window-v1` (ADR-006 there) is not affected until it opts into
  `md-section-v1`; the plan asks that app to stop chunking itself and feed the
  engine bytes (FR-20) instead, which removes the double implementation.
- **CAP-13 (MCP adapter) proposed four tools; FR-24 exposes nine.** Proposed amendment: retain CAP-13's four-tool read-only baseline and semantic parity; CAP-19 adds opt-in tools and separately authorized writes. Design alone does not realize CAP-13.
- **`docs/authorization.md` names leaks through global statistics.** Per-root
  statistics (FR-19) change the ranking slightly across roots (BM25 idf per
  root); documented as intended: a root is a corpus.
- **Incremental indexing rebuilds the whole lexical index per update.** Kept
  for now (NFR-12 allows it); a delta design is a later capability, measured
  first.
- No conflict with INV-05 (vectors untouched), INV-11 (no learning here).

## 8b. Dependencies

- Zig 0.16.0 toolchain; the three native builds (macOS, iOS, Android) and the
  consumer app's pin bump at the end of the plan.
- The consumer app supplies the folder walk and iCloud placeholder state
  (host-fed changes); that app's plan lives in its own repository.

## 9. Acceptance gate (step 6 — pending fixture and benchmark profile)

- `fixtures/family-folder/` exists with its judgment pack
  (`fixtures/family-folder/judgments.json`, UC-007's ten questions plus five
  phrase, five prefix and five outline cases, invented content only).
- Zig tests: positions round-trip; phrase/prefix/words modes; `md-section-v1`
  golden chunks; roots add/remove/filter; `apply_changes` with bytes and with
  files, including `pending` and `move`; `read_span` byte-exact; v1 segment
  readable with the `CAPACITY` answer for phrase.
- ABI tests for the six new functions; Dart tests for the bindings; CLI tests
  for `find`, `outline`, `read-span`, `list-files`, `apply`.
- MCP conformance: a standard-library Python client runs initialize,
  tools/list, tools/call for eight default read tools, authorized opt-in writes and resources/read; canonical payloads equal RPC for 100% of cases. Any mismatch blocks.
- Benchmarks before/after recorded in `docs/scale-benchmark.md` meeting
  NFR-10..NFR-12.
- The three native libraries rebuilt, digests updated, the consumer app's
  device fixture green on both phones (recorded in that app's repository).

Blocking review cases (see [review](../reviews/2026-10-31-folder-knowledge-review.md)):

- Freeze fixture/judgments for all 13 scenarios before T2/T3. Phrase/prefix precision and recall = 1.00 across all pages after overlap deduplication; words recall@5 ≥ 0.9; outline exactness = 1.00. Include repeated tokens, punctuation, Unicode, empty queries, expansion limits and phrases across chunk/heading boundaries (outside chunk-local scope).
- Exact spans match original bytes for CRLF, blank/whitespace lines, front matter, indentation, Unicode and missing final newline; over-cap responses fail explicitly.
- Hidden-versus-absent cases include mixed labels within one root, hidden-only prefixes, forged principal/vector fields, denied roots and every read/list/status/resource. Visible scores/payloads match exactly; timing remains a measured limitation.
- T3 freezes bounded payloads: exactly one of strict UTF-8 `content_base64` or trusted `file` for add/change, path confinement, byte/batch caps, engine-verified hashes, expected generation and deterministic operation ordering. Test crash recovery, atomic documents/lexical/state publication, stale retries, duplicate/conflicting changes, pending replacing indexed content and ambiguous equal-content moves. Freeze stale-read policy before building.
- **Pending:** pin benchmark hardware/runtime, corpus hash and byte/chunk distribution, warmups/sample counts and p95 reporting. NFR-10..NFR-12 remain proposed targets, not measured evidence. Compare old/new formats on the same corpus, including retained-source disk cost. Correctness failures block; target misses require a reviewed amendment before release.

## 10. Evidence plan (step 8)

Each task in the plan records measured numbers in its Report; `PROJECT-STATE.md`
gains a "folder knowledge" section with the benchmark table; the judgment pack
runs in CI on Linux.

## 10b. Evidence (S3-T8, 2026-10-31)

Measured on the invented family-folder fixture and the generated 10k corpus (Apple M5 Pro, 48 GB, macOS 26.6.2, Zig 0.16.0, `ReleaseSmall` and `ReleaseFast`); the table is in `PROJECT-STATE.md` ("Folder knowledge (S3)").

| Requirement | Status | Evidence |
|---|---|---|
| FR-17 | Diagnostic · implemented | [S3-T2](../tasks/S3-T2.md): phrase/prefix precision and recall 1.00 on the judgment pack |
| FR-18 | Diagnostic · implemented | [S3-T1](../tasks/S3-T1.md): 61-file golden, 189 headings identical |
| FR-19, FR-20, FR-21 | Diagnostic · implemented | [S3-T3](../tasks/S3-T3.md): roots, `apply_changes`, rename pairing, visible-scope statistics |
| FR-22 | Diagnostic · implemented | [S3-T1](../tasks/S3-T1.md) (core), [S3-T4](../tasks/S3-T4.md) (C ABI, Dart, CLI, RPC) |
| FR-23 | Diagnostic · implemented | [S3-T4](../tasks/S3-T4.md), [S3-T5](../tasks/S3-T5.md) |
| FR-24, NFR-14 | Diagnostic · implemented | [S3-T6](../tasks/S3-T6.md): MCP `2025-11-25`, 66 parity requests 100% equal, conformance 27/27 |
| FR-25 | Diagnostic · implemented | [S3-T2](../tasks/S3-T2.md), [S3-T3](../tasks/S3-T3.md), [S3-T6](../tasks/S3-T6.md) |
| NFR-10 | Diagnostic · implemented | [S3-T2](../tasks/S3-T2.md): phrase p50 17.6 µs, words p50 5.6 µs at 19,959 chunks (`ReleaseFast`) |
| NFR-11 | Diagnostic · implemented | [S3-T2](../tasks/S3-T2.md): `HYBLEX02` 1.39× `HYBLEX01` |
| NFR-12 | Diagnostic · implemented | [S3-T3](../tasks/S3-T3.md): full 10k index 326 ms and 144 MB; [S4-T1](../tasks/S4-T1.md): one changed file 154–158 ms `ReleaseSmall` (bound now `ReleaseSmall`), 88–91 ms `ReleaseFast` |
| NFR-13 | Proposed | bounded reads and page caps are tested (S3-T1, S3-T2, S3-T4), but the "64 MiB arena cap" test named above is not recorded in any S3 Report |

CFT-09 stays Blocked: interchange (CON-03) carries no chunker id. Device acceptance (the consumer app's fixture run on both phones) is recorded in that app's repository.

## 11. Open decisions

1. Positions per chunk (proposed: simplest, chunk-local offsets) versus per
   document (phrase hits across a chunk boundary). Proposed: per chunk; the
   3-line overlap already catches most boundary phrases; measure misses on the
   fixture before changing.
2. Retain immutable original source text plus line-byte mappings in the same generation. Existing chunks strip whitespace and normalize line endings; Markdown also excludes front matter. T1 freezes a versioned, checksummed source section. Legacy indexes without source return `CAPACITY` for exact spans until rebuilt.
3. MCP transport: stdio only in the first task; loopback HTTP later if a host
   needs it (CAP-13's open decision, now decided for stdio first).
4. Where the skill document lives for the consumer app: a copy in that app's
   repository, kept equal by a test, or a Dart string generated from this
   repository's file at the pin bump. Proposed: generated at the pin bump.

5. **Source retention per root** (orchestrator, after the review): `retain_source` defaults true for host-fed and iCloud roots, false for local desktop roots the engine may re-open (hash-checked at read time, `stale` on mismatch); cost measured in S3-T1. See `../folder-knowledge-implementation.md` §4.
6. **CAP-16 relation:** `list_files` is a listing, not filename search; CAP-16's channel inherits roots and scope. See §8 there.
7. **MCP revision** pinned in code and recorded in S3-T6's Report; `--baseline` lists CAP-13's four tools.

Implementation details: [`docs/folder-knowledge-implementation.md`](../folder-knowledge-implementation.md); task files `docs/tasks/S3-T1.md` … `S3-T8.md`.

## 12. Maintainer approval (step 6b — required before build)

Pending review of this capability, UC-007, the plan and the [review](../reviews/2026-10-31-folder-knowledge-review.md). No implementation approval is recorded.

- Approver: the owner (by message to the orchestrator, 2026-10-31 14:10 ET: "Go with your recommendation")
- Date: 2026-10-31
- Commit: the design branch at `59152a5` plus this amendment
- Status: Approved; open decisions 1–7 taken as proposed (positions per chunk, source retention per root, stdio MCP first, the skill generated at the consumer's pin bump)
