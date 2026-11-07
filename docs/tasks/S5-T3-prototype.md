# S5-T3 prototype · misspelling expansion at query time, measured through the Python reference

**Planner:** Claude Opus 5.5 · **Date:** 2026-11-07 · **Checkout:** `main` at `2485787` · **Python:** 3.9.6

**What this is.**
- A patch over the reference's `core._bm25_scores` and `core._title_scores` (`fuzzy_expand.py`).
- A grid of 96 candidates run on J2 through `relevance_smoke.run_j2_pack()` and judged by `scripts/j2_gate.py` against the committed baseline.
- The old packs run through `evaluation.evaluate_modes` and `relevance_smoke.run_pack`.
- Dictionary counts for the 10k timing corpus.

**What it is not.** No Zig was built or timed. Every number here is a ranking metric or a count.

## Files

The scripts are kept under `scripts/prototypes/s5t3/`. They are scratch code from the planning pass, kept only so these numbers can be reproduced; no test imports them.

| File | What it does |
|---|---|
| `fuzzy_expand.py` | `Cfg` (every knob), bounded OSA on code points, the trigger, candidates, the order and cut, groups, the blended df, group scoring, the patched body and title scorers, `install(cfg, root_ids)` |
| `proto_s5t3.py` | The grid. It runs J2 per candidate, checks `today` against the baseline's Python cells, and prints the slice table, the gate verdict and, with `--detail`, the rank moves, the changed negatives, the expansions and the `find` rewrite information |
| `proto_s5t3_rows.py` | One candidate: per query, the triggers, the expansions (distance, df) and the top hits with grades, against today |
| `proto_s5t3_packs.py` | The old packs for named candidates against today: metrics, success@1 and every per-query first rank that changed |
| `dict_stats.py` | A corpus's term dictionary (size, lengths, first code points) and the work of a bounded scan per df-0 probe |

## Reproduce

From a checkout at `2485787` (or any later commit with the same `fixtures/j2` and baseline):

```
export TMPDIR=<a scratch dir>
PYTHONHASHSEED=0 python3 <proto dir>/proto_s5t3.py --detail --json <scratch>/grid.json > <scratch>/grid.txt
PYTHONHASHSEED=0 python3 <proto dir>/proto_s5t3_packs.py R R-scripts R-w0.8 > <scratch>/packs.txt
PYTHONHASHSEED=0 python3 <proto dir>/proto_s5t3_rows.py R --slices misspelling control --top 3
python3 scripts/gen_timing_corpus.py <scratch>/corpus10k 10000
python3 <proto dir>/dict_stats.py <scratch>/corpus10k
python3 <proto dir>/dict_stats.py fixtures/j2
```

**Checks recorded at the planner's run:**
- **`grid.txt`:** 1,388 lines, sha256 `7741119ccea76839c908d89e409321a5ffceb5d5a169c9d8b8e8a7c1b5454460`, about 23 s.
- **Seed independence:** `PYTHONHASHSEED=1` gives byte-identical output (checked on the grid before `R-c:sum` was added).
- **`packs.txt`:** sha256 `4ec6c65bbe8118e468b6cbdb7d5a6f476f048f8101fcc2263b223f6a73cb0b3b`.
- **The baseline check:** no `BASELINE MISMATCH` line. `today` equals `baseline.json`'s Python cells, query for query.

## Rule R (the plan's ruling 2)

`Cfg(df_max=0, d1_min=5, d2_min=6, first_letter=True, max_expansions=3, weight=1.0, w2=0.5, blend="max", combine="max", title=True, title_guard=True, latin_only=True, cand_title=True)`

In words:
- **The trigger:** in-scope df 0, no visible title holds the term, Latin only, at least 5 code points.
- **The bound:** OSA distance 1 for 5 code points, 2 for 6 or more, with the first code point kept.
- **The candidates:** from the body dictionary and the visible title terms, ordered by (distance, −df, bytes), N = 3.
- **The scoring:** one blended df (the maximum), the best member per chunk, a weight of 1.0 at distance 1 and 0.5 at distance 2. The title field is fed too.

## J2: today and rule R (success@1 / MRR@10)

| Slice | `content` today | `content` R | `both` today | `both` R |
|---|---|---|---|---|
| control | 1.000/1.000 | 1.000/1.000 | 1.000/1.000 | 1.000/1.000 |
| misspelling | 0.062/0.199 | **0.500/0.593** | 0.062/0.156 | **0.500/0.539** |
| morphology | 0.154/0.349 | 0.308/0.429 | 0.154/0.346 | 0.308/0.404 |
| accent | 0.333/0.481 | 0.556/0.667 | 0.222/0.337 | 0.444/0.559 |
| tamil | 0.231/0.308 | 0.231/0.308 | 0.231/0.269 | 0.231/0.269 |
| title | 0.909/0.955 | 0.909/0.955 | 0.909/0.955 | 0.909/0.955 |
| phrase | 0.800/0.900 | 0.800/0.900 | 0.800/0.900 | 0.800/0.900 |
| title-heldout | 1.000/1.000 | 1.000/1.000 | 1.000/1.000 | 1.000/1.000 |
| overall | 0.526/0.616 | 0.642/0.711 | 0.516/0.590 | 0.632/0.683 |

