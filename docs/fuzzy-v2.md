# Misspelling tolerance v2 (`fuzzy-v2`)

Status: shipped by [S5-T8](tasks/S5-T8.md), contracts 2.7.0. Query side only:
no index format, writer or analyzer change, and an index written before S5-T8
answers under it with no rebuild. fuzzy-v2 is [fuzzy-v1](fuzzy-v1.md) (the
trigger, the candidates, the distance, the order, the cap of 3, the weights and
the score, unchanged) with one filter after the cap. The Python reference
(`core._fuzzy_groups`) and the Zig engine (`fuzzy.scan`, `prefixRuleKeeps` in
`zig/src/fuzzy.zig`) implement it; the fuzzy golden (`fixtures/fuzzy-golden.json`,
policy `fuzzy-v2`) holds them equal.

## Why

fuzzy-v1 reaches two edits for any word of 6 or more code points, and a short
correctly spelt word no file holds then finds unrelated words: `skating`
reaches `saving`, `setting`, `sorting`; `surfing` reaches `spring`, `string`;
`giants` reaches `goats`. Review R06 asked that such hits stop leading the list
for a question the files do not answer. A plain floor (no two-edit word below
8 code points, candidate F) cut them, and also cut the two-edit corrections a
child needs for a 6 or 7 letter word: on J2's `misspelling-short` slice it
lost six of thirteen rank-1 answers.

## The rule

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

## How it was chosen

Phase 1c of [S5-T8](tasks/S5-T8.md) added a held-out slice of 13 typed words
of 6 and 7 code points two Levenshtein edits from the meant word (six swaps of
neighbours, two a dropped and an added letter, five two wrong letters) and four
negatives, recorded with the engine before S5-T8, and then declared four
variants before any ran a row of it: F (two edits from 8 code points), F7 (from
7), Ft (F with a swap counted as one edit) and Fp2 (this rule). A decision rule
fixed in advance by the orchestrator chose among them: the variant that meets
the bars, loses no rank-1 answer on `misspelling-short`, and with
[fold-groups-v3](fold-groups-v3.md) has the lowest misleading-first share on
`negatives-heldout`.

| Variant | `misspelling-short` s@1 / MRR@10 | `negatives-heldout` misleading first with X | qualifies |
|---|---|---|---|
| today | 0.923 / 0.962 | 0.588 (X alone 0.529) | |
| F | 0.462 / 0.462 | 0.294 | no: loses `ms08`–`ms13` |
| F7 | 0.769 / 0.769 | 0.412 | no: loses `ms10`, `ms11` |
| Ft | as F (fuzzy-v1's distance already counts a swap as one edit) | 0.294 | no |
| **Fp2** | **0.923 / 0.962** | **0.353** | **yes** |

## What it measured

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

## What it gives up

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

## What the caller sees

- `retrieval.fuzzy_policy_id` is `"fuzzy-v2"` wherever it was `"fuzzy-v1"`.
- A dropped word is not searched and not listed in `query_term_expanded`'s
  `expansions`; when none is left the warning is not given and the word
  stays `query_term_unmatched`. There is no new warning code and no new field.

## Limits

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

## Cost

One comparison of two code points per two-edit word kept for a typed word
under 8 code points; the pool and the distance computations are fuzzy-v1's.
Measured on the 10k timing corpus with fold-groups-v3 (S5-T8's Report):
`opratin` (expanded to `operating`, one word at two edits that shares `op`)
+0.000 ms warm under `content`, +0.002 ms under `both`; the first `content`
query after an open −0.002 to +0.015 ms. Nothing is kept between queries.
