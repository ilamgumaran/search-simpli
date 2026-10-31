# Folder knowledge — implementation plan (S3)

**State:** proposed, 2026-10-31 · **Realizes:** [`CAP-19`](../requirements/cap-19-folder-knowledge.md), [`UC-007`](../use-cases/uc-007-family-folders-on-a-phone.md), [`CAP-13`](../requirements/cap-13-mcp-adapter.md) · **Builds on:** S1 (durable engine, incremental indexing, iOS alignment), S2 (query speed)

This plan turns CAP-19 into tasks the usual way (a task file per step in
`docs/tasks/`, the S1/S2 header shape, one builder, one verifier, measured
numbers in every Report). Implementation starts only after the owner approves CAP-19
(step 6b). The consumer app's side of the work is planned in that app's
repository (`docs/tasks/M16-PLAN.md` there); the two plans meet at S3-T8.

## The shape in one picture

```
host (app, CLI, MCP client)
   │  apply_changes(bytes|file, pending, move)      ← folders arrive as changes
   ▼
indexer ── md-section-v1 / line-window-v1 ──► documents-N.hybseg (text, lines, section_path)
   │                                             lexical-N.hyblex v2 (terms, positions)
   │                                             INDEX-STATE v2 (roots, files, status)
   ▼
query core: words | phrase | prefix  →  hits {root/path, lines, section_path, snippet, offsets, score}
   │
   ├─ C ABI / Dart / CLI            (apps, the consumer app on phones)
   ├─ RPC server (stdio, loopback)  (model apps' tool loop)
   └─ MCP server (stdio)            (desktop agents)
```

## Tasks

Task files: [`S3-T1`](../tasks/S3-T1.md), [`S3-T2`](../tasks/S3-T2.md), [`S3-T3`](../tasks/S3-T3.md), [`S3-T4`](../tasks/S3-T4.md), [`S3-T5`](../tasks/S3-T5.md), [`S3-T6`](../tasks/S3-T6.md), [`S3-T7`](../tasks/S3-T7.md), [`S3-T8`](../tasks/S3-T8.md). Formats, JSON shapes, ABI, MCP mapping, fixture inventory and benchmark profile: [`docs/folder-knowledge-implementation.md`](../folder-knowledge-implementation.md).

