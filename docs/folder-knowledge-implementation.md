# Folder knowledge — implementation details (CAP-19, S3)

Status: design (2026-10-31); §1, §2 and §4 implemented by S3-T1 with the
amendments marked **S3-T1** below (formats: [`manifest-format-v2.md`](manifest-format-v2.md),
[`segment-format-v4.md`](segment-format-v4.md), [`source-section-v1.md`](source-section-v1.md));
§5, §6 and §7 implemented in the core by S3-T3 (`zig/src/apply.zig`,
`zig/src/scope.zig`, `zig/src/incremental_state.zig`; Python reference
`src/search_platform/folders.py`) with the amendments marked **S3-T3**.
§3, the `find` part of §8 and the §13 profile implemented by S3-T2 with the
amendments marked **S3-T2** (format: [`lexical-segment-format-v2.md`](lexical-segment-format-v2.md)).
Every other format, field and number here is **proposed**; a task's Report
turns it into an observed fact or amends it.
Companion to [`CAP-19`](requirements/cap-19-folder-knowledge.md),
[`UC-007`](use-cases/uc-007-family-folders-on-a-phone.md), the
[plan](plans/folder-knowledge-plan.md) and the
[review](reviews/2026-10-31-folder-knowledge-review.md). The tasks
`docs/tasks/S3-T1.md` … `S3-T8.md` cite the sections below by number.

Conventions: all integers little-endian; "codepoint" means a Unicode scalar;
"line" means a `splitlines`-style line of the **original** bytes (CRLF, CR and
LF all end a line; the terminator belongs to the line); line numbers are
1-based inclusive. Nothing here changes `line-window-v1`'s golden output.
**S3-T1:** "splitlines-style" is exact: the boundary set is Python's
`str.splitlines` (also VT, FF, FS, GS, RS, NEL, LS, PS), the set
`line-window-v1` already numbers lines by, so a chunk's citation and a
`read_span` always count the same lines; a leading BOM is not part of line 1.

## 1. Generation layout (manifest v2)

A generation stays one atomic snapshot bound by the manifest
(`docs/manifest-format-v1.md`). Manifest **v2** (`HYBMAN02`) keeps the 88-byte
v1 header layout and adds a fifth and sixth payload string and three header
fields in the reserved/flags space:

| Offset | Size | Field | Change |
|---:|---:|---|---|
| 10 | 2 | flags | bit 0 `has_source` (a source section is bound); bit 1 `has_positions` (`HYBLEX02`); other bits zero |
| 32 | 4 | reserved → source section count | `0` or `1` |
| … | | (v1 fields unchanged) | |

**S3-T1 amendment:** binding the source section needs its byte length and
checksum, and the 88-byte header has no room for two u64s, so the v2 header is
104 bytes: offsets 0–75 as v1, source section length at 76, source section
checksum at 84, payload length at 92, manifest checksum at 96 (FNV-1a over
bytes 0–95 and the payload). Full table: [`manifest-format-v2.md`](manifest-format-v2.md).

Payload strings (u32 length + bytes), in order: 1 analyzer id, 2 embedding
model id or `none`, 3 document section filename, 4 lexical section filename,
**5 source section filename or empty**, **6 a UTF-8 JSON object `meta`**:

```json
{"manifest_meta":2,
 "chunkers":[{"id":"line-window-v1","params":{"max_chars":1600,"overlap_lines":3}},
             {"id":"md-section-v1","params":{"max_chars":1600,"overlap_lines":3,"front_matter":"yaml-v1"}}],
 "roots":[{"root_id":"r-6f1a","label":"School","kind":"icloud","required_labels":["cloud-ok"]}],
 "source_section_version":1}
```

