# S5-T12 evidence: the measured overhead of `both` (Phase 1)

The raw record of [S5-T12](../../tasks/S5-T12.md) Phase 1 (review R07). Invented content only (the generated 10k
timing corpus). Nothing here is shipped code.

| File | What it is |
| --- | --- |
| `run2.jsonl` | **The measurement.** 8 rounds x 4 libraries x 16 (query, field) rows: per row the p50 and minimum of 300 warm calls (ms), the sha256 of the untimed first answer, and its warning codes. Every gate passed. |
| `run2-summary.txt` | `harness/summarize.py run2.jsonl`, verbatim. |
| `run1.jsonl` | An earlier run, **incomplete and not used**: the gate refused at round 7's second start (`dartvm` in the top eight); 6 full rounds and 3 starts of round 7 were written before it, and its last line records the refusal. Kept as the record says. |
| `gates.txt` | Every gate check of the phase, one line each: three refusals before the rounds (the app check lock present, 5-minute load over 4.0), run1's 27 passes and 1 refusal, run2's 32 passes, each with the load and `top`'s top eight. |
| `harness/bench.py` | The bench: one library per process, one `ss_open` of the filename-indexed snapshot, then per query and field an untimed answer (hashed), 20 warm-ups and 300 timed `ss_query` calls, `top_k` 10, lexical. |
| `harness/gate.sh` | The load gate (S4-T18's, as S5-T3, S5-T4 and S5-T8 ran it): the app check lock absent, the 5-minute load at most 4.0, none of `dart`, `dartvm`, `flutter`, `flutter_tester`, `zig`, `xcodebuild`, `python3`, `swift`, `swift-frontend`, `clang`, `ld` in the second sample of `top -l 2 -o cpu -n 8`. |
| `harness/run.sh` | The rounds: 8, the four libraries in the order `main, main2, proto, noview` rotated by one each round (each library in each position twice), the gate before every start; a refusal ends the run. |
| `harness/summarize.py` | Per (query, field): `main`'s median of the per-round p50s; for `main2`, `proto` and `noview` the median and range over rounds of the per-round difference against `main`; each library's `both − content` per round; and the check that every answer is byte-identical to `main`'s. |
| `harness/proto.diff`, `harness/noview.diff` | The two scratch builds' only change, to `Engine.bothGroups` in `zig/src/engine.zig`. |

## The four libraries

All `ReleaseSmall`, `zig build lib` with Zig 0.16.0, each from its own `git archive c674a9c zig contracts` copy with
its own empty global and local Zig caches (macOS arm64 dylib):

| Library | Source | Bytes | sha256 |
| --- | --- | ---: | --- |
| `main` | `c674a9c` untouched | 953,848 | `848fe876…a09e7a8`, byte-identical to the committed `native/macos-arm64` dylib |
| `main2` | `c674a9c` untouched, a second copy and build (the noise reference) | 953,848 | `848fe876…a09e7a8` (identical to `main`: the noise is process noise only) |
| `proto` | `proto.diff`: the groups computed first without the view; no group, no view; with a group, the view as before | 954,408 | `ed2ecfc6…dc997e` |
| `noview` | `noview.diff`: the view never built (attribution only; wrong when a scope hides a document) | 953,928 | `c38787dd…aea2` |

## The corpus and the index

`scripts/gen_timing_corpus.py <dir> 10000`: 10,000 files, content sha256 (files in sorted path order)
`3a520dd5…ed96e38`, as recorded since S4-T18. Indexed by `main`'s `searchd` (`ReleaseSmall`, 1,095,640 B) with
`searchd index <dir> --out <idx> --filename-index`: analyzer-v2, 19,959 chunks, 24,057 terms, 1,023,806 postings.
`content` and `both` both run on this one snapshot.

## Reproducing

Build the four libraries as above into `<scratch>/<name>/zig/zig-out/lib/aarch64-macos/`, the index into
`<scratch>/idx10k-fn`, copy `harness/*` into `<scratch>`, then `<scratch>/run.sh <run name>` and
`python3 -I <scratch>/summarize.py <scratch>/<run name>.jsonl`.

# Phase 2: the shipped change measured (`phase2/`)

The raw record of S5-T12 Phase 2: (a) in two parts, the check (`a17c415`) and the lazy view (`8536159`, then
`104d7cd`). Every timed start passed the gate; `gates.txt` above now holds every check of both phases.

| File | What it is |
| --- | --- |
| `phase2/p2acc1.jsonl`, `phase2/p2acc2.jsonl` | **The acceptance runs.** 8 rounds x (`main`, `main2`, `part1`, `final`) x 40 (workload, query) rows. `p2acc2` is the one repeat the coordinator's rule allows: `p2acc1` ran with `mediaanalysisd` (a macOS process) at up to 117 % of a core, and one cell (`both-scoped` `system`) spread over 0.337–0.352 ms for every library. Both runs are reported. |
| `phase2/p2acc1-summary.txt`, `phase2/p2acc2-summary.txt` | `harness/summarize3.py RUN main main2 part1 final`, then `RUN part1 final`, verbatim. |
| `phase2/p2run3.jsonl`, `phase2/p2run3-summary.txt` | The first complete run, of `8536159` as `part2`: it found the scoped grouped `both` queries +0.005–0.008 ms slower than `part1`. That build is **a rejected attempt**, kept as the record. |
| `phase2/p2inv1.jsonl`, `phase2/p2inv1-summary.txt` | The attribution run: `part1`, `part2` (`8536159`), `part2b` (`part2` with `harness/part2b.py`, which became `104d7cd`) and `part2e` (`part2` with the view built first, as `main` does: an investigation build). |
| `phase2/p2run1.jsonl`, `phase2/p2run2.jsonl` | Two runs refused at their first start (5-minute load 4.29 and 4.02, from my own builds and plant suites). Nothing timed. |
| `phase2/firstq1.jsonl`, `phase2/firstq1-summary.txt` | S5-T8's bound "the first `content` query after an open ≤ +0.10 ms": 6 rounds x (`main`, `main2`, `final`), 15 fresh handles per query, the median. Filename-indexed snapshot only. |
| `phase2/df-counts.txt` | How many key df reads (`scope.documentFrequency` calls) each query makes, from instrumented copies of `c674a9c` (`cntm`), `8536159` (`cnt2`) and `104d7cd` (`cnt2b`): one `std.debug.print` per call, one call per query. Not timed. |
| `phase2/equivalence-final.json` | `harness/equivalence.py` with `main`'s and `final`'s `searchd`: 3,480 requests, 0 differ, 0 errors; the hidden-label file 60 cases, 0 leaks, and 26 of 26 found with the label. |
| `phase2/j2-gate-searchd.txt`, `phase2/j2-gate-reference.txt`, `phase2/j2-compare-main-final.txt` | `scripts/j2_gate.py` on `final`'s `searchd` run and on the Python reference (`scripts/relevance_smoke.py --pack j2 --top-k 10`): every row +0.000, gate pass; `j2_run.py --compare` of `main`'s and `final`'s runs: 0 queries differ under either field. |
| `phase2/plants.txt` | The plant suites' failing tests and summaries. |
| `phase2/harness/` | `bench2.py` (Phase 1's bench over five workloads), `run2p.sh` (the rounds; `VARIANTS` names the four libraries), `summarize2.py`, `summarize3.py`, `two_roots.py` (the two-root changes file), `equivalence.py`, `count_df.py`, `part2b.py`, `firstq.py`, `runfirst.sh`, and the three plant diffs. |

## The libraries

All `ReleaseSmall`, `zig build lib` with Zig 0.16.0, each from its own `git archive` copy with its own empty global
and local Zig caches (macOS arm64 dylib):

| Library | Source | Bytes | sha256 |
| --- | --- | ---: | --- |
| `main`, `main2` | `c674a9c`, two copies | 953,848 | `848fe876…a09e7a8` (identical: process noise only) |
| `part1` | `a17c415` (the check alone) | 954,120 | `fa462d65…f0ea0d6` |
| `part2` | `8536159` (the check and the first lazy view): rejected | 953,800 | `351940a6…abe7c0d` |
| `part2e` | `8536159` plus `_ = try lazy.get();` after `defer lazy.deinit();` in `bothGroups`: investigation only | 954,008 | `4fd06fa5…0bd454ba` |
| `part2b`, `final` | `8536159` plus `harness/part2b.py`; `final` from `104d7cd`, byte-identical | 953,688 | `1e44b57b…33cd557e7` |

`final`'s `searchd` (`zig build -Doptimize=ReleaseSmall`) is 1,095,960 B.

## The workloads

`bench2.py` runs Phase 1's eight queries over five workloads: `content` and `both` on Phase 1's one-root snapshot
(`idx10k-fn`); `both-all` on a two-root snapshot with every root allowed; `content-scoped` and `both-scoped` on it with
`"roots": ["r-left"]`. The two-root snapshot: `harness/two_roots.py <corpus> <changes.json>` (groups 00–49 in `r-left`,
50–99 in `r-right`, no labels), then `main`'s `searchd apply <dir> --changes <changes.json> --filename-index`: 10,000
files, 19,959 chunks, `r-left` 10,000 chunks, `r-right` 9,959. The mask hides `r-right`.

# Verifier (`verifier/`)

The S5-T12 verifier's own record, from its own builds (each a `git archive` with its own empty Zig caches), index and
harness. Nothing here was taken from the builder's scratch. See the Verdict in the task.

| File | What it is |
| --- | --- |
| `verifier/vrun1.jsonl`, `verifier/vrun2.jsonl` | The two timing runs: 8 rounds x (`main`, `main2`, `part1` = `a17c415`, `head` = `1769214`) x 60 (workload, query) rows, the builder's five workloads and eight queries plus the verifier's four held-out queries (`consensus`, `scheduler`, `garbaje`, `hash`). Every start passed the gate. |
| `verifier/vrun1-summary.txt`, `verifier/vrun2-summary.txt` | `harness/vsum.py RUN`, verbatim: per cell the differences against `main` and the rule of "Rulings on Phase 2" item 2 applied (`ABOVE` = `head` − `main` exceeds the run's largest noise median). |
| `verifier/vfirst1.jsonl`, `verifier/vfirst1-summary.txt` | The first `content` query after an open: 8 rounds, the same four libraries, 15 fresh handles per query, the filename-indexed and the plain snapshot. |
| `verifier/gates.txt` | Every gate check of the verifier (three refusals before any timed start, then 96 passes). |
| `verifier/walk-and-df-counts.txt` | Walks and key df reads per query, from instrumented copies of `c674a9c` and `1769214`. |
| `verifier/equivalence-main-head.json` | `harness/vequiv.py` with `main`'s and the head's `searchd`: 29,376 requests, 0 differ, 0 errors, 0 leaks of the hidden files. |
| `verifier/equivalence-main-plant-labels.json` | The same against plant P2b (the lazy view without the principal's labels): 4 differ, which no Zig test catches. |
| `verifier/harness/` | `vbench.py` (Phase 2's `bench2.py` with the held-out queries added), `vrun.sh`, `vsum.py`, `vfirst.py`, `vrunfirst.sh`, `vequiv.py`, `probe.py`, and `verify_check_test.zig` (the verifier's check-against-walk cases, run in a scratch copy, not shipped). `gate.sh` is `harness/gate.sh`. |

# Rework after the re-ruling (`rework/`)

The builder's record of the rework (part 1 alone, head `5f02074`: the engine is `a17c415`'s byte for byte). **No
timing**: the verifier measures. Builds from `git archive 5f02074` with their own empty Zig caches.

| File | What it is |
| --- | --- |
| `rework/equivalence-part1.json` | `phase2/harness/equivalence.py` with `main`'s and the head's `searchd` (`ReleaseSmall`, 1,095,880 B): 3,480 requests, 0 differ, 0 errors; the hidden-label file 60 cases, 0 leaks, 26 of 26 found with the label. |
| `rework/j2-gate-searchd.txt`, `rework/j2-gate-reference.txt`, `rework/j2-compare-main-head.txt` | `j2_gate.py` on the head's `searchd` run and on the Python reference: every row +0.000, gate pass; `j2_run.py --compare` against `main`'s run: 0 queries differ under either field. |
| `rework/nfr13-deltas.txt` | Every NFR-13 peak number that differs from `main`'s in the same session: `find` +8 and +262 B only. |
| `rework/plants.txt`, `rework/plant-r1-rooted-ignored.diff`, `rework/plant-r2-labels-ignored.diff` | Two plants on part 1's check, each failing the reshaped counter test and the condition test (R2 also the two S3-T3 privacy tests). |
