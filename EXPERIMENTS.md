# Experiment ledger

This file is append-oriented. Record the hypothesis, setup, exact command, observation, conclusion, and next action. Do not rewrite unsuccessful attempts out of history.

## 2026-07-11 — E001: establish the local behavioral reference

**Hypothesis:** A dependency-free implementation can validate the files → chunks → hybrid ranks → cited evidence contract before a durable engine exists.

**Setup:** Two small Markdown fixtures. Python 3.11.1. Line-window chunks, BM25, deterministic hash vectors, RRF with `k=60`, JSON persistence.

**Commands:**

```sh
python3 -m unittest discover -s tests -v
python3 search.py index fixtures/knowledge --out .search/index.json --vector-mode hash
python3 search.py query .search/index.json "How should hybrid search combine results?" --top-k 2
```

**Worked:**

- Three tests passed: Unicode/case tokenization, lexical result/citation, and context/path filtering.
- Two files produced two chunks with no skipped files.
- The hybrid-search fixture ranked first for the fusion question.
- Human-readable and structured context responses share the same retrieval function.

**Did not prove:**

- Hash vectors do not measure semantic understanding.
- The fixture corpus is too small for meaningful relevance or performance claims.
- JSON full rebuilds do not validate incremental indexing or crash recovery.

**Conclusion:** The contract is usable as a reference. The next relevance experiment requires real embeddings and judged questions.

## 2026-07-11 — E002: compile the Zig scoring seed on stable Zig

**Hypothesis:** The initial scoring seed can be pinned to and tested with the current stable Zig release.

**Setup:** No global Zig installation was present. The official Zig download page listed 0.16.0 as the stable release. The macOS ARM64 archive was unpacked at `/tmp/zig-aarch64-macos-0.16.0`.

**Download:**

```sh
curl -L https://ziglang.org/download/0.16.0/zig-aarch64-macos-0.16.0.tar.xz -o /tmp/zig-aarch64-macos-0.16.0.tar.xz
tar -xJf /tmp/zig-aarch64-macos-0.16.0.tar.xz -C /tmp
```

Source: <https://ziglang.org/download/>

**Attempt 1 — did not work:**

```sh
/tmp/zig-aarch64-macos-0.16.0/zig build test
```

Zig could not open its default global cache at `/Users/ilam/.cache/zig` because the workspace sandbox denied that write.

**Adjustment:** Use explicit writable cache paths under `/tmp`.

**Attempt 2 — did not work:** The 0.14-era `build.zig` supplied `root_source_file` directly to `addExecutable`. Zig 0.16.0 requires a `root_module` created with `b.createModule`. The CLI also used removed process-argument and older print APIs.

**Changes:**

- created executable/test modules and passed them as `root_module`;
- changed the entry point to accept `std.process.Init.Minimal` and iterate `init.args`;
- supplied the formatting tuple to `std.debug.print`.

**Final validation — worked:**

```sh
cd zig
/tmp/zig-aarch64-macos-0.16.0/zig build \
  --global-cache-dir /tmp/zig-global-cache \
  --cache-dir /tmp/search-zig-test-cache test
/tmp/zig-aarch64-macos-0.16.0/zig build \
  --global-cache-dir /tmp/zig-global-cache \
  --cache-dir /tmp/search-zig-run-cache run -- --help
```

- All three scoring tests passed with exit code 0.
- The `searchd --help` seed compiled and ran with exit code 0.

**Conclusion:** Pin Zig 0.16.0 for the next phase. Toolchain/API drift is real and should remain visible in the project state. The current Zig code validates ranking primitives only; it is not yet an index.

## 2026-07-11 — E003: allocation-free Zig hybrid retrieval core

**Hypothesis:** Before persistent segments exist, Zig can provide a testable ground-up retrieval core whose result semantics match the architecture: independent lexical and semantic scores/ranks, bounded candidate lists, RRF, deterministic top-k, and explanations.

**Setup:** Zig 0.16.0. Caller-owned document/result slices. ASCII token analysis, corpus-level BM25 scans, exact cosine scan over supplied vectors, rank assignment, per-channel candidate cutoff, and RRF.

**Command:**

```sh
cd zig
/tmp/zig-aarch64-macos-0.16.0/zig build \
  --global-cache-dir /tmp/zig-global-cache \
  --cache-dir /tmp/search-zig-final2-cache test --summary all
/tmp/zig-aarch64-macos-0.16.0/zig build \
  --global-cache-dir /tmp/zig-global-cache \
  --cache-dir /tmp/search-zig-demo2-cache run -- demo
```

**Worked:**

