# Incremental indexing and publication

Status: content-hash extraction and embedding reuse are implemented in Python; the resulting complete corpus is still published as a new immutable Zig snapshot.

## Three useful levels

### Option A — full rebuild

```sh
python3 search.py index ./knowledge --out .search/index.json
```

Every selected file is read, chunked, and vectorized. This is the smallest understandable option and remains appropriate for personal folders where rebuild time is comfortably inside the freshness target.

Advantages: few states, easy recovery, easy reproducibility. Cost: repeated extraction and neural inference even when nothing changed.

### Option B — reuse work, publish a full snapshot

Implemented now:

```sh
python3 search.py index ./knowledge \
  --vector-mode neural \
  --incremental-from .search/index.previous.json \
  --out .search/index.next.json

python3 export_zig.py .search/index.next.json --generation 5 --out /tmp/generation-5.json
cd zig
zig build run -- import-json /srv/search /tmp/generation-5.json
```

Python avoids repeated extraction and embedding; Zig still constructs complete document/vector and lexical sections and atomically selects them through a new manifest.

This middle option is deliberately strong: it reduces the most expensive model work without yet introducing query-time segment fan-out, tombstones, merge policy, or partial-publication recovery states.

### Option C — delta segments and compaction

Not implemented yet. A higher-update-rate engine would append operations to a write-ahead log, build small immutable document/lexical/vector delta segments, record tombstones, publish a manifest referencing several segments, and compact them in the background. Snapshot readers or epochs must prevent old segment deletion while queries still borrow them.

This complexity is justified only when Option B violates measured freshness, write amplification, or storage budgets.

## Reuse contract

Each reference index now records:

- root path;
- chunker id and parameters (`line-window-v1`, maximum characters, overlap lines);
- vector mode and exact embedding model identity;
- selected source path plus SHA-256 content hash;
- chunks, vectors, citations, and required access labels.

Incremental reuse fails closed if root, chunker, vector mode, neural model id, or dimensions differ. Older indexes without source hashes require one fresh build before they can become an incremental base.

For every current file:

1. read bytes and calculate SHA-256;
2. if the hash matches, reuse extracted chunks and vectors;
3. recalculate required access labels even for reused content;
4. if changed or new, decode, chunk, tokenize, and vectorize;
5. omit paths no longer present.

The build report records reused files/chunks, relabeled chunks, added/changed/deleted/stale files, and embedded chunks.

## Model-specific behavior

- **No vectors:** unchanged extraction is reused.
- **Hash mechanics:** unchanged stored vectors are reused; changed chunks recalculate locally.
- **Neural:** only changed/new chunks are sent as one document batch. A no-change or ACL-only build makes zero document-embedding calls, although the current CLI still initializes the provider and runs compatibility probes.
- **PPMI:** extraction can be reused, but any corpus content addition/change/deletion retrains the complete model and recomputes every vector because vocabulary axes and weights are corpus-global. A no-change build reuses the exact prior model.

This distinction is why “incremental” must describe actual work saved rather than merely a CLI flag.

## Read failures and deletion safety

If an existing file is still present but temporarily unreadable or invalid UTF-8, the incremental builder retains its prior chunks and hash, marks it `stale`, and records the error. A path that is truly absent is deleted from the next index.

This favors availability during transient connector/filesystem failures without silently claiming freshness. Operators must alert on stale files. A configurable fail-closed policy may be preferable for highly sensitive corpora; it is not implemented yet.

## Real neural update result

A temporary copy of the 13-document mixed corpus was indexed with local BGE embeddings. Then:

- one hybrid-search document was modified;
- one rollback document was added;
- one bread document was deleted.

The incremental report was:

```json
{
  "reused_files": 11,
  "reused_chunks": 11,
  "added_files": 1,
  "changed_files": 1,
  "deleted_files": 1,
  "embedded_chunks": 2
}
```

The rollback query ranked the new document first in Python. The deleted `cooking/bread.md` path was absent. Export and Zig import published generation 5 with 13 documents, 333 terms, 460 postings, and 384-dimensional BGE vectors. Through the text-only gateway, the rollback passage again ranked first with cosine 0.7263, and listing `cooking/` returned no sources.

An attempted lexical query about deleted bread still returned unrelated documents sharing common words. That did not indicate a deletion failure—the path was absent—but it exposed the current lack of stopword handling and score thresholds. Deletion assertions should inspect ids/paths, not assume arbitrary text queries return an empty list.

## What remains

- no filesystem watcher, debounce, or connector change feed;
- no WAL, delta segment, tombstone file, or background compaction;
- no ACL-only Zig segment patch; relabeling still publishes a full snapshot;
- no generation-aware incremental interchange stream;
- no query-reader leases or safe obsolete-generation deletion;
- no indexing throughput, model latency, write amplification, or disk-size benchmark at realistic scale;
- provider initialization occurs before incremental compatibility is established, so a no-change CLI run still pays model startup/probe cost;
- no crash injection between incremental scan and publication;
- no configurable policy for stale unreadable files.

The next scale experiment should generate corpora at increasing chunk/vector counts, separately time scan/hash, extraction, embedding, Zig import, startup, and p50/p95 query latency, then compare full rebuild against Option B. Delta segments should begin only if those measurements demand them.
