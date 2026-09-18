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
file's chunks are pulled back out of the *previous* generation's already-built
postings (`reconstructTokensFromPostings`: walk each term's postings list and
reconstruct each document's token multiset from `term`/`term_frequency`)
instead of re-running the chunker and analyzer over the file's text again.
Chunking/tokenizing text is the expensive step this reuse skips (round-A/B
measured effect: `docs/tasks/S1-T1.md`, `docs/tasks/S1-T3.md`).

**The lexical index itself is still rebuilt from scratch every generation**
(`lexical_build.build` over the full retained + new document set). There are
no delta segments, no merge policy, and no query-time segment fan-out — see
"What this is not" below. This is deliberate: `docs/tasks/S1-T1.md`'s
round-A verdict found the old rebuild-heavy design's real cost was an
`O(vocabulary × tokens)` dictionary build, not the full-index-per-generation
shape; S1-T3 fixed the former with hash-map dictionaries and did not attempt
the latter.

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
  *this run*, every remaining candidate file is left untouched for this
  generation: its previous chunks (if any) are carried forward unchanged,
  and it is eligible again on the next run. This is reported as
  `budget_exhausted`, a field distinct from `unchanged` (a file whose hash
  genuinely matched the previous run) — the two used to be the same
  `skipped` number, which meant a caller could not tell "this run finished,
  nothing changed" from "this run gave up partway through" by the report
  alone (round-B non-blocking finding, `docs/tasks/S1-T3.md`).

A file that is merely **unreadable this run** (stat failure, a transient I/O
error, or invalid UTF-8) is a third, different outcome: it is counted under
`unreadable` (and named in `unreadable_paths`), but its previous chunks *are*
carried forward, exactly like `budget_exhausted` — availability is favored
over freshness for a file that might come back on the next run. The table:

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

### Fails closed on analyzer mismatch

`--update`/`opts.update: true` refuses to run (`error.AnalyzerMismatch`) if
`out_dir` already holds a generation published with a different
`analyzer_id`: mixing `analyzer-v1` (ASCII) and `analyzer-v2` (Unicode)
tokens in one lexical index would silently produce incoherent scoring rather
than a clean error.

### What this is not

- No delta segments, write-ahead log, background compaction, or query-time
  segment fan-out. The lexical index is rebuilt whole every generation; only
  the expensive per-file chunk/tokenize step is skipped for unchanged files.
- No vector/embedding reuse of any kind — this path never produces vectors
  (`embedding_model_id` is always `"none"`). The Python path below is where
  embedding reuse lives.
- No filesystem watcher, debounce, or connector change feed — every run is
  triggered explicitly (`searchd index --update` / `ss_index_folder`).
- No query-reader leases or generation garbage collection; superseded
  generation files become orphans exactly as a full rebuild's do
  (`docs/generation-lifecycle.md`).
- Crash recovery between a linked immutable section and the manifest swap
  has been exercised with a real `SIGKILL` mid-publication run against this
  exact code path (`docs/tasks/S1-T3.md`'s Report), recovered cleanly by the
  existing scanner and `generation_alloc.nextFreeGeneration`; there is no
  automated crash-injection *test* for it, only that one manual run.

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