- Thirteen Zig tests cover analysis, BM25, cosine, lexical-only retrieval, semantic-only retrieval, overlap fusion, candidate depth, empty evidence, and invalid workspace/vector dimensions.
- The demo returned `hybrid-guide` first because it was rank 2 in both channels; the single-channel rank-1 documents followed it.
- All result storage is caller-owned, making allocation and capacity explicit.
- Result explanations preserve raw component scores, component ranks, and fused score.

**Initial behavior adjusted:** The first demo gave every positive cosine score a fusion contribution. Even a weak semantic rank could therefore help a primarily lexical result. Real hybrid retrieval should fuse bounded candidate sets, so `candidate_k` is now applied independently after each channel ranks and before RRF.

**Did not prove:**

- Manually supplied vectors do not validate semantic relevance.
- ASCII tokenization is not sufficient for multilingual or fully general source/document search.
- Corpus statistics and rank assignment are scan-based and quadratic; this is a correctness baseline, not a scalable index.
- No files, manifests, checksums, postings, updates, or recovery paths are implemented in Zig yet.

**Conclusion:** The in-memory Zig behavior is now concrete enough to serve as the query oracle for persistent postings/vector segments. Real embeddings and a judged corpus remain the relevance priority; binary segment work is the next independent engine priority.

## 2026-07-11 — E004: immutable Zig segment and ranking round trip

**Hypothesis:** A minimal binary format can preserve stored documents and vectors, detect corruption, use caller-owned decode storage, and reproduce hybrid query results before postings or filesystem publication exist.

**Format:** 36-byte little-endian versioned header, document records containing id/text/vector, and FNV-1a checksum over header metadata plus payload. The byte layout is specified in `docs/segment-format-v1.md`.

**Worked:**

- Encode calculates exact capacity and rejects undersized buffers or inconsistent vector dimensions.
- Inspect rejects bad sizes and checksum changes in both header metadata and payload.
- Decode borrows id/text bytes without copying and writes aligned vectors into caller-owned `f32` storage.
- A golden test runs the same query before encoding and after decoding, then compares result ids, component ranks, and fused scores.
- The full Zig suite now contains nineteen passing tests.

**Design correction:** The initial checksum covered only payload bytes. That left document count and vector-dimension metadata outside the checksum. The implementation now hashes header bytes 0–27 followed by the payload, excluding only the checksum field itself.

**Did not prove:**

- The codec is not published atomically to a filesystem and has no manifest or recovery behavior.
- It stores text and dense vectors without compression.
- FNV-1a detects accidental changes but does not provide cryptographic authenticity.
- It is not an inverted lexical index; BM25 still scans stored text.

**Conclusion:** The engine now has a tested persistence boundary and a correctness oracle. The next storage milestone is a term dictionary plus postings section; the next relevance milestone remains real embeddings over a judged corpus.

## Unrun experiments

- E005B: modern neural embedding provider versus BM25 and PPMI on 50–100 judged queries.
- E006: fixed line windows versus heading/structure-aware chunks.
- E007: Python golden results versus Zig postings/vector implementation.
- E008: exact vector scan capacity and latency breakpoint.

## 2026-07-11 — E004B: inverted postings versus the scan oracle

**Hypothesis:** An inverted term dictionary and postings can avoid scanning non-matching text while preserving the scan oracle’s BM25 and hybrid result semantics.

**Implementation:** Two-pass, caller-owned build. Each term records document frequency and a contiguous posting range. Each posting records document index and term frequency. The index retains document lengths and average length. Query terms traverse matching posting ranges and produce a lexical score array consumed by the shared hybrid fusion function.

**Worked:**

- Repeated terms produce one per-document posting with the correct term frequency.
- Postings BM25 matches scan BM25 within `0.000001` for every document in the golden corpus.
- Postings-driven hybrid results match scan-driven ids, component ranks, and fused scores.
- An integrated segment → decode → postings build → query test preserves the original in-memory result ordering.
- The Zig suite now contains twenty-four passing tests.

**Did not prove:**

- The first-seen dictionary uses linear lookup and the builder uses repeated token scans; build complexity is not production-ready.
- Postings are not yet serialized, compressed, skipped, or block-max annotated.
- Query score collection still allocates no heap but requires a dense caller-owned score per document.
- Unicode analysis and phrase positions remain undecided.

**Conclusion:** The lexical engine now has an actual inverted retrieval path and a scan oracle guarding correctness. Persisting dictionary/postings sections is the next engine storage step.

## 2026-07-11 — E004C: local knowledge tools for an LLM or agent

**Hypothesis:** The reference index can support skill/tool/agent behavior through narrow retrieval operations without exposing unrestricted filesystem access or coupling to one LLM provider.

**Implementation:** Newline-delimited JSON-RPC 2.0 over standard input/output with `search_knowledge`, `read_chunk`, `list_sources`, and `index_status`.

**Worked:**

