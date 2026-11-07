# S5-T2 prototype: a title/path field on J2, through the Python reference

Planner: Claude Opus 5.5, 6 Nov 2026. All numbers are measured, from Python 3.9.6, `PYTHONHASHSEED=0`. The output is byte-identical under `PYTHONHASHSEED=1`. They were taken at `origin/task/S5-T1` = `8025d9f`, with fixtures/j2 judgments sha256 `fc081a1c…`. The scripts were committed with the task file by the orchestrator; nothing else from the pass is in the tree.

## How to reproduce

The scripts are kept under `scripts/prototypes/s5t2/`. They are scratch code from the planning pass, kept only so these numbers can be reproduced; no test imports them.

```
cd <a checkout at origin/task/S5-T1 (8025d9f) or a later main that still holds the S5-T1 baseline>
export TMPDIR=<a scratch folder>
PYTHONHASHSEED=0 python3 scripts/prototypes/s5t2/proto_s5t2.py --detail --json OUT.json
#   stdout sha256 763426008d375be4c8a41cde22281ec579b81727817252b7f46c03a4ff132107 (113 lines)
PYTHONHASHSEED=0 python3 scripts/prototypes/s5t2/proto_s5t2_packs.py 0 2 3 5
```

- **The tables below** come from `proto_s5t2.py`'s `OUT.json`.
- **The baseline check.** `proto_s5t2.py` reimplements today's `content` and `both`. It checks every query's first grade-2 rank and every slice metric against the Python cells of `fixtures/j2/baseline.json`, and prints `BASELINE MISMATCH` on any difference. It printed none.
- **The cost bench.** The 10k bench is `s5t2_title_bench.zig`. Copy it into `zig/src/` of the same checkout, then run `zig run -lc -OReleaseSmall zig/src/s5t2_title_bench.zig -- INDEX`. INDEX is `searchd index <corpus> --out INDEX --filename-index` over `scripts/gen_timing_corpus.py <corpus> 10000`.

## The candidates

**The title field.** A file's title field is its root-relative folder names plus its stem. Both are tokenized with `_filename_tokenize`, the analyzer-v2 simple fold that the file-name channel uses and that Zig mirrors. There is one document per file, scored with BM25 (k1 1.2, b 0.75) over the files.

| Candidate | `content` | `both` |
|---|---|---|
| `baseline` | today | today: equal-weight RRF (k 60) of the per-file body rank and the stem channel's rank |
| `WRRF-stem-aA` | today | `1/(60+body rank) + A/(60+stem rank)` |
| `RRF-title-a1`, `WRRF-title-aA` | today | as above, with the folders+stem field in place of the stem channel |
| `T-fs-best-wW` | chunk score = body BM25 + W · title BM25. The title part goes on the file's best body chunk, or on its first chunk when no body chunk matches. | per file: best body chunk BM25 + W · title BM25 (a score-level merge) |
| `C1-fs-best-wW` | as `T`, with the title part multiplied by **coverage**: distinct query terms found in the file's title ÷ distinct query terms | as `T`, with coverage |
| `C2-…` | coverage squared | coverage squared |
| `-s-` | stem only, no folders | stem only, no folders |
| `-fsr-` | the root id kept as a folder | the root id kept as a folder |
| `-all-` | every body-matching chunk of the file gets the title part | per file, as above |

### search_field `content`: success@1 / MRR@10

