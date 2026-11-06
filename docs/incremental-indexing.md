# Incremental indexing and publication

Status (rewritten for S1-T4, `docs/tasks/S1-T4.md` criterion 4): the shipped,
tested incremental path is native — `searchd index --update` and
`ss_index_folder(..., "update": true)`, implemented in
`zig/src/indexer.zig`'s `indexFolderIncremental` (S1-T3,
`docs/tasks/S1-T3.md`). It reuses lexical work (tokenized chunks), not
embeddings: this path is lexical-only (`embedding_model_id: "none"`), same as
`searchd index`'s full rebuild. A separate, older Python-side incremental
path (`search.py index --incremental-from`) still exists for the
vector/embedding pipeline and is described at the end of this document; the
two are independent systems that happen to share the word "incremental".

## The native path: `searchd index --update` / `ss_index_folder`

```sh
searchd index ./my-notes --out .search/native-index --update
# {"generation":2,"analyzer_id":"analyzer-v2","added":0,"changed":1,
#  "removed":0,"unchanged":11,"budget_exhausted":0,"too_large":0,
#  "unreadable":0,"too_large_paths":[],"unreadable_paths":[],
#  "documents":12,"terms":233,"postings":410}
```

The same operation is exposed through the C ABI as
`ss_index_folder(dir_path, folder_path, "{\"update\":true}")`
(`zig/include/search_simpli.h`) and bound in Dart as
`SearchSimpli.indexFolder` (`bindings/dart/search_simpli/`).

### What "incremental" reuses

Every candidate file (same walk/extension/ignore rules as a full rebuild,
`indexer.collectCandidatePaths`) is still **read and SHA-256 hashed on every
run** — a hash requires the bytes — but only a file whose hash changed since
the last published generation is re-chunked and re-tokenized. An unchanged
file's chunks are carried as the previous generation's documents (S3-T2:
with their exact token ordinals and spans), not re-chunked or re-analyzed.

**What a generation carries and what it builds (S4-T11).** The sections a
generation writes are byte for byte what a full index of the same files
writes (tested after every step of `apply_test.zig`'s parity cases, by a
seeded randomized test in `incremental_indexing_test.zig`, and at 10,000
files by `scripts/s4t11_budgets.py compare`), but an unchanged file is not
rebuilt into them:

- *Lexical section.* `apply.buildPositionalMerged` builds only the changed
  files' documents fresh (the full-build path, `buildPositionalFresh`), then
  `mergeCarried` merges that small index with the previous generation's
  decoded one: the two dictionaries by bytes in one walk, each carried
  posting with its document number remapped and its term frequency and
  section-4 ordinal bytes unchanged (a whole term's run copied at once when
  no removed, moved or fresh document touches it), and each document's
  section-5 offset table copied. A previous term left with no posting drops
  out; a moved file's postings are re-sorted into their new place. Nothing
  is transposed back to tokens and nothing carried is re-sorted or
  re-encoded. A previous `HYBLEX01` generation (no positions) is still
  re-tokenized once, which upgrades it.
- *Source section.* An unchanged file's record (SHA-256, line map, encoding
  byte) is copied from the previous section (`source.carriedRecord`, its map
  bounded by its varints), which the writer opened and checked
  (`source.openTable` since S4-T14: the section checksum, computed once,
  against the manifest; the files table; each map's varint bounds; not each
  map against its bytes); its bytes are still copied whole, and only a fresh
  or changed file is hashed and scanned. The reader's per-call SHA-256 check
  (S4-T10) still catches a file whose bytes no longer match, and its
  per-file line-map check (S4-T14) a carried map that disagrees with its
  bytes, for that one file.