- Search returns the existing cited evidence envelope and supports pre-ranking path scope.
- A returned chunk id can be read authoritatively without accepting a file path from the model.
- Source listing reveals navigation metadata without dumping file content.
- Status reports snapshot freshness, vector mode, counts, and skipped inputs.
- Structured validation rejects missing chunks, unknown methods such as `read_file`, bad `top_k`, and unknown parameters.
- The process emits a parse error for malformed JSON and continues serving the next request.
- Seven Python tests pass, and a live piped two-request session returned search evidence followed by status.

**Did not prove:**

- No actual LLM provider is connected, so answer generation and citation faithfulness are not evaluated.
- JSON-lines is not yet an MCP or network service transport.
- Path prefix is a scope mechanism, not authenticated per-user authorization.
- Index updates require rebuilding and restarting the process.

**Conclusion:** The “LLM on top” boundary is now runnable and model-independent. Connecting a chosen model becomes an adapter/evaluation task rather than a search-engine redesign.

## 2026-07-11 — E004D: judged retrieval modes expose fake-vector regression

**Hypothesis:** Running lexical, vector, and hybrid modes against the same explicit judgments will expose whether a vector channel actually improves relevance.

**Setup:** Two fixture queries, path-level relevance judgments, `k=1`, macro recall, success rate, and mean reciprocal rank. Compared an index without vectors to an explicitly generated deterministic hash-vector index.

**Observed:**

| Run | Recall@1 | Success@1 | MRR |
|---|---:|---:|---:|
| no vectors / lexical | 1.0 | 1.0 | 1.0 |
| no vectors / hybrid | 1.0 | 1.0 | 1.0 |
| hash / vector | 0.5 | 0.5 | 0.5 |
| hash / hybrid | 0.5 | 0.5 | 0.5 |

**What did not work:** The hash channel ranked the LLM-contract chunk over the relevant hybrid-search chunk for the fusion question. RRF then promoted the wrong vector-supported result above the correct lexical result. Dense vectors alone did not add meaning.

**Decision:** Index creation now defaults to `vector_mode=none`. Hash mode requires an explicit flag and evaluation reports warn that it measures mechanics, not semantics. Hybrid mode safely reduces to lexical when no vector channel exists.

**Worked:** The evaluator reports aggregate and per-query results, validates judgment suites, and made a relevance regression visible enough to change the default. Eleven Python tests pass.

**Did not prove:** Two queries cannot select a real embedding model or fusion configuration. E005 still requires a representative corpus, substantially more judgments, and a real versioned embedding provider.

## 2026-07-11 — E005A: ground-up distributional semantics

**Hypothesis:** A corpus-trained word co-occurrence model with PPMI weighting can retrieve related vocabulary without exact token overlap, providing a real ground-up semantic baseline without external dependencies.

**Setup:** Five synthetic files. Training files use “car” and “doctor”; scoped target files use “automobile” and “physician” in deliberately parallel contexts. Query retrieval is restricted to `target/`, where the exact query words do not occur. Two judged queries at `k=1`.

**Observed:**

| Mode | Recall@1 | Success@1 | MRR |
|---|---:|---:|---:|
| lexical | 0.0 | 0.0 | 0.0 |
| co-occurrence vector | 1.0 | 1.0 | 1.0 |
| hybrid | 1.0 | 1.0 | 1.0 |

**Worked:** The model learned context similarity, retrieved both vocabulary-mismatched targets at rank 1, requires no network/model dependency, and stores its id/dimensions/window/vocabulary cap with the index.

**Did not prove:** The corpus was designed to make the distributional relationship learnable. This result does not establish quality on real documents, unknown terms, polysemy, negation, or broader language. Dense model storage is capped but quadratic. It is not a neural embedding benchmark.

**Conclusion:** Ground-up semantic retrieval is now functional and distinguishable from the failed hash projection. E005B remains: compare it, BM25, fusion, and a modern versioned neural embedding model on a representative judged corpus.

## 2026-07-11 — E005C: persistent lexical section and Zig test-harness audit

**Hypothesis:** A separate immutable lexical byte section can restore dictionary/postings state after restart and preserve BM25/hybrid behavior without tokenizing stored text again.

**Implementation:** `HYBLEX01` with a 64-byte versioned header, document-length section, variable term dictionary, fixed-width postings, caller-owned aligned decode arrays, and FNV-1a over header metadata plus payload.

**Worked:**

- Persisted postings reproduce in-memory BM25 scores within `0.000001`.
- Persisted lexical scores preserve final hybrid ids, lexical ranks, semantic ranks, and fused scores.
- Header and payload changes are detected, caller capacities are explicit, and inconsistent posting metadata is rejected.
- The byte layout and validation order are specified in `docs/lexical-segment-format-v1.md`.

