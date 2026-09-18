/*
 * Search Simpli — C ABI over the Zig hybrid search engine.
 *
 * ADR 0002 (docs/decisions/0002-standalone-portable-platform.md) and
 * docs/tasks/S1-T0.md. Implementation: zig/src/abi.zig. This header is the
 * only contract a caller needs; it never changes shape without a
 * corresponding bump of contracts/CONTRACTS_VERSION (see ss_version()).
 *
 * ---------------------------------------------------------------------------
 * Design summary
 * ---------------------------------------------------------------------------
 *
 * Handle:  ss_open() reads one published snapshot directory (as written by
 *          `searchd init-demo`, `searchd import-json`, or ss_import_json())
 *          into freshly allocated, immutable, in-memory workspaces and
 *          returns an opaque handle. Every later call reads that snapshot;
 *          none of them touch the filesystem again. ss_close() frees it.
 *          There is no engine-wide global mutable state: everything a query
 *          needs lives either in the handle (the decoded snapshot) or in
 *          memory allocated fresh for that one call.
 *
 * Allocation: every byte this library allocates — the handle's internal
 *          buffers and every JSON string it returns — comes from the C
 *          allocator (malloc/free), so `ss_free()` is exactly `free()`.
 *          Never call ss_free() on the result of ss_version() (a static
 *          string) or on a NULL pointer combined with any pointer this
 *          library did not return.
 *
 * Errors:  functions that return a pointer (ss_open, ss_status, ss_query,
 *          ss_evidence) return NULL on failure. ss_import_json, the one
 *          function that returns an integer result, returns a negative
 *          ss_error_code on failure (0 is never returned; success is the
 *          published generation number, always >= 1). Either way,
 *          ss_last_error() returns a thread-local, human-readable
 *          description of the most recent failure on the calling thread —
 *          a per-thread diagnostic, analogous to strerror()/dlerror(), not
 *          part of any handle's state.
 *
 * Threads: a single ss_handle may be read concurrently from multiple
 *          threads: ss_status/ss_query/ss_evidence only read the handle's
 *          immutable decoded snapshot and allocate fresh scratch memory per
 *          call. ss_close() must not race with any other call on the same
 *          handle. ss_last_error() is thread-local. ss_open()/
 *          ss_import_json() may be called concurrently with unrelated
 *          directories; behavior when two callers import into the *same*
 *          directory concurrently is whatever `WRITER.LOCK` gives the
 *          underlying publication path (see docs/zig-engine-api.md) — one
 *          succeeds, the other observes SS_ERR_IO.
 *
 * JSON shapes: ss_status()'s object has the same fields as JSON-RPC
 *          `index_status`'s `result` (docs/zig-rpc-service.md). ss_query()'s
 *          object is exactly `search_knowledge`'s `result`, produced by the
 *          same code the JSON-RPC service uses, so it is byte-for-byte what
 *          the service would return for the same request. ss_evidence()'s
 *          per-chunk object is exactly `read_chunk`'s `result` shape.
 */

#ifndef SEARCH_SIMPLI_H
#define SEARCH_SIMPLI_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Opaque handle returned by ss_open(). */
typedef struct ss_handle ss_handle;

/*
 * Negative error codes returned by ss_import_json(). Call ss_last_error()
 * for the human-readable reason; these codes are for programmatic branching
 * only (e.g. retry on SS_ERR_IO, never on SS_ERR_CORRUPT_SNAPSHOT).
 */
#define SS_ERR_INVALID_ARGUMENT   (-1) /* malformed interchange JSON or metadata */
#define SS_ERR_IO                 (-2) /* filesystem access, or lock contention */
#define SS_ERR_CORRUPT_SNAPSHOT   (-3) /* on-disk section/manifest failed validation */
#define SS_ERR_CAPACITY           (-4) /* an internal fixed-size workspace was too small */
#define SS_ERR_OUT_OF_MEMORY      (-5) /* malloc failure */
#define SS_ERR_NOT_FOUND          (-6) /* reserved for future lookup-style calls */
#define SS_ERR_INTERNAL           (-7) /* anything not covered above */

/*
 * The engine contract/build version (contracts/CONTRACTS_VERSION), e.g.
 * "1.0.0". The returned pointer is static storage owned by the library:
 * never pass it to ss_free(). Cannot fail.
 */
const char *ss_version(void);

/*
 * A thread-local, null-terminated description of the most recent ss_*
 * failure on the calling thread ("" if there has been none yet, or after a
 * call that succeeded does not update it — check the failing call's own
 * return value first). Valid until this thread's next failing ss_* call.
 * The returned pointer is thread-local static storage: never pass it to
 * ss_free(). Cannot fail.
 */