`chunkers` lists every chunker that produced a chunk in this generation with
its parameters (the review's "identity includes algorithm and parameters").
**S3-T1:** `line-window-v1` is always entry 0 (so `chunker_index` 0 means it,
as §2 says, even in a generation of Markdown only) and `md-section-v1` is entry
1 when used; each root also carries `required_labels` and `retain_source`;
`source_section_version` is 0 when no source section is bound. The `meta` of
the example above with `roots` written by `index_folder` is
`[{"root_id":"r-legacy","label":"folder","kind":"local","required_labels":[],"retain_source":true}]`.
Which chunker made a given chunk is stored per document record (§2). A v1
manifest opens; `has_source`/`has_positions` read as false; operations that
need them answer `SS_ERR_CAPACITY` with the message
`"re-index required: <source|positions> absent"` (CAP-19 FR-22/FR-17).
**S3-T3:** each root also carries `origin` (`folder` for `index_folder`'s
root, `host` for a root declared through `apply_changes`; read as `folder`
when absent) and its `required_labels`; `meta` gains two lists written only
when non-empty, after `roots`: `pending` (`{root_id, path, size,
required_labels}` of every pending file, so a reader counts and lists them
without `INDEX-STATE.json`) and `unchunked` (the same fields for indexed
files that produced no chunk, an empty or blank file, so they can be listed
and their labels are known). Duplicate root ids are refused.

Section files: `documents-N.hybseg` (v4, §2), `lexical-N.hyblex` (v2, §3),
`source-N.hybsrc` (v1, §4), `MANIFEST`, `INDEX-STATE.json` (v2, §5),
`WRITER.LOCK`. Publication keeps `lifecycle.publishSerialized` →
`publication.writeAtomicFile` and writes `INDEX-STATE.json` **after** the
manifest, as today; the review's "atomic generation consistency" is met by the
manifest binding all three sections' lengths and checksums, so a reader never
sees a documents section without its matching source section.

## 2. Document section v4 (`HYBSEG01`, record version 4)

Per-document record = v3 (`docs/segment-format-v3.md`) plus:

```text
u16 chunker_index        // into manifest meta.chunkers; 0 = line-window-v1
u16 section_depth        // number of section_path entries (0 for non-Markdown)
u32 heading_line         // 0 when none
u32 source_doc_index     // index into the source section's file table (§4); 0xFFFFFFFF when no source
u32 section_path_length  // bytes
section_path bytes       // UTF-8, entries separated by U+001F (unit separator); empty when depth 0
```

Order inside the record: the v3 fixed fields, the new fixed fields, then the
variable byte runs in the v3 order followed by `section_path`. **S3-T1:** "the
v3 order" includes the vector bytes, so `section_path` follows the vector; the
writer of `index_folder` emits record v4, `import-json` still emits v3 (its
interchange JSON carries no section, chunker or source fields). Readers of v1–v3
decode the new fields as zero/empty/none. The chunk id stays
`sha256(path\0start\0end\0text)[:20 hex]` over the chunk's **normalized** text
(unchanged), where `path` is now the root-qualified path `root_id/relative`
(§5); a `move` therefore changes ids (CAP-19 FR-21 says re-keyed, not
re-chunked: the text and section fields are copied). **S3-T3:** the legacy
folder root `r-legacy` keeps the bare relative path (no `r-legacy/` prefix),
so every index `index_folder` writes, its chunk ids and every citation a
consumer stored stay byte-for-byte as before; a record belongs to the root
whose `root_id/` prefixes its path, else to `r-legacy`, and `apply_changes`
refuses a root id equal to the first component of a legacy path (and a
legacy path whose first component is another root's id), so the rule is
never ambiguous. Records carry the union of the root's and the file's
`required_labels` (at most 64 together).

## 3. Lexical section v2 (`HYBLEX02`)

Header as v1 (`docs/lexical-segment-format-v1.md`) with `version = 2`, plus two
u64 fields appended before the checksum (header grows to 80 bytes; the checksum
covers bytes 0–71):

| Offset | Size | Field |
|---:|---:|---|
| 56 | 8 | positions bytes (section 4 length) |
| 64 | 8 | offsets bytes (section 5 length) |
| 72 | 8 | checksum |

Sections 1–3 as v1. **Section 4, positions:** for each posting in posting order,
`tf` unsigned LEB128 varints: the token ordinals of this term in this document,
delta-coded (first absolute, then gaps ≥ 1). **Section 5, offsets:** one table
per document in document order: `u32 token_count`, then per token two LEB128
varints: start codepoint offset delta and length in codepoints, into the
chunk's normalized text (the `text` bytes of §2). Ordinals are the key for
adjacency (phrase) and offsets are for highlighting (CAP-19 FR-17; the review's
"ordinals plus original-text offsets"). Mapping a chunk-text offset back to
original bytes goes through §4's line map.

Size budget (CAP-19 NFR-11, ≤ 2.5× v1 for the 10k benchmark corpus): with
average term frequency near 1, section 4 costs about one byte per posting and
section 5 about two bytes per token; both are measured in S3-T2, with the
alternative (positions only, offsets recomputed by re-tokenizing the chunk at
highlight time) kept as the rollback if the budget is missed.

Phrase evaluation: intersect the query terms' posting lists (document index
order, as v1 guarantees strictly increasing indexes), then for each candidate
document walk the ordinal lists checking `ordinal(term_i) = ordinal(term_0) + i`
for the analyzed query token sequence; repeated query tokens are handled by the
same walk. A phrase hit is chunk-local (open decision 1 of CAP-19). Prefix
evaluation: binary search in a **sorted** dictionary (v2 sorts terms by bytes;
v1 was first-seen order) for the range sharing the prefix, bounded to 1,000
terms; only the final query token may carry a trailing `*`; expansion counts
only terms visible to the caller's scope (§7). `words` mode is conjunctive
(every analyzed term present) then BM25 order; `search_knowledge` keeps its
current disjunctive BM25.

**S3-T2 amendments** (full format: [`lexical-segment-format-v2.md`](lexical-segment-format-v2.md)):
- Section 5's start is a delta from the **previous token's start** (the first
  from 0); a token's length is ≥ 1. "The chunk's normalized text" is the
  record's stored `text` (what a hit's `content` is), in codepoints of the
  original, not the NFC form: the writer maps NFC output back through
  `nfc.MappedIterator` (a region NFC changes maps to the whole region).
