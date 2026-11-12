# S5-T8 prototype: stop words, a floor for near words, cross-word verb forms over J2 (builder, 12 Nov 2026)

This is the builder's Phase 1 record for `docs/tasks/S5-T8.md` (rulings 1 to 4). It runs on the Python reference only; no Zig engine code, contract or Dart change is written in Phase 1. The prototype hooks the reference's module functions from `scripts/prototypes/s5t8/`; it edits no file under `src/`.

## The order kept (ruling 1, ruling 2)

| Step | Commit | What exists at that commit |
|---|---|---|
| Phase 1a: the measure, the two negative sets, R05's rows, `precision-control`, recorded with today's engine | `13266c7` | No candidate code. No candidate has run any query. |
| This record: the candidates W, Wb, F, F7 and X declared, with the combinations to run | the commit that adds this file | The prototype (`scripts/prototypes/s5t8/`) exists and has run only with every held-out row left out (the runs listed below). |
| The first run of a held-out row through any candidate | after `e8276fe` (progress file, 12 Nov) | The full grid below, every declared candidate and combination, all 248 queries. |
| The packs, the cost count and these results | the commit that adds `proto_s5t8_packs.py` and `cost.py` | No candidate changed after the held-out run. |

**Held-out rows** here are every row of the six `*-heldout` slices, every negative of those slices (`thn1`, `thn2`, `mhn1`, `mhn2`, `ohn1`, `ohn2`, `ahn1`, `ahn2`, `tahn1`, `tahn2`, `vhn1`, `vhn2`) and all of `negatives-heldout` (`nh01`–`nh17`): 106 queries. `proto_s5t8.py --no-heldout` leaves exactly these out and runs the other 142.

### Every exploratory run before this record

| Run | Engine | Rows | Why |
|---|---|---|---|
| E1 | today's (no candidate) | three draft questions on the J2 of `004ba85` (`caring for a hamster`, `the dragon`, `skiing trip`), `the dragon` later became `nt01`'s query | to see what today's groups take before writing negatives |
| Trees 1–4 | today's | the 198 earlier queries over four draft versions of the new files | that the new files move no earlier cell (tree 4 moved none) |
| E2 | today's | 18 new negatives without a named distractor, 10 of them in `negatives-heldout` (`nh04`–`nh06`, `nh09`–`nh15`) | to name a grade-0 distractor for each by the word that reaches it; today's engine is not a candidate |
| Phase 1a record | today's (`searchd` and the reference) | all 248 | the baseline and the measure of `13266c7` |
| E3 | candidates W0, W, Wb, W+Wb, F8, F7, Fdf2, Fd2df2, X | the 142 non-held-out queries | shaping on `negatives-tuning` and the graded tuning slices |
| E4 | W+Wb+F8, F8+X, W+Wb+X, W+Wb+F8+X, W+F8, Wb+F8 | the 142 non-held-out queries | the combinations |

What E3 and E4 showed, on tuning rows only:
- **W0** (W read literally: a query of stop words only loses its title part) drops `pc01` `this and that` out of the top 10. W is therefore declared with the all-stop exception below (deviation 3).
- **Fdf2** (a near word needs key df ≥ 2) loses three misspelling rows and three `precision-control` rows at rank 1 (misspelling success@1 0.562 → 0.375, `precision-control` 0.700): every near-spelling answer of `pc05`–`pc07` is a df-1 word. **Fd2df2** (the same floor on distance-2 words only) moves no first hit. Neither is declared.
- **Each rule alone moves the share of misleading first hits little, because the labels hand over**: with the stop words gone (W+Wb), `the dragon` is reached through fuzzy-v1 neighbours of `dragon`; with the near words gone (F8), the same question's hits are stop-word hits again. On `negatives-tuning`, `content`: today 0.471; W, Wb, X alone 0.471; F8 0.353; W+Wb+F8 0.176; W+Wb+F8+X 0.059 (mean top-5 hits 3.059 → 1.000). No graded tuning row moved under any declared candidate except `x02` and `x05` (3 → 1 and 2 → 1) under X.

## The stop words

Lucene's 33 English stop words (`EnglishAnalyzer.ENGLISH_STOP_WORDS_SET`) and `my`: `a an and are as at be but by for if in into is it no not of on or such that the their then there these they this to was will with my`. The same list labels the measure (`judgments.json` `stop_words`). `my` is added because ruling 1 names it among the common words in file names (deviation 1). No Tamil list (ruling 2).

