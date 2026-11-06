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
 *          ss_evidence, ss_index_folder and, since contract 2.0.0, ss_find,
 *          ss_outline, ss_read_span, ss_list_files, ss_roots,
 *          ss_apply_changes) return NULL on failure. ss_import_json, the one
 *          function that returns an integer result, returns a negative
 *          ss_error_code on failure (0 is never returned; success is the
 *          published generation number, always >= 1). Either way,
 *          ss_last_error() returns a thread-local, human-readable
 *          description of the most recent failure on the calling thread —
 *          a per-thread diagnostic, analogous to strerror()/dlerror(), not
 *          part of any handle's state. The 2.0.0 functions (and ss_status,
 *          ss_evidence since 2.0.0) spell their failure
 *          "<function>: SS_ERR_<CODE>: <reason>", so a caller can branch on
 *          the code name without parsing the reason: SS_ERR_INVALID_ARGUMENT
 *          (a malformed or unknown request field, a stale cursor, a stale
 *          expect_generation), SS_ERR_NOT_FOUND (an unknown, hidden or not
 *          retained file: the same message for all three), SS_ERR_CAPACITY
 *          (a span over its limits, a generation without retained source
 *          bytes or without positions, a prefix over 1,000 terms, a batch
 *          over its caps), SS_ERR_IO (WRITER.LOCK held by another writer).
 *
 * Threads: a single ss_handle may be read concurrently from multiple
 *          threads: ss_status/ss_query/ss_evidence and the 2.0.0 read
 *          functions (ss_find, ss_outline, ss_read_span, ss_list_files,
 *          ss_roots) only read the handle's
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
 *          object is `search_knowledge`'s `result`, produced by the same code
 *          the JSON-RPC service uses, without the folder fields the service
 *          adds since S3-T6 (each item's `root_id`, `section_path`; the
 *          result's `truncated`, `pending_files`). ss_evidence()'s
 *          per-chunk object is exactly `read_chunk`'s `result` shape (plus,
 *          since 2.0.0, three fields after it). The 2.0.0 read functions
 *          return exactly what `searchd serve` returns as `result` for the
 *          method of the same name and what the CLI prints with --json
 *          (one implementation, zig/src/ops.zig): the same bytes.
 *
 * Scope (contract 2.0.0): every read takes an optional "roots" (root ids;
 *          null or absent = every root, an unknown id names nothing) and
 *          "principal_labels" (a chunk or file is visible only when the
 *          caller holds every label it and its root require). The caller of
 *          this ABI is the host app and is trusted with both: a model or a
 *          remote client must never choose them (docs/authorization.md).
 *          A hidden file, chunk, term or root is indistinguishable from an
 *          absent one in every payload; BM25 statistics are computed over
 *          the visible scope.
 */

/* Contract 2.2.0 (PR #21, integrated by S4-T2) adds, opt-in and additive:
 * "search_field" ("content" default, "filename", "both"; lexical mode only)
 * in ss_query's options_json, "filename_index" in ss_index_folder's and
 * ss_apply_changes' options (set at a directory's creation; later updates
 * keep it), and "filename_policy_id" in ss_status on an enabled generation.
 * Function signatures are unchanged. Generations written since 2.2.0 are
 * manifest v2.2 (docs/manifest-format-v2.md); older libraries refuse them
 * with UnsupportedFlags, so a directory this library has updated must not be
 * opened by an older one. */
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
#define SS_ERR_CAPACITY           (-4) /* a workspace or limit was too small (2.0.0: span/batch caps, source or positions absent) */
#define SS_ERR_OUT_OF_MEMORY      (-5) /* malloc failure */
#define SS_ERR_NOT_FOUND          (-6) /* 2.0.0: an unknown, hidden or not retained file (ss_outline, ss_read_span) */
#define SS_ERR_INTERNAL           (-7) /* anything not covered above */