**Validation failure discovered:** A direct filtered Zig run returned `All 0 tests passed`. Zig lazily analyzed the root module exports, so the prior build step compiled modules but did not prove that every imported module’s test blocks executed. Earlier ledger statements describing 13, 19, or 24 “passing Zig tests” were based on declared test counts plus a successful build and were too strong.

**Correction:** `root.zig` now contains a test that explicitly references every engine module, forcing their test suites into the runner. The first real full run executed 30 tests: 29 passed and one failed. The failing corruption test expected `ChecksumMismatch` but received `InvalidSectionLength` because count-derived validation happened before header checksum verification. Inspection now verifies declared total size and checksum before trusting derived section lengths.

**Final evidence:** A direct `zig test src/root.zig` and `zig build test --summary all` both report 30/30 executed tests passing.

**Did not prove:** The two persistent sections are not yet bound by an atomic manifest, published through crash-safe filesystem operations, compressed, merged, or incrementally updated.

**Conclusion:** Durable exact lexical state now exists and the Zig validation evidence is trustworthy. The next storage milestone is an atomic generation manifest and publication/recovery protocol.

## 2026-07-11 — E005D: atomic generation selection and restart query

**Hypothesis:** Generation-unique immutable section files plus one atomically replaced manifest can ensure readers observe either the old complete snapshot or the new complete snapshot, never a half-published combination.

**Implementation:** `HYBMAN01` records generation, analyzer/model ids, safe section filenames, byte lengths, internal checksums, and shared counts. `publication.zig` validates all bytes, writes and syncs non-replacing immutable files, then syncs and atomically replaces `MANIFEST`. `loadCurrent` reads only that selected generation and validates it again.

**Worked:**

- Generation 1 publishes to a temporary filesystem directory and loads successfully.
- Loaded document/vector and lexical bytes decode, score, fuse, and return the expected hybrid top result.
- Generation 2 replaces manifest selection and is observed by the next load.
- Reusing generation-1 immutable filenames fails with `PathAlreadyExists`; generation 1 remains current.
- A corrupted document section is rejected before `MANIFEST` becomes visible.
- Manifest metadata/payload corruption and cross-section count disagreement are separately rejected.
- The fully loaded Zig suite now executes 38/38 tests successfully.

**Did not prove:** Portable directory sync is unavailable through the current Zig API used here, so file sync plus atomic name replacement establishes process-level atomicity but not every power-loss durability guarantee. Writer locking, reader-safe garbage collection, crash-orphan scanning, and incremental updates remain.

**Conclusion:** A restartable, coherent, atomically selected Zig search snapshot now exists. The next durability work is writer serialization, platform-specific directory sync, and generation lifecycle management—not another index-format redesign.

## 2026-07-11 — E005E: writer lease and conservative recovery scan

**Hypothesis:** One advisory writer lease can serialize local publication, while a non-destructive directory scan can identify current and unreferenced generation files without racing active readers.

**Worked:**

- A second writer handle cannot acquire `WRITER.LOCK` while the first exclusive lease is held.
- Releasing the first lease allows the next writer to acquire it.
- `publishSerialized` holds the lease around the complete immutable-files-plus-manifest transaction.
- With a valid current manifest, scanning reports its two referenced files, one orphan document file, one orphan lexical file, and one unrelated file.
- Without a manifest, recognized generation files are reported as orphans.
- The full engine suite now executes 41/41 tests successfully.

**Deliberate non-action:** The scanner does not delete orphans. A file unreferenced by the newest manifest may still be held by a reader using an older immutable snapshot. Destructive cleanup requires a reader lease, epoch, reference-count, or conservative retention policy.

**Did not prove:** Advisory locks only coordinate compliant writers. Distributed writer failover, compare-and-publish generation allocation, invalid-manifest rollback, directory sync, and safe deletion remain.

**Conclusion:** Local publication is serialized and recovery state is observable. The next engine boundary is a loaded snapshot/query API with citation-bearing results, then a service adapter.

## 2026-07-11 — E005F: citation-bearing persisted engine query

**Hypothesis:** A restart-loaded Zig engine can produce the same evidence unit required by an LLM tool—content plus source path/line citation and component ranking explanation—without reading source files at query time.

**Changes:** `hybrid.Document` and `Result` gained path/start/end fields. The `HYBSEG01` writer now emits format version 2 with citation metadata; the reader accepts both versions 1 and 2. `Engine.open` decodes one validated published snapshot, and `Engine.query/evidence` scores persisted postings/vectors and joins results to stored content.

**Worked:**

