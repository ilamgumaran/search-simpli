# Filename field v1: frozen implementation boundary

Status: implementation contract, 2026-10-25. Owner `ilamgumaran` explicitly
requested “Pls implement and push to remote” after CAP-16 was reviewed/merged in
PR #16 (`4693a21`, merge `4b12ce7`). This is the authorization for implementation
and routine format choices within that scope, not agent self-approval or an
invariant exception. Independent review checks this boundary before runtime work.

## Persistence

The filename field's semantics below remain v1. The pre-S3 draft persistence
layout is superseded by [manifest v2.2](manifest-format-v2.md#v22-filename-sections-s4-t2-cap-16)
(S4-T2): `HYBMAN02` version 2 with flag bit 3, 48 more header bytes and three
more payload strings (catalog file, filename lexical file, policy id),
binding body, positions, source, roots and both filename sections. Every v2.2
folder generation also sets bit 4 and binds its
[recovery-state section](manifest-format-v2.md#v22-recovery-state-section-s4-t2)
(16 header bytes after the filename fields, one payload string last).
PR #21's interim `HYBMAN03` was never released and is not read.
The old 136-byte HYBMAN02 draft must be rebuilt in a separate directory.
Publication syncs all bound sections before committing MANIFEST; current
allocation and retention cover filename sections as well.

Catalog reuses the existing document segment codec, no vectors. Records sort by
bytewise relative path, one per path with a body chunk. Record id/lines/labels
are copied from the earliest body anchor (start line, end line, chunk id);
record text is the basename with final supported suffix removed. All chunks at
one path must have identical required labels. Filename postings reuse
HYBLEX01, indexed by catalog record ordinal, with the same analyzer as
body/query.

**Carried lexical section (S4-T13).** An update whose files are the previous
generation's (the same paths in the same order with the same labels, compared
with the previous body documents) copies the previous
`filename-lexical-N.hyblex` byte for byte, after checking its size, its
checksum against its header and the manifest, `HYBLEX01` and its counts; only
the catalog is re-encoded, because anchors move with a changed file's chunks.
A rename, add, remove or label change, or a previous section that fails a
check, takes the full build. Both sections stay byte-identical to a full
build.

**Lazy load (S4-T2 R4).** An open reads neither filename section: it opens
both files (so the handle keeps this generation's bytes after a writer prunes
them), reserves their bytes in the open's one section allocation without
reading them (`filename_field.loadReservation`), and `index_status` reports
`filename_policy_id` from the manifest alone. The first `filename` or `both`
query on a handle loads both sections once, under the handle's lock
(`filename_field.load`): each file's size against the manifest
(`FilenameCatalogSizeMismatch`, `FilenameLexicalSizeMismatch`), each checksum
computed once against the manifest's (`FilenameCatalogChecksumMismatch`,
`FilenameLexicalChecksumMismatch`), the counts, then the catalog walk: sorted
unique safe paths, each text equal to its stem, zero vector dimensions, each
record anchored at a real body chunk with the same id, span and labels
(`FilenameCatalogMismatch`, `FilenameAnchorNotFound`). An error is kept on the
handle and every later filename query answers it (`SS_ERR_CORRUPT_SNAPSHOT`
through the C ABI); content queries are unaffected. Writers validate the
canonical postings in full (`filename_field.validate`) after building and
before publishing. The one-shot `snapshot_open.open` (the CLI's single
query) stays eager. `zig/src/lazy_open_test.zig` pins the deferral, the
single load under concurrent queries and the damaged-section errors.

**Query (S4-T2 R5).** One filename query is linear in the touched postings:
touched lists and seen flags instead of hash maps, a body-anchor ordinal map
for root masks, and an unscoped fast path that takes the corpus totals when
the mask allows every root. The answers equal PR #21's query exactly
(`zig/src/filename_field_test.zig` compares both on labelled and unlabelled
corpora, prefixes, labels and masks).

Readers open manifest v1, v2.0, v2.1 and v2.2; readers before v2.2 refuse bit
3 and bit 4 (`UnsupportedFlags`). `HYBMAN03` is not read. A filename request
on body-only data fails `FilenameIndexUnavailable` with rebuild guidance.

**The setting is the directory's.** Enabling the channel, disabling it or
changing its analyzer needs a fresh directory (`FilenameSettingMismatch`,
`FilenameMigrationRequiresNewDirectory`). Omitting the setting keeps it:
`searchd index` (with or without `--update`) without `--filename-index`,
`ss_index_folder` and `ss_apply_changes` without `filename_index`, and Dart
`filenameIndex: null` all keep an enabled directory enabled and a plain one
plain; only an explicit different value is refused (S4-T2 R6; PR #21
defaulted the folder paths to false, so an update without the flag was
refused). Filename data is derived from the final admitted/carried-forward
body set, including budget-exhausted paths.

## Process contracts

Contract version is 2.2.0 and Dart package 0.3.0; consumers must repin.
Native freshness requires real platform rebuilding; never stamp stale binaries current.
Index options add optional boolean `filename_index` (omitted: a new
directory is plain, an existing one keeps its setting); CLI spells it
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

Each channel keeps a bounded top `min(candidate_k, candidates)` under exactly
that order (score descending, then path bytes, then the body chunk id) instead
of sorting every scored file (S4-T15). The order is total over a channel's
candidates (scores are positive and finite, and each channel has one candidate
per path), so the kept candidates are the full sort's first `candidate_k`,
element for element, and every hit and the final order are unchanged. On the
10k timing corpus (filename channel on, `ReleaseSmall`, `the doc`, `top_k` 10,
`candidate_k` default) the warm `both` query went from 3.25-3.48 ms to
0.49-0.53 ms per call and the warm filename query from 0.77-0.83 ms to
0.25-0.27 ms; the two full sorts had cost 2.38 ms (body, 7,093 candidates) and
0.60 ms (filename, 10,000 candidates).

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
absent from that truncated channel. Engine exposes `queryFields` and carries
`filename_policy_id` from the manifest; the decoded sections live on the
handle's lazy loads (`scope.Loads`), not the engine. Default query methods are
untouched.

`manifest.Manifest.filename` is optional metadata containing counts, byte sizes,
checksums, two safe filenames and policy id. Preserve `create`/v1 APIs; add
`withFilename` and full-section validation. Publication preserves body APIs;
`publishWithExtrasRecorded` links the optional source, filename and state
sections. Handle opens (`snapshot_open.openScoped`: the C ABI, the servers and
the CLI's filename queries) defer the filename sections to the first filename
query; the one-shot `snapshot_open.open` loads them before returning.

Freeze six filename cases, hashes and native default-content golden output in
`fixtures/filename-search/` before builders start. Run authorization/path
hidden-absent parity, hand-computed fusion/ties/truncation, change/rename/delete,
corruption/cross-reference/atomic-failure and old-reader availability checks.
The frozen cases are correctness fixtures, not a representative holdout corpus.