- Two v2 rules the reader checks: the dictionary is strictly sorted by bytes
  (no hash set needed), and term ranges are contiguous in dictionary order
  (so a term's ordinals are one run of section 4). Sections 4 and 5 are
  validated completely at open; `postings.buildPositionTables` then records
  one start offset per term and per document.
- The manifest's `has_positions` is set exactly when the lexical section is
  `HYBLEX02`; a mismatch is refused, and a v1 manifest cannot bind
  `HYBLEX02`. `import-json` (v1 manifest) therefore keeps writing `HYBLEX01`,
  now with the sorted dictionary, so its sections 1–3 equal the folder door's
  byte for byte (the S2-T1 parity test compares those bytes).
- On a `HYBLEX01` generation `phrase` answers `CAPACITY` "re-index required:
  positions absent"; `words` and `prefix` still answer (a prefix scans the
  unsorted dictionary, highlights are recomputed by re-tokenizing the hit).
- `--update` carries unchanged chunks' exact token sequence and spans out of
  the previous `HYBLEX02` section instead of re-analyzing them; a `HYBLEX01`
  generation is re-tokenized once.
- Measured on the 10k corpus (19,959 chunks): section 4 is one byte per token
  (1.11 per posting), section 5 two bytes per token plus four per chunk; the
  section is 1.39× `HYBLEX01`. Neither rollback is needed.

## 4. Source section v1 (`HYBSRC01`)

Why: chunks are stripped and joined with LF, and `md-section-v1` drops front
matter, so byte-exact `read_span` needs the original bytes (review finding 2,
CFT-21). Retention is **per root** (`retain_source: true|false`, default true
for `kind` `host` and `icloud`, false for `local` desktop roots where the
engine may re-open the file, overridable); the cost is one copy of the text
bytes, measured and reported by S3-T1.

```text
u8[8]  magic "HYBSRC01"
u16    version = 1
u16    flags = 0
u32    file_count
u64    files table bytes
u64    line maps bytes
u64    text bytes
u64    checksum           // FNV-1a over header bytes 0–39 + all payload bytes
-- files table: file_count records
   u32 path_length, u64 text_offset, u64 text_length, u32 line_count, u64 line_map_offset, u8[32] sha256, u8 encoding (0 = UTF-8 exact), u8[3] reserved, path bytes
-- line maps: per file, line_count + 1 LEB128 varints: byte offset of each line start, then the end offset
-- text: the original bytes of every retained file, concatenated
```

**S3-T1 amendments** (full layout: [`source-section-v1.md`](source-section-v1.md)):
the line-map varints are delta coded (the first value absolute, then gaps), so
a typical line costs one byte instead of up to three; `encoding` 1 marks a
file with a BOM (line 1 starts at byte 3); records are strictly sorted by path
and text and maps are laid out in table order without gaps (so `open` can
check every offset and `find` can binary-search); `read_span` clamps an
`end_line` past the last line to it. In S3-T1 `index_folder` writes the one
root `r-legacy` with `kind: local` and `retain_source: true` (ruling 4), not
the `local` default of false proposed below; S3-T3 applies the per-kind
defaults. **S3-T3:** the per-kind defaults apply to roots declared through
`apply_changes` without `retain_source` (`host`/`icloud` true, `local`
false); `index_folder` keeps its `retain_source` option and its default true,
because `read_span` over a `local` root without retained bytes (re-reading
and hash-checking the file) is not built yet and would turn every existing
folder index's `read_span` into `CAPACITY`.

`read_span(path, a, b, context)` slices lines `a-context … b+context`
(clamped), total ≤ 400 lines and ≤ 256 KiB, else `SS_ERR_CAPACITY` with the
counts. Over a root with `retain_source: false` and a `file` the engine may
open, it reads the file and verifies the sha256 against INDEX-STATE before
answering; a mismatch (the file changed since indexing) answers
`SS_ERR_NOT_FOUND` with `"stale: file changed since generation N"`. Over a root
without retention and without a readable file the answer is `SS_ERR_CAPACITY`
`"source not retained"`. Front matter is part of the original bytes, so
`read_span` returns it; `outline` reports its line range as `front_matter`.

## 5. INDEX-STATE v2