- V2 citation metadata round-trips and inconsistent partial citations are rejected.
- A manually constructed v1 record loads through the v2 reader with empty citation fields.
- Hybrid results preserve citation fields before persistence.
- A filesystem-published snapshot opens into `Engine`, executes BM25 + exact cosine + RRF, and returns the expected passage with chunk id, `guides/hybrid.md:1-6`, content, and both component ranks.
- The full suite executes 45/45 Zig tests successfully.

**Did not prove:** There is no Zig JSON/MCP/HTTP adapter yet, query embeddings are still supplied by the caller, authorization filters are absent, and v1 snapshots require reindexing to gain citations.

**Conclusion:** The durable Zig core now reaches cited evidence. The next product boundary is a local service/tool adapter plus a real query-embedding provider.

## 2026-07-11 — E005G: live persisted Zig JSON-RPC tool process

**Hypothesis:** The persisted Zig engine can expose the same narrow search/read/list/status contract as the Python reference and serve real newline-delimited JSON-RPC requests without granting filesystem authority.

**Worked:**

- `Service` implements scoped lexical/vector/hybrid search, authoritative scoped chunk reads, sorted source listing, and index status.
- Path exclusions and retrieval mode are applied before component ranks.
- `rpc.zig` validates JSON-RPC envelopes, known fields, top-k, candidate depth, retrieval mode, query-vector dimensions/values, and scoped reads.
- `searchd init-demo` publishes a real generation through the writer/manifest path.
- `searchd serve` loads that generation, allocates workspaces from manifest counts, and processes stdin/stdout JSON lines.
- A live process received four requests and returned valid status, lexical-search, hybrid-search, and cited read responses.
- The full suite executes 51/51 Zig tests and 13/13 Python tests successfully.

**Observed ranking nuance:** With three semantic candidates admitted, a weak rank-3 contribution narrowly promoted the lexical guide in the hybrid request. Candidate depth is now an explicit RPC parameter; `candidate_k: 2` removes that tail contribution and returns the passage supported near the top of both channels.

**Follow-up evidence:** A second live process request with `candidate_k: 2` returned `hybrid-guide` at `guides/hybrid.md:1-6`, with both lexical and vector rank equal to 2. Python core, CLI, and tool-server candidate depth were then aligned with the same `candidate_k >= top_k` rule.

**Security correction:** Python `read_chunk` now accepts the same optional path prefix. An id learned under one scope cannot be reused under another; out-of-scope and unknown ids share the same error.

**Did not prove:** Query vectors still come from the caller, not a real neural provider. The loop is single-threaded, path prefixes are not authenticated authorization, and there is no MCP/HTTP framing, deadlines, metrics, or direct LLM generation.

**Conclusion:** Both simple Python and durable Zig implementations now provide a runnable LLM-tool retrieval surface. The next relevance/product risk is real embedding inference and representative authorization-aware evaluation.

## 2026-07-11 — E005H: Python files-to-Zig persisted semantic bridge

**Hypothesis:** A language-neutral snapshot contract can carry cited chunks and a ground-up semantic model from the simple Python file indexer into the durable Zig engine, while query vectors from the exact same model preserve meaning-based retrieval.

**Setup:** The Python semantic fixture was indexed with `cooccurrence-ppmi-v1`. `export_zig.py` emitted interchange format v1 with generation, analyzer/model identity, cited documents, and vectors. Zig `import-json` validated the complete payload, rebuilt ASCII lexical postings, encoded both immutable sections and their manifest, and published generation 1.

**Worked:**

- Python exported 5 documents with 34-dimensional PPMI vectors.
- Zig imported them as 34 lexical terms and 68 postings, then reopened the generation through the ordinary persisted engine path.
- `index_status` reported generation 1, analyzer `ascii-alnum-v1`, model `cooccurrence-ppmi-v1`, 34 vector dimensions, and 5 documents.
- `embed_query.py` reconstructed the exact index model and embedded `car`.
- A scoped Zig vector request returned `target/automobile.md:1-2` at vector rank 1. This is the intended vocabulary-mismatch case: the query says `car` and the evidence says `automobile`.
- Import validation rejects unsupported format/analyzer metadata, inconsistent dimensions, and malformed document/vector data.
- The full validation suites execute 18/18 Python tests and 53/53 Zig tests.

**Did not work:** A hand-copied vector request returned JSON-RPC `Invalid params` because the manually assembled array did not preserve the model's required shape. Directly piping a machine-generated vector from `embed_query.py` succeeded. Model vectors must travel as checked data, not presentation text.

**Did not prove:** The five-document fixture does not establish real-world quality, throughput, memory use, or neural embedding value. JSON import currently materializes the full payload. The caller still orchestrates query embedding, and model-id routing, authorization, Unicode parity, incremental updates, and direct answer generation remain outside the bridge.