| candidate | control | misspelling | morphology | accent | tamil | title | phrase | overall |
|---|---|---|---|---|---|---|---|---|
| today (S5-T1 baseline, reproduced) (`baseline`) | 1.000 / 1.000 | 0.062 / 0.199 | 0.154 / 0.362 | 0.333 / 0.485 | 0.231 / 0.308 | 0.000 / 0.258 | 0.800 / 0.900 | 0.421 / 0.538 |
| weighted RRF, stem channel at 0.25 (`WRRF-stem-a0.25`) | 1.000 / 1.000 | 0.062 / 0.199 | 0.154 / 0.362 | 0.333 / 0.485 | 0.231 / 0.308 | 0.000 / 0.258 | 0.800 / 0.900 | 0.421 / 0.538 |
| weighted RRF, stem channel at 0.5 (`WRRF-stem-a0.5`) | 1.000 / 1.000 | 0.062 / 0.199 | 0.154 / 0.362 | 0.333 / 0.485 | 0.231 / 0.308 | 0.000 / 0.258 | 0.800 / 0.900 | 0.421 / 0.538 |
| equal RRF, folders+stem channel (`RRF-title-a1`) | 1.000 / 1.000 | 0.062 / 0.199 | 0.154 / 0.362 | 0.333 / 0.485 | 0.231 / 0.308 | 0.000 / 0.258 | 0.800 / 0.900 | 0.421 / 0.538 |
| weighted RRF, folders+stem at 0.5 (`WRRF-title-a0.5`) | 1.000 / 1.000 | 0.062 / 0.199 | 0.154 / 0.362 | 0.333 / 0.485 | 0.231 / 0.308 | 0.000 / 0.258 | 0.800 / 0.900 | 0.421 / 0.538 |
| additive title, w 1.0, no coverage (`T-fs-best-w1.0`) | 1.000 / 1.000 | 0.062 / 0.199 | 0.154 / 0.349 | 0.333 / 0.481 | 0.231 / 0.308 | 0.273 / 0.606 | 0.800 / 0.900 | 0.453 / 0.576 |
| additive title, w 1.5, no coverage (`T-fs-best-w1.5`) | 1.000 / 1.000 | 0.062 / 0.199 | 0.154 / 0.338 | 0.333 / 0.481 | 0.231 / 0.308 | 0.727 / 0.864 | 0.800 / 0.900 | 0.505 / 0.604 |
| additive title, w 2.0, no coverage (`T-fs-best-w2.0`) | 0.957 / 0.978 | 0.062 / 0.193 | 0.154 / 0.338 | 0.333 / 0.481 | 0.231 / 0.295 | 0.909 / 0.955 | 0.800 / 0.900 | 0.516 / 0.607 |
| coverage title, stem only, w 2.5 (`C1-s-best-w2.5`) | 1.000 / 1.000 | 0.062 / 0.199 | 0.077 / 0.297 | 0.333 / 0.481 | 0.231 / 0.308 | 0.727 / 0.795 | 0.800 / 0.900 | 0.495 / 0.591 |
| coverage title, root id included, w 2.5 (`C1-fsr-best-w2.5`) | 1.000 / 1.000 | 0.062 / 0.199 | 0.154 / 0.349 | 0.333 / 0.481 | 0.231 / 0.308 | 0.909 / 0.955 | 0.800 / 0.900 | 0.526 / 0.616 |
| coverage title, every matching chunk, w 2.5 (`C1-fs-all-w2.5`) | 1.000 / 1.000 | 0.062 / 0.229 | 0.154 / 0.326 | 0.333 / 0.481 | 0.231 / 0.308 | 0.909 / 0.955 | 0.800 / 0.900 | 0.526 / 0.618 |
| coverage title, w 1.0 (`C1-fs-best-w1.0`) | 1.000 / 1.000 | 0.062 / 0.199 | 0.077 / 0.323 | 0.333 / 0.485 | 0.231 / 0.308 | 0.182 / 0.561 | 0.800 / 0.900 | 0.432 / 0.567 |
| coverage title, w 1.5 (`C1-fs-best-w1.5`) | 1.000 / 1.000 | 0.062 / 0.199 | 0.154 / 0.362 | 0.333 / 0.485 | 0.231 / 0.308 | 0.727 / 0.864 | 0.800 / 0.900 | 0.505 / 0.608 |
| coverage title, w 2.0 (`C1-fs-best-w2.0`) | 1.000 / 1.000 | 0.062 / 0.199 | 0.154 / 0.349 | 0.333 / 0.481 | 0.231 / 0.308 | 0.909 / 0.955 | 0.800 / 0.900 | 0.526 / 0.616 |
| coverage title, w 2.25 (`C1-fs-best-w2.25`) | 1.000 / 1.000 | 0.062 / 0.199 | 0.154 / 0.349 | 0.333 / 0.481 | 0.231 / 0.308 | 0.909 / 0.955 | 0.800 / 0.900 | 0.526 / 0.616 |
| **coverage title, w 2.5** (`C1-fs-best-w2.5`) | 1.000 / 1.000 | 0.062 / 0.199 | 0.154 / 0.349 | 0.333 / 0.481 | 0.231 / 0.308 | 0.909 / 0.955 | 0.800 / 0.900 | 0.526 / 0.616 |
| coverage title, w 2.75 (`C1-fs-best-w2.75`) | 1.000 / 1.000 | 0.062 / 0.199 | 0.154 / 0.349 | 0.333 / 0.481 | 0.231 / 0.308 | 1.000 / 1.000 | 0.800 / 0.900 | 0.537 / 0.622 |
| coverage title, w 3.0 (`C1-fs-best-w3.0`) | 1.000 / 1.000 | 0.062 / 0.199 | 0.154 / 0.349 | 0.333 / 0.481 | 0.231 / 0.308 | 1.000 / 1.000 | 0.800 / 0.900 | 0.537 / 0.622 |
| coverage title, w 3.5 (`C1-fs-best-w3.5`) | 1.000 / 1.000 | 0.062 / 0.193 | 0.154 / 0.349 | 0.333 / 0.481 | 0.231 / 0.295 | 1.000 / 1.000 | 0.800 / 0.900 | 0.537 / 0.619 |
| coverage title, w 4.0 (`C1-fs-best-w4.0`) | 1.000 / 1.000 | 0.062 / 0.193 | 0.154 / 0.342 | 0.333 / 0.481 | 0.231 / 0.295 | 1.000 / 1.000 | 0.800 / 0.900 | 0.537 / 0.618 |
| coverage title, w 5.0 (`C1-fs-best-w5.0`) | 1.000 / 1.000 | 0.062 / 0.193 | 0.154 / 0.338 | 0.333 / 0.481 | 0.231 / 0.295 | 1.000 / 1.000 | 0.800 / 0.900 | 0.537 / 0.617 |
| coverage squared, w 2.5 (`C2-fs-best-w2.5`) | 1.000 / 1.000 | 0.062 / 0.199 | 0.077 / 0.323 | 0.333 / 0.485 | 0.231 / 0.308 | 0.818 / 0.909 | 0.800 / 0.900 | 0.505 / 0.608 |