```json
{"state_version":2,"generation":17,"analyzer_id":"analyzer-v2",
 "roots":[{"root_id":"r-6f1a","label":"School","kind":"icloud","required_labels":["cloud-ok"],"retain_source":true,"origin":"host"}],
 "files":[{"root_id":"r-6f1a","path":"week-07.md","size":4211,"mtime_ms":1761900000000,"sha256":"…64 hex…",
           "status":"indexed","chunker":"md-section-v1","chunks":3,"moved_from":null},
          {"root_id":"r-6f1a","path":"week-08.md","size":3900,"mtime_ms":null,"sha256":null,"status":"pending","chunker":null,"chunks":0,"moved_from":null}]}
```

`status` ∈ `indexed | pending | too_large | unreadable | budget_exhausted`.
v1 state (no `state_version`, entries `{path, hash, size}`) loads as one root
`r-legacy` with `kind: local`, `origin: folder`. Paths are root-relative POSIX
with no `..`, no leading `/`, no NUL and no newline; the root-qualified path
used in records is `root_id + "/" + path`.

**S3-T3 amendments.** The state stores `status` `indexed` or `pending` only:
it names exactly the files the generation names. `too_large`, `unreadable`
and `budget_exhausted` are report outcomes (a too-large file is tombstoned,
an unreadable or left-over file keeps its previous entry, as S1-T4 decided
for `index_folder`, whose tests pin it). Each file also stores its own
`required_labels` (the root's are added in the records); `sha256` is `null`
when unknown (a pending file, or a file whose bytes were not retained when
the table had to be rebuilt). `moved_from` is the path the file was last
moved from. The state is trusted only when its `generation` and
`analyzer_id` equal the current `MANIFEST`'s; otherwise (a crash between the
manifest and the state write, `docs/publication-recovery.md`) the writer
rebuilds the file table from the generation itself: records grouped by path,
hashes and sizes from the source section where the root retains bytes,
`pending` and `unchunked` from `meta`, labels from the records minus the
root's. Version 1 still loads. Parsing is typed (no JSON object maps): a 10k
file state is read on every call.

## 6. `apply_changes` (host-fed changes)

C ABI: `char *ss_apply_changes(const char *dir_path, const char *changes_json, const char *opts_json)` (allocates the index writer, publishes one new generation, returns a report; `ss_free` the result). Dart: `SearchSimpli.applyChanges(dir, changes, opts)` static. CLI: `searchd apply <dir> --changes <file.json> [--expect-generation N]`. RPC/MCP: method `apply_changes` only when the server was started with `--allow-write`.

Request:

```json
{"expect_generation":17,
 "roots":[{"root_id":"r-6f1a","label":"School","kind":"icloud","required_labels":["cloud-ok"],"retain_source":true}],
 "changes":[
  {"op":"add",    "root_id":"r-6f1a","path":"week-07.md","size":4211,"mtime_ms":1761900000000,"sha256":"…","content_base64":"…"},
  {"op":"change", "root_id":"r-6f1a","path":"lists/words.txt","size":210,"mtime_ms":1761900100000,"file":"/abs/path/words.txt"},
  {"op":"remove", "root_id":"r-6f1a","path":"old.md"},
  {"op":"move",   "root_id":"r-6f1a","path":"week-7.md","moved_from":"week-07.md"},
  {"op":"pending","root_id":"r-6f1a","path":"week-09.md","size":5000},
  {"op":"remove_root","root_id":"r-old"}
 ]}
```

Rules (review finding 6, CAP-19 FR-20/FR-21):
- Exactly one of `content_base64` (strict base64, decoded bytes must be valid UTF-8 after an optional BOM, ≤ `max_file_bytes`) or `file` (an absolute path under a root the request declares with `kind: local` and that the engine was opened with `--allow-file-reads`; symlinks refused) for `add`/`change`; `sha256` optional for `content_base64` (the engine computes and, if given, verifies: mismatch → the change is rejected as `hash_mismatch`), required for `file` (verified after reading).
- Batch caps: ≤ 10,000 changes and ≤ `max_total_bytes` (512 MiB default) of decoded content per call; over → `SS_ERR_CAPACITY`, nothing published.
- `expect_generation` must equal the current generation, else `SS_ERR_INVALID_ARGUMENT` `"stale: generation is M"` and nothing is published (the host re-reads status and retries).
- Ordering: changes are applied in array order per `(root_id, path)`; a later op on the same path replaces an earlier one in the same batch; the report lists `conflicts` for such pairs.
- Rename detection: within one batch, a `remove` of path A and an `add` of path B whose computed sha256 equals A's recorded hash becomes a `move` A→B, recorded as `moved` (chunks copied with new ids). If several removed paths share the hash, pairing is by sorted path order (deterministic) and the report says `ambiguous_moves`. An explicit `move` whose `moved_from` is unknown is applied as `add` requires content → rejected `move_source_unknown`.
- `pending` keeps any previous indexed chunks of that path? **No**: a `pending` replaces the file's chunks with none and lists the file by name (status `pending`); the host sends `add` when the bytes arrive. (The review asked for a decided stale/pending policy; this is it: a pending file is never answered from stale content.)
- `remove_root` drops the root's files, chunks, statistics and state.
- One writer at a time (`WRITER.LOCK`); publication is atomic as today; the lexical and source sections are rebuilt whole per generation (NFR-12 allows it).

