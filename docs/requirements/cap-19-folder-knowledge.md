# CAP-19 — Folder knowledge: exact finding, document structure, several roots, host-fed changes, one tool surface for models, apps and MCP

Status: Proposed · Evidence: design only (2026-10-31)

> Run through the [capability process](../capability-process.md), steps 1–6.
> Requirements defined and conflicts checked; implementation is a later step
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
  lines; it has no positions (so no phrase, prefix or snippet), no document
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
  with the same JSON.

## 2. Motivating use case(s)

- Primary: [`UC-007`](../use-cases/uc-007-family-folders-on-a-phone.md)
- Also serves: UC-001 (personal files), UC-004 (MCP external agent), UC-002
  (codebase agent: prefix and phrase help code too)

## 3. Functional requirements (new or changed)

| ID | Requirement (testable) | New / changes | Traces to |
|---|---|---|---|
| FR-17 | **Positional postings.** The lexical segment stores, per term per chunk, the ordered token positions (codepoint offsets of each token's start and end within the chunk text). Queries gain three modes: `words` (today's BM25), `phrase` (all terms adjacent in order, after the analyzer; a filter, then BM25 order), `prefix` (a term matches any term that starts with it, bounded to 1,000 expansions, else `CAPACITY`). Results carry `match_offsets: [[start,end],…]` into `content` and a `snippet` (≤ 240 codepoints around the best window) built by the engine. | New | UC-007 q1–q3, q10 |
| FR-18 | **Markdown structure.** A chunker `md-section-v1`: front matter (`---` … `---` at the top) is parsed into string metadata and excluded from the body; ATX (`#`) and Setext headings open sections; a chunk never crosses a heading; inside a section `line-window-v1` applies; a fenced code block is kept in one chunk when it fits `max_chars`. Each chunk records `section_path: [h1, h2, …]` and `heading_line`. Files that are not Markdown keep `line-window-v1`. The chunker id is written to the manifest (closes the CFT-09 prerequisite named in CAP-15) and a chunk's citation gains `section_path`. `outline(path)` returns the headings with their line ranges. | New; manifest v2 | UC-007 q4, q6, q7, q9 |
| FR-19 | **Several roots.** An index holds N roots `{root_id, label, kind: local \| icloud \| host, principal_labels}`. A chunk's path is `root_id/relative/path`. Each root can be added, re-indexed or removed without touching another root's chunks; removing a root removes its terms, its statistics and its state. `path_prefix` and `principal_labels` filter per root **before** ranking (INV-03 in the native path, which today has no labels). | New; INDEX-STATE v2 | UC-007 q13, folder life |
| FR-20 | **Host-fed changes.** `apply_changes(changes_json)` takes `[{op: add \| change \| remove \| move \| pending, root_id, path, size, mtime, sha256?, bytes? \| file?, moved_from?}]`. With `bytes` the engine never opens a path (phones); with `file` it reads the path (desktop). `pending` records a file by name only (not yet downloaded) and `index_status` counts it; a later `add` replaces it. `move` keeps the chunk text and section data and re-keys the ids. The report keeps today's fields and adds `pending`, `moved`. A whole-folder `index_folder` remains for desktop roots and is expressed as a sequence of changes internally. | New | UC-007 q11, q12; corpus |
| FR-21 | **Rename detection.** When one change batch removes a path and adds a path whose `sha256` equals the removed file's, the engine records a `move` (chunk ids re-keyed, no re-chunk) and reports it as `moved`, not as `removed + added`. Two live files with equal content are both indexed (no de-duplication by content). | New | UC-007 q12 |
| FR-22 | **Traditional operations.** `find(query, mode, roots?, path_prefix?, page, page_size ≤ 100)` → hits as in FR-17 plus per-file counts `{path, hits}`; `outline(path)`; `read_span(path, start_line, end_line, context_lines ≤ 20)` → exact lines, byte-exact with the indexed text, bounded to 400 lines; `list_files(root_id?, path_prefix?, kind?, page)`. All four are available over the C ABI, the Dart binding, the CLI and the RPC server. | New | UC-007 q1–q5 |
| FR-23 | **One tool surface.** The tool contracts gain `find`, `outline`, `read_span`, `list_files`, `apply_changes` (write; off by default) beside `search_knowledge`, `read_chunk`, `list_sources`, `index_status`; each has a JSON Schema in `contracts/tools/<name>.schema.json` (request and result) that a model app can hand to a model as a tool definition unchanged. `evidence` adds `neighbours: {prev, next}` (the adjacent chunks of the same file) and `section_path`. A skill document `skills/folder-knowledge/SKILL.md` tells a model app when to use which tool and how to cite. | Changes FR-07; new | UC-007 flow |
| FR-24 | **MCP server.** `searchd mcp <index-dir> [--roots a,b] [--allow-write]` speaks MCP over stdio (JSON-RPC 2.0 with MCP's initialize / tools/list / tools/call / resources/list / resources/read). Tools are exactly FR-23's read set (the write tool only with `--allow-write`); resources are the indexed files, read-only and bounded by `read_span`'s limits. Results are byte-identical JSON to the RPC server for the same request. Realizes CAP-13 with the wider tool set; stdio first, loopback HTTP later if measured useful. | Realizes CAP-13 | UC-004, UC-007 |
| FR-25 | **Accuracy support.** A `find` or `search_knowledge` result says `exact_match: true` when a phrase hit exists, `coverage: {files, sections}` (distinct files and sections among the top results) and `empty: true` with no hits, so a model app can say "your folders hold nothing about this" instead of guessing. | New | UC-007 q8 |

## 4. Non-functional impact

| ID | Requirement | Measured how |
|---|---|---|
| NFR-10 | Phrase query p50 ≤ 5 ms and words query p50 ≤ 1 ms at 10k chunks on the macOS benchmark machine; `find` paging adds no re-ranking. | `searchd benchmark --mode phrase` before and after |
| NFR-11 | The positional lexical segment is at most 2.5× today's `HYBLEX01` size for the 10k-file benchmark corpus; positions are delta-coded varints. | segment sizes in the benchmark report |
| NFR-12 | Indexing 10k files (5,000 Markdown) ≤ 3 s wall and ≤ 300 MB peak on the benchmark machine; `apply_changes` of one changed file in a 10k index ≤ 200 ms (the lexical rebuild may stay whole-index until a delta design is measured to be worth it, INV-09). | `searchd benchmark --apply` |
| NFR-13 | All new operations run inside caller-owned bounded workspaces on phones (NFR-04); `read_span` and `outline` never load more than one file; `find` never returns more than `page_size` snippets per call. | Zig tests with a 64 MiB arena cap |
| NFR-14 | The MCP server and the Zig engine stay free of third-party packages (INV-06); the MCP conformance client used in tests is standard-library Python. | CI job |

## 5. Contracts touched (CON)

- `MANIFEST` v2: adds `chunker_id` per section, `roots[]`, keeps v1 readable.
- `lexical-N.hyblex` v2 (`HYBLEX02`): positions; a v1 segment is readable with
  `phrase`/`prefix` answering `CAPACITY: positions absent` until re-indexed.
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
- INV-03: roots and labels filter before ranking in the native path (today only
  the Python path does); the authorization doc's known leaks (global BM25
  statistics, `index_status` counts, timing) are re-measured per root, and
  per-root statistics are the design's answer to the first two.
