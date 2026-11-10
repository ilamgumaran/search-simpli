# Word-form groups v2 (`fold-groups-v2`)

Status: shipped by [S5-T5](tasks/S5-T5.md), contracts 2.6.0. Query side only:
no index format, writer or analyzer change, and an index written before S5-T5
groups its words the same way. fold-groups-v2 is
[fold-groups-v1](fold-groups-v1.md) (its key K, its key map, its order and
its scoring, unchanged) with one more source of members: R, the `-ing` and
`-ed` verb forms of a query word. R is implemented twice and held equal byte
for byte by a golden: the Zig engine (`zig/src/verb_forms.zig`, used by
`zig/src/fold.zig`) and the Python mirror (`src/search_platform/verb_forms.py`,
used by `core._query_groups`; `scripts/gen_verb_forms_golden.py`,
`fixtures/verb-forms-golden.json`: 2,856 terms listed with their forms, 16,211
listed as off, and a digest over 49,347 terms).

## Why

A child types `painting` and the note says `painted`; types `danced` and the
diary says `dancing`; types `tidied` and the list says `tidy`. fold-groups-v1
groups plurals, accents and Tamil suffixes but not verb forms, and stripping
`-ing` and `-ed` on the index side would need a stemmer whose `-ed` rule costs
J2's control row `c22` (`potted` → `pot`). R generates a word's verb forms
at query time instead, and each form joins the group only when the files hold
it and a cap allows it.

## R

R applies when u = A(F(t)) (K's first two parts) is one piece of 4 to 49
letters a–z. With p = S(u) (K's plural part), the **bases** are, in order and
without repeats:

- p;
- when p ends in `-ing`, the remainder r (p less `-ing`), when r has at least 3
  letters and holds one of `a e i o u y`: r, r + `e`, and r undoubled (its last
  letter dropped when the last two are one consonant other than `l`, `s`,
  `z`);
- the same for `-ed`;
- when p ends in `-ied` and has at least 5 letters: p less `-ied`, plus `y`.

The **relatives** of a base b are b, b`s`, b`es`, b`ed`, b`ing`; when b ends in
`e`, b`d` and b less `e` plus `ing`; when b ends consonant, vowel, consonant
(`y` counted a consonant), b doubled plus `ed` and plus `ing`; when b ends in a
consonant and `y`, b less `y` plus `ies` and plus `ied`. A vowel is one of
`a e i o u`. The **forms** of t are the relatives of every base, t itself left
out: one exact lookup each, at most 19 for a J2 word and at most 45 by
construction. `painting` → `paint`, `paints`, `painted`, …; `hopping` → `hop`,
`hopped`, …; `tidied` → `tidy`, `tidying`, …. R reads nothing but its word.

## The groups

A query word t's group is fold-groups-v1's members (the words that share its
key) and R's forms that are members by v1's own test: a body term some chunk
in scope holds (roots, labels and the path prefix), or a title term of a
visible file under the prefix. A form already in the group is not added twice.
The weights and the cap depend on whether t is **held**, that is whether a
chunk in scope or a visible file's name holds t itself:

- **t not held:** every R form that is a member joins at weight **1.0**. If it
  gives t a group, fuzzy-v1 does not also run on t.
- **t held:** an R-only form joins at weight **0.5**, and only when its key
  document frequency is no higher than t's own, both counted as fold-groups-v1
  counts them (the chunks the caller can see; a prefix narrows membership, not
  statistics). The consequence, stated by an engine test on every held word: a
  held word's group never takes a document frequency above the word's own
  through R. So `hashing` (1,277 chunks on the 10k timing corpus) takes `hash`
  (1,239) at 0.5, while `hash` does not take `hashing`.

The order is v1's (t first, then key document frequency, then bytes) and the
score is v1's (one document frequency for the group, each chunk its best
member's weight × BM25, never the sum). A query whose words gain no form ranks
exactly as under fold-groups-v1.

## What the caller sees

- `retrieval.fold_policy_id` is `"fold-groups-v2"` wherever it was
  `"fold-groups-v1"`.
- R's forms are listed in the `query_term_grouped` warning's `members`, in the
  group's order, beside the key-mates. There is no new warning code and no new
  field. A form only hidden chunks or files hold is never searched or named.

## What the margin rests on

From the Phase 1 rulings ([S5-T5](tasks/S5-T5.md), ruling 2), stated plainly:

- Candidates A, B and D (R's forms at full weight, at half weight, or at half
  weight for held words, all without a cap) fail on one control row, `c22`
  (`tomato seedlings potted`): the held word `potted` takes `pot` and `pots`,
  both commoner than it, the group's shared document frequency rises, and the
  answer drops from rank 1 (to 7 under A, 2 under B and D). E's cap was shaped
  on that row, before the held-out rows were run.
- E's gain over candidate C (R only for words not held) is two held-out rows:
  `vt2` 3 → 1 and `vt1` 3 → 2 under `content`.
- The five guard rows (`vg1`–`vg5`) hold at rank 1 under both C and E.
- On the Phase 2 form (the cap on the word's own key document frequency, the
  split on whether the word is held) J2 equals the prototype's E on every
  judged cell ([the prototype record](tasks/S5-T5-prototype.md)).

J2 on `searchd` against fold-groups-v1 (success@1, `content`): morphology
0.538 → 0.692, morphology-heldout 0.571 → 0.714, verbform-heldout 0.263 →
0.947; `both` the same three; control 1.000 in both modes; every other slice
unchanged.

## Cost

Measured on the 10k timing corpus, `ReleaseSmall`, six interleaved rounds
against the fold-groups-v1 library, with a second copy of it as the noise
reference ([S5-T5's Report](tasks/S5-T5.md)):

- **The first `content` query after an open:** +0.04 to +0.05 ms
  (`hybrid retrieval`, `system`), +0.08 ms for `hashing` (the verifier's six
  rounds: −0.021 to +0.003 ms and +0.025 / +0.049 ms).
- **A warm query whose words gain no form:** at most +0.002 ms `content` and
  `both`; the two long queries measured −0.006 to −0.012 ms (code placement). The verifier's rounds:
  at most +0.002 ms, and −0.003 to −0.009 ms for the long queries.
- **`hashing`**, the one corpus word that gains a form (`hash`, 1,239
  postings): +0.034 ms `content`, +0.035 ms `both`.
- **Memory:** nothing is kept. R runs on the stack; the key map is
  fold-groups-v1's, 64 bytes on NFR-13's 10k corpus with or without a word
  grouped through R.

## Known residuals

- **Ranks R does not fix.** `o05` stays at rank 3 in both modes, and `o12` at
  rank 6 under `content` (outside the top 10 under `both`), the cap keeping
  the commoner `paint` out of `painted`'s group. `vt1` moves 3 → 2 under
  `content` and stays outside the top 10 under `both`.
- **Forms of another word.** A base not ending in `e` also takes b`es`, b`ed`
  and b`ing` with the `e` rule's shapes, so `hop` generates `hopes`, `hoped`
  and `hoping`, which are forms of `hope`; `evening` generates `even`. No J2
  group took such a form; with three verb files, `both` measures this less
  than `content` ([03-next](journey/03-next.md)).
- **No irregular verbs** (`ran`, `ate`, `went`), no `-er`/`-est`, no other
  language.
- **Index side.** As fold-groups-v1: `find` and the `filename` field do not
  group, and the snippet holds the form the file holds.