Report:

```json
{"generation":18,"added":1,"changed":1,"removed":1,"moved":1,"pending":1,"unchanged":37,
 "too_large":0,"too_large_paths":[],"unreadable":0,"unreadable_paths":[],"rejected":[{"path":"x.md","reason":"hash_mismatch"}],
 "conflicts":[],"ambiguous_moves":[],"roots_removed":1,"budget_exhausted":0,"bytes_read":9341,"ms":41}
```

`index_folder` becomes a walk that produces this request internally (`file`
changes, one root, `retain_source` per opts) so one code path writes
generations.

**S3-T3 amendments** (each one is tested in `zig/src/apply_test.zig` and
`tests/test_folders.py`; the C ABI, Dart, CLI and RPC surfaces above are
S3-T4's, the core entry point is `apply.applyChanges(dir, request_json,
options)`):

- *Roots.* A request may declare a root with `path` (an absolute folder, no
  `.`/`..` component, only for `kind: local`); a `file` change needs its own
  root declared in the same request with `kind: local` and a `path`, and the
  file must lie under it. A new root needs `kind`; `label` defaults to the
  id. Root ids are 1–64 bytes of `[A-Za-z0-9._-]`; `r-legacy` is reserved for
  `index_folder` and cannot be declared by a host. Re-declaring a root
  updates its label, kind, labels and retention (records are relabelled).
- *Per-file labels.* `add`/`change`/`pending` take an optional
  `required_labels` (the file's own; absent means none); the review's "two
  label domains inside one root" needs them, §6's example had none.
- *Whole-request refusals* (nothing is published, nothing is read):
  `invalid_argument` for invalid JSON, an unknown field anywhere (a
  `principal_labels` field anywhere gets its own message: the scope comes from
  the trusted caller), an unknown op, an unsafe path (`..`, `.`, an empty
  component, a leading `/`, NUL, a line break, over 4,096 bytes), an
  undeclared root, not exactly one of `content_base64`/`file`,
  `content_base64` that is not strict base64 (standard alphabet, padded,
  canonical: it must equal the encoding of what it decodes to), `sha256` not
  64 hex digits, `file` without `sha256`, `file` with file reads disabled,
  `file` not absolute or outside its root, a symlink below the root's
  folder (every component under it is checked with `lstat`, and the file is
  opened without following a link), a root id colliding with a legacy path, more
  than 64 labels on a file once its root's are added, and a stale
  `expect_generation`; `capacity` for more than 10,000 changes or more than
  `max_total_bytes` of decoded content (counted from the base64 and the
  files' sizes before anything is decoded or read). The generation check
  comes before every other refusal, under `WRITER.LOCK`, which is held from
  the check through the publication.
- *Per-change outcomes* (the rest of the batch is published): `rejected`
  entries `{root_id, path, reason}` with `hash_mismatch`, `size_mismatch` (a
  supplied `size` that differs from the bytes), `invalid_utf8` (decoded
  content), `move_source_unknown`, `root_removed` (a change after
  `remove_root` of a root this request does not declare) and
  `path_collides_with_root`; `too_large` (content or a file over
  `max_file_bytes`: its chunks are dropped, as S1-T4 tombstones a file);
  `unreadable` (a `file` that cannot be read, or is not UTF-8: its previous
  chunks are kept). `too_large_paths`, `unreadable_paths` and
  `budget_exhausted_paths` hold `{root_id, path}` objects.
- *Semantics made exact.* `change` of an unknown path adds it; `remove` of
  an unknown path and `remove_root` of an unknown root are no-ops; an `add`
  or `change` whose bytes hash to the file's recorded hash with the same
  chunker keeps its chunks (counted `unchanged`, the bytes retained again).
  `conflicts` lists one `{root_id, path, replaced, by}` per later op on a
  path an earlier op of the batch touched (a `move` touches both its paths).
  Rename detection pairs only within one root, only `remove`s of files that
  were indexed with a known hash and `add`/`change`s of paths that were not
  indexed before the batch; per `(root, hash)` both sides are sorted by path
  and paired in order; `ambiguous_moves` has one `{root_id, sha256, from,
  to, pairs}` entry for every hash with more than one candidate on either
  side. A detected move copies the chunks (re-keyed) when the chunker is the
  same and re-chunks the bytes it has otherwise. An explicit `move` takes no
  content and keeps the file's chunks, labels and status (a pending file
  moves pending). `index_folder`'s walk does not detect renames: its report
  has no `moved`, so a renamed file stays `removed` + `added` as S1 tests pin.
- *Counts.* `added`: indexed after, not indexed before (a pending file that
  arrives is `added`); `changed`: indexed before and after, re-chunked;
  `unchanged`: indexed before and after, not re-chunked (untouched files
  included; `index_folder` counts its own root only); `moved`: moved in this
  batch; `pending`: set pending in this batch; `removed`: indexed or pending
  before and gone by a `remove`.
- *Report.* §6's fields plus `analyzer_id`, `budget_exhausted_paths`,
  `documents`, `terms`, `postings` and `recovered` (when the previous
  generation lost its `MANIFEST` or a section the writer starts from an
  empty table, like `index_folder --update`, and says so: a host must then
  send its files again).
- *Recovery.* A failure after the manifest is published and before the state
  is written leaves the new generation readable; the next call rebuilds the
  table from it (§5) and reports retried, identical content as `unchanged`.

## 7. Scope, labels and statistics

A request's **scope** = the roots named (default all) ∩ the caller's trusted
`principal_labels` against each root's `required_labels` **and** each
document's own `required_labels` (v3 semantics kept; a root's labels add to the
document's). The scope is applied before candidate generation on every
operation (`search_knowledge`, `find`, `read_chunk`, `read_span`, `outline`,
`list_files`, `list_sources`, `index_status`, `evidence`, MCP resources).

Statistics: BM25 uses document count, average length and document frequency
computed **over the visible scope** (review finding 3, CFT-20): per-root
statistics are precomputed per generation; a scope that hides documents within
a root by label uses the per-label-set statistics precomputed for each distinct
`required_labels` set in that root (bounded: a root with more than 64 distinct
label sets falls back to exact counting at query time, measured). Prefix
expansion counts only terms that occur in at least one visible document.
`index_status` and `list_files` count only visible files; a hidden file is
indistinguishable from an absent one in every payload. Timing is measured in
S3-T3 (hidden vs absent) and disclosed, not promised equal.

**S3-T3 amendments.** A path prefix narrows candidates, not statistics (it
is a search constraint, not authorization; the Python reference's older
`search` still computes over the prefix-filtered set). A group is one root
and one distinct label field; groups hold the document count, total length
and per-term document frequency, built once per opened generation
(`snapshot_open.openScoped`). When nothing is hidden (no label in any record
and no root named, or every document visible) BM25 uses the index's own
values, bit for bit. Without precomputed groups (the RPC server and the C
ABI until S3-T4 wires a scope) a query whose principal cannot see every
labelled record counts its visible scope exactly at query time, one pass
over the documents. `index_status` reports `documents`, `terms`, `postings`,
`files`, `pending` and `pending_paths`, `roots` (with per-root counts),
`chunkers` (those visible documents use) and `has_source` (visible files
have retained bytes) over the scope; `read_span`/`outline` of a hidden file
answer the absent file's `not_found` message. The prefix-expansion hook for
S3-T2 is `scope.termVisible`. Measured timing: `docs/authorization.md`.
`find` over a scope is `service.ScopedService.find`: the roots mask joins
`find`'s label and prefix filter (candidates and prefix expansion), its BM25
goes through `scoring.CorpusStatistics` with the visible scope's count,
average length and a document-frequency provider, and the answer's
`pending_files` counts the scope's visible pending files. `truncated` is true
when a visible file was given to a writer but not indexed in full (too large,
unreadable, or over the run's byte budget): the manifest's `meta.skipped`
lists such files (`{root_id, path, size, required_labels, reason}`) until a
later change of the path; `index_status` carries the same `truncated`.
**S3-T2:** `find` takes its scope from the request's `path_prefix` and trusted
`principal_labels` (the existing filter), applied before candidates are
scored; prefix expansion counts a term only when one of its postings is in
that scope. BM25 in `find` is computed through `scoring.CorpusStatistics`
(document count, average length, and a per-term document-frequency provider);
the default is the whole generation, and S3-T3 plugs the visible-scope
statistics in there. `search_knowledge` is unchanged.

## 8. Read operations (JSON shapes)

All operations share `{"request":{…echo…},"generation":N,"scope":{"roots":[…],"labels_applied":true},"warnings":[…]}`.

`find`:

```json
{"query":"\"count me in\"","mode":"phrase","roots":["r-6f1a"],"path_prefix":null,"page_size":20,"cursor":null}
→ {"hits":[{"chunk_id":"…","root_id":"r-6f1a","path":"week-07.md","section_path":["Week 7","Dates"],
            "start_line":31,"end_line":34,"score":7.41,
            "snippet":"… band concert: count me in, Friday 6 …","snippet_offsets":[[16,27]],
            "match_offsets":[[112,123]]}],
    "files":[{"root_id":"r-6f1a","path":"week-07.md","hits":2}],
    "exact_match":true,"empty":false,"coverage":{"files":1,"sections":1},
    "truncated":false,"next_cursor":null,"pending_files":1}