## The candidates, as declared

The terms are the query's group terms as today: under `content` the body terms (`tokenize`) and the title terms (`_filename_tokenize`) of the query, under `both` its file-name tokens. A stop word is a term equal, by bytes, to a word of the list.

**W, stop words in the title part** (`core._title_scores`). The title part scores the query's title terms less the stop words: BM25 over the title field and title coverage (the share of the query's title terms the field holds) both count only the non-stop terms. When every title term of the query is a stop word, the title part is today's. The body is unchanged.

**Wb, stop words in the body** (`core._bm25_scores` on body chunks: the `content` field's body scoring and `both`'s best-chunk scoring; not the title documents, not the file-name records). When the query's body terms hold at least one non-stop term, its stop words leave the body query. A query of stop words only is scored as today. The title part is unchanged (W is separate).

**F, a floor for fuzzy-v1** (`core._fuzzy_groups`). fuzzy-v1 as today, except that a distance-2 near word is kept only for a typed word of 8 or more code points (fuzzy-v1: 6). Distance-1 near words, the trigger, the candidate set, the order, the three-word cap and the weights are unchanged; a typed word of 6 or 7 code points keeps its distance-1 near words. It is a tighter edit rule for a word whose shape is that of a correct word, read as its length: no document-frequency floor (Fdf2 above).

**F7**: F with the threshold at 7 code points. Declared as the alternative, should F fail bar (c) on `misspelling-heldout`.