/*
 * The engine contract/build version (contracts/CONTRACTS_VERSION), e.g.
 * "2.2.0". The returned pointer is static storage owned by the library:
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
 *
 * Since 2.0.0 the handle also holds the generation's roots, pending files,
 * per-root statistics and, when the generation retains source bytes, the
 * source section (with a path index and a sparse line index). A source
 * section that is missing or does not validate does not fail ss_open:
 * ss_query, ss_find and the listings work, and only ss_read_span and
 * ss_outline answer SS_ERR_CAPACITY "re-index required: source section
 * unavailable (<reason>)".
 *
 * Since 2.1.0 (S4-T1) ss_open is lazy: it validates the manifest and the
 * document and lexical sections and decodes what ss_status needs. The
 * source section (opened, not read, by ss_open), the per-root statistics
 * and the phrase position tables load at their first use (the first
 * ss_read_span, ss_outline or ss_list_files that reads the source; the
 * first scored query; the first ss_find), once per handle: a second thread
 * calling during a load waits for it. A damaged source section therefore
 * fails that first read, not ss_open (ss_status says "source":
 * "unverified" until then); damaged positions fail the first ss_find with
 * SS_ERR_CORRUPT_SNAPSHOT.
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
 * `postings`. Since contract 2.0.0 these are followed (additive; removing
 * them gives the 1.x output) by:
 *   "files"          visible files (indexed, including those without a chunk)
 *   "pending"        visible pending files (announced, bytes not yet given)
 *   "truncated"      a visible file was given but not indexed in full
 *   "roots"          [{"root_id","label","kind","files","documents","pending"}]
 *   "pending_paths"  [{"root_id","path"}]
 *   "has_source"     visible files have retained source bytes (false once
 *                    the section is known to be lost or damaged)
 *   "has_positions"  the lexical section holds positions (phrase works)
 *   "chunkers"       the chunker ids visible documents use
 * and since contract 2.1.0 by:
 *   "source"         "absent" | "unverified" (retained, not read yet) |
 *                    "verified" | "unavailable" (lost or damaged); reading
 *                    the status never loads the source section
 * and since contract 2.2.0, only on a filename-enabled generation, by:
 *   "filename_policy_id"  "filename-field-v1", read from the manifest alone
 *                    (the filename sections are not read)
 * All counts, the v1 ones included, are over the default scope: every
 * root, no principal labels (the scope ss_query uses without options), so
 * a labelled file is not counted; ss_roots() counts over a scope you name.
 *
 * Returns a heap-allocated, null-terminated JSON string on success — the
 * caller must free it with ss_free() — or NULL on failure (out of memory;
 * see ss_last_error()). `handle` must not be NULL.
 */
char *ss_status(ss_handle *handle);