```

`mode` ∈ `words | phrase | prefix`; a quoted query forces `phrase`, a trailing
`*` on the last token forces `prefix`, else the given mode. Hits are ordered
by score desc, then root_id, path, start_line (INV-08). Overlapping chunks
(the 3-line window overlap) that both match the same phrase occurrence are
deduplicated to the earlier chunk (the review's "overlap deduplication").
`cursor` is `"<generation>:<offset>"`; a cursor from another generation →
`SS_ERR_INVALID_ARGUMENT` `"stale cursor"`. `exact_match` is `null` unless mode
is `phrase`. `empty: true` means this page has no hits; `pending_files` and
`truncated` tell the caller the corpus may be incomplete (review finding 5,
CFT-23).

**S3-T2 amendments to `find`** (implemented in `zig/src/find.zig`, the Python
reference `search_platform/find.py`; no ABI, CLI or RPC surface until S3-T4):
- Each hit also carries `snippet_start` (CAP-19 FR-17: the snippet's start
  offset in `content`). The snippet is a plain substring of `content` (no
  `…` added), so `snippet_offsets` are `match_offsets` minus `snippet_start`.
  The example's snippet would read `"band concert: count me in, Friday 6"`.
  The window: of the windows of at most 240 codepoints that start at a
  match, the one covering the most distinct matched terms, then the most
  matches, earliest first; widened evenly; cut so it starts at a token start
  (or the text start) and ends at a token end (or the text end).
- `match_offsets`: one range per phrase occurrence (occurrences are
  non-overlapping, left to right: "the the" in "the the the" is one) or per
  matched token (words, prefix).
- Overlap deduplication, made exact: for two hits of one file whose line
  ranges overlap, the lines they share are the largest `j` (at most the
  overlap of the ranges) with the last `j` lines of the earlier chunk's text
  equal to the first `j` of the later one's (each stripped); the later hit is
  dropped when every one of its matches ends inside the lines it shares with
  an earlier **kept** hit. It applies to all three modes. `words` and
  `prefix` are chunk-local like `phrase`.
- `files` counts all hits (every page) in the order each file first appears
  in the ranking; `coverage` counts this page's hits; `truncated` is `false`
  and `pending_files` `0` until S3-T3 gives them a source.
- Refusals: `INVALID_ARGUMENT` for an empty query (nothing analyzable,
  `""` and `*` included), a `*` that ends any token but the last, `page_size`
  outside 1..100, invalid UTF-8, a malformed cursor, and `"stale cursor"`
  for another generation's; `CAPACITY` for `"re-index required: positions
  absent"` and `prefix "<p>" expands to more than 1000 terms`.

