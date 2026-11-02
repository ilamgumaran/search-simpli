# S4-T1 integration and review improvements

Owner authorized updating the PRs and commenting with the results. PR #21
integrates main `f45c06d` with the earlier recovery/filename candidate
`54f667d`. The resulting contract is **2.2.0**, Dart **0.3.0**: main's
2.1.0 source-state surface and XXH3 generation format remain available.
PRs #18 and #11 are historical predecessors, not alternative merge targets.

## Changes

- Keep main's lazy source/position/statistics initialization and single-pass
  section checksums; support FNV v1/v2, XXH3 v2.1 and filename v3. V3 carries
  the XXH3 flag and validates filename sections alongside the current body.
- Keep exact committed recovery state, no-follow confined reads, restricted
  writer checks, filename root/label filtering and honest pending counts.
- Reject a source section whose actual pinned file size differs from its
  manifest, including appended and truncated bytes after open. Source reads
  report unavailable; token/position retrieval continues to work.
- Cache decoded filename tables, hashed term lookups and catalog-to-body
  anchor ordinals per handle. Validate canonical filename postings one file at
  a time instead of rebuilding a second complete reference index. Compute visible filename averages once per
  query and use a path map to group body candidates. Existing ranking and
  authorization fixtures remain the oracle; dictionary order is not assumed.
- Query metadata parsing skips the writer-only recovery tree. Update parsing
  reads committed state directly as typed fields, without an intermediate
  JSON tree/string; absent state uses the compatibility cache, malformed or
  mismatched committed state fails closed.
- Coallocate serialized sections and reserve their source-byte range in the
  same slab, avoiding geometric arena slack. Reserving source capacity is
  eager; reading, checksum validation, source indexing, position tables and
  statistics remain lazy. The source range is not initialized/read at open.
  This tradeoff keeps the existing 10k 64 MiB gate without raising its cap.

## Verification and performance evidence

The intermediate combined suite exposed an OutOfMemory failure in the
unchanged NFR-13 10k gate. The final allocation/metadata approach passes
that targeted gate: open 54,681,990 bytes; find 60,857,260; read_span
54,682,054; outline 54,683,446; list_files 61,953,666; search_knowledge
54,692,352 (Linux Debug). These include the reader and operation arenas;
they are authored-corpus evidence, not phone results.

The first filename optimization incorrectly assumed dictionaries were sorted;
two existing fixtures rejected it. Hashed term lookups preserve the format's
actual ordering and the targeted filename suite passes (9 tests). Final
integrated and platform results are appended after the final checks.

`zig/src/filename_bench.zig` supplies a reproducible ReleaseSmall diagnostic:
five warmups, twenty timed queries per field, p50/p95 and capped allocator
peak including open. Generate invented corpora with
`scripts/gen_timing_corpus.py`, index each with `--filename-index`, then run
the tool at 1k/10k/15k/20k. Record cap failures as failures, not skipped data;
a larger diagnostic cap may measure the actual headroom needed. No noisy
wall-clock CI threshold is introduced.

## Remaining acceptance work

- Physical iOS/Android runs and a consumer pin/rollback check need the app
  and devices. Old readers refuse XXH3/v3 generations; retain a separate
  prior index for rollback. No device result is inferred from a cross-build.
- Memory beyond the tested corpus, particularly filename modes, must use
  the recorded matrix before choosing resident-table/list paging changes.
  No arbitrary folder size is claimed to fit 64 MiB.
- E-02's strict suite-v3 negative evaluation and a human-confirmed real-folder
  holdout remain separate runtime/data work. Use the existing
  [E-02 design](../requirements/cap-11-e02-negative-evaluation.md); preserve
  its view binding, null denominators and absence of production confidence
  claims. No private folder or invented human confirmation is committed.
- Delta chains, ANN and reranking remain measurement-driven follow-ups.

No automatic merge or consumer deployment is part of this update.

## Filename scale measurements

Invented `gen_timing_corpus.py` corpora, Linux x86_64, Zig 0.16.0
ReleaseSmall, common filename query `doc`, 5 warmups and 20 timed samples
per field. Peak is allocations observed by the capped allocator, not process
RSS. Codec scratch allocations using their own allocator are outside this
measure, as in the existing NFR-13 instrumentation. These are diagnostic
measurements, not a wall-clock regression gate or phone evidence.
[Raw rows and corpus/binary hashes](2026-11-01-filename-scale.json).

