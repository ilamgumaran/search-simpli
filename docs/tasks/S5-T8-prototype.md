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

## Phase 1c: the F variants, as declared (ruling 3 of the Phase 1 rulings)

Declared in the commit that adds this section, after `f453d14` (the slice `misspelling-short`, `ms01`–`ms13`, and `negatives-short`, `msn1`–`msn4`, recorded with today's engine) and before any F variant has run a row of either. Each is run alone and with X, over all 265 queries.

- **F** and **F7**: as declared at `e8276fe` (above).
- **Ft**: F, except that the floor's edit count is the optimal-string-alignment distance recomputed for the pair, in which one swapped adjacent pair is one edit. fuzzy-v1's own distance is that alignment (`docs/fuzzy-v1.md`, "The distance"; `core._osa_within`), so a near word one swap away is already at distance 1, weighted 1.0, and kept by F: **Ft keeps exactly the near words F keeps** on every query, by construction. It is declared and run as ruled; the decision rule's tie goes to the simpler rule.
- **Fp2** (the builder's one more): F, except that a typed word of 6 or 7 code points keeps a distance-2 near word when the near word starts with the typed word's first two code points. Distance-1 near words, the trigger, the order, the cap and the weights are fuzzy-v1's; a typed word of 8 or more code points is fuzzy-v1's.
  - **A limit, stated before the run.** Fp2 was chosen, and noted in the progress file, before any `misspelling-short` row was written. The rows were then written by the same builder to ruling 3's description and none of the 13 typed words errs in its first two code points.
  - So the slice cannot show what Fp2 costs on a typo of the second letter. A swap is distance 1 and never reaches Fp2's test, so the limit bears on the seven two-edit rows.

**The decision rule, as ruled.** Among the variants that meet (a)–(c), lose no rank-1 answer on `misspelling-short` against today's engine, and lower (d) on `negatives-heldout` together with X, the one with the lowest misleading-first share ships with X. A tie goes to the simpler rule. If none qualifies, X ships alone.

Run:

```
PYTHONHASHSEED=0 python3 scripts/prototypes/s5t8/proto_s5t8.py --candidates X F F7 Ft Fp2 F+X F7+X Ft+X Fp2+X
```

**Phase 1c results** (after `7f72d5a`; the table, the rule applied and the choice are in the task file's "Phase 1c"):
- `today` and `rewrite` equal all 700 cells of both surfaces of the baseline.
- F, F7 and Ft fail the gate and bar (c) on `misspelling-short`; Ft equals F on every cell.
- Fp2 alone and Fp2+X lose no rank-1 answer anywhere and leave every old pack identical: `PYTHONHASHSEED=0 python3 scripts/prototypes/s5t8/proto_s5t8_packs.py Fp2 Fp2+X`.
- On the 10k corpus (`cost.py`), Fp2 keeps `opratin` → `operating` and drops `sistems` → `system` (`si`/`sy`), the second-letter case it gives up.
- **Fp2+X ships** by the rule.

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

## fuzzy-v2 (Fp2): built in Phase 2, then rejected (the re-ruling, 13 Nov 2026)

**Status: rejected; not shipped.** Fp2 was chosen by Phase 1c's decision rule and
built in Phase 2 (contracts 2.7.0 as first filed), then withdrawn by the
orchestrator's re-ruling after the verifier's measurement
([S5-T8](S5-T8.md), "Re-ruling after the verifier's measurement"): on 16 typed
words of the verifier's own with the second letter wrong, fuzzy-v1 puts the
meant file first for 13 and Fp2 for none. "An answerable question is not traded
for a tidier list on an unanswerable one." The prefix rule was removed from the
Zig engine and the reference; `fuzzy_policy_id` stays `fuzzy-v1`. This section
was `docs/fuzzy-v2.md`, the rule document, until then; it is kept here as the
record of a rejected candidate, both tables (what it gained, what it gave up)
as they were measured.

**In J2 since the re-ruling.** The verifier's 25 words are J2's held-out slice
`misspelling-opening` (`mo01`–`mo25`, the short questions it ran). Measured
through `searchd` `ReleaseSmall` on that slice before Fp2 was removed (the
branch's Fp2 engine, unchanged from `d3c0471` to `4b7e900`) and after (the head that ships, equal to `main`'s engine at
`68e77da` on every cell of the slice), success@1 / MRR@10:

| `misspelling-opening` (25) | `content` | `both` |
|---|---|---|
| fuzzy-v1 (ships; `main`) | 0.120 / 0.214 | 0.120 / 0.219 |
| Fp2 | 0.040 / 0.063 | 0.040 / 0.063 |

Under Fp2 the second-letter rows `mo02`, `mo04`, `mo08`, `mo17`, `mo20`,
`mo21`, `mo22`, `mo23`, `mo24` leave the top 10 (`mo08` and `mo22` were at
rank 1); `mo06` stays at rank 3 through `day`; the first-letter rows are equal
(`mo01` rank 4, `mo13` rank 1 through their other words).

The rule document, as it stood:

> Status: shipped by [S5-T8](S5-T8.md), contracts 2.7.0. Query side only:
> no index format, writer or analyzer change, and an index written before S5-T8
> answers under it with no rebuild. fuzzy-v2 is [fuzzy-v1](../fuzzy-v1.md) (the
> trigger, the candidates, the distance, the order, the cap of 3, the weights and
> the score, unchanged) with one filter after the cap. The Python reference
> (`core._fuzzy_groups`) and the Zig engine (`fuzzy.scan`, `prefixRuleKeeps` in
> `zig/src/fuzzy.zig`) implement it; the fuzzy golden (`fixtures/fuzzy-golden.json`,
> policy `fuzzy-v2`) holds them equal.

### Why

fuzzy-v1 reaches two edits for any word of 6 or more code points, and a short
correctly spelt word no file holds then finds unrelated words: `skating`
reaches `saving`, `setting`, `sorting`; `surfing` reaches `spring`, `string`;
`giants` reaches `goats`. Review R06 asked that such hits stop leading the list
for a question the files do not answer. A plain floor (no two-edit word below
8 code points, candidate F) cut them, and also cut the two-edit corrections a
child needs for a 6 or 7 letter word: on J2's `misspelling-short` slice it
lost six of thirteen rank-1 answers.

### The rule

Of the up to 3 words fuzzy-v1 keeps, a word **two edits** away is dropped when
the typed word has **fewer than 8 code points** and the two words' **first two
code points differ**. Nothing from beyond the cut of 3 takes a dropped word's
place, and a word one edit away is never dropped. Code points are compared,
not bytes (`écolezz` keeps `écolaxz`).

So `sistems` (7) keeps `systems` (one edit) and no longer searches `system`
(two edits, `si`/`sy`); `freind` keeps `friend` (a swap is one edit) and drops
`find`; `skating`, `surfing`, `sewing`, `skiing`, `curling`, `sailing`
(`selling`), `fiancé` (`france`), `giants`, `appels` (`ampel`) and `center`
(`counter`, `crater`) lose their two-edit neighbours of another opening.

### How it was chosen

Phase 1c of [S5-T8](S5-T8.md) added a held-out slice of 13 typed words
of 6 and 7 code points two Levenshtein edits from the meant word (six swaps of
neighbours, two a dropped and an added letter, five two wrong letters) and four
negatives, recorded with the engine before S5-T8, and then declared four
variants before any ran a row of it: F (two edits from 8 code points), F7 (from
7), Ft (F with a swap counted as one edit) and Fp2 (this rule). A decision rule
fixed in advance by the orchestrator chose among them: the variant that meets
the bars, loses no rank-1 answer on `misspelling-short`, and with
[fold-groups-v3](../fold-groups-v3.md) has the lowest misleading-first share on
`negatives-heldout`.

| Variant | `misspelling-short` s@1 / MRR@10 | `negatives-heldout` misleading first with X | qualifies |
|---|---|---|---|
| today | 0.923 / 0.962 | 0.588 (X alone 0.529) | |
| F | 0.462 / 0.462 | 0.294 | no: loses `ms08`–`ms13` |
| F7 | 0.769 / 0.769 | 0.412 | no: loses `ms10`, `ms11` |
| Ft | as F (fuzzy-v1's distance already counts a swap as one edit) | 0.294 | no |
| **Fp2** | **0.923 / 0.962** | **0.353** | **yes** |

### What it measured

J2 on `searchd` and the Python reference, which agree on every cell, with
fold-groups-v3:

- No slice moves: misspelling, misspelling-heldout and misspelling-short keep
  every rank (`ms07` `bukett` stays at rank 2 behind `buckets`).
- `negatives-heldout`: misleading first 0.588 → 0.353 under `content` and
  `both`; mean top-5 hits 3.176 → 2.294 (`content`), 3.059 → 2.176 (`both`);
  mean real hits in the top 5 unchanged (0.706, 0.647).
- `negatives-tuning`: misleading first 0.471 → 0.412; mean top-5 hits 3.059 →
  2.471 (`content`), 2.765 → 2.176 (`both`).
- `negatives-short` is not moved: each of its four neighbours shares the typed
  word's first two letters.
- The older packs are identical per query.

### What it gives up

Measured by the S5-T8 verifier before the merge (ruling 2 of the rulings on
the Report), on typed words written by the verifier, who had not designed the
rule: each two edits (optimal string alignment) from a word a J2 file holds,
with one of the edits in the first two letters and no word of the fixture one
edit away, and not itself a word of the fixture. They ran in a scratch copy of
the fixture, never committed to J2, through `searchd` `ReleaseSmall` built from
`main` at `68e77da` (fuzzy-v1, fold-groups-v2) and from the S5-T8 branch. The
rank is the first rank of a file holding the meant word in the top 10, for the
typed word alone, under `content` and `both` (equal for every word).

**The edit in the second letter (16 words):** 13 reach the meant file at rank
1 before (15 in the top 10); **none** reaches it at rank 1 after (1 in the top
10, through another word).

| Typed | Meant | Answer file | Before | After |
|---|---|---|---:|---:|
| `riming` | rhyming | `home/owl-and-the-moon.md` | 1 | - |
| `kabobs` | kebabs | `home/birthday-party-wren.md` | 1 | - |
| `cikken` | chicken | `school/lunch-menu.md` | 1 | - |
| `skootur` | scooter | `laptop/notes/weekend-jobs.md` | 1 | - |
| `skweaky` | squeaky | `laptop/errands.md` | 1 | - |
| `captur` | chapter | `laptop/notes/bedtime-stories.md` | 1 | - |
| `pulmer` | plumber | `home/plumbing.md` | 1 | - |
| `cumbel` | crumble | `home/household.md` | 1 | - |
| `sapner` | spanner | `home/plumbing.md` | 1 | - |
| `skwash` | squash | `laptop/chess.md`, `school/noticeboard.md` | 1 | - |
| `kittid` | knitted | `home/household.md` | 1 | - |
| `skailes` | scales | `home/music/recorder-practice.md` | 1 | - |
| `torley` | trolley | `laptop/notes/weekend-jobs.md` | 1 | - |
| `wistel` | whistle | `laptop/notes/jottings.md`, `school/noticeboard.md` | 8 | - |
| `galses` | glasses | `home/health/doctor-visits.md`, `laptop/notes/jottings.md` | 8 | 6 |
| `palstr` | plaster | `school/dinosaur-topic.md` | - | - |

`-` is not in the top 10. `galses`'s file at rank 6 after is reached through
another kept word of the same opening, not `glasses` (**inferred** from the
distances: `games` and `gates` are two edits and share `ga`; JSON-RPC carries
no expansion warning). `palstr` misses before as well: fuzzy-v1's three kept
words were nearer or commoner (`past`, `pasta`, `paste` share `pa`).

Each word was also asked as a short question (`riming words`, `who wanted
kabobs`, `when is the pulmer coming`, ...). Before, 10 of the 16 questions put
the meant file in the top 10 (2 at rank 1); after, 1 does (`which day is
cikken`, rank 3 before and after, reached through `day`).

**The edit in the first letter (9 more words, written first):** `fonics`,
`kwizzes`, `salery`, `kushon`, `cayacs`, `nittid`, `senter`, `catchup`,
`kustad` reach nothing alone, before or after. fuzzy-v1 already compares only
dictionary words that start with the typed word's first code point, so a
first-letter slip was never caught and fuzzy-v2 gives up nothing there. (As
questions, `fonics this week` and `catchup with chips` find the meant file at
ranks 4 and 1 both times, through their other words.)

So the price of the rule, on these words, is the second-letter case: a 6 or 7
letter typo whose second letter is wrong (`sq` typed `sk`, a dropped `h`, `l`
or `r`, two letters swapped across the second position) and that needs two
edits no longer finds its word. It
gates nothing; the rule's own decision stands, and a 03-next row asks for such
rows as a held-out slice in the next fuzzy task.

### What the caller would have seen

- `retrieval.fuzzy_policy_id` is `"fuzzy-v2"` wherever it was `"fuzzy-v1"`.
- A dropped word is not searched and not listed in `query_term_expanded`'s
  `expansions`; when none is left the warning is not given and the word
  stays `query_term_unmatched`. There is no new warning code and no new field.

### Limits

- **The held-out set was unseen by every candidate, not by the person writing
  the definition.** The definition of a misleading hit
  (`fixtures/j2/README.md`) was written after two exploratory runs of the
  engine before S5-T8, and ten `negatives-heldout` rows were run through that
  engine to name their distractors. No candidate rule ran a held-out row before
  every candidate was declared.
- **Fp2 was the builder's own variant**, declared before the slice's run but by
  the person who wrote the slice. None of the 13 typed words errs in its first
  two code points.
- **A second-letter typo** two edits from a 6 or 7 letter word is what the rule
  gives up: `sistems` no longer finds `system`. J2 does not measure it; the
  verifier's 16 words above (not in J2) measure it once: 13 at rank 1 before,
  none after.
- The `ß` residual of fuzzy-v1 stands.

### Cost

One comparison of two code points per two-edit word kept for a typed word
under 8 code points; the pool and the distance computations are fuzzy-v1's.
Measured on the 10k timing corpus with fold-groups-v3 (S5-T8's Report):
`opratin` (expanded to `operating`, one word at two edits that shares `op`)
+0.000 ms warm under `content`, +0.002 ms under `both`; the first `content`
query after an open −0.002 to +0.015 ms. Nothing is kept between queries.