`outline`:

```json
{"root_id":"r-6f1a","path":"week-07.md"}
→ {"front_matter":{"start_line":1,"end_line":4,"fields":{"title":"Week 7"}},
   "headings":[{"level":1,"text":"Week 7","line":6,"end_line":40},{"level":2,"text":"Spelling","line":8,"end_line":22}],
   "lines":40,"chunker":"md-section-v1"}
```

**S3-T1:** a front-matter block whose inner lines are not all `key: value`
reports `fields: {}` plus `raw` (the inner lines joined by LF).

`read_span`: `{"root_id","path","start_line","end_line","context_lines"}` →
`{"start_line","end_line","text","context_before","context_after","byte_exact":true,"sha256":"…"}` (§4 limits).

`list_files`: `{"root_id?","path_prefix?","status?","page_size","cursor"}` →
`{"files":[{"root_id","path","size","mtime_ms","status","chunks","chunker"}],"next_cursor"}`.

`evidence` (existing) adds per item `section_path`, `neighbours:{prev:{chunk_id,start_line,end_line},next:{…}}`, `root_id`.

`index_status` adds `generation`, `roots[]` (visible), `pending`, `has_source`,
`has_positions`, `chunkers[]`.

Relation to CAP-16 (directory filename retrieval): `list_files` is a listing
with a prefix, not a ranked filename search; CAP-16's `search_field` channel
stays the way to find a file by name, and it inherits roots and scope from §7
when both land.

## 9. C ABI additions (contract 2.0.0)

```c
char *ss_find(ss_handle *h, const char *request_json);
char *ss_outline(ss_handle *h, const char *request_json);
char *ss_read_span(ss_handle *h, const char *request_json);
char *ss_list_files(ss_handle *h, const char *request_json);
char *ss_roots(ss_handle *h, const char *options_json);          // visible roots and their counts
char *ss_apply_changes(const char *dir_path, const char *changes_json, const char *opts_json);
```

All return a JSON string to `ss_free`, or NULL with `ss_last_error` set; error
codes unchanged (−1 … −7). `ss_query`/`ss_evidence` gain `roots` in
`options_json`. The ten v1 functions keep their signatures and behaviour.

