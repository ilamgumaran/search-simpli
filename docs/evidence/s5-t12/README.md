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