- *Filename sections (S4-T13).* When the update keeps every path, in order,
  with its labels (compared with the previous generation's body documents),
  the previous `filename-lexical-N.hyblex` is copied byte for byte after its
  size, checksum (against its header and the manifest), kind and counts are
  checked, and only the catalog is re-encoded (`filename_field.carryLexical`,
  `buildCarried`; `docs/filename-field-format-v1.md`). A rename, add, remove
  or label change, or a previous section that fails a check, takes the full
  build.
- *Documents section, state, manifest.* Encoded whole from the carried and
  fresh records, as before.

**The writer's open of the previous generation (S4-T13, S4-T14).** `apply.openPrevious`
computes each section's checksum once and compares it with the manifest's,
decodes the documents section, decodes the lexical section without its
positions walk, and opens the source section with its files table walked and
each line map bounded by its varints (S4-T14; S4-T13 still checked every map
against its bytes).
The positions walk was a second check of bytes the checksum covers: a
carried posting's section-4 bytes are copied, not interpreted, by
`mergeCarried`, and a positions run that a wrong writer could still have
sealed is refused by the merge's checked walk (`InvalidLexicalSection`) or by
the new section's own validation (`InvalidPositions`) before anything is
published. S4-T13 kept the line-map walk, about 10.4 ms of the open's 21 ms
on the 10,000-file corpus, because the reader then refused a section with one
bad map whole. Since S4-T14 the reader checks a map where it reads the file
and refuses only that file, so the walk went (`docs/source-section-v1.md`,
"The writer's guard (S4-T13, S4-T14)"): `open_previous` 20.7 → 10.9 ms off
and 10.7 on, one changed file 68.4 → 59.0 ms off and 78.0 → 69.2 ms on (p50
of ten, `ReleaseSmall`).

**The documents pass and `loadPrevious` (S4-T16).** Every generation `buildGeneration` has written since S3-T3 (`b18c2bd`), including `searchd index`, lists its files in record-path order with each file's records together, and writes its recovery state in the same order; `import-json` generations may be unsorted and take the fallback. The writer relies on that, checking it every time:

- *The previous documents by range.* `PreviousDocs.build` makes one pass over the decoded records: each path's records are one range `[first, end)` when consecutive runs ascend strictly by bytes and no path starts a second run. A generation that breaks either keeps the list of indices per path the writer used before, with the same results.
- *`loadPrevious`.* The work table and `work.initial` are sized for the state's files and filled in the same step. While the state's records ascend strictly, one forward walk over the runs answers whether a record has previous chunks (compares, not a hash lookup per record). When that walk matched every previous path, the loop that rebuilds files the state does not name is skipped: every pass of it would have stopped at its first check. A state that misses a path, or one out of order, runs the loop and looks a record up only when its entry has no chunker.
- *The order of the files.* When the state's records ascend, each file still under the key and the very record slice the state put takes its state position; the batch's added, moved and re-put files are sorted and merged in (`orderedFiles`). Keys are unique, so this is the sort of every file, which any other state still takes.
- *The source section.* A file looked up under its own path advances one cursor over the previous source section's table (both in path order) instead of a binary search per file; a moved or renamed file's previous path, and a section opened without record offsets, keep `Section.find`.
- *The documents section.* `segment.encodeAllocV4` validates every record once, sizes an exact buffer and writes (the writer had validated every record twice, through `encodedLengthV4` and again inside `encodeV4`). Every record is still encoded from its fields; carrying an unchanged record's bytes was measured and not taken (below 1 ms to gain at 10k).
- *What it saved* (10,000-file timing corpus, one changed file, `ReleaseSmall`, `scripts/s4t4_budgets.py profile`, p50 of ten, two interleaved runs, stage timers on in every build): `load_previous` 5.64–5.73 → 1.95–2.01 ms, `build_documents` 10.73–10.84 → 2.96–3.00 ms, the documents encode 3.96–4.08 → 3.67–3.72 ms (the three together 20.41–20.56 → 8.61–8.73 ms); the call's stages 58.41–58.53 → 46.77–46.95 ms with the filename channel off and 67.32–68.10 → 55.70–55.89 ms on (`docs/tasks/S4-T16.md`).

On S4-T1's 10,000-file timing corpus (one changed file, `ReleaseSmall`,
`scripts/s4t4_budgets.py profile`, p50 of ten) `build_lexical` went from
33.8 ms to 4.9 ms and `encode_sections` from 35.7 ms to 23.1 ms (source line
maps 10.9 → 0.35 ms, SHA-256 2.7 → 0.03 ms); the whole call from 122.1 ms to
77.8 ms with the filename channel off and from 140.0 ms to 96.0 ms with it
on (`scripts/s4t4_budgets.py budgets`, p50 of five; `docs/tasks/S4-T11.md`).
What remains is mostly reading and checking the previous generation (about
24–26 ms), building the documents (about 10 ms), encoding and validating the
lexical section (about 16 ms) and the publish. There are still no delta
segments, no merge policy and no query-time segment fan-out — see "What
this is not" below.