| Files | 64 MiB cap | Open ms | filename p50 ms | both p50 ms | Observed peak bytes |
|---:|---|---:|---:|---:|---:|
| 1,000 | pass | 13.83 | 0.077 | 0.096 | 18,930,238 |
| 10,000 | pass | 103.48 | 1.326 | 1.372 | 57,269,176 |
| 15,000 | open fails | 137.39* | 2.193* | 2.112* | 84,958,978* |
| 20,000 | open fails | 198.58* | 2.770* | 2.924* | 112,924,828* |

`*` Measured only with an explicitly larger 256 MiB diagnostic cap, not a
pass under 64 MiB. Single-open times are load/cache dependent. At 10k, the
first candidate consumed 147,427,326 bytes under that larger cap and failed
under 64 MiB. Streaming canonical validation and coallocation reduce the
observed peak to 57,269,176 without weakening content/label/anchor checks.

15k/20k corpus support under a 64 MiB budget remains a separate paging or
resident-data representation task. Keep filename enablement opt-in.

The combined 10k regression also queries `doc the`, so both filename and
body channels have broad matches while all lazy tables stay on the handle.
It passes the same cap: open 56,587,630; find 62,775,446; read_span
56,587,694; outline 56,589,086; list_files 63,859,306; search_knowledge
56,598,740; filename 57,430,112; both 61,371,674 bytes (Linux Debug).
All eight operation peaks must be nonzero; body-only fixtures check only
the six enabled operations. The original family fixture's assertion was
adapted when the optional modes expanded the measurement enum.

A separate ReleaseSmall `doc the` probe at 10k completes under 64 MiB:
filename p50/p95 1.389/2.434 ms, peak 57,270,508 bytes; both p50/p95
6.781/10.192 ms, peak 61,210,640 bytes. These broader body matches should
be used alongside the filename-only `doc` scaling rows, not hidden behind
the cheaper query's timings. Raw rows are included in the JSON report.

## Verification notes

A concurrent local full-suite run hit the unchanged NFC timing ratio test
(6.04x against its 5x bound); its source and bound are unchanged. An isolated
full-suite rerun and exact-head CI provide the final result below. The
intermediate Python runs execute 238 tests with four platform skips and
only the expected stale-package failure before authentic package adoption.
C ABI checks pass 22/22. Requirements, home-path and diff whitespace checks
pass. No failure is hidden by changing a threshold or source stamp.

The isolated final Linux Zig run passes **282/282** (including both 10k cap
regressions and the source-size/streaming-posting/state tests), with the
original NFC bound unchanged. Exact source-head CI at `dc800e3` also passes
the Zig engine and 22 ABI checks. Package adoption and the remaining final
CI results are recorded below.

## Authentic final native packages

[macOS build 41382210500](https://github.com/ilamgumaran/search-simpli/actions/runs/41382210500)
at source `dc800e34b479e1906f5656252ab6396c7123bf54` passes the genuine
platform rebuild, platform checks, Dart analysis and **83/83 Dart tests**.
The pipeline uses Zig 0.16.0 and NDK 28.2.13676358. Artifacts: macOS arm64
790,296 bytes; Android arm64 759,784; iOS arm64 framework binary 1,032,680.
The checker confirms the iOS platform/deployment metadata and four segments
with 16 KiB alignment. No physical-device execution is inferred.

Adopted artifact `13114145877`, archive SHA-256
`0b3798a406a24518597ff5261ea3f82adaec31aebe8d03ed2b211c418e3388e6`.
Verified that checksum, the archive's exact source commit, paths/types and
its genuine build-generated source digest before copying the native paths.
The Android JNI example copy is byte-identical to the packaged library.
Source digest:
`8c57075d1c5e252baf1b599d29d29b0df2a8d8a38a0f017294be1a1e8418a5b2`.
No stamp was edited to match unbuilt source.

After adopting the authentic packages, the full Python suite passes:
**238 tests in 40.949 seconds, four platform/Unicode skips, no failures**.
This includes native freshness and 66-request MCP/RPC canonical parity.
Requirements, home-path and whitespace checks pass after evidence updates.
The final package/evidence commit reruns both GitHub workflows; its result
is linked from the PR description and update comment.