#### search_field `both`: success@1 / MRR@10

| candidate | control | misspelling | morphology | accent | tamil | title | phrase | overall |
|---|---|---|---|---|---|---|---|---|
| today (S5-T1 baseline, reproduced) (`baseline`) | 0.870 / 0.924 | 0.062 / 0.156 | 0.077 / 0.295 | 0.222 / 0.337 | 0.231 / 0.256 | 0.545 / 0.685 | 0.800 / 0.900 | 0.432 / 0.531 |
| weighted RRF, stem channel at 0.25 (`WRRF-stem-a0.25`) | 0.870 / 0.924 | 0.062 / 0.156 | 0.077 / 0.295 | 0.222 / 0.337 | 0.231 / 0.269 | 0.455 / 0.624 | 0.800 / 0.900 | 0.421 / 0.526 |
| weighted RRF, stem channel at 0.5 (`WRRF-stem-a0.5`) | 0.870 / 0.924 | 0.062 / 0.156 | 0.077 / 0.295 | 0.222 / 0.337 | 0.231 / 0.269 | 0.455 / 0.624 | 0.800 / 0.900 | 0.421 / 0.526 |
| equal RRF, folders+stem channel (`RRF-title-a1`) | 0.870 / 0.917 | 0.062 / 0.156 | 0.154 / 0.346 | 0.222 / 0.337 | 0.231 / 0.256 | 0.727 / 0.848 | 0.800 / 0.900 | 0.463 / 0.556 |
| weighted RRF, folders+stem at 0.5 (`WRRF-title-a0.5`) | 0.870 / 0.917 | 0.062 / 0.156 | 0.154 / 0.346 | 0.222 / 0.337 | 0.231 / 0.269 | 0.545 / 0.727 | 0.800 / 0.900 | 0.442 / 0.543 |
| additive title, w 1.0, no coverage (`T-fs-best-w1.0`) | 1.000 / 1.000 | 0.062 / 0.156 | 0.154 / 0.346 | 0.222 / 0.337 | 0.231 / 0.269 | 0.273 / 0.606 | 0.800 / 0.900 | 0.442 / 0.549 |
| additive title, w 1.5, no coverage (`T-fs-best-w1.5`) | 1.000 / 1.000 | 0.062 / 0.156 | 0.154 / 0.346 | 0.222 / 0.337 | 0.231 / 0.269 | 0.727 / 0.864 | 0.800 / 0.900 | 0.495 / 0.579 |
| additive title, w 2.0, no coverage (`T-fs-best-w2.0`) | 0.957 / 0.978 | 0.062 / 0.156 | 0.154 / 0.346 | 0.222 / 0.337 | 0.231 / 0.256 | 0.909 / 0.955 | 0.800 / 0.900 | 0.505 / 0.583 |
| coverage title, stem only, w 2.5 (`C1-s-best-w2.5`) | 1.000 / 1.000 | 0.062 / 0.156 | 0.077 / 0.295 | 0.222 / 0.337 | 0.231 / 0.269 | 0.727 / 0.806 | 0.800 / 0.900 | 0.484 / 0.566 |
| coverage title, root id included, w 2.5 (`C1-fsr-best-w2.5`) | 1.000 / 1.000 | 0.062 / 0.156 | 0.154 / 0.346 | 0.222 / 0.337 | 0.231 / 0.269 | 0.909 / 0.955 | 0.800 / 0.900 | 0.516 / 0.590 |
| coverage title, every matching chunk, w 2.5 (`C1-fs-all-w2.5`) | 1.000 / 1.000 | 0.062 / 0.156 | 0.154 / 0.346 | 0.222 / 0.337 | 0.231 / 0.269 | 0.909 / 0.955 | 0.800 / 0.900 | 0.516 / 0.590 |
| coverage title, w 1.0 (`C1-fs-best-w1.0`) | 1.000 / 1.000 | 0.062 / 0.156 | 0.077 / 0.308 | 0.222 / 0.343 | 0.231 / 0.269 | 0.182 / 0.561 | 0.800 / 0.900 | 0.421 / 0.539 |
| coverage title, w 1.5 (`C1-fs-best-w1.5`) | 1.000 / 1.000 | 0.062 / 0.156 | 0.154 / 0.346 | 0.222 / 0.343 | 0.231 / 0.269 | 0.727 / 0.864 | 0.800 / 0.900 | 0.495 / 0.580 |
| coverage title, w 2.0 (`C1-fs-best-w2.0`) | 1.000 / 1.000 | 0.062 / 0.156 | 0.154 / 0.346 | 0.222 / 0.337 | 0.231 / 0.269 | 0.909 / 0.955 | 0.800 / 0.900 | 0.516 / 0.590 |
| coverage title, w 2.25 (`C1-fs-best-w2.25`) | 1.000 / 1.000 | 0.062 / 0.156 | 0.154 / 0.346 | 0.222 / 0.337 | 0.231 / 0.269 | 0.909 / 0.955 | 0.800 / 0.900 | 0.516 / 0.590 |
| **coverage title, w 2.5** (`C1-fs-best-w2.5`) | 1.000 / 1.000 | 0.062 / 0.156 | 0.154 / 0.346 | 0.222 / 0.337 | 0.231 / 0.269 | 0.909 / 0.955 | 0.800 / 0.900 | 0.516 / 0.590 |
| coverage title, w 2.75 (`C1-fs-best-w2.75`) | 1.000 / 1.000 | 0.062 / 0.156 | 0.154 / 0.346 | 0.222 / 0.337 | 0.231 / 0.269 | 1.000 / 1.000 | 0.800 / 0.900 | 0.526 / 0.595 |
| coverage title, w 3.0 (`C1-fs-best-w3.0`) | 1.000 / 1.000 | 0.062 / 0.156 | 0.154 / 0.346 | 0.222 / 0.337 | 0.231 / 0.269 | 1.000 / 1.000 | 0.800 / 0.900 | 0.526 / 0.595 |
| coverage title, w 3.5 (`C1-fs-best-w3.5`) | 1.000 / 1.000 | 0.062 / 0.156 | 0.154 / 0.346 | 0.222 / 0.337 | 0.231 / 0.256 | 1.000 / 1.000 | 0.800 / 0.900 | 0.526 / 0.593 |
| coverage title, w 4.0 (`C1-fs-best-w4.0`) | 1.000 / 1.000 | 0.062 / 0.156 | 0.154 / 0.346 | 0.222 / 0.337 | 0.231 / 0.256 | 1.000 / 1.000 | 0.800 / 0.900 | 0.526 / 0.593 |
| coverage title, w 5.0 (`C1-fs-best-w5.0`) | 1.000 / 1.000 | 0.062 / 0.156 | 0.154 / 0.346 | 0.222 / 0.337 | 0.231 / 0.256 | 1.000 / 1.000 | 0.800 / 0.900 | 0.526 / 0.593 |
| coverage squared, w 2.5 (`C2-fs-best-w2.5`) | 1.000 / 1.000 | 0.062 / 0.156 | 0.077 / 0.308 | 0.222 / 0.343 | 0.231 / 0.269 | 0.818 / 0.909 | 0.800 / 0.900 | 0.495 / 0.580 |

