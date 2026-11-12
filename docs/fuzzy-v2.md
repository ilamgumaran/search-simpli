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
  gives up: `sistems` no longer finds `system`. J2 does not measure it.
- The `ß` residual of fuzzy-v1 stands.

## Cost

One comparison of two code points per two-edit word kept for a typed word
under 8 code points; the pool and the distance computations are fuzzy-v1's.
Measured on the 10k timing corpus with fold-groups-v3 (S5-T8's Report):
`opratin` (expanded to `operating`, one word at two edits that shares `op`)
+0.000 ms warm under `content`, +0.002 ms under `both`; the first `content`
query after an open −0.002 to +0.015 ms. Nothing is kept between queries.