**Conclusion:** Files-to-durable-Zig search is now a working vertical slice rather than an architectural placeholder. The next semantic step is not another persistence format: automate the query-model gateway and run E005B on a representative judged corpus with a versioned modern provider.

## 2026-07-11 — E005I: text-only, fail-closed query-embedding gateway

**Hypothesis:** An LLM-facing process can accept ordinary text search parameters, select the exact model used by the persisted Zig snapshot, and inject compatible query vectors without exposing vector mechanics or weakening lexical search.

**Correctness issue discovered:** `cooccurrence-ppmi-v1` named an algorithm family, not one trained artifact. Two folders can produce incompatible vocabularies and weights under the same family name, and dimensions alone do not prove compatibility.

**Implementation:** PPMI training now hashes a canonical representation of its family, window, dimensions, vocabulary, and learned word vectors. The full fingerprint becomes the model id exported into `HYBMAN01`; the shorter family remains descriptive metadata. `zig_gateway.py` reads Zig `index_status` at startup, compares the full id and dimensions, embeds vector/hybrid queries, forwards lexical/read/list/status unchanged, and rejects caller-supplied vectors.

**Worked:**

- Identical trained artifacts produce the same fingerprint; different corpora produce different fingerprints.
- Legacy family-only Python indexes derive an exact fingerprint when loaded.
- The live snapshot reported generation 2, 5 documents, 34 dimensions, and model `cooccurrence-ppmi-v1-sha256-78fa...2931`.
- A text-only vector query `car` returned `target/automobile.md:1-2` at vector rank 1.
- A text-only hybrid query `doctor` returned `target/physician.md:1-2` at vector rank 1.
- A text-only lexical query `automobile` returned the exact passage at lexical rank 1 without embedding.
- Pairing the snapshot with a different folder model was rejected before serving; the gateway exited 2 and reported both incompatible identities/dimensions.
- The Python suite now executes 25/25 tests; the existing Zig engine suite remains 53/53.

**Did not work:** The first live import command was invoked from the repository root rather than `zig/`, so Zig could not find `build.zig` and no manifest was published. The gateway then failed startup when the backend could not load `MANIFEST`. Re-running import from `zig/` succeeded. This is an invocation error, but it also demonstrated that the gateway does not silently serve an absent snapshot.

**Did not prove:** PPMI remains a controlled baseline. The gateway is synchronous, starts a `zig build run` child, and has no deadlines, concurrency pool, authentication, metrics, neural provider, or secret/egress policy. Exact model compatibility prevents invalid vector comparisons; it does not establish relevance quality.

**Conclusion:** Agents can now use the durable Zig engine through a text-only, cited search contract with automatic semantic embedding and a fail-closed model handshake. E005B—the representative judged comparison with a pinned modern model—is now the highest-value relevance experiment.

## 2026-07-11 — E005J: optional local neural provider and 20-query diagnostic

**Hypothesis:** A pinned pretrained model will improve paraphrase retrieval beyond both BM25 and corpus-only PPMI while preserving the model-independent Zig storage/query boundary.

**Selection:** The optional environment installed `fastembed==0.8.0` and downloaded `BAAI/bge-small-en-v1.5` into `/tmp`. The provider uses local ONNX inference, separate passage/query calls, 384 dimensions, batch operations, and L2 normalization. Fixed query/passage probes produce an exact runtime/model conformance id stored through Python, interchange, and Zig.

**Worked:**

- The base Python environment remains dependency-free; neural imports are lazy and emit a concise provider error when unavailable.
- A provider-neutral interface now covers metadata, document batches, and query batches; a language-neutral schema records the future process form.
- The two-query controlled suite scored 0.0 lexical and 1.0 neural vector/hybrid at k=1.
- On 20 mixed-domain diagnostic queries, success@1 was BM25 0.60, PPMI vector 0.70, neural vector 0.90, and neural equal-RRF 0.85.
- At k=3, neural vector and neural hybrid both reached 1.0 success; MRR was 0.95 vector versus 0.925 hybrid.
- Python exported the neural index, Zig imported generation 3 with 384 dimensions, and the gateway returned `target/automobile.md:1-2` for `car` (cosine 0.7797) and `target/physician.md:1-2` for `doctor` (cosine 0.7293).
- Provider contract tests cover normalized document vectors, distinct query vectors, identity mismatch, missing provider, lexical operation without the optional runtime, gateway injection, and structured runtime failures. The full Python suite now executes 30/30 tests.

**Fusion finding:** Equal RRF regressed neural success@1 from 0.90 to 0.85. Two losses were symmetric rank swaps: lexical rank 1/vector rank 2 tied lexical rank 2/vector rank 1. Stable chunk-id ordering then decided relevance. Fusion needs held-out weight/routing/reranking experiments; it is not automatically superior.

