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