const char *ss_last_error(void);

/*
 * Open the published snapshot directory at `dir_path` (a null-terminated
 * path, absolute or relative to the process's current directory) and decode
 * its current generation into freshly allocated workspaces.
 *
 * Returns an opaque handle on success, or NULL on any I/O or validation
 * failure (missing/corrupt MANIFEST, checksum mismatch, cross-section count
 * mismatch, out of memory, ...) — see ss_last_error().
 */
ss_handle *ss_open(const char *dir_path);

/*
 * Free everything ss_open() allocated for `handle`. `handle` may be NULL
 * (no-op). Do not call any other ss_* function with `handle` afterward, and
 * do not call ss_close() twice on the same handle.
 */
void ss_close(ss_handle *handle);

/*
 * Snapshot status as a JSON object: `ready` (bool, always true for a
 * successfully opened handle), `generation`, `analyzer_id`,
 * `embedding_model_id`, `vector_dimensions`, `documents`, `terms`,
 * `postings`.
 *
 * Returns a heap-allocated, null-terminated JSON string on success — the
 * caller must free it with ss_free() — or NULL on failure (out of memory;
 * see ss_last_error()). `handle` must not be NULL.
 */
char *ss_status(ss_handle *handle);

/*
 * Run one query against `handle`'s snapshot.
 *
 *   query_text    Null-terminated UTF-8 query text. Must not be empty.
 *   query_vector  Array of `dims` 32-bit floats, or NULL when `dims` is 0.
 *                 Ignored entirely for retrieval_mode "lexical" and for
 *                 snapshots with zero vector dimensions (see ss_status()).
 *                 Otherwise `dims` must equal the snapshot's vector
 *                 dimensions and every element must be finite, or this call
 *                 fails.
 *   dims          Length of `query_vector`.
 *   top_k         Final result count, 1-100.
 *   options_json  NULL or "" for defaults, or a null-terminated JSON object
 *                 with any of:
 *                   "retrieval_mode"    "lexical" | "vector" | "hybrid"
 *                                       (default "hybrid")
 *                   "candidate_k"       integer, default 100, must be
 *                                       >= top_k and <= 10000
 *                   "path_prefix"       string, restricts results to chunks
 *                                       whose path starts with this prefix
 *                   "principal_labels"  array of strings; a chunk is only
 *                                       returned if the caller holds every
 *                                       one of its required labels (see
 *                                       docs/authorization.md)
 *
 * Returns a heap-allocated, null-terminated JSON object on success — the
 * caller must free it with ss_free() — with fields `tool`, `query`, `index`,
 * `retrieval`, `results` (array of chunk_id/citation/content/score/ranking),
 * and `answer_policy`. This is exactly the `result` value a `search_knowledge`
 * JSON-RPC response carries for the same request (docs/zig-rpc-service.md).
 *
 * Returns NULL on failure — invalid top_k/candidate_k, a wrong-sized or
 * non-finite query_vector, malformed options_json, or an unknown
 * retrieval_mode — see ss_last_error(). `handle` must not be NULL.
 */
char *ss_query(
    ss_handle *handle,
    const char *query_text,
    const float *query_vector,
    size_t dims,
    size_t top_k,
    const char *options_json
);

/*
 * Look up stored chunks by id. `ids_json` is a null-terminated JSON object:
 *
 *   {"ids": ["chunk-1", "chunk-2"], "path_prefix": "guides/",
 *    "principal_labels": []}
 *
 * `path_prefix` and `principal_labels` are optional and have the same
 * meaning as `read_chunk`'s parameters of the same name.
 *
 * Returns a heap-allocated, null-terminated JSON array on success — the
 * caller must free it with ss_free() — with one entry per id, in the same
 * order as `ids`: a chunk object (`chunk_id`, `citation` {path, start_line,
 * end_line}, `content`) when found and authorized, or
 * `{"chunk_id": "...", "found": false}` otherwise. Ids are never rejected
 * individually; the whole call only fails (returns NULL) if `ids_json`
 * itself is malformed, `ids` is missing, or of out of memory — see
 * ss_last_error(). `handle` must not be NULL.
 */
char *ss_evidence(ss_handle *handle, const char *ids_json);

/*
 * Validate the neutral interchange JSON in bytes[0..bytes_len]
 * (contracts/snapshot-interchange.schema.json) and atomically publish it as
 * a new generation under `dir_path` (created, including parent directories,
 * if it does not already exist) — exactly what `searchd import-json` does.
 *
 * Returns the published generation number (>= 1) on success, or a negative
 * ss_error_code (SS_ERR_* above) on failure — see ss_last_error() for the
 * specific reason (e.g. unsupported analyzer/format version, inconsistent
 * vector dimensions, a document missing its id/path, or an I/O error).
 */
