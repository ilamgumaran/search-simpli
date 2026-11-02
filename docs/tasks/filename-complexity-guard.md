# Filename-query complexity guard and objectives review

Claim: [issue #22](https://github.com/ilamgumaran/search-simpli/issues/22).
Base: main `b45b1c4` (S4-T2). Branch `improve/filename-complexity-guard`.
Owner requested reviewing overall objectives and implementing useful repo improvements.
State: implemented; final verification/native package adoption in progress.

## Objectives and choice

The objective remains the smallest useful set of authorized passages for a
correct, cited answer, keeping retrieval separate from generation. S3/S4 now
provide much of the durable local/agent engine: roots/labels, exact source
reads, structured find/outline, MCP, recovery, filename search and measured
10k budgets. The roadmap's older progress text incorrectly left several of
these capabilities in its future queue; this change reconciles it.

The most concrete next code gap is S4-T2's verifier note: restoring the old
catalog × body anchor scan still passed 295 tests; only the benchmark caught
it (1k/10k filename latency grew 123x). This task protects the existing
performance contract before adding machinery or changing ranking.

The next product-quality gates remain human-confirmed real-folder/holdout
judgments and explicit negative evaluation (E-02). Synthetic mechanics tests
cannot claim either. Physical phone/app pin validation, larger-folder memory
work and the persisted 384-d/concurrent-query benchmark remain separate.
No private corpus, approval, device result or production-confidence score is
invented here. ANN/reranking/sharding still require measured need.

## Implementation and acceptance

- `filename_complexity_test.zig` builds invented 1k/10k-file corpora, two
  chunks per file, reversed body order, both labelled and unlabelled variants.
- For filename-only scoring, copy body records into an OS mapping and make
  it inaccessible with `mprotect`. Cached catalog/anchor/root tables stay
  readable. Any actual body-record scan fails immediately, including an
  uninstrumented restored anchor loop; no timing threshold or self-reported
  operation counter is needed. Results must equal the readable-body path.
- Exercise public and privileged labels, narrowing and all-allowed root
  masks, path prefixes, repeated terms, bounded candidates and unique-file
  result/rank checks. Both plain and scoped fast paths run.
- For filename and combined broad-match queries, a fixed buffer limits
  request scratch to `1024 * files + 65536` bytes. It covers the query, not
  fixture building, immutable tables, process RSS or all engine operations.
  Existing S4-T2 budget tests retain those broader checks.
- The guard found one existing unnecessary read: a sort can compare a
  candidate with itself, and its final tie-break loaded its own body id.
  Return false for equal body ordinals after equal score/path instead.
  Distinct-candidate tie-breaking and public results remain unchanged.
- Both guards run in the ordinary Zig suite and a named Linux CI step that
  requires exactly two passing tests. The macOS packaging workflow runs the
  same no-skip step. Other OSs skip the protection test explicitly; neither
  Linux nor macOS CI may silently skip it.
- No production API, wire shape, contract 2.2.0 or index format changes.
  No instrumentation overhead is added to query loops. Source changes still
  require a genuine native rebuild and build-generated source stamp.

## Performed negative controls

The first new guard on the base failed at the comparator's self-comparison
body read. After the equality fast path, both new tests pass on Linux.

In a scratch copy with fresh local cache, replace the cached filename
candidate anchor with `plantedFindAnchor(body_docs, catalog[i])`; its body
loops over every record comparing path/id, as the old implementation did.
Run only the protected-body test. It fails with a segmentation fault in
`plantedFindAnchor` and the test runner exits nonzero. The plant was never
committed; the real working tree retains its cached ordinal lookup.

## Limits

This guards body-array scans in filename scoring and superlinear scratch
allocation. It is not a proof that every future computation is linear: a
CPU-only loop over another table, quadratic body grouping in `both`, sorting
costs or a filename-load regression still need review and benchmarks.
A legitimate future need to read body records while scoring filenames must
explicitly revise this guard and its measured budget. Wall-clock performance
and phone acceptance are not inferred from the protected-memory test.

Final suites, platform guard results and package provenance are appended
after verification. No automatic merge or deployment.