/*
 * Run one query against `handle`'s snapshot.
 *
 *   query_text    Null-terminated UTF-8 query text. It MUST be valid UTF-8
 *                 (checked before any analysis, for every analyzer and
 *                 retrieval mode; since S2-T11): invalid text -- a byte that
 *                 cannot start a sequence such as 0xFF or a lone 0x80, a
 *                 truncated or overlong sequence, a surrogate -- makes
 *                 ss_query return NULL with ss_last_error() "ss_query:
 *                 query_text is not valid UTF-8 (SS_ERR_INVALID_ARGUMENT)".
 *                 An empty or
 *                 punctuation-only query is accepted: it ranks nothing and
 *                 reports query_empty_after_analysis (lexical and hybrid).
 *   query_vector  Array of `dims` 32-bit floats, or NULL when `dims` is 0.
 *                 Ignored entirely for retrieval_mode "lexical" and for
 *                 snapshots with zero vector dimensions (see ss_status()).
 *                 Otherwise `dims` must equal the snapshot's vector
 *                 dimensions and the vector must be valid, or this call
 *                 fails (NULL, ss_last_error()). A valid vector has only
 *                 finite components (no NaN, no +-infinity) and a finite L2
 *                 norm: the sum of squares, accumulated in float, must not
 *                 overflow, which in practice means a norm below about
 *                 1.8e19. An all-zero vector is valid (cosine 0). Lexical
 *                 mode does not read the vector, so it does not validate it
 *                 either; it still reports vector_ignored.
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
 *                   "profile"           boolean, default false (since
 *                                       contract 1.2.0); true adds the
 *                                       `profile` field described below
 *                   "roots"             array of root ids (since 2.0.0):
 *                                       only chunks of these roots are
 *                                       candidates, and BM25 counts over
 *                                       the visible scope; absent = every
 *                                       root, the 1.x behaviour exactly
 *                   "search_field"      "content" (default) | "filename" |
 *                                       "both" (since 2.2.0): filename and
 *                                       both need retrieval_mode "lexical"
 *                                       given explicitly and no profile, and
 *                                       a generation built with
 *                                       filename_index (else NULL,
 *                                       "FilenameIndexUnavailable"). The
 *                                       first such query on a handle loads
 *                                       the filename sections (once; a
 *                                       damaged one fails it, ss_last_error
 *                                       naming the check, while content
 *                                       queries keep working)
 *
 * Returns a heap-allocated, null-terminated JSON object on success — the
 * caller must free it with ss_free() — with fields `tool`, `query`, `index`,
 * `retrieval`, `results` (array of chunk_id/citation/content/score/ranking),
 * and `answer_policy`. These are exactly the fields of the `result` value a
 * `search_knowledge` JSON-RPC response carries for the same request
 * (docs/zig-rpc-service.md), in the same order and byte for byte, except
 * that the service (and `searchd mcp`) add, since S3-T6, `root_id` and
 * `section_path` to each item and `truncated` and `pending_files` after
 * `answer_policy`; ss_query()'s output is unchanged.
 *
 * Since contract 1.2.0 the object ends with three more fields (additive;
 * removing them gives the 1.1.0 output exactly):
 *
 *   "warnings"  array, always present, usually empty, of
 *               {"code", "message", "term"?}. Codes:
 *                 query_term_unmatched       an analysed query word that was
 *                     not found in the searched files. "term" is the
 *                     query's own analysed form (lowercased under
 *                     ascii-alnum-v1, NFC and case-folded under analyzer-v2),
 *                     never the index's spelling. The message is the same
 *                     whether the word occurs in no chunk or only in chunks
 *                     outside path_prefix or the caller's labels, so the
 *                     report does not reveal which hidden files hold a word
 *                     (docs/authorization.md). One warning per distinct term,
 *                     at its first occurrence, in query order (words not in
 *                     the index and words hidden by the scope are
 *                     interleaved as they appear). Lexical and hybrid modes
 *                     only: vector mode does not use the words.
 *                 query_empty_after_analysis the query has no searchable
 *                     terms (empty, punctuation, unknown script for the
 *                     analyzer). Lexical and hybrid modes only.
 *                 vector_ignored             a query vector was passed but
 *                     not used: retrieval_mode is "lexical", or the
 *                     snapshot stores no vectors.
 *                 candidate_depth_cut        a channel produced more
 *                     candidates than candidate_k, and the cut can change
 *                     the returned list: in hybrid mode when both channels
 *                     produced candidates (a hybrid query on a snapshot
 *                     without vectors is one channel and does not warn), in
 *                     lexical or vector mode, or hybrid, when candidate_k <
 *                     top_k (which this function rejects, so it does not
 *                     occur there). "lexical" and/or "vector" in the message.
 *               Order of the array: query_empty_after_analysis, then the
 *               query_term_unmatched entries in query order, then
 *               vector_ignored, then candidate_depth_cut.
 *   "request"   {"analyzer_id", "retrieval_mode", "top_k", "candidate_k",
 *               "path_prefix"}: what the engine used, defaults filled in
 *               (path_prefix is null when none).
 *   "profile"   only when options "profile" is true: {"tokenize_us",
 *               "score_us", "rank_us", "serialize_us", "matched_chunks"}.
 *               Microseconds on a monotonic clock; matched_chunks is the
 *               number of chunks inside path_prefix and the caller's labels
 *               holding at least one query term (so a word that only hidden
 *               chunks hold counts 0, like an absent word; 0 in vector mode). serialize_us covers writing the report up to
 *               the "profile" field itself. With "profile" off no clock is
 *               read.
 *
 * Returns NULL on failure — query_text that is not valid UTF-8, invalid top_k/candidate_k, a wrong-sized or
 * invalid (non-finite or norm-overflowing) query_vector, malformed options_json, or an unknown
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
 *    "principal_labels": [], "roots": ["school"]}
 *
 * `path_prefix` (on the citation path), `principal_labels` and, since
 * 2.0.0, `roots` are optional and have the same meaning as `read_chunk`'s
 * parameters of the same name; an unknown field fails the call. At most
 * 1,000 ids.
 *
 * Returns a heap-allocated, null-terminated JSON array on success — the
 * caller must free it with ss_free() — with one entry per id, in the same
 * order as `ids`: a chunk object (`chunk_id`, `citation` {path, start_line,
 * end_line}, `content`, then since 2.0.0 `root_id`, `section_path` (the
 * Markdown heading path, [] for other files) and `neighbours` {"prev",
 * "next"}, each {"chunk_id","start_line","end_line"} of the adjacent chunk
 * of the same file or null) when found and inside the scope, or
 * `{"chunk_id": "...", "found": false}` otherwise (unknown and hidden alike). Ids are never rejected
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
 * `analyzer_id` selects how the documents' text is tokenized and is
 * recorded in the snapshot; queries on it use the same analyzer:
 *   "ascii-alnum-v1"  ASCII letters/digits only, case-insensitive; text in
 *                     any other script yields no terms. Unchanged since
 *                     contract 1.0.0.
 *   "analyzer-v2"     Unicode (NFC, simple case folding, Unicode letter and
 *                     digit categories), since contract 1.1.0. Builds the
 *                     same index `searchd index` (and ss_index_folder with
 *                     the default analyzer) builds from the same chunks.
 * Any other value fails with SS_ERR_INVALID_ARGUMENT.
 *
 * Returns the published generation number (>= 1) on success, or a negative
 * ss_error_code (SS_ERR_* above) on failure — see ss_last_error() for the
 * specific reason (e.g. unsupported analyzer/format version, inconsistent
 * vector dimensions, a document missing its id/path, a stored vector that is
 * not valid in the sense of ss_query's query_vector -- a non-finite component
 * or an L2 norm that overflows float, SS_ERR_INVALID_ARGUMENT with nothing
 * published -- or an I/O error).
 *
 * The payload may carry one optional extra top-level field,
 * "keep_generations" (integer >= 1, opt-in), with the same meaning as
 * ss_index_folder's option: after the publish succeeds, section files of
 * generations older than the newest N are deleted. Absent: nothing is
 * deleted. 0 returns SS_ERR_INVALID_ARGUMENT.
 */