Per-file state (path, SHA-256 hex, byte size) persists beside `MANIFEST` in
`<dir>/INDEX-STATE.json` (`incremental_state.zig`), written only *after* the
new generation has already published successfully through the same atomic
path a full rebuild uses (`lifecycle.publishSerialized` →
`publication.writeAtomicFile`, `docs/publication-recovery.md`) — a crash
between publish and this write just costs the next run its skip
optimization for every file, never correctness (`incremental_state.zig`'s
doc comment). `lifecycle.scan`'s recovery scanner knows this file by name
and never counts it as an operator-facing anomaly
(`docs/generation-lifecycle.md`).

A full rebuild (`searchd index` without `--update`, `ss_index_folder` with
`"update": false`/omitted, `indexer.indexFolder`) writes `INDEX-STATE.json`
too, for exactly the files it indexed (S1-T5 criterion 2) — so the *first*
`--update`/`opts.update: true` run after a full rebuild reports every
untouched file `unchanged`, not `added`; before this it re-read and
re-chunked everything the very next run and called that `added`, which is
what the round-B non-blocking finding (`docs/tasks/S1-T4.md`) flagged. A file
left out of a full rebuild by `max_total_bytes` (see Caps below) gets no
state entry — nothing was read for it this run — so it looks new to the
next `--update` the same as if the folder had just grown that file.

### Caps, and why the report has both `unchanged` and `budget_exhausted`

Two independent caps, both overridable (`--max-file-bytes`/
`--max-total-bytes`, or `opts.max_file_bytes`/`opts.max_total_bytes` on
`ss_index_folder`; defaults 10 MiB / 512 MiB):

- **`max_file_bytes`** — a file larger than this is never read. It is
  **tombstoned**, not carried forward: counted (and named, in
  `too_large_paths`) under `too_large`, its `INDEX-STATE.json` entry is
  dropped, and any chunks it contributed to a previous generation do not
  appear in the new one. This is a deliberate policy choice, the same one a
  deleted file gets, not an accident.
- **`max_total_bytes`** — once this many bytes have been read from disk in
  *this run*, every remaining candidate file is left out of this generation
  and reported as `budget_exhausted`, a field distinct from `unchanged` (a
  file whose hash genuinely matched the previous run) — the two used to be
  the same `skipped` number, which meant a caller could not tell "this run
  finished, nothing changed" from "this run gave up partway through" by the
  report alone (round-B non-blocking finding, `docs/tasks/S1-T3.md`). On
  `--update`/`opts.update: true` (`indexFolderIncremental`) a left-over
  file's previous chunks (if any) are carried forward unchanged, and it is
  eligible again on the next run. A full rebuild (`indexFolder`, S1-T5
  criterion 1) enforces the same cap but has no previous generation to
  carry anything forward from: a left-over file there is simply absent from
  the new generation — the same outcome as a file over `max_file_bytes`,
  just reported under a different field so a caller can still tell "skipped
  for good, over the cap" from "skipped for now, try `--update` again".

A file that is merely **unreadable this run** (stat failure, a transient I/O
error, or invalid UTF-8) is a third, different outcome: it is counted under
`unreadable` (and named in `unreadable_paths`), but its previous chunks *are*
carried forward, exactly like `budget_exhausted` — availability is favored
over freshness for a file that might come back on the next run. The
"Previous chunks" and "State entry" columns below describe `--update` runs;
a full rebuild has neither to keep. The table:

| Outcome | Counted as | Previous chunks | State entry |
|---|---|---|---|
| Hash unchanged | `unchanged` | kept (reused, not re-chunked) | kept (re-appended as-is) |
| Left over by `max_total_bytes` | `budget_exhausted` | kept | kept |
| Stat/read/UTF-8 failure this run | `unreadable` | kept | kept |
| Over `max_file_bytes` | `too_large` | **dropped** | **dropped** |
| No longer present in the walk | `removed` | dropped | dropped |
| New or hash changed | `added` / `changed` | re-chunked | replaced |

Every one of `too_large`/`unreadable` now comes with a path array
(`too_large_paths`/`unreadable_paths`) rather than a bare count — S1-T4
criterion 3.

### Deletion, including the last file

A path that was previously indexed but no longer appears in the walk is
tombstoned and counted under `removed`. This includes the case where the
folder's **last** indexable file is deleted, or the folder was empty to
begin with (no candidate files at all): both publish an empty generation (0
documents/terms/postings) instead of failing. Before S1-T4 this returned
`error.NoDocuments`, which meant a folder that lost its last file could never
be updated again — the empty generation is just as real and queryable as any
other, and a file re-added later publishes normally on top of it.

### A `MANIFEST` whose section is missing: self-heal (S2-T5)

If `MANIFEST` exists but a section it names is missing or unreadable (a lost
file, or a crash that left a `MANIFEST` without its sections), `--update` /
`ss_index_folder` with `"update": true` does **not** treat that as "no
previous index" while trusting `INDEX-STATE.json` (which would mark every file
unchanged and publish an empty generation). It discards the state, re-indexes
every file, publishes a full next generation, and the report JSON carries the
additive field `"recovered": "missing_section"` (absent otherwise). A phone
with no human to delete the directory heals itself on the next import.

### A missing `MANIFEST` with `INDEX-STATE.json` present (S2-T12)

With no `MANIFEST` there is no previous engine, so the state file's "every file
unchanged" has nothing to refer to. `INDEX-STATE.json` is **not loaded**: every
file is re-indexed, a full generation is published, and the report carries
`"recovered": "missing_manifest"`. Before this, such an update published an
empty generation with exit 0 (and pruned older complete generations when
`keep_generations` was set). A directory with no `MANIFEST` **and** no state
file is simply new, and reports no `recovered`. An update publishes zero
documents only when the folder holds zero indexable files (`"documents": 0`,
no `recovered`). The one exception is a double fault: if the folder is empty
**and** a recovery was needed (`MANIFEST` or a section lost), the report says
both, `"documents": 0` with `recovered`, because the lost `MANIFEST` or
section is still worth knowing about.

Values of `"recovered"` (the field is absent on an ordinary run):

| Value | Meaning | Cost |
| --- | --- | --- |
| `missing_section` | `MANIFEST` exists but a section it names is missing or unreadable | every file is read, chunked and hashed again: the cost of a full index, not of an update |
| `missing_manifest` | no `MANIFEST`, but `INDEX-STATE.json` exists | same full re-index; with `keep_generations`, older generations are pruned only after the new full generation is published |

A corrupt `MANIFEST` or a checksum-failing section still fails with its own
error and publishes nothing. Dart: `IndexFolderReport.recovered`
(`IndexRecovery`, with an `unknown` fallback) and `recoveredRaw`.

### Fails closed on analyzer mismatch

`--update`/`opts.update: true` refuses to run (`error.AnalyzerMismatch`) if
`out_dir` already holds a generation published with a different
`analyzer_id`: mixing `analyzer-v1` (ASCII) and `analyzer-v2` (Unicode)
tokens in one lexical index would silently produce incoherent scoring rather
than a clean error.

### What this is not

- No delta segments, write-ahead log, background compaction, or query-time
  segment fan-out. Every generation still writes whole sections (one
  lexical, one source, one documents section); an unchanged file is not
  re-chunked or re-tokenized, and since S4-T11 its postings, positions,
  offsets and source record are carried into them, not rebuilt (above).