#### First grade-2 rank per query: the title slice and the three `both` control rows (– = not in the top 10)

| candidate | variant | ti01 | ti02 | ti03 | ti04 | ti05 | ti06 | ti07 | ti08 | ti09 | ti10 | ti11 | c02 | c06 | c07 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| `baseline` | content | 9 | 7 | 2 | 3 | 3 | 6 | 2 | – | 2 | – | 4 | 1 | 1 | 1 |
| `baseline` | both | 3 | 1 | 1 | 1 | 1 | 5 | 3 | 3 | 1 | 1 | 3 | 2 | 4 | 2 |
| `WRRF-stem-a0.25` | content | 9 | 7 | 2 | 3 | 3 | 6 | 2 | – | 2 | – | 4 | 1 | 1 | 1 |
| `WRRF-stem-a0.25` | both | 3 | 3 | 1 | 1 | 1 | 5 | 3 | 3 | 1 | 1 | 3 | 2 | 4 | 2 |
| `RRF-title-a1` | content | 9 | 7 | 2 | 3 | 3 | 6 | 2 | – | 2 | – | 4 | 1 | 1 | 1 |
| `RRF-title-a1` | both | 1 | 1 | 1 | 1 | 2 | 1 | 2 | 3 | 1 | 1 | 1 | 3 | 4 | 2 |
| `T-fs-best-w1.5` | content | 2 | 1 | 1 | 1 | 1 | 2 | 2 | 1 | 1 | 1 | 1 | 1 | 1 | 1 |
| `T-fs-best-w1.5` | both | 2 | 1 | 1 | 1 | 1 | 2 | 2 | 1 | 1 | 1 | 1 | 1 | 1 | 1 |
| `T-fs-best-w2.0` | content | 1 | 1 | 1 | 1 | 1 | 1 | 2 | 1 | 1 | 1 | 1 | 2 | 1 | 1 |
| `T-fs-best-w2.0` | both | 1 | 1 | 1 | 1 | 1 | 1 | 2 | 1 | 1 | 1 | 1 | 2 | 1 | 1 |
| `C1-s-best-w2.5` | content | 1 | 1 | 1 | 1 | 1 | 6 | 3 | 1 | 1 | 1 | 4 | 1 | 1 | 1 |
| `C1-s-best-w2.5` | both | 1 | 1 | 1 | 1 | 1 | 5 | 3 | 1 | 1 | 1 | 3 | 1 | 1 | 1 |
| `C1-fsr-best-w2.5` | content | 1 | 1 | 1 | 1 | 1 | 1 | 1 | 1 | 2 | 1 | 1 | 1 | 1 | 1 |
| `C1-fsr-best-w2.5` | both | 1 | 1 | 1 | 1 | 1 | 1 | 1 | 1 | 2 | 1 | 1 | 1 | 1 | 1 |
| `C1-fs-best-w2.0` | content | 1 | 1 | 1 | 1 | 1 | 1 | 1 | 1 | 2 | 1 | 1 | 1 | 1 | 1 |
| `C1-fs-best-w2.0` | both | 1 | 1 | 1 | 1 | 1 | 1 | 1 | 1 | 2 | 1 | 1 | 1 | 1 | 1 |
| `C1-fs-best-w2.5` | content | 1 | 1 | 1 | 1 | 1 | 1 | 1 | 1 | 2 | 1 | 1 | 1 | 1 | 1 |
| `C1-fs-best-w2.5` | both | 1 | 1 | 1 | 1 | 1 | 1 | 1 | 1 | 2 | 1 | 1 | 1 | 1 | 1 |
| `C1-fs-best-w3.0` | content | 1 | 1 | 1 | 1 | 1 | 1 | 1 | 1 | 1 | 1 | 1 | 1 | 1 | 1 |
| `C1-fs-best-w3.0` | both | 1 | 1 | 1 | 1 | 1 | 1 | 1 | 1 | 1 | 1 | 1 | 1 | 1 | 1 |