| Task | Title | Size | Depends on | Delivers |
|---|---|---|---|---|
| S3-T1 | Manifest v2 and the Markdown chunker | M | — | `chunker_id` in the manifest; `md-section-v1` (front matter, ATX/Setext headings, fenced blocks, `section_path`, `heading_line`); versioned retained source bytes and line maps for exact reads; `outline` in the core; golden fixtures for both chunkers; v1 manifests still open. |
| S3-T2 | Positions, phrase, prefix, snippets | M–L | T1 | `HYBLEX02` with delta-coded positions; `words`/`phrase`/`prefix` modes; `match_offsets` and `snippet`; `exact_match`, `coverage`, `empty` in results; v1 segments answer `CAPACITY` for phrase; benchmark before/after (NFR-10, NFR-11). |
| S3-T3 | Roots and host-fed changes | M–L | T1 | `roots[]` in the manifest, `INDEX-STATE` v2; `apply_changes` with `bytes` or `file`, `pending`, `move`, rename detection by hash; visible-scope statistics/vocabulary and trusted root-plus-document filtering across all operations; atomic state publication; `index_folder` rewritten over `apply_changes`; benchmark (NFR-12). |
| S3-T4 | The traditional operations over every surface | M | T2, T3 | `find`, `outline`, `read_span`, `list_files`, `apply_changes`, `roots` on the C ABI (six functions), the Dart binding, the CLI (`find`, `outline`, `read-span`, `list-files`, `apply`) and the RPC server; `evidence` gains `neighbours` and `section_path`; `CONTRACTS_VERSION` 2.0.0; ABI, Dart and CLI tests. |
| S3-T5 | Tool schemas and the skill document | S | T4 | `contracts/tools/<name>.schema.json` for the nine tools (request and result), validated against real responses in tests; `skills/folder-knowledge/SKILL.md` (when to use which tool, how to cite, what to say on `empty`); a Python example loop using only the standard library. |
| S3-T6 | The MCP server | M | T4, T5 | `searchd mcp` over stdio (initialize, tools/list, tools/call, resources/list, resources/read; `--allow-write` for `apply_changes`); a standard-library conformance client in `tests/`; semantically equal canonical payloads to the RPC server for the fixture questions; CAP-13 marked realized. |
| S3-T7 | The family-folder fixture and judgment pack | S | — | `fixtures/family-folder/` (invented content: ≥ 40 files, three roots, front matter, nested headings, lists, code fences, one file > 1 MB, two files with equal content) and `judgments.json` (UC-007's ten questions plus five phrase, five prefix, five outline cases); `scripts/relevance_smoke.py` runs it; the acceptance numbers of UC-007 recorded. Freeze source cases and expected behavior before T1/T2/T3; execution follows feature availability. |
| S3-T8 | Native rebuild and the consumer pin | S | T4, T6, T7 | The three native libraries rebuilt (`tool/build_native.sh`), `native/SOURCE-SHA256` updated, iOS alignment check green, `PROJECT-STATE.md` updated with the benchmark table; the consumer app bumps its pin (its M16-T1). |

Order: T7 fixture freeze → T1 → T2 and T3 (parallel, separate worktrees, T2 and T3 touch
different files: `postings.zig`/`scoring.zig`/`lexical_*` versus
`indexer.zig`/`incremental_state.zig`/manifest) → T4 → T5 → T6 → T8.
Estimated calendar with one builder and one verifier at a time: eight tasks,
each a day or less, the way S1 ran.

## Rulings that hold across the tasks

1. **Formats stay readable.** A v1 manifest, `HYBLEX01` segment or
   `INDEX-STATE` v1 opens; features that need v2 answer `CAPACITY` with a
   message naming the re-index, never a crash (INV-07).
2. **`line-window-v1` is byte-for-byte unchanged**; `md-section-v1` is a second
   chunker chosen per file by extension (`.md`, `.markdown`), recorded in the
   manifest, and the consumer app is asked (in its plan) to stop chunking on
   its own and feed bytes.
3. **Phones get bytes, desktops get paths.** `apply_changes` is the one write
   API; `index_folder` is a convenience over it. The engine opens a path only
   when the change says `file`.
4. **A root is a corpus.** Statistics and vocabulary also respect the visible label scope within a root; a
   query names its roots (default: all the caller may see).
5. **Measured numbers only**, before and after, in each Report; the benchmark
   machine and corpus named; a rollback for every format change.
6. **No third-party packages** anywhere in the engine, the server or the
   tests (INV-06); the MCP client in tests is standard-library Python.
7. **Public repository rules**: invented content only in fixtures; no home
   paths, no device identifiers, no `Claude-Session:` trailers.

## What the consumer app does with it (summary; detail in its own repository)

- Replaces its per-file index rebuild with `apply_changes` batches from its
  folder walk (iOS and Android hand bytes; the Mac may hand paths).
- Reports iCloud placeholders as `pending` and downloads on demand.
- Shows a Library "Find in files" box (words, phrase, prefix, snippets, per-file
  counts, jump to the span) over `find`, `outline`, `read_span`.
- Gives its model the nine tools where the provider supports tool calling, and
  a two-step search-then-answer loop where it does not; cites
  `root/path › section · lines`; says "I found no matching indexed passages in the selected folders"
  on a retrieval miss; reports incomplete indexing and paging limits.
- Ships the skill document as the model app's instruction for the tools.

## Open items for the owner

- Approve CAP-19 (step 6b) or send it back with changes.
- Decide open decision 1 of CAP-19 (positions per chunk) if the fixture shows
  boundary misses.
- Say whether S1-T9 (memory and disk under a long-running caller, still a draft
  commit) should land before S3-T3, since `apply_changes` is exactly such a
  caller.

## Review amendments (2026-10-31)

See the [review](../reviews/2026-10-31-folder-knowledge-review.md) and CAP-19's blocking acceptance cases. No implementation approval is recorded.

- T1 freezes source retention/checksums, original line mappings and per-file chunker/configuration identity through interchange, manifest and status. Golden line-window output stays unchanged; CFT-09 stays blocked until tested.
- T2 freezes ordinals versus codepoint offsets, words conjunction, final-token prefix semantics, overlap deduplication, generation-bound pagination and visible-only expansion caps. Chunk-local phrase completeness is explicit.
- T3 freezes strict base64 UTF-8 payloads, path confinement, hash verification, batch caps, expected-generation retries, atomic state publication, stale/pending policy and deterministic rename pairing. Test two label domains inside one root.
- T4 gates every new read/list/status operation and defines exact span byte caps. T5 wraps schemas per provider and teaches retrieval-limited negative wording.
- T6 pins an MCP revision, protocol lifecycle/framing and semantic payload parity; preserves CAP-13's four-tool read-only baseline, eight CAP-19 read tools and separately authorized writes. Retain CAP-13's p95 ≤ 5 ms adapter-overhead gate.
- Benchmark profiles (hardware, corpus hashes, distributions, warmups, repetitions, p50/p95 and source-retention disk overhead) remain pending before performance acceptance. Task sizes are estimates, not measured completion promises.
