# Filename-query complexity guard and objectives review

Claim: [issue #22](https://github.com/ilamgumaran/search-simpli/issues/22).
Base: main `b45b1c4` (S4-T2). Branch `improve/filename-complexity-guard`.
Owner requested reviewing overall objectives and implementing useful repo improvements.
State: implemented and verified; PR #23, unmerged.
Adopted on `main`: [S4-T3](S4-T3.md) (PR #23 merged at 94c6071; the suites and the plant re-run on the Mac, natives rebuilt there).

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
  same no-skip step, in both Debug and ReleaseSmall. Other OSs skip the protection test explicitly; neither
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

## Source verification

Pinned Zig 0.16.0 on Linux: full suite **297/297**, C ABI **23/23**; the
two named complexity tests pass in both Debug and ReleaseSmall. The first
full Python run executes 238 tests with four existing platform/Unicode
skips and only the expected native-freshness failure before rebuild/adoption.
Requirements, home-path and diff-whitespace checks pass. The macOS CI guard
also passes on source `554e2c3`; final platform/package results follow.

## Native build and final verification

[macOS run 41391464219](https://github.com/ilamgumaran/search-simpli/actions/runs/41391464219)
at source `554e2c352c0275b6245eeeca44fd8afcb421809c` passes the guard,
three-target build, platform checks, clean Dart analysis and **83/83 Dart
tests**. The follow-up workflow at `23a9720` runs the no-skip guard in both
Debug and ReleaseSmall on macOS as well; that guard step passes. Compiled
source and the build recipe are unchanged between those commits.

Adopted artifact `13117727699`, archive SHA-256
`a43755e7d0ec0364deda957477f2223bcc4878337bb70187c4e648febcb07a64`.
Verified archive checksum, safe paths/types, embedded exact source commit
and the genuine build-generated digest against this working tree before
copying native paths. Android JNI copy is byte-identical. Source digest:
`139bd8af4b3293bcb0e4a078a188c40bb3f6da31a1e4f2bd62add5443a672feb`.
No source stamp was fabricated. The pinned build uses Zig 0.16.0 and NDK
28.2.13676358; platform checks retain 16 KiB iOS segment alignment.

Packaged sizes: macOS 808,408 bytes, Android 777,672, iOS 1,051,512. The
main iOS binary was 789,368 bytes: it uses SDK 27.0 while this CI build
records SDK 17.5; both record IOS/minos 17.0. Header inspection shows
`__TEXT` remains 671,744 bytes (the code section changes by 16 bytes),
`__LINKEDIT` remains 84,856 bytes, and `__DATA` file size changes from
16,384 to 278,528 bytes. The size delta is data layout, not a claim of a
larger query workspace. Byte-identical reproduction across SDKs is not
claimed. The rebuilt framework passes platform/export checks; physical
phone/app signing and load validation remain the consumer gate.

After authentic package adoption: **238 Python tests in 41.038 seconds,
four existing platform/Unicode skips, no failures**, including freshness
and 66-request MCP/RPC canonical parity. Zig 297/297, ABI 23/23, both
complexity tests in Debug/ReleaseSmall, requirements, privacy and whitespace
checks pass. Final package/evidence commit reruns both GitHub workflows;
its results are linked from the PR description/comment.