int64_t ss_import_json(const char *dir_path, const char *bytes, size_t bytes_len);

/*
 * Free a pointer previously returned by ss_status(), ss_query(),
 * ss_evidence(), ss_index_folder() or a 2.0.0 function (ss_find,
 * ss_outline, ss_read_span, ss_list_files, ss_roots, ss_apply_changes). `ptr` may be NULL (no-op). Never call this on the result
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
 *                    "keep_generations"  integer >= 1, opt-in. After a
 *                                        successful publish, delete the
 *                                        section files of generations older
 *                                        than the newest N (the current
 *                                        generation is always kept; so are
 *                                        MANIFEST, WRITER.LOCK and
 *                                        INDEX-STATE.json). Absent: nothing
 *                                        is deleted. 0 is an error. A failed
 *                                        deletion never fails the call; the
 *                                        report then carries "pruned_files"
 *                                        and "prune_failures" (integers,
 *                                        present only when this option is
 *                                        set). Close handles on a pruned
 *                                        generation first if they matter to
 *                                        you: see docs/generation-lifecycle.md.
 *
 * Returns a heap-allocated, null-terminated JSON report object on success —
 * the caller must free it with ss_free() — with fields "generation"
 * (integer), "analyzer_id" (string), "added", "changed", "removed",
 * "unchanged", "budget_exhausted", "too_large", "unreadable" (all
 * integers), "too_large_paths", "unreadable_paths" (arrays of the relative
 * paths counted under "too_large"/"unreadable" — never just a bare count),
 * "documents", "terms", "postings" (all integers). A non-"update" run
 * always reports "changed"/"removed"/"unchanged" as 0 (a full rebuild never
 * compares against a previous generation); an "update" run additionally
 * reports "changed"/"removed". max_file_bytes/max_total_bytes are enforced
 * on a non-"update" run exactly as on an "update" run (S1-T5), so
 * "too_large"/"too_large_paths"/"budget_exhausted" can be nonzero either
 * way — "added" only counts the files a non-"update" run actually indexed.
 * "unchanged" and "budget_exhausted" are reported separately — "nothing to
 * do" and "left for a later run because max_total_bytes ran out" are never
 * the same number. An empty folder_path, or a folder whose last indexable
 * file was just deleted, publishes an empty generation (0
 * documents/terms/postings) instead of failing.
 *
 * With "update": true, if MANIFEST exists but a section file it names is
 * missing or unreadable, the update does not trust INDEX-STATE.json: it
 * re-indexes every file, publishes a full next generation, and the report
 * carries "recovered": "missing_section" (the field is absent otherwise).
 * With no MANIFEST but an INDEX-STATE.json present, the state is likewise
 * not trusted: the update re-indexes every file and reports
 * "recovered": "missing_manifest".
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

/* -------------------------------------------------------------------------
 * Contract 2.0.0: folder knowledge (docs/tasks/S3-T4.md, CAP-19 FR-22,
 * docs/folder-knowledge-implementation.md sections 4 to 9). Additive: the
 * ten functions above keep their signatures.
 *
 * Every read below takes a handle and a null-terminated JSON request object
 * (NULL or "" is {} where every field is optional) and returns a
 * heap-allocated JSON object to ss_free(), or NULL with ss_last_error() =
 * "<function>: SS_ERR_<CODE>: <reason>". An unknown request field is
 * SS_ERR_INVALID_ARGUMENT. Every result starts with the same envelope:
 *
 *   "request"   the request echoed with defaults filled in
 *   "generation" the handle's generation
 *   "scope"     {"roots": [visible root ids, in the generation's order],
 *                "labels_applied": true}
 *   "warnings"  [{"code","message"}] (ss_read_span: "end_line_clamped")
 *
 * Paths in requests and results are root-relative ("week.md" in root
 * "school"); a cursor is "<generation>:<offset>" and a cursor from another
 * generation is SS_ERR_INVALID_ARGUMENT "stale cursor".
 * ---------------------------------------------------------------------- */

