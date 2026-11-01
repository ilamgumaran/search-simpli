# Filename field v1: frozen implementation boundary

Status: implementation contract, 2026-10-25. Owner `ilamgumaran` explicitly
requested “Pls implement and push to remote” after CAP-16 was reviewed/merged in
PR #16 (`4693a21`, merge `4b12ce7`). This is the authorization for implementation
and routine format choices within that scope, not agent self-approval or an
invariant exception. Independent review checks this boundary before runtime work.

## Persistence

Body-only builds retain byte-identical manifest v1 and body sections. Opt-in
`--filename-index` builds use `HYBMAN02`, version 2, flags/reserved zero, fixed
header 136 bytes. Integers are little-endian. Bytes 12–75 retain manifest-v1's
generation/body counts, sizes and internal checksums. Offsets 76/80 hold u32
filename-file/term counts; 84 holds u64 filename-posting count; 92/100 hold u64
catalog size/internal checksum; 108/116 hold filename lexical size/checksum;
124 holds u32 payload size; 128 holds u64 manifest checksum. FNV-1a covers bytes
0–127 then payload; corruption detection, not cryptographic authentication.

Payload: seven u32-length-prefixed strings: analyzer id, embedding model id,
body documents name, body lexical name, filename catalog name, filename lexical
name, `filename-field-v1`. Safe distinct basename rules from v1 apply to all
section names. Catalog name is `filenames-N.hybseg`; lexical name is
`filename-lexical-N.hyblex`. Generation allocation, lifecycle scanning/pruning
and orphan recovery recognize all four immutable sections. Publish syncs all
sections and the directory before replacing MANIFEST, then syncs the directory.
Never remove selected sections after the manifest becomes visible.

Catalog reuses the existing document segment codec, no vectors. Records sort by
bytewise relative path, one per path with a body chunk. Record id/lines/labels
are copied from the earliest body anchor (start line, end line, chunk id);
record text is the basename with final supported suffix removed. All chunks at
one path must have identical required labels. Load validates path uniqueness,
anchor identity/span/path/labels, basename text and zero vector dimensions.
Filename postings reuse HYBLEX01, indexed by catalog record ordinal, with the
same analyzer as body/query. Validate section bounds/counts/checksums as for body.

New readers open both versions. Old readers reject HYBMAN02. A filename request
on body-only data fails `FilenameIndexUnavailable` with rebuild guidance.
Changing filename-index setting/analyzer during incremental refresh fails;
full rebuild in a separate directory is required. Filename data is derived from
the final admitted/carried-forward body set, including budget-exhausted paths.

## Process contracts

Contract version becomes 1.3.0 on source; old bundled 1.2.0 libraries remain
explicitly stale until real platform rebuild, never stamp them current by hand.
Index options add boolean `filename_index` (default false); CLI spells it
`--filename-index`. Python opt-in snapshot version 2 contains filename-index
metadata; body-only stays version 1. Import payload v2 adds required
`filename_policy_id: "filename-field-v1"`; v1 remains unchanged. Import derives
and validates filename records from body documents, not caller-supplied postings.

Query options add `search_field: content|filename|both`, default content. CLI
uses `--search-field`. New modes require explicit lexical retrieval; legacy
content remains unchanged. New responses add `retrieval.search_field` and
`retrieval.filename_policy_id`; each result adds `matched_in` (array of content
and/or filename), `basename`, `ranking.filename` (rank/score) beside body lexical
rank/score. Always return real body chunk id/citation/content. Add an answer-policy
boolean `filename_matches_are_navigation: true`. Do not emit new keys in legacy
responses. New-mode counts/stats/warnings may not expose hidden corpus data.
`path_prefix` retains the existing literal string-prefix semantics in every
surface, including read/list; use `public/` to scope a directory rather than
`public` (which also matches `public-secret/`). Labels remain the authorization
boundary and are applied before candidate statistics.

Use CAP-16's exact file BM25, scoped body BM25 for `both`, per-file collapse,
candidate truncation and equal RRF k=60; bytewise path/chunk ties. No implicit
embedding, substring, phrase, fuzzy or parent-directory search. Unsupported
empty/binary/hidden files remain outside passage retrieval.

## Match sections (2026-10-28 owner presentation request)

New-mode results additionally carry `match_sections.filename` and `.content`.
Each has `label`, `matched`, `matched_terms`, `text`, and `citation`. Terms are
unique in query order, normalized with the relevant analyzer and intersected with
the displayed source. Filename terms use the indexed stem, not the suffix;
its citation is `{path, field: "filename"}`. Content citation is
`{path, field: "content", start_line, end_line}` for the actual stored passage.
Both sections are present even if one has no matches. `matched_in` remains the
ranked-channel explanation and can differ after candidate truncation or a
filename-only request; section flags describe actual text matches. Do not infer
answer support from a filename. Human `query` uses these sections; `--json`,
`evidence` and tool responses retain machine-readable fields. This adds no new
on-disk format or reindex requirement for already enabled filename snapshots.

## Ownership APIs and tests

`filename_field.zig` owns `Field { content, filename, both }`, `policy_id`,
`Built { catalog, lexical }`, `build(allocator, documents, analyzer_id)`,
`validate(allocator, body_documents, catalog, lexical, analyzer_id)`, and
`query(allocator, body_documents, body_index, catalog, lexical, analyzer_id,
query_text, field, options) -> []Hit`. Hit has `document_index`, `body_score`,
`body_rank`, `filename_score`, `filename_rank`, `fused_score`. Null rank means
absent from that truncated channel. Engine exposes `queryFields` and stores
borrowed encoded filename data; default query methods are untouched.

`manifest.Manifest.filename` is optional metadata containing counts, byte sizes,
checksums, two safe filenames and policy id. Preserve `create`/v1 APIs; add
`withFilename` and full-section validation. Publication preserves body APIs and
adds `publishWithFilename` / `loadCurrentWithFilename`; loaded snapshots carry
encoded optional sections. Shared `snapshot_open.open` validates catalog anchors
before returning a usable engine. CLI/ABI/server reuse that loader.

Freeze six filename cases, hashes and native default-content golden output in
`fixtures/filename-search/` before builders start. Run authorization/path
hidden-absent parity, hand-computed fusion/ties/truncation, change/rename/delete,
corruption/cross-reference/atomic-failure and old-reader availability checks.
The frozen cases are correctness fixtures, not a representative holdout corpus.