- INV-04/INV-07: chunker id in the manifest; all formats versioned, bounded,
  checksummed; v1 segments readable.
- INV-06: Zig and standard-library Python only.
- INV-08: deterministic ordering; phrase hits order by BM25 then path then
  start line.
- INV-09: positions and roots are measured before and after (NFR-10..15) with
  a rollback (the v1 reader stays).
- INV-10: every claim in this document is "proposed" until the plan's tasks
  record measurements.

## 7. Register updates (fill when consolidating — step 4)

- Add CAP-19, FR-17..FR-25, NFR-10..NFR-14, CON changes above; mark CAP-13 as
  realized by FR-24 when it lands; note CFT-09's prerequisite met by FR-18.

## 8. Conflict check (step 5 — required)

- **CAP-15 (structure-aware chunking) said "prose keeps line windows".** FR-18
  changes that for Markdown only, by a new chunker id in the manifest, so an
  index says which chunker made it; `line-window-v1` stays the default and the
  golden fixtures stay byte-for-byte. The consumer app's own Dart port of
  `line-window-v1` (ADR-006 there) is not affected until it opts into
  `md-section-v1`; the plan asks that app to stop chunking itself and feed the
  engine bytes (FR-20) instead, which removes the double implementation.
- **CAP-13 (MCP adapter) proposed four tools; FR-24 exposes nine.** Resolved by
  realizing CAP-13 with the FR-23 set; CAP-13's "no new powers" holds: the only
  write tool is off by default.
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

## 9. Acceptance gate (step 6 — decidable before building)

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
  tools/list, tools/call for all nine tools and resources/read; the JSON equals
  the RPC server's for the same inputs.
- Benchmarks before/after recorded in `docs/scale-benchmark.md` meeting
  NFR-10..NFR-12.
- The three native libraries rebuilt, digests updated, the consumer app's
  device fixture green on both phones (recorded in that app's repository).

## 10. Evidence plan (step 8)

Each task in the plan records measured numbers in its Report; `PROJECT-STATE.md`
gains a "folder knowledge" section with the benchmark table; the judgment pack
runs in CI on Linux.

## 11. Open decisions

1. Positions per chunk (proposed: simplest, chunk-local offsets) versus per
   document (phrase hits across a chunk boundary). Proposed: per chunk; the
   3-line overlap already catches most boundary phrases; measure misses on the
   fixture before changing.
2. Whether `apply_changes` with `bytes` stores the text in the segment (as
   today) or also a copy for `read_span` when the host cannot re-open the file.
   Proposed: the segment text is the source of truth for `read_span`, so no
   second copy.
3. MCP transport: stdio only in the first task; loopback HTTP later if a host
   needs it (CAP-13's open decision, now decided for stdio first).
4. Where the skill document lives for the consumer app: a copy in that app's
   repository, kept equal by a test, or a Dart string generated from this
   repository's file at the pin bump. Proposed: generated at the pin bump.

## 12. Maintainer approval (step 6b — required before build)

Pending the owner's reading of this capability, UC-007 and the plan.