## 10. Tool schemas and the skill document

`contracts/tools/<name>.request.schema.json` and `<name>.result.schema.json`
(JSON Schema 2020-12, `additionalProperties: false`) for `search_knowledge`,
`read_chunk`, `list_sources`, `index_status`, `find`, `outline`, `read_span`,
`list_files`, `apply_changes`. A test loads each schema and validates recorded
real responses from the fixture (§12) against it, using the repository's own
minimal validator (standard library only). `skills/folder-knowledge/SKILL.md`
sections: when to use which tool; the search → read → cite loop; how to quote a
span; the exact negative wording ("I found no matching indexed passages in the
selected folders" plus the pending/truncated caveat when the status says so);
never claim a fact without a `[n]` that maps to a returned hit; never call
`apply_changes`. Adapters (the consumer app, a Python example) wrap the schemas
into their provider's tool descriptor; the schemas themselves are
provider-neutral (review finding on FR-23).

## 11. MCP server

`searchd mcp <dir> [--roots a,b] [--labels l1,l2] [--allow-write] [--allow-file-reads]`.
Transport: stdio, newline-delimited JSON-RPC 2.0 as MCP specifies; the MCP
protocol revision is pinned in `zig/src/mcp.zig` as a constant and in the
server's `initialize` result (`protocolVersion`), chosen at build time as the
latest stable revision the conformance client implements; the task records
the exact string. Methods: `initialize`, `notifications/initialized`,
`ping`, `tools/list`, `tools/call`, `resources/list`, `resources/read`,
`resources/templates/list` (one template `search://{root_id}/{path}`). Tools:
the eight read tools by default (`search_knowledge`, `read_chunk`,
`list_sources`, `index_status`, `find`, `outline`, `read_span`, `list_files`);
`apply_changes` only with `--allow-write`. `tools/call` results carry the
canonical JSON of §8 as `structuredContent` and the same JSON serialized in one
`text` content block; parity with the RPC server is checked on the canonical
JSON after removing the transport envelope (review finding 4, CFT-22; CAP-13's
four-tool baseline is the server's `--baseline` mode, which lists only those
four). The scope (§7) comes from the command line, never from the client
(CAP-13's "no caller-supplied principals"). Adapter overhead p95 ≤ 5 ms over
the direct call (CAP-13's gate), measured in S3-T6.

## 12. Fixture and judgments (`fixtures/family-folder/`)

Invented content only. Layout: three roots `school/`, `home/`, `laptop/`
(≥ 40 files in all, ≥ 25 Markdown): front matter (YAML subset: `key: value`
strings only), ATX and Setext headings nested to depth 3, lists, two fenced
code blocks (one longer than `max_chars`), one file > 1 MB (generated,
deterministic), two files with identical content under different names, a
CRLF file, a file without a final newline, a file with a UTF-8 BOM, a file
with Tamil text, a file with repeated tokens ("the the"), an empty file.
`judgments.json`: version 2, the 13 UC-007 scenarios plus five phrase, five
prefix, five outline and five `read_span` cases, each with the expected
`{root_id, path, start_line, end_line}` set (phrase/prefix: the complete set
across all pages; `read_span`: the expected sha256 of the returned text).
`scripts/relevance_smoke.py` gains a `--pack family-folder` mode that runs them
through the Python reference and, when the native library is present, the Zig
engine, and prints the metrics named in UC-007. The fixture is frozen in
S3-T7 before S3-T2/T3 start (review finding 8).

## 13. Benchmark profile

Recorded once in S3-T2's Report and reused: machine (the Xcode Mac, chip and
memory as `system_profiler` prints them, macOS version), Zig 0.16.0
`ReleaseSmall` and `ReleaseFast` both, corpus = the existing 10k-file benchmark
generator's output with its sha256 plus the family-folder fixture, 5 warm-up
queries then 200 timed queries per mode, p50 and p95, three repetitions, peak
RSS from `/usr/bin/time -l`, segment sizes per section, retained-source bytes
separately. Before/after tables live in `docs/scale-benchmark.md`.

**S3-T2 (recorded):** MacBook Pro, Apple M5 Pro (18 cores), 48 GB, macOS
26.6.2 (25G83); Zig 0.16.0 `ReleaseFast` and `ReleaseSmall`; corpus
`scripts/gen_timing_corpus.py <dir> 10000` (10,000 Markdown files,
7,269,199 bytes, sha256 of the files concatenated in sorted path order
`3a520dd588fa34cb2bec9a15b12f7ad8a0fc3c0d5feebd4baba4ce49fed96e38`,
19,959 chunks) plus the family-folder fixture (three roots side by side,
998 chunks); the timer is `zig/src/find_bench.zig` (queries drawn from the
indexed chunks, 5 warm-up then 200 timed per mode, three repetitions); index
runs are three per build. NFR-10's "10k chunks" is measured at 19,959.