int64_t ss_import_json(const char *dir_path, const char *bytes, size_t bytes_len);

/*
 * Free a pointer previously returned by ss_status(), ss_query(), or
 * ss_evidence(). `ptr` may be NULL (no-op). Never call this on the result
 * of ss_version() or ss_last_error() (both static storage, not caller-owned).
 */
void ss_free(char *ptr);

/* -------------------------------------------------------------------------
 * S1-T3: incremental folder indexing (docs/tasks/S1-T3.md). Additive; does
 * not change the shape or behavior of anything above.
 * ---------------------------------------------------------------------- */

/*
 * Index the folder at `folder_path` and atomically publish (or
 * re-publish/update) a lexical-only snapshot into `dir_path` (created,
 * including parent directories, if it does not already exist) — the
 * native-engine equivalent of `searchd index` / `searchd index --update`.
 *
 * This call mutates the directory identified by `dir_path` rather than
 * operating on an already-open ss_handle: indexing publishes a *new*
 * generation, and a handle is a decoded snapshot of one already-published
 * generation, so there is nothing for an open handle to do here that
 * closing and reopening afterward (ss_close then ss_open) does not already
 * cover — do that to see the new generation through a handle.
 *
 *   dir_path      Snapshot directory to publish/update (created if
 *                  missing).
 *   folder_path    Folder to index.
 *   opts_json      NULL or "" for defaults, or a null-terminated JSON
 *                  object with any of:
 *                    "analyzer"          "analyzer-v1"/"v1" or
 *                                        "analyzer-v2"/"v2" (default),
 *                                        same spelling as `searchd index
 *                                        --analyzer`
 *                    "max_chars"         chunker max characters per chunk
 *                                        (default 1600)
 *                    "overlap_lines"     chunker overlap lines (default 3)
 *                    "update"            bool, default false. false: full
 *                                        rebuild, always publishing the
 *                                        next free generation in
 *                                        `dir_path` (never fails with
 *                                        PathAlreadyExists on a directory
 *                                        that already holds a snapshot).
 *                                        true: incremental update —
 *                                        per-file content hashes (persisted
 *                                        in `dir_path`/INDEX-STATE.json)
 *                                        skip unchanged files, deleted
 *                                        files are tombstoned. Fails
 *                                        closed (see below) if `dir_path`
 *                                        already holds a snapshot published
 *                                        with a different analyzer.
 *                    "max_file_bytes"    per-file size cap in bytes
 *                                        (default 10 MiB); a larger file is
 *                                        never read and is excluded,
 *                                        counted under the report's
 *                                        "too_large"
 *                    "max_total_bytes"   total bytes read in one call
 *                                        before remaining unprocessed files
 *                                        are left untouched for this
 *                                        generation (default 512 MiB)
 *
 * Returns a heap-allocated, null-terminated JSON report object on success —
 * the caller must free it with ss_free() — with fields "generation"
 * (integer), "analyzer_id" (string), "added", "changed", "removed",
 * "unchanged", "budget_exhausted", "too_large", "unreadable" (all
 * integers), "too_large_paths", "unreadable_paths" (arrays of the relative
 * paths counted under "too_large"/"unreadable" — never just a bare count),
 * "documents", "terms", "postings" (all integers). A non-"update" run
 * always reports "changed"/"removed"/"unchanged"/"budget_exhausted"/
 * "too_large" as 0, "too_large_paths" as an empty array, and
 * "added"/"unreadable"/"unreadable_paths" as the files indexed/skipped; an
 * "update" run reports the full incremental breakdown. "unchanged" and
 * "budget_exhausted" are reported separately — "nothing to do" and "left
 * for a later run because max_total_bytes ran out" are never the same
 * number. An empty folder_path, or a folder whose last indexable file was
 * just deleted, publishes an empty generation (0 documents/terms/postings)
 * instead of failing.
 *
 * A file larger than max_file_bytes is tombstoned, not silently kept: it is
 * counted (and named) under "too_large"/"too_large_paths", and its
 * previously indexed chunks (if any) are dropped from this generation. A
 * file that is merely unreadable this run (permissions, a transient I/O
 * error, invalid UTF-8) keeps its previously indexed chunks instead — see
 * docs/incremental-indexing.md.
 *
 * Returns NULL on failure — a missing/unreadable folder_path, an
 * unrecognized "analyzer", or (with "update": true) `dir_path` already
 * holding a snapshot published with a different analyzer — see
 * ss_last_error().
 */
char *ss_index_folder(const char *dir_path, const char *folder_path, const char *opts_json);

#ifdef __cplusplus
}
#endif

#endif /* SEARCH_SIMPLI_H */