#### Every first grade-2 rank that moves against today, `C1-fs-best-w2.5`

- `content`: `o06` 2→3, `o08` 1→2, `o13` 2→1, `a06` 5→6, `ti01` 9→1, `ti02` 7→1, `ti03` 2→1, `ti04` 3→1, `ti05` 3→1, `ti06` 6→1, `ti07` 2→1, `ti08` –→1, `ti10` –→1, `ti11` 4→1, `p02` 2→1, `p06` 1→2
  - negatives whose top hit changes: `cn1` wishlist.md → swimming-lessons/autumn-term.md (grade 0), `mn2` newsletter-autumn.md → swimming-lessons/autumn-term.md (grade 0), `on2` garden-diary.md → pets/biscuit-the-dog.md (grade 0), `tin1` newsletter-autumn.md → log/homework-tracker.txt (grade 0)
- `both`: `c02` 2→1, `c06` 4→1, `c07` 2→1, `o13` 3→1, `t06` 3→2, `ti01` 3→1, `ti06` 5→1, `ti07` 3→1, `ti08` 3→1, `ti09` 1→2, `ti11` 3→1
  - negatives whose top hit changes: `cn1` wishlist.md → swimming-lessons/autumn-term.md (grade 0), `mn2` newsletter-autumn.md → swimming-lessons/autumn-term.md (grade 0), `on2` weekend/sale-in-the-field.md → pets/biscuit-the-dog.md (grade 0)