/*
 * The search box. Request:
 *   "query"        string, required; a query in double quotes is a phrase,
 *                  a trailing * makes the last word a prefix
 *   "mode"         "words" (every word, default) | "phrase" | "prefix"
 *   "roots"        array of root ids (default every root)
 *   "principal_labels" array of strings (default none)
 *   "path_prefix"  root-relative path prefix (default none)
 *   "page_size"    1-100 (default 20); every match is scored regardless
 *   "cursor"       the previous page's next_cursor
 * Result, after the envelope: "hits" [{"chunk_id","root_id","path",
 * "section_path","start_line","end_line","score","snippet" (at most 240
 * codepoints of the chunk),"snippet_start","snippet_offsets","match_offsets"
 * (half-open codepoint ranges into the chunk's content)}], ordered by score
 * then root_id, path, start_line; "files" [{"root_id","path","hits"}] over
 * every page; "exact_match" (phrase mode: whether a hit exists; else
 * null); "empty"; "coverage" {"files","sections"} of this page;
 * "truncated" (a file in scope was not indexed in full); "next_cursor";
 * "pending_files" (files in scope announced but not indexed yet).
 * Refusals: SS_ERR_INVALID_ARGUMENT for an empty query, a * inside the
 * query, page_size out of range, a malformed or stale cursor;
 * SS_ERR_CAPACITY "re-index required: positions absent" (phrase over a
 * generation without positions) and "prefix ... expands to more than 1000
 * terms".
 */
char *ss_find(ss_handle *handle, const char *request_json);

/*
 * One file's structure. Request: "root_id", "path" (both required),
 * "roots", "principal_labels". Result, after the envelope: "front_matter"
 * ({"start_line","end_line","fields"{...}, "raw" when not key: value} or
 * null), "headings" [{"level","text","line","end_line"}] (Markdown only),
 * "lines", "chunker". Refusals: SS_ERR_NOT_FOUND "not indexed or not
 * retained: <root>/<path>" for an unknown, hidden or not retained file;
 * SS_ERR_CAPACITY when the generation retains no source bytes ("re-index
 * required: source absent") or its source section cannot be read.
 */
char *ss_outline(ss_handle *handle, const char *request_json);

