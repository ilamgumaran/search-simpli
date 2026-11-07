# S5-T4 prototype: folding and light stemming over J2 (planner, 7 Nov 2026)

This is the planner's prototype for `docs/tasks/S5-T4.md`. It runs on the Python reference only, with no timed Zig measurement: an app check chain was running on this Mac.

**Setup.**
- Python 3.9.6, whose `unicodedata` is Unicode 13.0.0 (the version of `zig/src/unicode_tables.zig`).
- J2 at `e0d258b`, `PYTHONHASHSEED=0`.

**The scripts** live in `scripts/prototypes/s5t4/` if the orchestrator wants them in the tree; until then they are in the planner's scratch. They take the checkout as the working directory and hold no machine paths:

| Script | What it does |
|---|---|
| `analyzer_v3.py` | The steps F, A, P, S, I, D, T and W (`key_terms` is K), and the hooks that install a candidate over `core.tokenize`, `core._filename_tokenize`, `find.tokenize` and `find.tokenize_positioned`. |
| `j2run.py` | The J2 pack exactly as `relevance_smoke.run_j2_pack`, with a hook between the build and the queries. Also holds the query-side groups (`install_groups`), the title and query stop words, and the fuzzy-v1 log. |
| `proto_s5t4.py` | The grid: every candidate, both variants, the gate against the `searchd` and the Python baseline cells, and the moves, negatives, groups and fuzzy expansions. |
| `proto_s5t4_rows.py` | The first grade-2 rank per row, across candidates. |
| `proto_s5t4_packs.py` | The old packs (relevance-smoke, `judgments.json`, mixed, Tamil, semantic, family folder) at a candidate against today. |
| `vocab_merges.py` | A corpus's dictionary under a candidate: counts, classes of two or more, and `--traps`. |
| `smoke.py` | The baseline-reproduction check. |