## What it says

1. **Rank fusion cannot repair `c02`, `c06` or `c07`.** At every measured stem weight (0.25, 0.5, 0.75), control under `both` stays at 0.870. A file that is name rank 1 and body rank 2 gets 1/62 + A/61. That beats the body answer's 1/61 for any A above about 0.016, so the one-word name match always wins. RRF on folders and stem lifts the title slice under `both` (0.727) but leaves control at 0.870. A weighted RRF never touches `content`.
2. **An additive title part with no coverage has no safe weight.** At W 1.5 the title slice reaches 0.727. At W 2.0 it reaches 0.909, but `c02` falls to rank 2 (`school/pe-kit.txt`: 5.23 body + 2 · 4.22 title = 13.66, against the answer's 13.56).
3. **Coverage gives a plateau.** Control holds 1.000 in both variants from W 1.0 to 5.0. The title slice is ≥ 0.909 from W 2.0 to 5.0. No other slice's MRR@10 moves past its W 2.0 level until W 3.5. At W 3.5 misspelling drops 0.199 → 0.193 and Tamil 0.308 → 0.295, from `m14` and `t06`. At W 4.0 morphology drops 0.349 → 0.342. W 2.5 sits in the middle of the flat range [2.0, 3.0]. W 2.75 and above add only `ti09`.
4. **Folders matter.** Stem only loses the three folder rows (`ti06` 6, `ti07` 3, `ti11` 4) and morphology `o13`.
5. **The root id must stay out.** The app's root ids are opaque (`library` and Shared-folder ids). On J2, keeping the root `school` as a folder word costs `ti09` at W 3.0: `school` then names every file in the school root.
6. **`C1-fs-best-w2.5` against today.** It passes the S5-T1 gate's rules on both variants:
   - no control row loses rank 1;
   - no slice MRR@10 falls by more than 0.02 (largest: morphology `content` −0.013);
   - no first grade-2 rank worsens by more than 3 (largest: 1).
7. **The old packs are unchanged at W 0, 2, 3 and 5** (`proto_s5t2_packs.py`, Python reference, lexical, the title part patched into `content`):

   | Pack | Result |
   |---|---|
   | relevance-smoke strict | 1.0 on all four metrics |
   | `fixtures/judgments.json` | 1.0 |
   | mixed | MRR 0.775, nDCG 0.8327, success 1.0; every per-query first rank identical |
   | Tamil | 1.0, every query at rank 1 |
   | semantic | 0.0, as today: paraphrases |
   | family-folder pack | words recall 1.0, exactness 1.0, `find` precision and recall 1.0 |

   No file name in those fixtures shares a word with their queries strongly enough to move a rank. That is evidence that nothing breaks, not that the field helps.

## The derived field at 10k: cost (Zig, ReleaseSmall, a scratch bench)

**The method.**
- **Corpus:** the 10k timing corpus (`gen_timing_corpus.py`, 10,000 files in 100 `group-NN` folders, `doc-NNNNN.md`).
- **Index:** `searchd index --filename-index` at `8025d9f`: 19,959 chunks.
- **The derive:**
  - walk the documents section's record paths, one file per path;
  - tokenize each distinct folder once and each stem once with `analyzer_v2.tokenize`;
  - build postings with `lexical_build.build`;
  - make a term lookup map.
- **The walk:** per query, BM25 × coverage over the title postings.
- **Load:** these runs were taken while another agent's verifier was running. The 1-minute load was 6.22 at the first run and 3.69 at the second pair. **They are not under the S4 timing gate. Read them as indicative.**

**The derive.** 10,000 files, 100 distinct folders, 40,000 title tokens, 10,102 terms.

| Measure | Value |
|---|---|
| p50, three runs | 4.21, 4.19, 4.14 ms |
| p95, three runs | 4.74, 4.64, 4.25 ms |
| The scratch arena's transient bytes | 14,761,748 B (`lexical_build.build`'s per-document hash maps, which are never freed inside an arena) |
| The structures a reader keeps | about 1,238,188 B (terms 40 B each and their bytes, postings 8 B each, lengths, the chunk→file map, the lookup map) |

**The per-query title walk** (p50 of 40 after 10 warm-ups):

| Query | Title walk | Notes |
|---|---|---|
| `doc`, `group 42`, `doc 00042`, `search ranking doc` | 0.0333–0.0338 ms | a term in every file's title: the worst case |
| `hybrid retrieval`, `nosuchword` | 0.0006–0.0008 ms | no title term |
| `hybrid retrieval` (today's `content` query, for scale) | 0.031 ms | |

The merge of title-only files into the bounded top-k was not built in the bench and is not measured.

## Which effects should carry to searchd

**What should carry:**
- The title field's terms are the same on both surfaces. Python's `_filename_tokenize` mirrors `analyzer_v2.zig`'s simple fold, and the field is built only from paths.
- The title slice, the three control rows and the coverage factor should therefore carry rank for rank.

**What may not:**
- The body part differs exactly where S5-T1 found it: the Python reference folds body text fully (`a06`, `a07`, `a09`). That moves `a06` by one place here (5 → 6). On searchd it should move from 8.
- Zig sums in f32 in query-term order, and Python in f64 in sorted-term order. Expect tie-order differences below the answer, as S5-T1 recorded, and nothing else.