**Did not work:** The first package installation and model download attempts failed under restricted network access, then succeeded with explicitly approved temporary downloads. A later evaluation used the empty default model cache instead of `/tmp/search-fastembed-models`, attempted offline model discovery, and failed; passing the recorded cache path succeeded.

**Did not prove:** The 13-document/20-query corpus is authored diagnostic data, not representative user behavior. It has no graded judgments, held-out tuning split, independent assessors, latency/throughput measurements, multilingual data, or artifact supply-chain policy. The provider process is not pooled and authorization/incremental re-embedding remain absent.

**Conclusion:** A real pretrained semantic model now completes the files → Python provider → Zig persisted hybrid engine → text-only agent tool path and materially improves diagnostic top-1 relevance. The next relevance claim must come from 50–100 real user-derived questions with a held-out evaluation split; the next engine safety step is authorization filtering before both channels rank candidates.

## 2026-07-11 — E005K: persisted pre-retrieval authorization

**Hypothesis:** One canonical document-label policy can prevent forbidden chunks from entering lexical ranks, vector ranks, fusion, source discovery, and authoritative reads across both the Python reference and persisted Zig engine.

**Policy:** `all-required-labels-v1`. All matching path rules union their labels; principals must possess every required label. Public documents have none. Principal labels are gateway configuration, not LLM-controlled parameters.

**Worked:**

- Python validates safe path rules and canonical labels, stores them on every chunk, filters before lexical/vector scoring, and reuses the same principal for list/read.
- Interchange v1 now carries required-label arrays. Zig import bounds, validates, sorts, deduplicates, and packs them.
- `HYBSEG01` v3 persists a canonical newline-separated required-label field and decodes it zero-copy. V1/v2 remain readable as unlabeled/public.
- Zig filters unauthorized documents before component ranks and fusion. Service list/read recheck the same requirements.
- Raw RPC accepts at most 64 validated internal labels using stack storage. The gateway rejects caller-supplied labels and injects its configured principal into search/list/read.
- Python executes 35/35 tests and Zig executes 56/56 tests, including denied and authorized paths in both channels and leak-free RPC parsing.
- A live generation-4 snapshot contained public, tenant, and engineering documents. Anonymous saw one source; tenant saw two; engineering saw three. Confidential and engineering queries/reads followed the same boundaries. A forged principal returned `-32602`.

**Did not work:** The first Zig RPC implementation allocated a label-slice array from the supplied allocator. Functional assertions passed, but the debug allocator reported three leaks in tests. Replacing allocation with a fixed 64-label stack workspace removed the leaks and bounded request complexity.

**Did not prove:** The CLI-configured principal is not authentication. `index_status` still exposes global counts, and BM25 uses corpus-global statistics before unauthorized scores are zeroed, leaving potential aggregate/timing side channels. Static rules require reindexing after ACL changes. V1/v2 records are public by interpretation. Storage encryption, logs, backups, operator access, token verification, and tenant isolation are outside this experiment.

**Conclusion:** Forbidden content now has one enforced path from indexing through retrieval and authoritative reads, rather than relying on prompt instructions or path scopes. A production multi-tenant design must next choose label-aware corpus statistics or separate tenant indexes, and must derive principals from authenticated identity rather than CLI input.

## 2026-07-11 — E005L: content-hash incremental reuse with full Zig publication

**Hypothesis:** The platform can avoid repeated file extraction and neural inference without prematurely introducing query-visible delta segments: reuse unchanged work in Python, then publish one complete immutable Zig generation.

**Contract:** Indexes record root, `line-window-v1` chunk parameters, vector mode/exact model, source path/SHA-256, chunks, vectors, and access labels. Incremental reuse fails closed on root, chunker, vector-mode, neural-id, or dimension mismatch. Indexes created before source-hash metadata require a fresh base build.

**Worked:**

- Unchanged files reuse chunk ids, terms, citations, and stored vectors.
- ACL-only changes relabel reused chunks without invoking document embeddings.
- Neural mode batches only changed/new chunks and makes no provider call for an empty batch.
- Deleted paths disappear. Existing but transiently unreadable files retain prior chunks and are marked stale with the error.
- No-change PPMI reuses the model; any corpus content change retrains and re-embeds every chunk because its learned coordinate system is corpus-global.
- Five focused incremental tests cover change/add/delete, no-change, ACL-only change, provider/root/chunker/hash-metadata mismatch, PPMI behavior, and stale-file retention. The full Python suite executes 40/40 tests.
- A real FastEmbed/BGE run over 13 documents modified one, added one, and deleted one. It reused 11 files/chunks and embedded exactly two chunks.
- The new rollback passage ranked first. `cooking/bread.md` was absent from the index.
- Export and Zig import published generation 5 with 13 documents, 333 terms, 460 postings, and 384 dimensions. The gateway returned `storage/rollback.md:1-1` first with cosine 0.7263; listing `cooking/` returned zero sources.