**Reproduce** (from a checkout; `$PROTO` is the scripts' directory; about 30 s in total):

```
export TMPDIR=<a scratch dir>
PYTHONHASHSEED=0 python3 $PROTO/proto_s5t4.py --detail --json $TMPDIR/grid.json > $TMPDIR/grid.txt
PYTHONHASHSEED=0 python3 $PROTO/proto_s5t4.py --only today-py today-eng FAST qG:FAST qN:FAST FASIDkT qG:FASIDkT --detail
PYTHONHASHSEED=0 python3 $PROTO/proto_s5t4_rows.py today-eng FAST qG:FAST qN:FAST FASIDkT qG:FASIDkT --slices morphology accent tamil
PYTHONHASHSEED=0 python3 $PROTO/proto_s5t4_packs.py FAST qG:FAST FASIDkT qG:FASIDkT FAPST qG:FAPST FAPSDkT FAPSIDkT
python3 $PROTO/vocab_merges.py FAST fixtures/j2/home --traps
python3 $PROTO/vocab_merges.py FAST fixtures/family-folder/home --classes
python3 scripts/gen_timing_corpus.py $TMPDIR/corpus10k 10000 && python3 $PROTO/vocab_merges.py FAST $TMPDIR/corpus10k
```

**The baseline reproduces.**
- `today-py` (the Python reference as it is) equals every Python cell of `fixtures/j2/baseline.json`.
- `today-eng` (the same reference with the engine's simple fold on the body) equals every `searchd` cell and every `searchd` first grade-2 rank.
- The grid checks both on every run and prints `BASELINE MISMATCH` if either differs. It printed none.
- Every candidate is built on `today-eng`'s base, so its gate result against the `searchd` cells is the prediction for `searchd`.

**The names.**
- **The steps:**
  - **F**: NFKC and full case fold, to a fixpoint, then the re-split.
  - **A**: Latin marks and the eight-letter table.
  - **P**: the possessive `s`.
  - **S**: English plural.
  - **I**: `-ing`.
  - **D**: Porter `-ed`. **Dk** is `-ed` with a doubled consonant left whole.
  - **T**: Tamil.
  - **Wt / Wq / Wi**: stop words in the title field only, dropped from the query, or in the analyzer.
- **The placement prefixes:**
  - **no prefix**: index side;
  - **`qN:`**: query side, the term and its own key only;
  - **`qG:`**: query side with key groups (plan ruling 10).

## J2 (success@1 / MRR@10)

| candidate | variant | control | misspelling | morphology | accent | tamil | title | phrase | title-heldout | misspelling-heldout | overall | gate vs `searchd` |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| today-py | content | 1.000/1.000 | 0.500/0.593 | 0.308/0.429 | 0.556/0.667 | 0.231/0.308 | 0.909/0.955 | 0.800/0.900 | 1.000/1.000 | 0.917/0.958 | 0.642/0.711 | pass |
| today-py | both | 1.000/1.000 | 0.500/0.539 | 0.308/0.404 | 0.444/0.559 | 0.231/0.269 | 0.909/0.955 | 0.800/0.900 | 1.000/1.000 | 0.917/0.958 | 0.632/0.683 | pass |
| today-eng | content | 1.000/1.000 | 0.500/0.593 | 0.308/0.429 | 0.444/0.551 | 0.231/0.308 | 0.909/0.955 | 0.800/0.900 | 1.000/1.000 | 0.917/0.958 | 0.632/0.700 | pass |
| today-eng | both | 1.000/1.000 | 0.500/0.539 | 0.308/0.404 | 0.444/0.553 | 0.231/0.269 | 0.909/0.955 | 0.800/0.900 | 1.000/1.000 | 0.917/0.958 | 0.632/0.683 | pass |
| F | content | 1.000/1.000 | 0.500/0.593 | 0.308/0.429 | 0.778/0.852 | 0.231/0.308 | 0.909/0.955 | 0.800/0.900 | 1.000/1.000 | 0.917/0.958 | 0.663/0.729 | pass |
| F | both | 1.000/1.000 | 0.500/0.539 | 0.308/0.404 | 0.778/0.856 | 0.231/0.269 | 0.909/0.955 | 0.800/0.900 | 1.000/1.000 | 0.917/0.958 | 0.663/0.711 | pass |
| A | content | 1.000/1.000 | 0.500/0.593 | 0.308/0.429 | 0.444/0.551 | 0.231/0.308 | 0.909/0.955 | 0.800/0.900 | 1.000/1.000 | 0.917/0.958 | 0.632/0.700 | pass |
| A | both | 1.000/1.000 | 0.500/0.539 | 0.308/0.404 | 0.444/0.553 | 0.231/0.269 | 0.909/0.955 | 0.800/0.900 | 1.000/1.000 | 0.917/0.958 | 0.632/0.683 | pass |
| P | content | 1.000/1.000 | 0.500/0.593 | 0.231/0.391 | 0.444/0.551 | 0.231/0.308 | 0.909/0.955 | 0.800/0.900 | 1.000/1.000 | 0.917/0.958 | 0.621/0.695 | FAIL (a) slice morphology: MRR@10 0.429 -> 0.391, a drop of 0.038 (limit 0. |
| P | both | 1.000/1.000 | 0.500/0.539 | 0.231/0.365 | 0.444/0.553 | 0.231/0.269 | 0.909/0.955 | 0.800/0.900 | 1.000/1.000 | 0.917/0.958 | 0.621/0.677 | FAIL (a) slice morphology: MRR@10 0.404 -> 0.365, a drop of 0.038 (limit 0. |
| S | content | 1.000/1.000 | 0.562/0.648 | 0.538/0.718 | 0.444/0.537 | 0.231/0.308 | 0.909/0.955 | 0.800/0.900 | 1.000/1.000 | 0.917/0.958 | 0.674/0.748 | pass |
| S | both | 1.000/1.000 | 0.562/0.594 | 0.538/0.679 | 0.444/0.548 | 0.231/0.269 | 0.909/0.955 | 0.800/0.900 | 1.000/1.000 | 0.917/0.958 | 0.674/0.729 | pass |
| T | content | 1.000/1.000 | 0.500/0.593 | 0.308/0.429 | 0.444/0.551 | 1.000/1.000 | 0.909/0.955 | 0.800/0.900 | 1.000/1.000 | 0.917/0.958 | 0.737/0.795 | pass |
| T | both | 1.000/1.000 | 0.500/0.539 | 0.308/0.404 | 0.444/0.553 | 1.000/1.000 | 0.909/0.955 | 0.800/0.900 | 1.000/1.000 | 0.917/0.958 | 0.737/0.783 | pass |
| D | content | 0.957/0.965 | 0.500/0.593 | 0.308/0.468 | 0.444/0.551 | 0.231/0.308 | 0.909/0.955 | 0.800/0.900 | 1.000/1.000 | 0.917/0.958 | 0.621/0.697 | FAIL (a) slice control: MRR@10 1.000 -> 0.965, a drop of 0.035 (limit 0.02) |
| D | both | 0.957/0.967 | 0.500/0.539 | 0.308/0.442 | 0.444/0.553 | 0.231/0.269 | 0.909/0.955 | 0.800/0.900 | 1.000/1.000 | 0.917/0.958 | 0.621/0.680 | FAIL (a) slice control: MRR@10 1.000 -> 0.967, a drop of 0.033 (limit 0.02) |
| Dk | content | 1.000/1.000 | 0.500/0.593 | 0.308/0.468 | 0.444/0.551 | 0.231/0.308 | 0.909/0.955 | 0.800/0.900 | 1.000/1.000 | 0.917/0.958 | 0.632/0.706 | pass |
| Dk | both | 1.000/1.000 | 0.500/0.539 | 0.308/0.442 | 0.444/0.553 | 0.231/0.269 | 0.909/0.955 | 0.800/0.900 | 1.000/1.000 | 0.917/0.958 | 0.632/0.688 | pass |
| I | content | 1.000/1.000 | 0.500/0.593 | 0.308/0.442 | 0.333/0.440 | 0.231/0.308 | 0.909/0.955 | 0.800/0.900 | 1.000/1.000 | 0.917/0.958 | 0.621/0.692 | FAIL (a) slice accent: MRR@10 0.551 -> 0.440, a drop of 0.111 (limit 0.02) |
| I | both | 1.000/1.000 | 0.500/0.539 | 0.308/0.404 | 0.333/0.442 | 0.231/0.269 | 0.909/0.955 | 0.800/0.900 | 1.000/1.000 | 0.917/0.958 | 0.621/0.672 | FAIL (a) slice accent: MRR@10 0.553 -> 0.442, a drop of 0.111 (limit 0.02) |
| Wt | content | 1.000/1.000 | 0.500/0.593 | 0.231/0.391 | 0.444/0.551 | 0.231/0.308 | 0.909/0.955 | 0.800/0.900 | 1.000/1.000 | 0.917/0.958 | 0.621/0.695 | FAIL (a) slice morphology: MRR@10 0.429 -> 0.391, a drop of 0.038 (limit 0. |
| Wt | both | 1.000/1.000 | 0.500/0.539 | 0.231/0.365 | 0.444/0.553 | 0.231/0.269 | 0.909/0.955 | 0.800/0.900 | 1.000/1.000 | 0.917/0.958 | 0.621/0.677 | FAIL (a) slice morphology: MRR@10 0.404 -> 0.365, a drop of 0.038 (limit 0. |
| Wq | content | 1.000/1.000 | 0.500/0.593 | 0.308/0.429 | 0.444/0.551 | 0.231/0.308 | 0.909/0.955 | 0.800/0.900 | 1.000/1.000 | 0.917/0.958 | 0.632/0.700 | pass |
| Wq | both | 1.000/1.000 | 0.500/0.539 | 0.308/0.404 | 0.444/0.553 | 0.231/0.269 | 0.909/0.955 | 0.800/0.900 | 1.000/1.000 | 0.917/0.958 | 0.632/0.683 | pass |
| FA | content | 1.000/1.000 | 0.500/0.593 | 0.308/0.429 | 0.778/0.852 | 0.231/0.308 | 0.909/0.955 | 0.800/0.900 | 1.000/1.000 | 0.917/0.958 | 0.663/0.729 | pass |
| FA | both | 1.000/1.000 | 0.500/0.539 | 0.308/0.404 | 0.778/0.856 | 0.231/0.269 | 0.909/0.955 | 0.800/0.900 | 1.000/1.000 | 0.917/0.958 | 0.663/0.711 | pass |
| PS | content | 1.000/1.000 | 0.562/0.648 | 0.538/0.718 | 0.444/0.537 | 0.231/0.308 | 0.909/0.955 | 0.800/0.900 | 1.000/1.000 | 0.917/0.958 | 0.674/0.748 | pass |
| PS | both | 1.000/1.000 | 0.562/0.594 | 0.538/0.679 | 0.444/0.548 | 0.231/0.269 | 0.909/0.955 | 0.800/0.900 | 1.000/1.000 | 0.917/0.958 | 0.674/0.729 | pass |
| FAPS | content | 1.000/1.000 | 0.562/0.648 | 0.538/0.718 | 0.778/0.847 | 0.231/0.308 | 0.909/0.955 | 0.800/0.900 | 1.000/1.000 | 0.917/0.958 | 0.705/0.777 | pass |
| FAPS | both | 1.000/1.000 | 0.562/0.594 | 0.538/0.679 | 0.778/0.849 | 0.231/0.269 | 0.909/0.955 | 0.800/0.900 | 1.000/1.000 | 0.917/0.958 | 0.705/0.758 | pass |
| FST | content | 1.000/1.000 | 0.562/0.648 | 0.538/0.718 | 0.778/0.847 | 1.000/1.000 | 0.909/0.955 | 0.800/0.900 | 1.000/1.000 | 0.917/0.958 | 0.811/0.872 | pass |
| FST | both | 1.000/1.000 | 0.562/0.594 | 0.538/0.679 | 0.778/0.849 | 1.000/1.000 | 0.909/0.955 | 0.800/0.900 | 1.000/1.000 | 0.917/0.958 | 0.811/0.858 | pass |
| FPST | content | 1.000/1.000 | 0.562/0.648 | 0.538/0.718 | 0.778/0.847 | 1.000/1.000 | 0.909/0.955 | 0.800/0.900 | 1.000/1.000 | 0.917/0.958 | 0.811/0.872 | pass |
| FPST | both | 1.000/1.000 | 0.562/0.594 | 0.538/0.679 | 0.778/0.849 | 1.000/1.000 | 0.909/0.955 | 0.800/0.900 | 1.000/1.000 | 0.917/0.958 | 0.811/0.858 | pass |
| FAST | content | 1.000/1.000 | 0.562/0.648 | 0.538/0.718 | 0.778/0.847 | 1.000/1.000 | 0.909/0.955 | 0.800/0.900 | 1.000/1.000 | 0.917/0.958 | 0.811/0.872 | pass |
| FAST | both | 1.000/1.000 | 0.562/0.594 | 0.538/0.679 | 0.778/0.849 | 1.000/1.000 | 0.909/0.955 | 0.800/0.900 | 1.000/1.000 | 0.917/0.958 | 0.811/0.858 | pass |
| FAPST | content | 1.000/1.000 | 0.562/0.648 | 0.538/0.718 | 0.778/0.847 | 1.000/1.000 | 0.909/0.955 | 0.800/0.900 | 1.000/1.000 | 0.917/0.958 | 0.811/0.872 | pass |
| FAPST | both | 1.000/1.000 | 0.562/0.594 | 0.538/0.679 | 0.778/0.849 | 1.000/1.000 | 0.909/0.955 | 0.800/0.900 | 1.000/1.000 | 0.917/0.958 | 0.811/0.858 | pass |
| FAPSIT | content | 1.000/1.000 | 0.562/0.648 | 0.538/0.718 | 0.778/0.847 | 1.000/1.000 | 0.909/0.955 | 0.800/0.900 | 1.000/1.000 | 0.917/0.958 | 0.811/0.872 | pass |
| FAPSIT | both | 1.000/1.000 | 0.562/0.594 | 0.538/0.669 | 0.778/0.849 | 1.000/1.000 | 0.909/0.955 | 0.800/0.900 | 1.000/1.000 | 0.917/0.958 | 0.811/0.856 | pass |
| FAPSDkT | content | 1.000/1.000 | 0.562/0.648 | 0.615/0.782 | 0.778/0.847 | 1.000/1.000 | 0.909/0.955 | 0.800/0.900 | 1.000/1.000 | 0.917/0.958 | 0.821/0.881 | pass |
| FAPSDkT | both | 1.000/1.000 | 0.562/0.594 | 0.615/0.756 | 0.778/0.849 | 1.000/1.000 | 0.909/0.955 | 0.800/0.900 | 1.000/1.000 | 0.917/0.958 | 0.821/0.868 | pass |
| FASIDkT | content | 1.000/1.000 | 0.562/0.648 | 0.692/0.821 | 0.778/0.847 | 1.000/1.000 | 0.909/0.955 | 0.800/0.900 | 1.000/1.000 | 0.917/0.958 | 0.832/0.886 | pass |
| FASIDkT | both | 1.000/1.000 | 0.562/0.594 | 0.692/0.823 | 0.778/0.849 | 1.000/1.000 | 0.909/0.955 | 0.800/0.900 | 1.000/1.000 | 0.917/0.958 | 0.832/0.877 | pass |
| FAPSIDkT | content | 1.000/1.000 | 0.562/0.648 | 0.692/0.821 | 0.778/0.847 | 1.000/1.000 | 0.909/0.955 | 0.800/0.900 | 1.000/1.000 | 0.917/0.958 | 0.832/0.886 | pass |
| FAPSIDkT | both | 1.000/1.000 | 0.562/0.594 | 0.692/0.823 | 0.778/0.849 | 1.000/1.000 | 0.909/0.955 | 0.800/0.900 | 1.000/1.000 | 0.917/0.958 | 0.832/0.877 | pass |
| FAPSIDT | content | 0.957/0.963 | 0.562/0.648 | 0.692/0.821 | 0.778/0.847 | 1.000/1.000 | 0.909/0.955 | 0.800/0.900 | 1.000/1.000 | 0.917/0.958 | 0.821/0.877 | FAIL (a) slice control: MRR@10 1.000 -> 0.963, a drop of 0.037 (limit 0.02) |
| FAPSIDT | both | 0.957/0.964 | 0.562/0.594 | 0.692/0.823 | 0.778/0.849 | 1.000/1.000 | 0.909/0.955 | 0.800/0.900 | 1.000/1.000 | 0.917/0.958 | 0.821/0.869 | FAIL (a) slice control: MRR@10 1.000 -> 0.964, a drop of 0.036 (limit 0.02) |
| FAPST+Wt | content | 1.000/1.000 | 0.562/0.648 | 0.462/0.679 | 0.778/0.847 | 1.000/1.000 | 0.909/0.955 | 0.800/0.900 | 1.000/1.000 | 0.917/0.958 | 0.800/0.867 | pass |
| FAPST+Wt | both | 1.000/1.000 | 0.562/0.594 | 0.462/0.641 | 0.778/0.849 | 1.000/1.000 | 0.909/0.955 | 0.800/0.900 | 1.000/1.000 | 0.917/0.958 | 0.800/0.852 | pass |
| FAPST+Wq | content | 1.000/1.000 | 0.562/0.648 | 0.538/0.718 | 0.778/0.847 | 1.000/1.000 | 0.909/0.955 | 0.800/0.900 | 1.000/1.000 | 0.917/0.958 | 0.811/0.872 | pass |
| FAPST+Wq | both | 1.000/1.000 | 0.562/0.594 | 0.538/0.679 | 0.778/0.849 | 1.000/1.000 | 0.909/0.955 | 0.800/0.900 | 1.000/1.000 | 0.917/0.958 | 0.811/0.858 | pass |
| FAPST+Wi | content | 1.000/1.000 | 0.562/0.651 | 0.462/0.679 | 0.889/0.905 | 1.000/1.000 | 1.000/1.000 | 0.800/0.900 | 1.000/1.000 | 0.917/0.944 | 0.821/0.878 | pass |
| FAPST+Wi | both | 1.000/1.000 | 0.562/0.594 | 0.462/0.641 | 0.889/0.907 | 1.000/1.000 | 1.000/1.000 | 0.800/0.900 | 1.000/1.000 | 0.917/0.944 | 0.821/0.863 | pass |
| qN:FAST | content | 1.000/1.000 | 0.562/0.655 | 0.462/0.641 | 0.556/0.662 | 0.692/0.769 | 0.909/0.955 | 0.800/0.900 | 1.000/1.000 | 0.917/0.958 | 0.737/0.813 | pass |
| qN:FAST | both | 1.000/1.000 | 0.562/0.594 | 0.462/0.603 | 0.556/0.664 | 0.692/0.731 | 0.909/0.955 | 0.800/0.900 | 1.000/1.000 | 0.917/0.958 | 0.737/0.793 | pass |
| qG:FAST | content | 1.000/1.000 | 0.562/0.649 | 0.538/0.718 | 0.778/0.846 | 1.000/1.000 | 0.909/0.955 | 0.800/0.900 | 1.000/1.000 | 0.917/0.958 | 0.811/0.872 | pass |
| qG:FAST | both | 1.000/1.000 | 0.562/0.594 | 0.538/0.679 | 0.778/0.847 | 1.000/1.000 | 0.909/0.955 | 0.800/0.900 | 1.000/1.000 | 0.917/0.958 | 0.811/0.857 | pass |
| qN:FAPST | content | 1.000/1.000 | 0.562/0.655 | 0.462/0.641 | 0.556/0.662 | 0.692/0.769 | 0.909/0.955 | 0.800/0.900 | 1.000/1.000 | 0.917/0.958 | 0.737/0.813 | pass |
| qN:FAPST | both | 1.000/1.000 | 0.562/0.594 | 0.462/0.603 | 0.556/0.664 | 0.692/0.731 | 0.909/0.955 | 0.800/0.900 | 1.000/1.000 | 0.917/0.958 | 0.737/0.793 | pass |
| qG:FAPST | content | 1.000/1.000 | 0.562/0.649 | 0.538/0.718 | 0.778/0.846 | 1.000/1.000 | 0.909/0.955 | 0.800/0.900 | 1.000/1.000 | 0.917/0.958 | 0.811/0.872 | pass |
| qG:FAPST | both | 1.000/1.000 | 0.562/0.594 | 0.538/0.679 | 0.778/0.847 | 1.000/1.000 | 0.909/0.955 | 0.800/0.900 | 1.000/1.000 | 0.917/0.958 | 0.811/0.857 | pass |
| qG:FASIDkT | content | 1.000/1.000 | 0.562/0.649 | 0.769/0.859 | 0.778/0.846 | 1.000/1.000 | 0.909/0.955 | 0.800/0.900 | 1.000/1.000 | 0.917/0.958 | 0.842/0.891 | pass |
| qG:FASIDkT | both | 1.000/1.000 | 0.562/0.594 | 0.769/0.862 | 0.778/0.847 | 1.000/1.000 | 0.909/0.955 | 0.800/0.900 | 1.000/1.000 | 0.917/0.958 | 0.842/0.882 | pass |
| qG:FAPSIDkT | content | 1.000/1.000 | 0.562/0.649 | 0.769/0.859 | 0.778/0.846 | 1.000/1.000 | 0.909/0.955 | 0.800/0.900 | 1.000/1.000 | 0.917/0.958 | 0.842/0.891 | pass |
| qG:FAPSIDkT | both | 1.000/1.000 | 0.562/0.594 | 0.769/0.862 | 0.778/0.847 | 1.000/1.000 | 0.909/0.955 | 0.800/0.900 | 1.000/1.000 | 0.917/0.958 | 0.842/0.882 | pass |
| qN:T | content | 1.000/1.000 | 0.500/0.593 | 0.308/0.429 | 0.444/0.551 | 0.692/0.769 | 0.909/0.955 | 0.800/0.900 | 1.000/1.000 | 0.917/0.958 | 0.695/0.763 | pass |
| qN:T | both | 1.000/1.000 | 0.500/0.539 | 0.308/0.404 | 0.444/0.553 | 0.692/0.731 | 0.909/0.955 | 0.800/0.900 | 1.000/1.000 | 0.917/0.958 | 0.695/0.746 | pass |
| qG:T | content | 1.000/1.000 | 0.500/0.593 | 0.308/0.429 | 0.444/0.551 | 1.000/1.000 | 0.909/0.955 | 0.800/0.900 | 1.000/1.000 | 0.917/0.958 | 0.737/0.795 | pass |
| qG:T | both | 1.000/1.000 | 0.500/0.539 | 0.308/0.404 | 0.444/0.553 | 1.000/1.000 | 0.909/0.955 | 0.800/0.900 | 1.000/1.000 | 0.917/0.958 | 0.737/0.783 | pass |
| qN:S | content | 1.000/1.000 | 0.562/0.655 | 0.462/0.641 | 0.444/0.551 | 0.231/0.308 | 0.909/0.955 | 0.800/0.900 | 1.000/1.000 | 0.917/0.958 | 0.663/0.740 | pass |
| qN:S | both | 1.000/1.000 | 0.562/0.594 | 0.462/0.603 | 0.444/0.553 | 0.231/0.269 | 0.909/0.955 | 0.800/0.900 | 1.000/1.000 | 0.917/0.958 | 0.663/0.719 | pass |
| qG:S | content | 1.000/1.000 | 0.562/0.649 | 0.538/0.718 | 0.444/0.537 | 0.231/0.308 | 0.909/0.955 | 0.800/0.900 | 1.000/1.000 | 0.917/0.958 | 0.674/0.748 | pass |
| qG:S | both | 1.000/1.000 | 0.562/0.594 | 0.538/0.679 | 0.444/0.548 | 0.231/0.269 | 0.909/0.955 | 0.800/0.900 | 1.000/1.000 | 0.917/0.958 | 0.674/0.729 | pass |

## Per row: first grade-2 rank (`-` = not in the top 10; `*` = moves in some candidate)

No control row moves under any candidate in this table (`proto_s5t4_rows.py … --slices control`).

```
== content: first grade-2 rank (- = not in the top 10)
id    query                            today-eng        FAST     qG:FAST     qN:FAST     FASIDkT  qG:FASIDkT
o01   dinosaurs teeth                          1           1           1           1           1           1
o02   pony ride                                -           1           1           -           1           1  *
o03   teachers names                           -           1           1           1           1           1  *
o04   biscuit's lead                           1           1           1           1           1           1
o05   planting tulips                          -           3           3           3           6           6  *
o06   football practice cancelled              3           3           3           3           1           1  *
o07   feeds biscuit                            1           1           1           1           2           1  *
o08   spelling tests                           2           2           2           2           2           2
o09   strawberries                             -           2           2           2           2           2  *
o10   craft boxes                              4           1           1           1           1           1  *
o11   skip rope                                2           2           2           2           1           1  *
o12   painted pots                             -           6           6           6           1           1  *
o13   paati's recipes                          1           1           1           1           1           1
a01   cafe menu                                2           2           2           2           2           2
a02   naïve character book                     1           1           1           1           1           1
a03   fruhling                                 1           1           1           1           1           1
a04   room 12                                  3           1           1           3           1           1  *
a05   ｇｏｇｇｌｅｓ                                  -           1           1           -           1           1  *
a06   field trip date                          8           8           9           8           8           9  *
a07   ﬂute                                     -           1           1           1           1           1  *
a08   noël concert                             1           1           1           1           1           1
a09   strasse                                  1           1           1           1           1           1
t01   புத்தகங்கள்                              -           1           1           1           1           1  *
t02   யானை                                     -           1           1           -           1           1  *
t03   கடைக்கு                                  -           1           1           1           1           1  *
t04   மரம் கதை                                 2           1           1           2           1           1  *
t05   நூலகத்தில்                               -           1           1           1           1           1  *
t06   பாட்டி வீடு                              2           1           1           2           1           1  *
t07   பழங்கள்                                  -           1           1           1           1           1  *
t08   தேர்வுக்கு                               -           1           1           1           1           1  *
t09   பாடல்                                    -           1           1           -           1           1  *
t10   பள்ளிக்கு                                -           1           1           1           1           1  *
g1    காலை                                     1           1           1           1           1           1
g2    நாளை                                     1           1           1           1           1           1
g3    தேர்வு                                   1           1           1           1           1           1
== both: first grade-2 rank (- = not in the top 10)
id    query                            today-eng        FAST     qG:FAST     qN:FAST     FASIDkT  qG:FASIDkT
o01   dinosaurs teeth                          1           1           1           1           1           1
o02   pony ride                                -           1           1           -           1           1  *
o03   teachers names                           -           1           1           1           1           1  *
o04   biscuit's lead                           1           1           1           1           1           1
o05   planting tulips                          -           3           3           3           5           5  *
o06   football practice cancelled              -           -           -           -           1           1  *
o07   feeds biscuit                            1           1           1           1           2           1  *
o08   spelling tests                           2           2           2           2           2           2
o09   strawberries                             -           2           2           2           2           2  *
o10   craft boxes                              4           1           1           1           1           1  *
o11   skip rope                                2           2           2           2           1           1  *
o12   painted pots                             -           -           -           -           1           1  *
o13   paati's recipes                          1           1           1           1           1           1
a01   cafe menu                                2           2           2           2           2           2
a02   naïve character book                     1           1           1           1           1           1
a03   fruhling                                 1           1           1           1           1           1
a04   room 12                                  3           1           1           3           1           1  *
a05   ｇｏｇｇｌｅｓ                                  -           1           1           -           1           1  *
a06   field trip date                          7           7           8           7           7           8  *
a07   ﬂute                                     -           1           1           1           1           1  *
a08   noël concert                             1           1           1           1           1           1
a09   strasse                                  1           1           1           1           1           1
t01   புத்தகங்கள்                              -           1           1           1           1           1  *
t02   யானை                                     -           1           1           -           1           1  *
t03   கடைக்கு                                  -           1           1           1           1           1  *
t04   மரம் கதை                                 -           1           1           -           1           1  *
t05   நூலகத்தில்                               -           1           1           1           1           1  *
t06   பாட்டி வீடு                              2           1           1           2           1           1  *
t07   பழங்கள்                                  -           1           1           1           1           1  *
t08   தேர்வுக்கு                               -           1           1           1           1           1  *
t09   பாடல்                                    -           1           1           -           1           1  *
t10   பள்ளிக்கு                                -           1           1           1           1           1  *
g1    காலை                                     1           1           1           1           1           1
g2    நாளை                                     1           1           1           1           1           1
g3    தேர்வு                                   1           1           1           1           1           1
```

## Moves, negatives and expansions (`proto_s5t4.py --detail`)

```
MOVES FAPST+Wi both a01:2->1 a04:3->1 a05:None->1 a06:7->6 a07:None->1 m07:8->1 mh10:2->3 o02:None->1 o03:None->1 o05:None->3 o07:1->2 o09:None->2 o10:4->1 t01:None->1 t02:None->1 t03:None->1 t04:None->1 t05:None->1 t06:2->1 t07:None->1 t08:None->1 t09:None->1 t10:None->1 ti09:2->1
MOVES FAPST+Wi content a01:2->1 a04:3->1 a05:None->1 a06:8->7 a07:None->1 m03:6->7 m07:None->1 m15:8->6 m16:3->4 mh10:2->3 o02:None->1 o03:None->1 o05:None->3 o07:1->2 o09:None->2 o10:4->1 o12:None->6 t01:None->1 t02:None->1 t03:None->1 t04:2->1 t05:None->1 t06:2->1 t07:None->1 t08:None->1 t09:None->1 t10:None->1 ti09:2->1
MOVES FAPST+Wt both a04:3->1 a05:None->1 a07:None->1 m07:8->1 o02:None->1 o03:None->1 o05:None->3 o07:1->2 o09:None->2 o10:4->1 t01:None->1 t02:None->1 t03:None->1 t04:None->1 t05:None->1 t06:2->1 t07:None->1 t08:None->1 t09:None->1 t10:None->1
MOVES FAPST+Wt content a04:3->1 a05:None->1 a07:None->1 m03:6->7 m04:9->10 m07:None->1 m16:3->4 o02:None->1 o03:None->1 o05:None->3 o07:1->2 o09:None->2 o10:4->1 o12:None->6 t01:None->1 t02:None->1 t03:None->1 t04:2->1 t05:None->1 t06:2->1 t07:None->1 t08:None->1 t09:None->1 t10:None->1
MOVES FASIDkT both a04:3->1 a05:None->1 a07:None->1 m07:8->1 o02:None->1 o03:None->1 o05:None->5 o06:None->1 o07:1->2 o09:None->2 o10:4->1 o11:2->1 o12:None->1 t01:None->1 t02:None->1 t03:None->1 t04:None->1 t05:None->1 t06:2->1 t07:None->1 t08:None->1 t09:None->1 t10:None->1
MOVES FASIDkT content a04:3->1 a05:None->1 a07:None->1 m03:6->7 m04:9->10 m07:None->1 m16:3->4 o02:None->1 o03:None->1 o05:None->6 o06:3->1 o07:1->2 o09:None->2 o10:4->1 o11:2->1 o12:None->1 t01:None->1 t02:None->1 t03:None->1 t04:2->1 t05:None->1 t06:2->1 t07:None->1 t08:None->1 t09:None->1 t10:None->1
MOVES FAST both a04:3->1 a05:None->1 a07:None->1 m07:8->1 o02:None->1 o03:None->1 o05:None->3 o09:None->2 o10:4->1 t01:None->1 t02:None->1 t03:None->1 t04:None->1 t05:None->1 t06:2->1 t07:None->1 t08:None->1 t09:None->1 t10:None->1
MOVES FAST content a04:3->1 a05:None->1 a07:None->1 m03:6->7 m04:9->10 m07:None->1 m16:3->4 o02:None->1 o03:None->1 o05:None->3 o09:None->2 o10:4->1 o12:None->6 t01:None->1 t02:None->1 t03:None->1 t04:2->1 t05:None->1 t06:2->1 t07:None->1 t08:None->1 t09:None->1 t10:None->1
MOVES qG:FASIDkT both a04:3->1 a05:None->1 a06:7->8 a07:None->1 m07:8->1 o02:None->1 o03:None->1 o05:None->5 o06:None->1 o09:None->2 o10:4->1 o11:2->1 o12:None->1 t01:None->1 t02:None->1 t03:None->1 t04:None->1 t05:None->1 t06:2->1 t07:None->1 t08:None->1 t09:None->1 t10:None->1
MOVES qG:FASIDkT content a04:3->1 a05:None->1 a06:8->9 a07:None->1 m03:6->7 m07:None->1 m16:3->4 o02:None->1 o03:None->1 o05:None->6 o06:3->1 o09:None->2 o10:4->1 o11:2->1 o12:None->1 t01:None->1 t02:None->1 t03:None->1 t04:2->1 t05:None->1 t06:2->1 t07:None->1 t08:None->1 t09:None->1 t10:None->1
MOVES qG:FAST both a04:3->1 a05:None->1 a06:7->8 a07:None->1 m07:8->1 o02:None->1 o03:None->1 o05:None->3 o09:None->2 o10:4->1 t01:None->1 t02:None->1 t03:None->1 t04:None->1 t05:None->1 t06:2->1 t07:None->1 t08:None->1 t09:None->1 t10:None->1
MOVES qG:FAST content a04:3->1 a05:None->1 a06:8->9 a07:None->1 m03:6->7 m07:None->1 m16:3->4 o02:None->1 o03:None->1 o05:None->3 o09:None->2 o10:4->1 o12:None->6 t01:None->1 t02:None->1 t03:None->1 t04:2->1 t05:None->1 t06:2->1 t07:None->1 t08:None->1 t09:None->1 t10:None->1
NEG FAPST+Wq both an1 [2, 'recipes/pancakes.md'] -> [4, 'recipes/pancakes.md', 0, True]
NEG FAPST+Wq both an2 [2, 'letters/letter-home-oct.txt'] -> [4, 'letters/letter-home-oct.txt', 0, True]
NEG FAPST+Wq both cn1 [5, 'swimming-lessons/autumn-term.md'] -> [6, 'swimming-lessons/autumn-term.md', 0, True]
NEG FAPST+Wq both mn2 [4, 'swimming-lessons/autumn-term.md'] -> [5, 'swimming-lessons/autumn-term.md', 0, True]
NEG FAPST+Wq both on2 [10, 'science-homework.md'] -> [2, 'science-homework.md', 0, False]
NEG FAPST+Wq both thn1 [6, 'budget-autumn.md'] -> [5, 'budget-autumn.md', 0, False]
NEG FAPST+Wq content an1 [2, 'recipes/pancakes.md'] -> [4, 'recipes/pancakes.md', 0, True]
NEG FAPST+Wq content an2 [2, 'letters/letter-home-oct.txt'] -> [5, 'letters/letter-home-oct.txt', 0, True]
NEG FAPST+Wq content cn1 [5, 'swimming-lessons/autumn-term.md'] -> [6, 'swimming-lessons/autumn-term.md', 0, True]
NEG FAPST+Wq content mn2 [4, 'swimming-lessons/autumn-term.md'] -> [5, 'swimming-lessons/autumn-term.md', 0, True]
NEG FAPST+Wq content on2 [10, 'science-homework.md'] -> [2, 'science-homework.md', 0, False]
NEG FAPST+Wq content thn1 [6, 'budget-autumn.md'] -> [5, 'budget-autumn.md', 0, False]
NEG FASIDkT both an1 [2, 'recipes/pancakes.md'] -> [4, 'recipes/pancakes.md', 0, True]
NEG FASIDkT both an2 [2, 'letters/letter-home-oct.txt'] -> [4, 'letters/letter-home-oct.txt', 0, True]
NEG FASIDkT both cn1 [5, 'swimming-lessons/autumn-term.md'] -> [6, 'swimming-lessons/autumn-term.md', 0, True]
NEG FASIDkT both mn2 [4, 'swimming-lessons/autumn-term.md'] -> [5, 'swimming-lessons/autumn-term.md', 0, True]
NEG FASIDkT both on2 [10, 'science-homework.md'] -> [10, 'projects/pip-planet-model.md', 0, False]
NEG FASIDkT both pn1 [5, 'birthday-party-wren.md'] -> [2, 'birthday-party-wren.md', 0, True]
NEG FASIDkT both thn1 [6, 'budget-autumn.md'] -> [5, 'budget-autumn.md', 0, False]
NEG FASIDkT content an1 [2, 'recipes/pancakes.md'] -> [4, 'recipes/pancakes.md', 0, True]
NEG FASIDkT content an2 [2, 'letters/letter-home-oct.txt'] -> [5, 'letters/letter-home-oct.txt', 0, True]
NEG FASIDkT content cn1 [5, 'swimming-lessons/autumn-term.md'] -> [6, 'swimming-lessons/autumn-term.md', 0, True]
NEG FASIDkT content mn2 [4, 'swimming-lessons/autumn-term.md'] -> [5, 'swimming-lessons/autumn-term.md', 0, True]
NEG FASIDkT content on2 [10, 'science-homework.md'] -> [10, 'projects/pip-planet-model.md', 0, False]
NEG FASIDkT content pn1 [7, 'birthday-party-wren.md'] -> [2, 'birthday-party-wren.md', 0, True]
NEG FASIDkT content thn1 [6, 'budget-autumn.md'] -> [5, 'budget-autumn.md', 0, False]
NEG FAST both an1 [2, 'recipes/pancakes.md'] -> [4, 'recipes/pancakes.md', 0, True]
NEG FAST both an2 [2, 'letters/letter-home-oct.txt'] -> [4, 'letters/letter-home-oct.txt', 0, True]
NEG FAST both cn1 [5, 'swimming-lessons/autumn-term.md'] -> [6, 'swimming-lessons/autumn-term.md', 0, True]
NEG FAST both mn2 [4, 'swimming-lessons/autumn-term.md'] -> [5, 'swimming-lessons/autumn-term.md', 0, True]
NEG FAST both thn1 [6, 'budget-autumn.md'] -> [5, 'budget-autumn.md', 0, False]
NEG FAST content an1 [2, 'recipes/pancakes.md'] -> [4, 'recipes/pancakes.md', 0, True]
NEG FAST content an2 [2, 'letters/letter-home-oct.txt'] -> [5, 'letters/letter-home-oct.txt', 0, True]
NEG FAST content cn1 [5, 'swimming-lessons/autumn-term.md'] -> [6, 'swimming-lessons/autumn-term.md', 0, True]
NEG FAST content mn2 [4, 'swimming-lessons/autumn-term.md'] -> [5, 'swimming-lessons/autumn-term.md', 0, True]
NEG FAST content thn1 [6, 'budget-autumn.md'] -> [5, 'budget-autumn.md', 0, False]
NEG qG:FAST both an1 [2, 'recipes/pancakes.md'] -> [4, 'recipes/pancakes.md', 0, True]
NEG qG:FAST both an2 [2, 'letters/letter-home-oct.txt'] -> [4, 'tamil/பாட்டி-கடிதங்கள்.md', 0, False]
NEG qG:FAST both cn1 [5, 'swimming-lessons/autumn-term.md'] -> [6, 'swimming-lessons/autumn-term.md', 0, True]
NEG qG:FAST both mn2 [4, 'swimming-lessons/autumn-term.md'] -> [5, 'swimming-lessons/autumn-term.md', 0, True]
NEG qG:FAST both thn1 [6, 'budget-autumn.md'] -> [5, 'budget-autumn.md', 0, False]
NEG qG:FAST content an1 [2, 'recipes/pancakes.md'] -> [4, 'recipes/pancakes.md', 0, True]
NEG qG:FAST content an2 [2, 'letters/letter-home-oct.txt'] -> [5, 'tamil/பாட்டி-கடிதங்கள்.md', 0, False]
NEG qG:FAST content cn1 [5, 'swimming-lessons/autumn-term.md'] -> [6, 'swimming-lessons/autumn-term.md', 0, True]
NEG qG:FAST content mn2 [4, 'swimming-lessons/autumn-term.md'] -> [5, 'swimming-lessons/autumn-term.md', 0, True]
NEG qG:FAST content thn1 [6, 'budget-autumn.md'] -> [5, 'budget-autumn.md', 0, False]
FUZZY today-eng {"boxes": ["bones"], "brekfest": ["breakfast"], "choclate": ["chocolate"], "dinosaurs": ["dinosaur"], "dinosoar": ["dinosaur"], "dinosuar": ["dinosaur"], "febuary": ["february"], "feeds": ["feed"], "fractoins": ["fractions", "fraction"], "freind": ["friend", "find", "fried"], "fruhling": ["frühling"], "goggels": ["goggles"], "hieght": ["height"], "invitiations": ["invitations"], "lantren": ["lantern"], "libary": ["library"], "mikroscope": ["microscope"], "multiplicaton": ["multiplication"], "naïve": ["naive"], "neccesary": ["necessary"], "painting": ["planting"], "pancaeks": ["pancakes"], "pasword": ["password"], "photos": ["photo", "pots"], "recyling": ["recycling"], "rehersal": ["rehearsal"], "résumé": ["resume"], "sandwitches": ["sandwiches"], "sciense": ["science"], "skating": ["saving", "setting", "sorting"], "strasse": ["straße"], "tests": ["test"], "thrusday": ["thursday", "thursdays"], "tournamnet": ["tournament"], "volcanoe": ["volcano"], "wierd": ["weird"], "wislist": ["wishlist"]}
FUZZY FAPST {"brekfest": ["breakfast"], "choclate": ["chocolate"], "dinosoar": ["dinosaur"], "dinosuar": ["dinosaur"], "febuary": ["february"], "fractoin": ["fraction"], "freind": ["friend", "find", "fried"], "goggel": ["goggle"], "hieght": ["height"], "invitiation": ["invitation"], "lantren": ["lantern"], "libary": ["library"], "mikroscope": ["microscope"], "multiplicaton": ["multiplication"], "neccesary": ["necessary"], "painting": ["planting"], "pancaek": ["pancake"], "pasword": ["password"], "recyling": ["recycling"], "rehersal": ["rehearsal"], "sandwitch": ["sandwich"], "sciense": ["science"], "skating": ["saving", "setting", "sorting"], "thrusday": ["thursday"], "tournamnet": ["tournament"], "volcanoe": ["volcano"], "wierd": ["weird"], "wislist": ["wishlist"]}
GROUPS qG:FAST {"12": ["12", "１２"], "bins": ["bins", "bin"], "bones": ["bones", "bone"], "book": ["book", "books"], "books": ["books", "book"], "boxes": ["box"], "cafe": ["café"], "club": ["club", "clubs"], "date": ["date", "dates"], "dates": ["dates", "date"], "dinosaurs": ["dinosaur"], "feeds": ["feed"], "field": ["field", "ﬁeld"], "fruhling": ["frühling"], "hours": ["hours", "hour"], "lessons": ["lessons", "lesson"], "letter": ["letter", "letters"], "list": ["list", "lists"], "minutes": ["minutes", "minute"], "names": ["names", "name"], "naïve": ["naive"], "nights": ["nights", "night"], "number": ["number", "numbers"], "photos": ["photo"], "pony": ["ponies"], "pots": ["pots", "pot"], "project": ["project", "projects"], "questions": ["questions", "question"], "recipe": ["recipe", "recipes"], "recipes": ["recipes", "recipe"], "ride": ["ride", "rides"], "résumé": ["resume"], "saturday": ["saturday", "saturdays"], "screen": ["screen", "screens"], "strasse": ["straße"], "strawberries": ["strawberries", "strawberry"], "tables": ["tables", "table"], "teachers": ["teachers", "teacher"], "tests": ["test"], "time": ["time", "times"], "times": ["times", "time"], "tomato": ["tomato", "tomatoes"], "tuesday": ["tuesday", "tuesdays"], "tulips": ["tulips", "tulip"], "wednesday": ["wednesday", "wednesdays"], "கடைக்கு": ["கடை"], "கதை": ["கதை", "கதைகள்"], "தேர்வுக்கு": ["தேர்வு"], "நூலகத்தில்": ["நூலகம்"], "பள்ளிக்கு": ["பள்ளி"], "பழங்கள்": ["பழம்"], "பாடல்": ["பாடல்கள்"], "பாட்டி": ["பாட்டி", "பாட்டியின்"], "புத்தகங்கள்": ["புத்தகங்கள்", "புத்தகம்"], "மரம்": ["மரங்கள்", "மரத்தில்"], "யானை": ["யானைகள்"], "ﬂute": ["flute"], "ｇｏｇｇｌｅｓ": ["goggles"]}
```

**`on2`** ("painting the fence") stays at 10 hits with top hit `science-homework.md` under FAST and qG:FAST: fuzzy-v1 still expands `painting`→`planting`. Under FAPST+Wq and FAPST+Wi it falls to 2 hits, with the same top hit. Under every candidate with I, the top hit becomes `projects/pip-planet-model.md`.

**`p06`** (`fish fingers`) is at rank 2 under every candidate, in both variants.

## The old packs (`proto_s5t4_packs.py`)

- **The five unchanged packs** (relevance-smoke, `judgments.json`, Tamil, semantic, family folder) are identical to today, every first rank included, at FAST, FST, FAPST, qG:FAST, qG:FAPST, FASIDkT, qG:FASIDkT, FAPSDkT, FAPSDk, FAPSIDkT and qG:FAPSDkT.
- **Mixed** changes. Today it is 0.70 / 0.833 (success@1 / MRR), and nDCG 0.876.

| Candidate | Mixed success@1 / MRR / nDCG | Per-query moves (first rank, today → candidate) |
|---|---|---|
| FAST, FST, FAPST | 0.60 / 0.783 / 0.839 | `avoid-full-corpus-scan` 2→3, `crash-safe-snapshot` 1→2, `first-correct-result-metric` 1→2, `permission-filter-order` 1→2, `malicious-indexed-instructions` 3→2, `safe-old-file-cleanup` 2→1 |
| qG:FAST, qG:FAPST, qG:FASIDkT, qG:FAPSDkT | 0.65 / 0.796 / 0.848 | `avoid-full-corpus-scan` 2→3, `crash-safe-snapshot` 1→2, `permission-filter-order` 1→2, `malicious-indexed-instructions` 3→4, `safe-old-file-cleanup` 2→1 |
| FASIDkT, FAPSIDkT | 0.60 / 0.783 / 0.839 | as FAST, with `world-around-other-star` 1→2 in place of `first-correct-result-metric` 1→2 |
| FAPSDk, FAPSDkT | 0.50 / 0.733 / 0.802 | as FAST, plus `world-around-other-star` 1→2, without `safe-old-file-cleanup` 2→1 |

## Dictionaries (`vocab_merges.py`, FAST; counts, not timings)

| Corpus | v2 terms | v3 terms | Terms changed (plural / Tamil / A / F) | Classes of two or more |
|---|---|---|---|---|
| J2 `home` | 644 | 616 | 98 (90 / 7 / 1 / 0) | 28, largest 2 |
| J2 `laptop` | 508 | 486 | 78 (72 / 6 / 0 / 0) | 22, largest 2 |
| J2 `school` | 848 | 776 | 148 (131 / 8 / 4 / 5) | 72, largest 2 |
| family folder `home` | 348 | 339 | 64 (61 plural, 3 Tamil) | 9, largest 2 |
| 10k timing corpus | 34,058 | 34,057 | 7 (plural) | 1 |

- **The family folder's classes:** bed/beds, come/comes, day/days, leave/leaves, lentil/lentils, plan/plans, slip/slips, treat/treats, கடற்கரை/கடற்கரைக்கு. The family folder holds no false merge; `leave`/`leaves` is a noun/verb merge, recorded.
- **FASIDkT adds** bake/baking and rockpooling/rockpools there.

**The traps (FAST):**
- **Unchanged:** news, species, series, was, this, bus, glass, has, his, its, yes, gas, is, us, lens, always, christmas, maths, physics, does and goes.
- **The `-ing`/`-ed` words are unchanged** under FAST: evening, morning, wedding, painting, skipping, potted, skipped, used, need, …
- **Plurals:** shoes→shoe, toes→toe, potatoes→potato, boxes→box, classes→class, horses→horse, houses→house, lunches→lunch, ponies→pony, ties→tie, pies→pie, strawberries→strawberry, dinosaurs→dinosaur.
- **Misses (no false merge):** buses→buse, caches→cach, headaches→headach, movies→movy, cookies→cooky.
- **Possessives are not changed by FAST:** `biscuit's` stays `biscuit` + `s`.
- **F and A:** résumé→resume, crêpe→crepe, øre→ore, łódź→lodz, æsop→aesop, ½→`1`,`2`, x²→x2, Ⅻ→xii.
- **Tamil:**
  - புத்தகங்கள்→புத்தகம், யானைகள்→யானை, கடைக்கு→கடை, மரத்தில்→மரம், நூலகத்தில்→நூலகம், பாட்டியின்→பாட்டி, பழங்கள்→பழம், தேர்வுக்கு→தேர்வு, பாடல்கள்→பாடல், பள்ளிக்கு→பள்ளி, பள்ளியில்→பள்ளி, மரத்தின்→மரம்;
  - unchanged: காலை, நாளை, தேர்வு, கால், நாள், தேர், வெயில், கள்;
  - miss: நாட்கள்→நாட்.

## The fold table (counts for plan ruling 2; Unicode 13.0.0)

- **Changed by the fold.** Of all code points (surrogates excluded), 6,158 change under the fold: `NFKC(casefold(NFKC(c)))` to a fixpoint, per code point.
- **New work.** 3,852 of them are not already handled by NFC and a simple lowercase fold. Their UTF-8 output totals 10,529 bytes.
- **Multi-code-point output.** 1,303 of the 6,158 map to more than one code point, and the longest maps to 18.
- **The 3,852 by block:**
  - mathematical alphanumerics (U+1D400–U+1D7FF): 996;
  - Arabic presentation forms: 797;
  - enclosed and squared forms: 777;
  - fullwidth: 173;
  - Hangul compatibility jamo: 146;
  - other: 963.
- **Size.** A naive table (4-byte key, 2-byte offset, 1-byte length, UTF-8 pool) is about 37.5 KB. This is an estimate for research bar (f), which is ≤ 64 KB. The Zig profile gives the real figure.
- **Compatibility decompositions.** `unicodedata` lists 3,675 code points with a compatibility decomposition.

## What the prototype does not show

- **No timing.** It times nothing in Zig: no build cost, no K per-token cost, no key-map derive, no library size.
- **The query side's key map** is built per query from the scope. The engine would derive it once per generation and filter by scope.
- **The mixed moves under S** were not traced to their terms.
- **The Tamil rules were written from J2's rows**, so their J2 number is an upper estimate. The tamil-heldout slice is their test.