**X, cross-word verb forms** (`core._fold_groups`; R's bases and relatives as `verb_forms` gives them, then two eligibility rules; the cap and the membership rule of fold-groups-v2 unchanged). A base *b* has the **doubling shape** when it has one vowel group (`a e i o u`; `y` a consonant) and ends consonant, vowel, consonant, the last not `w`, `x` or `y` (`hop`, `tap`, `car`, `bit`; not `visit`, `oil`, `box`, `row`, `even`).
1. For a base of the doubling shape, *b* + `ed`, *b* + `ing` and (unless *b* ends `s`, `x`, `z`, `ch` or `sh`) *b* + `es` are dropped: they are the forms of *b* + `e` (`hop`: `hopes`, `hoped`, `hoping` are `hope`'s); *b*'s own are *b* + `s` and the doubled forms.
2. When *p* (R's plural-stemmed word) is *r* + `ing` or *r* + `ed` with *r* of the doubling shape, the base *r* is dropped and *r* + `e` kept: such a word with one consonant is not *r*'s form, since *r*'s own double (`hoping`: `hope`, not `hop`; `caring`: `care`, not `car`).

What X cannot tell apart, and leaves: a remainder of two vowel groups (`evening` → `even`, `even` → `evening`), and a doubled remainder that is itself a held word (`shedding` → `shed`, `canned` → `can`).

**The combinations run** (ruling 2: each alone, then the passing ones together): W+Wb, W+Wb+F, F+X, W+Wb+X, W+Wb+F+X, W+Wb+F7+X.

## The bars, as the prototype reads them (ruling 3)

- (a) `control` and `precision-control` success@1 1.000 in `content` and `both`.
- (b) `scripts/j2_gate.py`'s rules against the committed `searchd` baseline, both variants, the allow-list untouched.
- (c) no query at rank 1 today leaves rank 1 (every graded slice, both variants), and no cell (success@1, MRR@10, nDCG@10, recall@5) of `misspelling-heldout`, `morphology-heldout` or `verbform-heldout` lower.
- (d) on `negatives-heldout`, in `content` and in `both`: the share of misleading first hits falls, and the mean top-5 hit count does not rise.
- (e) the old packs (`relevance-smoke`, `knowledge`, `mixed`, `tamil`, `semantic`, `family-folder`) identical to today, or each move named.
- (f) every moved first grade-2 rank named.

## Files

| File | What it is |
|---|---|
| `scripts/prototypes/s5t8/rules.py` | The candidates as hooks; `install("W+Wb")`, `restore()`. `rewrite` is `_fold_groups` rewritten with R unchanged (must equal today on every cell). |
| `scripts/prototypes/s5t8/proto_s5t8.py` | J2 with a candidate installed: the slice tables, the measure, the bars, the moves. |
| `scripts/prototypes/s5t8/proto_s5t8_packs.py` | The old packs with a candidate installed, against today (bar (e)). |
| `scripts/prototypes/s5t8/cost.py` | The cost count on a corpus (the 10k timing corpus). |

Run:

```
PYTHONHASHSEED=0 python3 scripts/prototypes/s5t8/proto_s5t8.py --candidates W Wb F F7 X W+Wb W+Wb+F F+X W+Wb+X W+Wb+F+X W+Wb+F7+X
PYTHONHASHSEED=0 python3 scripts/prototypes/s5t8/proto_s5t8_packs.py W Wb F F7 X W+Wb W+Wb+F F+X W+Wb+X W+Wb+F+X W+Wb+F7+X
python3 scripts/gen_timing_corpus.py SCRATCH/timing10k 10000
PYTHONHASHSEED=0 python3 scripts/prototypes/s5t8/cost.py SCRATCH/timing10k
```

## Results (the full grid, after `e8276fe`)

**The baseline reproduces.** `today` (core's own functions) and `rewrite` (`_fold_groups` rewritten with R unchanged) each equal all 656 cells of both surfaces of `fixtures/j2/baseline.json`, and every old pack.

The per-candidate tables, the bars and the recommendation are in the task file's Report (`docs/tasks/S5-T8.md`, Phase 1). What the Report does not repeat:

**What X drops** (forms held in J2 that R gives today and X does not, over all 248 queries): `biting` `bit`; `caring` `car`; `hating` `hat`, `hats`; `hoping` `hopped`; `hopping` `hopes`, `hoped`; `hops` `hopes`, `hoped`; `mating` `mat`, `mats`; `taping` `tap`, `taps`, `tapped`; `tapping` `tapes`, `taped`. Nothing else, in any slice.

**What F drops** (near words fuzzy-v1 keeps today and F does not, over all 248 queries): `curling` `cooling`, `cycling` (keeps `curving`); `dragon` `drawn`, `drag`; `fiancé` `france`; `freind` (`m05`) `find`, `fried` (keeps `friend`; `m05` stays at rank 1); `giants` `goats`; `golfing` `going`; `jungle` `june`, `juggled`, `juggler`; `midges` `miles`; `rocket` `rock`, `rocks`; `sailing` `saving`, `selling`; `sewing`, `skiing` `spring`, `saving`, `string`; `skating` `saving`, `setting`, `sorting`; `surfing` `spring`, `string`, `sorting`. F7 keeps the 7-code-point words' (`curling`, `golfing`, `sailing`, `skating`, `surfing`).

**Where J2 cannot see F's cost.** Every distance-2 typo row in J2 is 8 or more code points (`m01` `dinosoar`, `mh08` `neccesary`, `mh09` `brekfest`), so no J2 row exercises a 6- or 7-code-point typo two edits from its word, the case F gives up. On the 10k timing corpus `opratin` (7) loses `operating` under F (measured below); whether such typos matter is not measured here.

**Cost on the 10k timing corpus** (10,000 files, 19,959 chunks, 24,057 body terms, 10,102 title terms; counts, no timing):

| Candidate | Count |
|---|---|
| W | Title terms scored: 9 → 6 for `how does the hybrid retrieval work for a search`, 2 → 1 for `the system`, unchanged for the rest; one stop-list test per title term. No stop word is a title term of this corpus. |
| Wb | Body postings walked (sum of the query terms' chunk df): `how does the hybrid retrieval work for a search` 34,083 → 3,708; `the system` 11,311 → 1,241; `the and of to in` 50,514 unchanged (stop words only). 21 of the 34 stop words are body terms, each in about 10,000 chunks. |
| F | The pool (34,159 words) and the distance computations are unchanged (F filters after them); kept near words: `systm`, `retreival`, `schedulars` unchanged; `sistems` 2 → 1 (`system`, distance 2 at 7 code points, dropped); `opratin` 1 → 0 (`operating`). |
| X | R applies to 24,039 dictionary words: lookups 105,854 → 105,837 (per word: median 4 both, max 16 both); 24,049 shape tests added (one per base); 6 words' forms change; no held form is dropped on this corpus. |