The gate passes in both variants.

### Per-query, the misspelling slice (first grade-2 rank, `content`; – = not in the top 10)

| Row | Query | Triggers → expansions (distance, df) | Today | R |
|---|---|---|---|---|
| m01 | dinosoar bones | dinosoar → dinosaur (2, 3) | 2 | **1** |
| m02 | multiplicaton tables | → multiplication (1, 2) | 3 | **1** |
| m03 | volcanoe project | → volcano (1, 5) | – | 6 (the intro chunk, grade 0, is first) |
| m04 | fractoins homework | → fractions (1, 3), fraction (2, 1) | – | 9 |
| m05 | freind birthday party | → friend (1, 1), find (2, 1), fried (2, 1) | – | **1** |
| m06 | wendesday pickup | `find:words`, not expanded | – | – |
| m07 | libary books | → library (1, 9) | – | – (`both`: 8) |
| m08 | bean hieght | → height (1, 2) | – | 4 |
| m09 | wierd noise car | → weird (1, 1) | 1 | 1 |
| m10 | recyling bins | → recycling (1, 2) | 2 | **1** |
| m11 | dinosuar | → dinosaur (1, 3) | – | **1** |
| m12 | febuary | → february (1, 2) | – | 2 |
| m13 | play rehersal times | → rehearsal (1, 1) | 7 | **1** |
| m14 | swimming goggels | → goggles (1, 1) | 3 | **1** |
| m15 | sciense fair | → science (1, 10) | 5 | 8 (worse by 3: gate (c)'s limit) |
| m16 | pancaeks recipe | → pancakes (1, 2) | – | 3 (the intro chunk is first) |

`both`: `m01` 2→1, `m02` –→1, `m05` –→1, `m07` –→8, `m10` 2→1, `m11` –→1, `m12` –→2, `m13` –→1, `m14` –→1.

### The control rows

No control row has a triggering term in either variant, so every control row's hits are byte-identical to today's.

### The other slices' moves

| Variant | Accent | Morphology |
|---|---|---|
| `content` | `a02` (`naïve`→naive) 3→1, `a03` (`fruhling`→frühling) –→1 | `o01` (`dinosaurs`→dinosaur) 2→1, `o07` (`feeds`→feed) 5→1, `o10` (`boxes`→bones, wrong) **2→4** |
| `both` | `a02` –→1, `a03` –→1 | `o01` 2→1, `o07` 2→1, `o10` 2→4 |

### The negatives whose top hit or hit count changes (all still grade 0)

| Negative | `content` | `both` |
|---|---|---|
| `an2` | 1 → 2 hits | 1 → 2 hits |
| `mn1` dinosuar museum | top: `trip-permission-museum.md` → `dinosaur-topic.md` (4 → 6 hits) | the same top change (3 hits) |
| `on2` | top → `science-homework.md` (`painting`→planting, d2) | the same |
| `pn1` | 2 → 7 hits (`skating`→saving, setting, sorting, d2) | 2 → 5 hits |
| `thn1` | 4 → 6 hits; the top is kept | the same |

## The sweep (J2 misspelling `content`, then `both`; the gate)

The `E-` candidates have a distance-1 bound from 3 code points and a base weight of 0.8 unless they set one. The `R-` candidates are rule R with one change.

| Candidate | Misspelling `content` | Misspelling `both` | Other effect | Gate |
|---|---|---|---|---|
| today | 0.062/0.199 | 0.062/0.156 | | pass |
| **R** | **0.500/0.593** | **0.500/0.539** | | pass |
| R-n1, R-n10 (and E-n1…n50) | 0.500/0.593 | 0.500/0.539 | N has no effect on J2 | pass |
| R-w0.8 (w2 0.4) | 0.438/0.546 | 0.438/0.477 | morphology 0.231; mixed MRR 0.808 | pass |
| E-n3-w0.5 | 0.375/0.509 | 0.375/0.445 | | pass |
| E-n3-w0.3 | 0.250/0.449 | 0.250/0.352 | | pass |
| E-damp-w1 | 0.438/0.545 | 0.438/0.477 | loses `m05` | pass |
| R-w1-n3-latin-d2:99 (no distance 2) | 0.438/0.562 | 0.438/0.508 | loses `m01` | pass |
| R-anyfirst | 0.500/0.590 | 0.500/0.538 | morphology `content` 0.308 → 0.231 | pass |
| R-lowdf1 (trigger at df ≤ 1) | 0.500/0.593 | 0.500/0.539 | control 0.957: `c22` loses rank 1 | **FAIL** |
| E-lowdf1-nokeep | 0.438/0.545 | 0.438/0.477 | control 0.913; Tamil 0.000 | **FAIL** |
| R-noguard (no title guard) | 0.500/0.593 | 0.500/0.539 | title-heldout 0.875: `th08` out of the top 10 | **FAIL** |
| R-notitle (no title feed) | 0.500/0.594 | 0.500/0.539 | `m15` 5→7 instead of 8; `helth` no longer finds `home/health/` | pass |
| R-scripts (no Latin rule) | 0.500/0.593 | 0.500/0.539 | identical J2; Tamil expansions all wrong in meaning | pass |
| R-df:own-c:sum | 0.500/0.593 | 0.500/0.539 | identical J2 at d1 ≥ 5 (at d1 ≥ 3: accent 0.667 via `cafe`→café, cage, cake) | pass |
| R-c:sum (sum within a chunk) | 0.500/0.593 | 0.500/0.539 | mixed MRR 0.808 (loses `combine-exact-and-meaning`) | pass |
| R-final (d1 from 3 cp) | 0.500/0.593 | 0.500/0.539 | morphology MRR 0.417; mixed MRR 0.825, `avoid-full-corpus-scan` 2→3 | pass |
| R-ct-d1:4 / d1:5, w2 0.25…0.5 | 0.500/0.593 | 0.500/0.539 | the distance-2 weight changes no J2 slice; at w2 1.0 the top hit of `thn1` becomes `chores.md` | pass |
| E-prefix4 | 0.438/0.545 | 0.438/0.477 | **Tamil 0.385/0.462**, morphology 0.308/0.429 | pass |
| E-prefix5 | 0.438/0.545 | 0.438/0.477 | Tamil 0.308/0.385 | pass |

The full 96-candidate table, with every slice in both variants, is `grid.txt`.

**The title-only demonstration** (rule R, `content`, J2 union):
- `helth` → health (1, a title-only term) → `home/health/doctor-visits.md`. Today there are no hits.
- `musik` → music → `home/music/recorder-practice.md` first.
- At d1 ≥ 5, `cafe menu`, `pony club` and `skip rope` are not expanded and are identical to today.

**The `find` rewrite (information only).** `m06` rewritten to the first expansion, `wednesday pickup`, gives first grade-2 rank 1. That would be a "did you mean", not part of this rule.

## The old packs at rule R

| Pack | Today | R |
|---|---|---|
| relevance-smoke | 1.0 strict | identical |
| knowledge (`fixtures/judgments.json`) | 1.0 | identical |
| tamil | 1.0 | identical |
| semantic (lexical) | 0.0 | identical |
| family-folder | words recall 1.0, exactness 1.0, `find` 1.0 | identical |
| mixed | MRR 0.775, nDCG 0.8327, success@1 0.60 | **MRR 0.8333, nDCG 0.8762, success@1 0.70** |

The mixed queries move as follows:

| Query | Expansion | Rank |
|---|---|---|
| `bread-rises` | `expand`→expands | 3→1 |
| `combine-exact-and-meaning` | `lists`→list, `merge`→merged, merges | 2→1 |
| `crash-safe-snapshot` | `written`→writes, d2 | 2→1 |
| `latency-breakdown` | `inference`→influence, d2 | **1→2** |

Other mixed expansions change no first rank: `change`→channel, `models`→model and moves, `stale`→scale, `rewards`→reads and records, `engine`→engines, `machine`→matching.

R-scripts: identical to R. R-w0.8: mixed MRR 0.8083 (`crash-safe-snapshot` is not lifted). At d1 ≥ 3 (R-final-candtitle): mixed MRR 0.825, and `avoid-full-corpus-scan` goes 2→3 (`file`→files).

## Dictionary counts (`dict_stats.py`; analyzer-v2 tokens; 200 probes, seed 7, one random edit of a dictionary word with the first letter kept and df 0)

| | 10k timing corpus | J2 |
|---|---|---|
| Distinct terms; bytes | 24,057; 152,881 | 1,743; 11,724 |
| Lengths (code points) | 6: 16,206 · 7: 7,046 · 8: 763 · other ≤ 16 each | spread 1–17, mode 4–5 |
| First code points; largest range | 17; `b` 24,003 | 60; `s` 168 |
| First-letter range scanned (median) | 24,003 | 87 |
| After the length filter (median) | 24,001 | 49.5 |
| Banded OSA cells (median / max) | 592,381 / 681,480 | 718.5 / 3,188 |
| The same with no first-letter rule | 592,915 / 682,258 | 11,995 / 28,172 |
| After a bag-distance prefilter: survivors; OSA cells (median / max) | 720 / 6,638; 20,970.5 / 162,712 | 2 / 10; 31 / 210 |
| Candidates within the bound (median / max) | 74 / 633 | 1 / 6 |
| Probes with more than 3 candidates; more than 50 | 0.91; 0.62 | 0.04; 0.00 |
| The original word among the candidates | 0.95 | 0.94 |

The probe bound in `dict_stats.py` is distance 1 from 3 code points and 2 from 6. At 10k almost every term has 6 or more code points, so this equals rule R there.

**The timing queries' terms at 10k.** `how does the hybrid retrieval work for a search` holds `how`, `does` and `work` at df 0. All are shorter than 5 code points, so rule R does not scan for them. `benico`, `hybrid retrieval` and `the and of to in` have no df-0 term.