**Did not work:** The first no-change neural test observed one `embed_documents` call containing an empty batch. Although it produced no vectors, it would still create avoidable hosted/runtime overhead. The builder now skips the document batch when there are no pending chunks. The current CLI still initializes the provider and runs conformance probes before compatibility is known.

**Retrieval observation:** A lexical query asking why bread rises returned unrelated passages after the bread file was deleted because common query words still matched. Direct path inspection and source listing proved deletion. This is a stopword/threshold relevance issue, not stale document retention.

**Did not prove:** Zig still rewrites complete sections; there is no watcher, WAL, delta segment, tombstone file, compaction, reader lease, safe obsolete-generation deletion, crash injection, or realistic throughput/latency/size benchmark. Stale-file retention is fixed policy rather than operator-configurable.

**Conclusion:** The system now has a practical middle tier between naive rebuilds and a full LSM-like engine: incremental preparation saves extraction/model cost while complete immutable publication preserves simple query and recovery semantics. Delta segments should be justified by measured freshness or write-amplification limits, not implemented by default.

## 2026-07-12 — E005M: files/folders build scale and Zig ranking bottleneck

**Hypothesis:** The next scalable mechanism should be selected by separating file preparation, artifact size, postings scoring, exact vector scoring, and fusion/ranking rather than assuming ANN or sharding is the first need.

**Setup:** A reusable Python harness generated 100, 1,000, and 5,000 small Markdown files with one chunk each. It measured no-vector and synthetic 384-dimensional full/unchanged builds plus JSON bytes. The synthetic provider exercises vector validation, normalization, copying, serialization, and reuse, but excludes neural inference. A Zig `ReleaseFast` harness built the real postings index and ran the real engine over equal-score documents, forcing every document into lexical and vector consideration with 32 dimensions, `top_k=10`, and `candidate_k=100`.

**Python observations:**

- At 5,000 files, the no-vector build took 591.6 ms and produced 3.31 MB of JSON.
- The synthetic-384 full build took 4.54 s and produced 10.98 MB; unchanged preparation took 2.02 s, reused all 5,000 chunks, and embedded zero chunks.
- At 1,000 files, unchanged one-shot measurements were slower than full builds in both modes. Reuse still enumerates, reads, and hashes every file and reconstructs the index object, so it is not a constant-time change detector. The run had no repetitions/confidence intervals and does not establish a stable regression.
- The vector JSON was about 3.3 times the no-vector JSON at 5,000 chunks. Binary `f32` values alone account for 7.68 MB of the vector payload.

**Zig baseline:** Nested per-result rank scans were O(n²); final insertion sorting was O(n²) in the worst case. Hybrid p50 rose from 0.487 ms at 500 candidates to 174.6 ms at 8,000.

**What did not work:** Replacing the nested scans and insertion sort with allocation-free heap sorts was asymptotically correct, but stage timing still put 43.0 ms of an 8,000-candidate query in ranking. Postings scoring was only 48.5 microseconds. The theoretically safe replacement had poor practical constants for these result records.

**What worked:** Zig's in-place pattern-defeating quicksort uses the same total order—score descending and document index ascending—so ranks are assigned in one pass without losing deterministic ties. Final hybrid p50 was 0.024 ms at 500, 0.049 ms at 1,000, 0.104 ms at 2,000, 0.208 ms at 4,000, and 0.417 ms at 8,000. The same implementation recorded 0.827 ms at 16,000 and 1.69 ms at 32,000. A focused correctness test preserves channel ties, candidate cutoffs, and final fusion order.

**Limits:** These are local synthetic wall-clock runs, not a calibrated performance study. Equal vectors and 32 dimensions do not represent BGE's 384 dimensions or a real score distribution. The benchmark excludes process startup, persisted section open, resident memory, concurrent load, extraction of large formats, real model inference, and end-to-end LLM latency. `candidate_k` limits fusion depth but does not yet avoid exhaustive vector scoring or full sorts.

**Decision:** Keep exact vector scan and the new deterministic `O(n log n)` ranking for the single-node baseline. Do not add HNSW, WAND, quantization, delta segments, or sharding from this result. First measure 384-dimensional persisted snapshots, memory/startup, concurrency, and a representative corpus. Incremental Python reuse remains the simple middle tier when embedding cost is the problem; watcher/delta machinery requires a measured freshness or write-amplification failure.

**Artifacts:** `benchmark_scale.py`, `zig/src/benchmark.zig`, `docs/scale-benchmark.md`, `benchmarks/python-scale-2026-07-12.json`, and `benchmarks/zig-ranking-scale-2026-07-12.json`.