- No vector/embedding reuse of any kind — this path never produces vectors
  (`embedding_model_id` is always `"none"`). The Python path below is where
  embedding reuse lives.
- No filesystem watcher, debounce, or connector change feed — every run is
  triggered explicitly (`searchd index --update` / `ss_index_folder`).
- No query-reader leases. Superseded generation files stay on disk exactly as
  a full rebuild's do unless the caller opts in to `keep_generations: N`
  (S2-T5; `docs/generation-lifecycle.md`).
- Crash recovery between a linked immutable section and the manifest swap
  has been exercised with a real `SIGKILL` mid-publication run against this
  exact code path (`docs/tasks/S1-T3.md`'s Report), recovered cleanly by the
  existing scanner and `generation_alloc.nextFreeGeneration`; there is no
  automated crash-injection *test* for it, only that one manual run.

### Chunkers and retained source (S3-T1)

Since S3-T1 a generation records which chunker made every chunk
(`md-section-v1` for `.md`/`.markdown`, `line-window-v1` for the rest;
[`manifest-format-v2.md`](manifest-format-v2.md),
[`segment-format-v4.md`](segment-format-v4.md)) and keeps every indexed file's
original bytes in a source section ([`source-section-v1.md`](source-section-v1.md)).
An update therefore:

- re-chunks a file whose bytes are unchanged when the chunker its extension
  selects differs from the one that made its previous chunks (a generation
  written before S3-T1 chunked Markdown by line windows), and reports it under
  `changed`;
- retains the bytes it read for every file it keeps; a file it carries without
  reading (unreadable this run, or over the run's byte budget) keeps its bytes
  from the previous source section when they were there, and its records are
  re-pointed at the new section;
- treats a lost `source-N.hybsrc` like a lost document or lexical section:
  `recovered: "missing_section"` and a full re-index.

The Python reference records the same per-chunk fields (`section_path`,
`heading_line`, `chunker`) and adds the Markdown chunker to its `chunking`
contract, so an index saved before S3-T1 no longer matches it and an
incremental build from it is refused with "chunker contract does not match"
(a full build is needed once).

### Roots, host-fed changes and INDEX-STATE v2 (S3-T3)

Since S3-T3 every generation is written by one core function,
`apply.applyChanges` / `apply.applyBatch` (`zig/src/apply.zig`;
[implementation §5–§6](folder-knowledge-implementation.md)). A request names
roots (`root_id`, `label`, `kind` local/icloud/host, `required_labels`,
`retain_source`, and for a `local` root the absolute `path` its `file`
changes must lie under) and up to 10,000 changes: `add`/`change` with exactly
one of strict `content_base64` or a confined `file` (with its `sha256`),
`remove`, `move` (`moved_from`), `pending` (a file named before its bytes
arrive: no chunks, listed by name) and `remove_root`. The engine checks
`expect_generation` first (`"stale: generation is M"`), refuses a malformed
or over-cap request whole, applies the changes in array order per path
(`conflicts`), pairs equal-content removes and adds into moves (sorted by
path, `ambiguous_moves`), publishes one generation through the same atomic
path as before (documents, lexical and source sections bound by the
manifest, with the roots, pending, unchunked and skipped files in its
`meta`), then writes `INDEX-STATE.json`.

`index_folder` is now a walk that builds such a batch: one `local` root
`r-legacy` (whose records keep their bare relative paths, so ids and
citations are unchanged), one `change` per candidate file read through the
walked folder, every root file the walk no longer sees removed, a byte budget
that leaves files `budget_exhausted` instead of refusing, and no rename
detection (its report has no `moved`; a rename stays `removed` + `added`).
Every report field above is unchanged, and so is each outcome in the table:
an unchanged hash keeps the chunks, a too-large file is tombstoned, an
unreadable or left-over file keeps its previous chunks. A `--update` over an
index that also holds host roots leaves them untouched and reports on its own
root only; a full rebuild (`--update` absent) starts a fresh index.

`INDEX-STATE.json` is version 2: `state_version`, `generation`,
`analyzer_id`, the roots, and per file `root_id`, `path`, `size`, `mtime_ms`,
`sha256` (null when unknown), `status` (`indexed` or `pending`), `chunker`,
`chunks`, `moved_from` and the file's own `required_labels`. Version 1
(entries `{path, hash, size}`) still loads, as root `r-legacy`. The state is
trusted only when its generation equals `MANIFEST`'s; after a crash between
the publication and the state write the writer rebuilds the file table from
the generation (hashes from the retained source), so a retried batch still
reports unchanged files as `unchanged`.

What an update costs now: the previous generation is read once (each
section's checksum computed once), carried documents keep their postings,
ordinals and offsets without being re-tokenized (`buildPositionalMerged`
yields the same bytes as a fresh positional build), and only changed files
are chunked and analysed; the lexical and source sections are still
rewritten whole (NFR-12 allows it). Measured on the 10k corpus (S3-T3
Report): one changed file 163 ms (ReleaseFast) and 215 ms (ReleaseSmall);
a full index through `apply_changes` 0.33 s / 144 MB peak.

## The Python path: `search.py index --incremental-from`

Separate, older system for the Python vector/embedding pipeline — still
real and still runs (see the root [README](../README.md)'s "Reuse unchanged
extraction and vectors" example), but not the same code, and not what
`searchd`/`ss_index_folder` use.

```sh
python3 search.py index ./knowledge \
  --incremental-from .search/index.previous.json \
  --out .search/index.next.json

python3 export_zig.py .search/index.next.json --generation 5 --out /tmp/generation-5.json
cd zig
zig build run -- import-json /srv/search /tmp/generation-5.json
```

The export writes `"analyzer_id": "ascii-alnum-v1"` unless given
`--analyzer analyzer-v2` (contract 1.1.0), in which case `import-json`
tokenizes with the same Unicode analyzer as the native path above.

Python reuses extracted chunks and vectors for unchanged files (matched by
SHA-256 content hash, the same idea as the native path above but computed
and stored independently); Zig still constructs a complete document/vector
and lexical section and atomically publishes it as one new generation
through `import-json` — there is no equivalent of the native path's
`--update` at the Zig layer here, because this route always hands Zig a
complete interchange document.

Incremental reuse fails closed if root, chunker, vector mode, neural model
id, or dimensions differ from the previous index; older indexes without
source hashes require one fresh build before they can become an incremental
base. For every current file: read bytes and hash; if the hash matches,
reuse extracted chunks and vectors; if changed or new, re-chunk/tokenize/
vectorize; recalculate required access labels even for reused content; omit
paths no longer present. The build report distinguishes reused, changed,
added, deleted, stale, relabeled, and newly embedded work.

**Model-specific reuse behavior:**

- **No vectors:** unchanged extraction is reused.
- **Hash mechanics:** unchanged stored vectors are reused; changed chunks
  recalculate locally.
- **Neural:** only changed/new chunks are sent as one document batch. A
  no-change or ACL-only build makes zero document-embedding calls, although
  the current CLI still initializes the provider and runs compatibility
  probes.
- **PPMI:** extraction can be reused, but any corpus content
  addition/change/deletion retrains the complete model and recomputes every
  vector because vocabulary axes and weights are corpus-global. A no-change
  build reuses the exact prior model.

**Read failures and deletion safety (Python path only):** if an existing
file is still present but temporarily unreadable or invalid UTF-8, the
Python incremental builder retains its prior chunks and hash, marks it
`stale`, and records the error — the native path's `unreadable` outcome
above was modeled on this same policy. A path that is truly absent is
deleted from the next index.

**What remains unimplemented, Python side:** no filesystem watcher or
connector change feed; no WAL/delta segments/tombstone file/background
compaction; no ACL-only segment patch (relabeling still publishes a full
snapshot); no generation-aware incremental interchange stream; no
query-reader leases or safe obsolete-generation deletion; provider
initialization happens before incremental compatibility is established, so
a no-change CLI run still pays model startup/probe cost; no configurable
policy for stale unreadable files (fixed at "retain and mark stale").
