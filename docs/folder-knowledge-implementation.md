# Folder knowledge — implementation details (CAP-19, S3)

Status: design (2026-10-31); §1, §2 and §4 implemented by S3-T1 with the
amendments marked **S3-T1** below (formats: [`manifest-format-v2.md`](manifest-format-v2.md),
[`segment-format-v4.md`](segment-format-v4.md), [`source-section-v1.md`](source-section-v1.md)).
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

Section files: `documents-N.hybseg` (v4, §2), `lexical-N.hyblex` (v2, §3),
`source-N.hybsrc` (v1, §4), `MANIFEST`, `INDEX-STATE.json` (v2, §5),
`WRITER.LOCK`. Publication keeps `lifecycle.publishSerialized` →
`publication.writeAtomicFile` and writes `INDEX-STATE.json` **after** the
manifest, as today. This is the implemented S3-T1 desktop behavior only:
segments are coherent, but mutable INDEX-STATE is not an atomic state commit.
Before S3-T3 ships host-fed changes, publish immutable `state-N.json` before
MANIFEST, bind its filename, byte length and SHA-256 in the manifest metadata,
and fsync all sections and state before replacing MANIFEST. Readers/writers
load only that generation's bound state; `INDEX-STATE.json` becomes a
best-effort compatibility cache, never authority for host-fed mutations.
An absent or corrupt bound state fails closed for writes; never reconstruct
pending/empty/unreadable files or labels by scanning chunks. Desktop v1/v2
indexes without bound state may migrate by a full authorized folder walk;
host-only indexes require explicit host replay before mutation. A failure
after MANIFEST publication may have committed: status exposes the committed
generation, stale retries publish nothing, and callers inspect/reconcile it.
Retention/pruning includes immutable state and preserves held generations.

**Cross-branch format ruling:** S3-T1's implemented HYBMAN02 is the 104-byte
layout in `manifest-format-v2.md`. The unmerged CAP-16 branch independently
uses HYBMAN02 for a 136-byte filename-channel layout. Those formats are
incompatible despite sharing magic/version. Preserve main's v2 unchanged;
the combined filename/source format must use a new HYBMAN03/version 3 with
an explicit header length, section descriptors and checksums. Before CAP-16
integration, freeze the full v3 table and test v1, main-v2, filename-v3 and
combined-v3. Existing CAP-16 draft-v2 artifacts require a separate-directory
rebuild; do not guess layout from file length, silently decode them as main
v2, or merge the conflicting decoder. S3-T3's bound state can use validated,
checksummed v2 meta fields; if a fixed header extension is needed it uses v3.
The filename-search branch must rebase onto this main-v2 baseline before
its packaged-native rebuild.

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
re-chunked: the text and section fields are copied).

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
defaults.

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
- Root identities, filesystem handles/base paths, label requirements and write permissions come from trusted host configuration. A request cannot create a local filesystem grant, widen its authorized roots, remove another scope's root or weaken existing required labels. Untrusted tool requests cannot change root policy. Resolve and open file paths relative to a trusted root handle without following symlinks in any component; verify the opened file itself (not a separate pre-check), and hash the same bytes used for indexing. Test forged roots, policy downgrades, cross-root moves and symlink swaps. New root provisioning is a separate trusted host operation.
- Exactly one of `content_base64` (strict base64, decoded bytes must be valid UTF-8 after an optional BOM, ≤ `max_file_bytes`) or `file` (an absolute path under a trusted host-configured root with `kind: local` and that the engine was opened with `--allow-file-reads`; symlinks refused) for `add`/`change`; `sha256` optional for `content_base64` (the engine computes and, if given, verifies: mismatch → the change is rejected as `hash_mismatch`), required for `file` (verified after reading).
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