/*
 * Lines of one file, byte for byte. Request: "root_id", "path",
 * "start_line", "end_line" (1-based, inclusive; all required),
 * "context_lines" (0-20, default 0), "roots", "principal_labels". An
 * end_line past the last line is clamped (warning "end_line_clamped").
 * Result, after the envelope: "start_line", "end_line", "text",
 * "context_before", "context_after" (original bytes, terminators included),
 * "byte_exact": true, "sha256" (hex of "text"). Refusals:
 * SS_ERR_CAPACITY when the lines including context exceed 400 or their
 * bytes 256 KiB (the message gives both counts), or the source is absent or
 * unreadable; SS_ERR_NOT_FOUND as ss_outline; SS_ERR_INVALID_ARGUMENT for a
 * start_line of 0 or past the last line, end_line < start_line,
 * context_lines over 20.
 */
char *ss_read_span(ss_handle *handle, const char *request_json);

/*
 * The visible files. Request (all optional): "root_id", "path_prefix"
 * (root-relative), "status" ("indexed" | "pending"), "page_size" (1-1000,
 * default 100), "cursor", "roots", "principal_labels". Result, after the
 * envelope: "files" [{"root_id","path","size" (retained bytes, a pending
 * file's announced size, or null),"mtime_ms" (null: a generation does not
 * record it),"status","chunks","chunker" (null when the file has no
 * chunk)}] ordered by root then path, "total" (files matching, every page),
 * "next_cursor". Refusals: SS_ERR_INVALID_ARGUMENT for a bad status,
 * page_size or cursor.
 */
char *ss_list_files(ss_handle *handle, const char *request_json);

/*
 * The visible roots and their counts. `options_json` (NULL = {}): "roots",
 * "principal_labels". Result, after the envelope: "roots"
 * [{"root_id","label","kind","files","documents","pending"}].
 */
char *ss_roots(ss_handle *handle, const char *options_json);

/*
 * Publish one new generation in `dir_path` (created if missing) from
 * host-fed changes, exactly as `searchd apply` does
 * (docs/folder-knowledge-implementation.md section 6). Close and reopen
 * any handle on `dir_path` afterwards to see it. Until then a handle keeps
 * answering the generation it opened, in every build mode, also after this
 * call prunes that generation's files ("keep_generations"): the handle holds
 * its section files from ss_open and its lazy loads read those bytes
 * (S4-T6; zig/tests/abi_test.c).
 *
 *   changes_json  {"expect_generation"?: N, "roots"?: [{"root_id","label"?,
 *                  "kind"?,"required_labels"?,"retain_source"?,"path"?}],
 *                  "changes": [{"op": "add"|"change"|"remove"|"move"|
 *                  "pending"|"remove_root", "root_id", "path", "moved_from"?,
 *                  "size"?, "mtime_ms"?, "sha256"?, "content_base64"? |
 *                  "file"?, "required_labels"?}]}. A field
 *                  "principal_labels" anywhere is refused: the scope comes
 *                  from the trusted caller.
 *   opts_json     NULL or {"allow_file_reads"?: bool (default false; a
 *                  "file" change is refused without it), "max_file_bytes"?,
 *                  "max_total_bytes"?, "analyzer"?, "max_chars"?,
 *                  "overlap_lines"?, "keep_generations"?, "filename_index"?:
 *                  bool (since 2.2.0; true on a new directory builds the
 *                  filename channel; omitted, an existing directory keeps
 *                  its setting; a value that differs from it is refused)}
 *
 * Returns the report ({"generation","analyzer_id","added","changed",
 * "removed","moved","pending","unchanged","too_large","too_large_paths",
 * "unreadable","unreadable_paths","rejected","conflicts","ambiguous_moves",
 * "roots_removed","budget_exhausted","budget_exhausted_paths","bytes_read",
 * "ms","documents","terms","postings", and "recovered" when the previous
 * generation could not be read) to ss_free(), or NULL: SS_ERR_INVALID_ARGUMENT
 * for a malformed or refused request (nothing is published; "stale:
 * generation is M" when expect_generation differs), SS_ERR_CAPACITY for
 * more than 10,000 changes or content over max_total_bytes, SS_ERR_IO when
 * another writer holds WRITER.LOCK.
 */
char *ss_apply_changes(const char *dir_path, const char *changes_json, const char *opts_json);

#ifdef __cplusplus
}
#endif

#endif /* SEARCH_SIMPLI_H */
