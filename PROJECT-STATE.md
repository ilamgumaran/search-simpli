# Project state and continuation handoff

Last updated: 2026-09-17

Project: **Search Simpli** (`search-simpli`)

> **Resuming a session (CLI or web)?** Start at
> [`docs/journey/`](docs/journey/README.md) — vision, how we work, the next task,
> and the evolution record. This file remains authoritative for *exact current
> behavior and commands*.

## Standalone platform plan (2026-09-13)
ADR 0002 and `docs/tasks/S1-T*.md`: C ABI + libraries, native indexing with a Unicode analyzer, standalone CLI, Dart FFI binding, incremental folder indexing. The family app (`simpli-helper`, M12-T0) then replaces its Dart port with the core.

## Standalone platform status (round C, 2026-09-17)

**S1-T4 is `verified` and merged to `main`** — merge commit `d860bb1` (branch `task/S1-T4` `0bcc446`, which continued a rate-limited builder's `wip` `60be2dc`), then the verdict commit `ddb72a6`, which is `main`'s head. Round C is hardening only: it closes the round-B verdicts' non-blocking findings rather than adding a capability. The owner has paused this work after round C until later in the weekend.

- **`ss_index_folder` is bound in Dart.** `SearchSimpli.indexFolder(dirPath, folderPath, {options, library})` → a typed `IndexFolderReport`; `IndexFolderOptions` carries `analyzer`, `maxChars`, `overlapLines`, `update`, `maxFileBytes`, `maxTotalBytes`. A static method, not an instance one, because it takes a directory rather than an open handle (same shape as `importSnapshotJson`/`ss_import_json`). Proven by the tester on the Mac and **on the API 34 emulator against the app's own private storage** (`/data/user/0/<pkg>/files`), where it published generation 1, answered a query, tombstoned a file grown past the cap, and published an empty generation when the last file was deleted.
- **The Dart package loads its library package-relatively.** `library_loader.dart` finds the nearest `.dart_tool/package_config.json` and reads `search_simpli`'s own `rootUri` out of it (read directly rather than via `Isolate.resolvePackageUri`, which is `Future`-returning and would force `SearchSimpli.open` to become async). A `path:` dependency now works from any working directory with **no environment variable** — verified by the tester from a fresh consumer package outside the checkout, following the README literally with `SEARCH_SIMPLI_LIBRARY_PATH` unset. `SEARCH_SIMPLI_LIBRARY_PATH` still overrides, on every platform.
- **The report JSON names files instead of only counting them, and `skipped` is gone.** One shape for both entry points: `generation`, `analyzer_id`, `added`, `changed`, `removed`, `unchanged`, `budget_exhausted`, `too_large`, `unreadable`, `too_large_paths`, `unreadable_paths`, `documents`, `terms`, `postings`. `unchanged` ("hash matched, nothing to do") and `budget_exhausted` ("left for a later run because `--max-total-bytes` ran out") are now distinct numbers, and `too_large`/`unreadable` files come with relative-path arrays (properly JSON-escaped — the tester checked quotes, backslashes, tabs, newlines, Cyrillic and emoji in filenames).
- **An empty folder, or a folder that lost its last file, publishes an empty generation.** Measured against the previous binary built from the same tree: `origin/main` exits 1 with `error: NoDocuments` in both cases, the merge publishes a real, openable generation with 0 documents/terms/postings that answers `query` and `evidence` with empty arrays.
- **A file grown past `--max-file-bytes` is reported *and* tombstoned.** It is named in `too_large_paths`, its previous chunks and its `INDEX-STATE.json` entry are dropped, it stays dropped on the next run, and it comes back as `added` if it shrinks below the cap — while an unrelated file in the same run stays `unchanged`. (An *unreadable* file keeps its chunks; the two policies differ by design, and `docs/incremental-indexing.md` now tabulates all six outcomes.)
- **`lifecycle.scan` knows `INDEX-STATE.json`.** Over the same incrementally indexed directory, the previous binary reports `unknown_files=1` and this one `unknown_files=0`.
- **Docs.** `docs/incremental-indexing.md` is rewritten to the shipped native design (and keeps the separate Python `--incremental-from` path clearly labelled as a different system); the four live "API 37" labels now read API 34 / Android 14 (package README, `example/lib/main.dart`, `docs/publication-recovery.md`, `zig/src/publication.zig`); `docs/generation-lifecycle.md` lists the third control file; `scripts/gen_timing_corpus.py`'s dead `shuffled` copy is gone; and the four schema-optional fields (`index.root`, `retrieval.vector_mode`, `retrieval.candidate_k`, `retrieval.embedding`) have Dart members that round-trip and are omitted when absent.
- **Timings re-measured by the tester on the merge** (ReleaseSafe, `/usr/bin/time -p`, 1,000-file / 3.9 MB corpus with **24,057** independently counted distinct terms): full rebuild **0.12 / 0.11 / 0.11 s** over three fresh `--out` dirs · re-index into the same `--out` **0.11 s** · `--update` with no prior state **0.12 s** · `--update` with one file changed of 1,000 **0.08 s**. The README's old 0.30 s full-rebuild figure is replaced; its "this repository's own tree" row measures **216 files / 1,471 documents / 14,137 terms / 0.17 s** on a tracked-files-only export (the row in the README reads 1,462 / 14,099 / 0.20 s — it was measured before the task file it indexes had finished growing).
- **Prebuilt libraries shipped with the Dart package** (ReleaseSmall, rebuilt by the tester from the merge with `tool/build_native.sh` and **byte-identical** to the committed files): macOS arm64 `.dylib` **381,592 B** (`sha256 6a0bfc87…673233`), Android arm64 `.so` **381,728 B** (`sha256 caf7c367…6cee00`, the same bytes as the example app's `jniLibs` copy). Both export 10 `ss_*` symbols; `lib/src/bindings_generated.dart` regenerates byte-identically from the changed header.
- **Known gaps carried forward** (detail in `docs/tasks/S1-T4.md`'s Verdict): `--max-file-bytes`/`--max-total-bytes` are silently ignored on a non-`update` run, though the header and the new Dart doc comment read as unconditional; a full rebuild writes no `INDEX-STATE.json`, so the first `--update` after one reports everything as `added` (true and tested, but not stated where a reader would look); the README's repository-tree row is self-referential and will keep drifting; leak-freedom is still a code-review claim with nothing measuring it; the binding's conformance test still asserts top-1 only; judged-relevance fixtures are still uncovered (no vectors from `searchd index`); case folding is still simple, not full; the Linux binary is still never executed.
- **Suites on the merge**: `zig build test` **94/94** (87 + 7 new), `zig build test-abi` **12/12**, `zig build lib` **15/15** (all three ADR-0002 targets), `python3 -m unittest discover -s tests` **67/67**, `dart analyze` clean, `dart test` **16/16**, `flutter analyze` (example) clean, Android instrumentation **2/2** on the emulator.

## Standalone platform status (round B, 2026-09-17)

**S1-T3 and S1-T2 are `verified` and merged to `main`** (merge commits `beb4e4a` and `4ac5b3e`, on branches `task/S1-T3` `fc74854` and `task/S1-T2` `116a67a`), followed by `3602ebd`, which rebuilds the Dart package's prebuilt libraries from the merged engine. Search Simpli can now update an index in place, and a Dart program — including a Flutter app on an Android device — can use the engine in process.

- **Incremental folder indexing** (`ss_index_folder`, `searchd index --update`, `zig/src/indexer.zig`): per-file SHA-256 content hashes persisted in `<out>/INDEX-STATE.json`, unchanged files skipped (neither chunked nor re-analyzed — their tokens are reconstructed from the previous generation's postings), deleted files tombstoned, and the new generation published through the existing atomic path. One report JSON shape for both entry points: `generation`, `analyzer_id`, `added`, `changed`, `removed`, `skipped`, `too_large`, `unreadable`, `documents`, `terms`, `postings`. Caps: `--max-file-bytes` (default 10 MiB, over-cap files are never opened) and `--max-total-bytes` (default 512 MiB). Verified by the tester step by step: add → `added:1, skipped:2`; edit → `changed:1`; delete → `removed:1`; rename → `added:1, removed:1`; oversize → `too_large:1`, with the expected query result after each.
- **Re-publishing works.** `searchd index --out <existing dir>` now publishes the next free generation (`generation_alloc.nextFreeGeneration`) instead of failing with `PathAlreadyExists` — round A's sharpest rough edge, closed. An explicit `--generation N` is still honoured, collision and all.
- **Indexing is no longer superlinear in vocabulary.** `lexical_build.build` and `lexical_segment.zig`'s `validateIndex`/`decode` all replaced O(terms²) scans with hash lookups. Measured by the tester on one 1,000-file / 3.9 MB / **24,057-distinct-term** corpus (`scripts/gen_timing_corpus.py`, which now guarantees ≥20,000 distinct terms; the old generator produced 57): the pre-S1-T3 binary takes **7.10 s**, the merged one **0.12 s** — ~59×.
- **Timings** (ReleaseSafe, `/usr/bin/time -p`, tester-measured on the merge): full index 0.13 s · full re-index into the same `--out` 0.11 s · `--update` baseline with no prior state 0.13 s · `--update` with one file changed of 1,000 0.07 s · `--update` with nothing changed 0.07 s · this repository's own tree (208 files, 1,384 chunks, 13,819 terms) 0.18 s. Two independent runs over the same corpus produce byte-identical sections and manifest.
- **Crash-safe publication is portable now.** `publication.writeAtomicFile` (named temp file with `O_CREAT|O_EXCL`, write, `fsync`, `rename`/`renamePreserve`) replaces `Dir.createFileAtomic` for *every* file a publish writes — both immutable sections, `MANIFEST`, and `INDEX-STATE.json`. **This is the Android fix:** Zig 0.16's `createFileAtomic` uses `O_TMPFILE` when not replacing, and an app's SELinux policy denies that inside its own private directory, so `ss_import_json` failed there with `AccessDenied`. Proven on the emulator by the tester, before and after: the pre-S1-T3 library fails with `ss_import_json: AccessDenied`; the rebuilt one publishes generation 1 into `/data/user/0/…/files/…`, opens it, answers a query, and re-publishes generation 2. `ss_index_folder`, called through raw FFI on a folder in the same private storage, published generation 1 (`added:2`) then generation 2 (`added:1, skipped:2`) with `INDEX-STATE.json`.
- **Crash recovery, proven by killing a real process**: `SIGKILL` during publication left `documents-2.hybseg` orphaned with `MANIFEST` still at generation 1; `lifecycle.scan` reported `current_generation=1, orphan_document_files=1`; the previous generation still opened (1,002 documents) and answered queries; the next `--update` published generation 3 around the orphan.
- **Dart FFI package** (`bindings/dart/search_simpli/`): `ffigen`-generated bindings (regenerated by the tester, byte-identical), a `SearchSimpli` class (`open`/`query`/`evidence`/`status`/`close`) plus `importSnapshotJson`, typed results matching `contracts/search-tool.schema.json` field for field, and `CONTRACTS_VERSION` asserted against the native `ss_version()` at open (proven by building a library with a planted `9.9.9` and catching `ContractsVersionMismatchException`). `dart test` 12/12. Conformance, re-measured more strictly than the committed test asserts: **18/18 complete rankings** identical to the Python golden and **34/34 full top-5** identical to the `searchd` CLI, including 16 tester-invented queries. The Android instrumentation smoke test loads the library and answers a query on the `vizhi-phone` emulator (Android 14, API 34 — the "API 37" labels several files carried at the time were corrected in round C).
- **Prebuilt libraries shipped with the Dart package** (ReleaseSmall, rebuilt from the merge with `tool/build_native.sh`): macOS arm64 `.dylib` **381,000 B** (`sha256 89845bc3…9826b4`), Android arm64 `.so` **379,808 B** (`sha256 14665ece…81d4b3`, byte-identical to the example app's `jniLibs` copy). Both export 10 `ss_*` symbols, `ss_index_folder` included. A binding that ships binaries goes stale the moment the engine merges — rebuilding them is now part of the tester's merge routine.
- **Known gaps carried forward** (detail in each task file's Verdict): `--update` on a folder whose last indexable file was deleted fails with `NoDocuments` instead of publishing an empty generation; `lifecycle.scan` counts `INDEX-STATE.json` as an unknown file; a file that grows past `--max-file-bytes` loses its existing chunks while being reported only as `too_large`; unreadable/too-large files are counted but not listed by path; `skipped` conflates "unchanged" with "budget exhausted"; the macOS Dart library loader searches the working/script directory rather than the package root, so the README's path-dependency install needs `SEARCH_SIMPLI_LIBRARY_PATH`; the binding's conformance test still asserts top-1 only; judged-relevance fixtures are not covered by any binding conformance test (no vectors in `searchd index` yet); case folding is still simple, not full; the Linux binary is still never executed.
- **Suites on the merge**: `zig build test` **87/87**, `zig build test-abi` **12/12**, `zig build lib` **15/15** (all three ADR-0002 targets), `python3 -m unittest discover -s tests` **67/67**, `dart test` **12/12**, Android instrumentation **1/1**.

## Standalone platform status (round A, 2026-09-17)

**S1-T0 and S1-T1 are `verified` and merged to `main`** (merge commits `3466083` and `3a17af8`, on branches `task/S1-T0` `20750b9` and `task/S1-T1` `cbf2607`). Search Simpli now indexes and queries a folder with no Python in the loop, and exposes the engine over a C ABI.

- **C ABI** (`zig/include/search_simpli.h`, `zig/src/abi.zig`): `ss_open`/`ss_close`/`ss_status`/`ss_query`/`ss_evidence`/`ss_import_json`/`ss_free`/`ss_version`/`ss_last_error`. `ss_query` and `ss_evidence` reuse the JSON-RPC service's own writers, so their output is byte-identical to a `search_knowledge`/`read_chunk` response for the same request — asserted against golden JSON captured from a real `init-demo` + `serve` session (`zig build test-abi`, 12/12). No global mutable state beyond the handle; `ss_last_error` is a thread-local diagnostic. `contracts/CONTRACTS_VERSION` is `1.0.0` and is what `ss_version()` returns.
- **Libraries** (`zig build lib`, static + shared for `aarch64-macos`, `aarch64-linux-android` via `SS_ANDROID_NDK`, `x86_64-linux`). ReleaseSmall, measured on the merge: macOS `.a` 428,296 / `.dylib` 342,264; Android `.a` 389,226 / `.so` 326,976; Linux `.a` 403,114 / `.so` 340,168 bytes. (Each grew ~60 KB over S1-T0 alone once the Unicode tables joined the engine.)
- **Native indexing**: `line-window-v1` ported to Zig on codepoints, with a golden test against the live Python reference — 56 files, 85 chunks, **85/85 identical**, regenerable with `scripts/gen_chunk_golden.py`.
- **`analyzer-v2`**: NFC + Unicode letter/digit categories + simple case folding, from tables generated by `scripts/gen_unicode_tables.py` out of Python's `unicodedata` (Unicode 13.0.0); `analyzer-v1` (ASCII) stays available, and the analyzer id is recorded in the manifest so query time picks the matching tokenizer — through the CLI, the RPC service, and the C ABI alike. Full BM25 rankings (path, lines, raw score) are identical between Python and Zig on **36/36 queries** measured at verification; Tamil runs end to end at **10/10** judged top-1.
- **`searchd`** gained `index`, `query`, `evidence`, and `serve --http 127.0.0.1:<port>` (loopback-only, verified bound to `127.0.0.1` and unreachable from the LAN address). One static binary per platform, ReleaseSafe: macOS arm64 **851,096 B**, Linux x86_64 (musl) **5,294,368 B**.
- **Timing**: 1,000 files / 3.9 MB / 1,021 chunks index in **0.27 s** cold and **0.08 s** warm — but that corpus has only 57 distinct terms. `lexical_build.build` scans the term list linearly per token, so the same 1,000 files with a realistic 20,000-word vocabulary take **9.69 s**, and this repository itself (202 files, 13,297 terms) takes 0.77 s. A hash map there is the first performance fix before the CLI meets a real corpus.
- **Known gaps carried forward** (detail in each task file's Verdict): `searchd index` cannot re-publish into an output directory that already holds that generation (`error: PathAlreadyExists`; `--generation N` works) — S1-T3's job; case folding is simple, not full, so `ß`, `ﬁ`, `ﬀ` and `İ` do not fold; `scripts/gen_bm25_golden.py` needs `PYTHONHASHSEED` pinned to regenerate byte-identically; the Linux binary is cross-compiled but has never been executed.
- **Suites on the merge**: `zig build test` **77/77**, `zig build test-abi` **12/12**, `python3 -m unittest discover -s tests` **67/67**.

## Goal

Build toward a search solution that begins with files/folders and an LLM-friendly tool boundary, then evolves into a ground-up Zig hybrid lexical/semantic indexing platform.

## Current state

- The workspace began empty and is now a Git repository on `main`, published at `github.com/ilamgumaran/search-simpli`.
- A dependency-free Python behavioral reference is runnable.
- The reference scans selected UTF-8 text/source formats, makes cited chunks, calculates BM25, supports an offline vector channel, fuses by RRF, filters by path prefix, and emits an LLM evidence envelope.
- A Zig 0.16.0 in-memory retrieval core implements ASCII analysis, corpus-level BM25, exact cosine scoring for supplied vectors, independent candidate ranks, candidate cutoffs, RRF, deterministic top-k, and component explanations.
- Zig also has a versioned, checksummed immutable document/vector segment with caller-owned encoding/decoding and a golden ranking round trip.
- An in-memory inverted term dictionary and postings index calculates BM25 without scanning non-matching documents, then feeds the shared hybrid fusion path. Integrated golden tests cover segment decode through final ranking.
- A separate `HYBLEX01` immutable lexical section persists document lengths, dictionary terms/ranges, document frequency, and postings. Decoding it reproduces BM25 and final hybrid ordering without re-tokenizing stored text.
- `HYBMAN01` binds document/vector and lexical sections by generation, filenames, byte lengths, internal checksums, counts, analyzer id, and embedding model id.
- Filesystem publication syncs and atomically links generation-unique sections, then atomically replaces `MANIFEST`. Loading a published generation through both decoders and querying it is covered by integration tests.
- `WRITER.LOCK` provides advisory exclusive publication serialization. A recovery scanner reports current, unreferenced document/lexical, and unknown files without unsafe deletion.
- Current document segments are v3 and persist source path/start/end lines plus canonical required labels; the reader remains compatible with v1/v2 records.
- `Engine.open/query/evidence` turns a loaded published snapshot into cited lexical+semantic+RRF results using only caller-owned workspaces.
- Zig `Service` and JSON-RPC layers expose `search_knowledge`, scoped `read_chunk`, `list_sources`, and `index_status`. `searchd init-demo` publishes a snapshot and `searchd serve` runs the live stdin/stdout process.
- Query vectors are explicit for vector/hybrid RPC calls and validated against manifest dimensions; `candidate_k` is explicit and bounded.
- A versioned neutral interchange exports Python chunks, citations, vectors, analyzer id, and model id. `searchd import-json` validates it, builds both Zig sections, and atomically publishes a queryable generation.
- `embed_query.py` reproduces query vectors from the exact model stored in a Python index. In the live cross-language test, Zig imported 5 PPMI documents with 34 dimensions and returned `target/automobile.md:1-2` at vector rank 1 for `car`.
- Corpus-trained models now use a deterministic SHA-256 instance fingerprint, not only the `cooccurrence-ppmi-v1` family label. Legacy reference indexes derive it on load.
- `zig_gateway.py` exposes text-only agent/tool requests, verifies model fingerprint and dimensions against Zig status at startup, injects vectors for semantic modes, passes lexical/read/list/status through, and forbids callers from overriding vectors.
- Live gateway requests returned `automobile` for `car`, `physician` for `doctor`, and exact lexical evidence for `automobile`. A different folder model was rejected before serving with exit code 2.
- An optional provider-neutral neural path now batches document and query embeddings separately. The first adapter pins FastEmbed 0.8.0 with `BAAI/bge-small-en-v1.5`, validates a 384-dimensional conformance fingerprint, and keeps the base mode dependency-free.
- The 20-query mixed-domain diagnostic measured success@1 of 0.60 for BM25, 0.70 for PPMI vector, 0.90 for neural vector, and 0.85 for equal-weight neural RRF. At k=3 neural vector and hybrid both reached 1.0 success; vector MRR was higher.
- A neural snapshot completed the full Python → interchange → Zig generation 3 → gateway path. Live `car` and `doctor` queries returned the cited `automobile` and `physician` passages from 384-dimensional vectors.
- Path rules now assign canonical all-required access labels. Python and Zig filter both retrieval channels before ranks, then enforce the same principal on source listing and chunk reads. The gateway injects trusted labels and rejects caller forgery.
- `HYBSEG01` v3 persists required labels while reading v1/v2 as unlabeled/public. A live generation-4 run proved anonymous, tenant, and engineering views across search/list/read.
- Reference indexes now record chunker identity and per-file SHA-256 hashes. Compatible incremental builds reuse unchanged extraction/vectors, relabel ACL-only changes, remove deleted files, preserve transiently unreadable prior files as reported stale data, and embed only changed/new neural chunks.
- A real BGE update reused 11/13 files, embedded only two changed/new chunks, removed one deleted path, and published the complete result as Zig generation 5. The new rollback passage ranked first in Python and Zig.
- A reproducible files/folders scale harness now measures full and unchanged Python builds, vector movement, embedding-call avoidance, and JSON artifact size. At 5,000 one-chunk Markdown files, no-vector preparation took 591.6 ms/3.31 MB; synthetic 384-dimensional preparation took 4.54 s/10.98 MB, while unchanged preparation took 2.02 s and embedded zero chunks.
- A real Zig engine benchmark now reports total, lexical, and ranking p50/p95 timings. It exposed quadratic rank assignment as the first query bottleneck: hybrid p50 at 8,000 exhaustive 32-dimensional candidates was 174.6 ms.
- An allocation-free heap-sort rewrite improved complexity but still spent 43.0 ms median in ranking at 8,000 candidates. Deterministic in-place pdq ordering reduced the equivalent final p50 to 0.417 ms and continued to 1.69 ms at 32,000 candidates. Raw before/intermediate/after evidence and limits are preserved.
- A recreation kit now preserves the objective, executable functional/non-functional specification, acceptance gates, and staged coding-agent prompts. A use-case library provides a durable catalog, contribution template, and initial personal-files, codebase-agent, and authorized-team scenarios.
- Python and Zig now share the `candidate_k >= top_k` fusion-depth rule. A live Zig request with `candidate_k=2` returned `hybrid-guide` with both component ranks equal to 2.
- The root test harness explicitly loads every engine module; 57/57 Zig tests actually execute and pass using the temporary official toolchain. Live process tests cover Python export, Zig import/publication, semantic query, and principal-isolated authorization.
- A local JSON-lines tool process exposes `search_knowledge`, `read_chunk`, `list_sources`, and `index_status` for an LLM/skill/agent wrapper.
- Retrieval can run as lexical-only, vector-only, or hybrid. Evaluation suite v2 adds graded 1–3 judgments and nDCG@k while retaining recall@k, success@k, MRR, returned paths, matched grades, and per-query failures. Version 1 binary suites remain supported.
- `relevance_smoke.py` binds corpus hashes, suite, model identity, modes, and cutoff into a profile id; it enforces explicit floors or same-profile baseline tolerances. The 10-product/4-query dependency-free fixture scores 1.0 on nDCG@10, MRR@10, success@10, and macro recall@10 and runs in CI.
- Expensive smoke profiles can save a newly built index and reuse it later; prebuilt reuse validates the corpus root and reconstructs the exact neural provider identity before semantic evaluation.
- A deterministic WANDS adapter downloads no external data into the repository. A requested 10,000-product/1,000-query cap honestly produced 10,000 products and 47 queries because WANDS has only 480 queries and the sample preserves every Exact/Partial product for each retained query.
- The corrected one-product/one-chunk WANDS lexical run scored nDCG@10 0.6866, MRR@10 0.8574, success@10 0.9149, and macro recall@10 0.0528. The failed first representation produced 41,377 chunks and nDCG@10 0.5562 because duplicate chunks consumed result slots; both raw runs are preserved.
- A 500-product/11-query WANDS neural profile completed with nDCG@10 lexical/vector/hybrid of 0.4176/0.4550/0.4287. BGE vector improved every aggregate over lexical; equal-RRF improved nDCG, success, and recall but regressed MRR and underperformed vector-only. Neural construction took 313.4 seconds while three-mode evaluation took 0.934 seconds. Larger 10k and 2k neural attempts were stopped after exceeding an interactive smoke duration.
- The dependency-free Python suite now executes 67/67 tests; the latest recorded
  pinned-toolchain Zig run executes 87/87 tests (57 before round A, 59 with the
  C ABI, 77 with the native chunker/analyzer-v2/CLI, 87 with round B's
  incremental indexing and portable publish), plus `zig build test-abi`'s
  12/12 C-ABI conformance checks and the Dart package's 12/12.
- The CAP-11 graded-relevance extension now has a formal capability change record,
  template-aligned UC-005, and resolved CFT-10 against INV-09. Process step 6b
  did not receive qualifying approval before PR #3 merged as `2a512cb`; the
  record now preserves that historical process exception rather than inventing
  retroactive approval.
- E-01A real-folder judgment packs are claimed in issue #4 and specified through
  capability-process step 6. Implementation is intentionally paused at step 6b
  until a human maintainer approves its invariants, CFT-11–13 resolutions, and
  acceptance gate on the final specification commit.
- The first judged run showed hash-vector hybrid retrieval regressing from 1.0 to 0.5 at `k=1`, so new indexes default to no vectors; hash mode is explicit test-only behavior.
- A dependency-free `cooccurrence-ppmi-v1` distributional model provides real corpus-trained semantic vectors. On two controlled vocabulary-mismatch queries, lexical scored 0.0 and vector/hybrid scored 1.0 at `k=1`; this is synthetic evidence, not a modern embedding benchmark.
- There is no representative user-derived judged corpus, authenticated identity/token adapter, label-aware BM25 statistics, directory-sync backend, reader-safe generation GC, WAL/delta-segment writer, filesystem watcher, MCP/network adapter, or direct LLM generation call yet. WANDS is real-label product-domain evidence but the 10k capped profile is biased and not score-comparable to full WANDS. Incremental preparation still publishes a complete Zig snapshot. Scale evidence is synthetic and does not yet cover 384-dimensional Zig queries, persisted startup/memory, or concurrency.

## Important decisions

1. Retrieval and generation remain separate.
2. Python is the behavioral/evaluation reference; Zig is the durable engine path.
3. Embedding inference starts outside the Zig engine.
4. BM25 and vector candidates are retrieved independently and fused with RRF.
5. Citations, authorization scope, and embedding/index versions are first-class data.
6. Complexity such as HNSW, WAND, quantization, or sharding requires benchmark evidence.

## Resume commands

```sh
cd /Users/ilam/workspace/search-platform-exploration
python3 -m unittest discover -s tests -v
python3 search.py index fixtures/knowledge --out .search/index.json
python3 search.py context .search/index.json "How should hybrid search combine results?"
python3 knowledge_tools.py .search/index.json
python3 evaluate.py .search/index.json fixtures/judgments.json --top-k 1
python3 relevance_smoke.py fixtures/relevance-smoke/corpus \
  fixtures/relevance-smoke/judgments.json --mode lexical --top-k 10 \
  --min-ndcg 1 --min-mrr 1 --min-recall 1 --min-success 1
python3 scripts/prepare_wands_smoke.py /tmp/WANDS/dataset \
  /tmp/search-simpli-wands-10k --max-products 10000 --max-queries 1000
python3 benchmark_scale.py --sizes 100 1000 5000 --dimensions 384
python3 search.py index fixtures/semantic-knowledge --vector-mode cooccurrence --out /tmp/python-index.json
python3 search.py index fixtures/semantic-knowledge --vector-mode cooccurrence \
  --incremental-from /tmp/python-index.json --out /tmp/python-index-next.json
python3 export_zig.py /tmp/python-index.json --generation 1 --out /tmp/zig-snapshot.json
python3 embed_query.py /tmp/python-index.json car
python3 zig_gateway.py /tmp/python-index.json /tmp/search-snapshot

# Optional neural environment after installing fastembed==0.8.0:
.search/fastembed-env/bin/python search.py index fixtures/mixed-knowledge \
  --vector-mode neural --model-cache .search/models --out /tmp/mixed-neural-index.json
.search/fastembed-env/bin/python evaluate.py /tmp/mixed-neural-index.json \
  fixtures/mixed-judgments.json --top-k 3 --model-cache .search/models
```

If `/tmp/zig-aarch64-macos-0.16.0` still exists:

```sh
cd /Users/ilam/workspace/search-platform-exploration/zig
/tmp/zig-aarch64-macos-0.16.0/zig build \
  --global-cache-dir /tmp/zig-global-cache \
  --cache-dir /tmp/search-zig-test-cache test

/tmp/zig-aarch64-macos-0.16.0/zig build run -- \
  import-json /tmp/search-snapshot /tmp/zig-snapshot.json

/tmp/zig-aarch64-macos-0.16.0/zig build -Doptimize=ReleaseFast
./zig-out/bin/searchd benchmark 8000 32 51 hybrid
```

Otherwise repeat the official download commands in `EXPERIMENTS.md`, or install Zig 0.16.0 and run `zig build test`.

## Best next step

Complete the E-01 real-folder relevance sequence before making production claims:

1. Review and explicitly approve the pending E-01A specification on its final
   commit, covering invariant compliance, CFT-11–13, and the acceptance gate.
2. Implement and verify the content-free judgment-pack workflow described there.
3. Select one representative single-owner folder and have a human data owner
   author/confirm 50–100 tuning/holdout questions with expected passages.
4. Compare BM25, PPMI, BGE, and equal-RRF on the sealed pack, preserving
   per-query wins/losses; only then test weighted fusion or routing.
5. Use WANDS full/larger repeated profiles as a complementary product-domain
   check, not a substitute for the intended files-and-folders evidence.

This sequence determines whether semantic retrieval produces enough value on
the real target corpus to justify the vector infrastructure and default mode.

In parallel, the next self-contained scale milestone is a persisted 384-dimensional benchmark covering snapshot bytes, open/startup time, resident memory, and concurrent long-lived queries. That evidence decides whether the next engine feature should be candidate-union fusion, ANN, lexical pruning, or only better process/service management.

## Choices still needed

- corpus type: personal documents, source repositories, mixed, or another domain;
- embedding preference: local/private versus hosted;
- LLM preference and whether generation may send retrieved content to a hosted service;
- target scale and freshness: approximate files/chunks, update rate, and latency goal;
- initial interface: CLI, local HTTP API, or MCP-compatible tool adapter.

These choices do not block the current reference. They materially affect E005B and the service boundary.
