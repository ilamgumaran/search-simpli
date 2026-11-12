# Word-form groups v3 (`fold-groups-v3`)

Status: shipped by [S5-T8](tasks/S5-T8.md), contracts 2.7.0. Query side only:
no index format, writer or analyzer change, and an index written before S5-T8
answers under it with no rebuild. fold-groups-v3 is
[fold-groups-v2](fold-groups-v2.md) (K, the key map, R's bases and relatives,
the weights, the cap, the membership test, the order and the scoring,
unchanged) with one change: a query word's verb forms are R's **eligible
forms** only, R's forms less those that belong to another word. The rule is
implemented twice and held equal byte for byte by the verb-forms golden: the
Zig engine (`verb_forms.eligibleForms` in `zig/src/verb_forms.zig`, used by
`zig/src/fold.zig`) and the Python mirror (`verb_forms.eligible_forms` in
`src/search_platform/verb_forms.py`, used by `core._fold_groups`;
`scripts/gen_verb_forms_golden.py`, `fixtures/verb-forms-golden.json`, which
now lists each term's eligible forms beside its forms: 2,978 terms listed, 16,214
off, a digest over 49,471 terms with 122,865 eligible forms of 123,482).

## Why

R builds a base's relatives by shape, so a base like `hop` also generated the
`e` shapes `hopes`, `hoped` and `hoping`, which are forms of `hope`, and a word
like `hoping` took the base `hop` and with it `hopped` and `hopping`. Review
R05 named the rows. Under fold-groups-v2, J2's `hoping` (`x02`) found the hop
file first and its own answer at rank 3, and `tapping` (`x05`) found the taped
parcels first and its own answer at rank 2.

## The rule

A base b has the **doubling shape** when it has one vowel group (a run of `a e
i o u`; `y` counts as a consonant) and ends consonant, vowel, consonant, the
last letter not `w`, `x` or `y`: `hop`, `tap`, `car`, `bit`, `whiz`. Such a
word doubles its last letter before `-ed` and `-ing` (`hopped`, `hopping`), so
its undoubled shapes belong to b + `e`. With p = S(u) as in R:

1. **For a base of the doubling shape**, b + `ed`, b + `ing` and b + `es` are
   left out of its relatives (`hoped`, `hoping` and `hopes` are `hope`'s).
   b + `es` stays when b ends in `s`, `x`, `z`, `ch` or `sh`, where `-es` is
   the plural (`whizes`).
2. **When p is r + `ing` or r + `ed`** with r of the doubling shape, the base r
   is left out (`hoping` is not `hop`'s; `caring` is not `car`'s). r + `e`
   stays.

The eligible forms are the relatives of the remaining bases, the typed word
left out, first seen first. They are a subset of R's forms. Each is then a
member, or not, by fold-groups-v2's own test and weights. One shape test per
base is all the rule adds.

What it changes on J2 (all 265 queries): `biting` loses `bit`; `caring` loses
`car`; `hating` loses `hat` and `hats`; `hoping` loses `hopped`; `hopping` and
`hops` lose `hopes` and `hoped`; `mating` loses `mat` and `mats`; `taping`
loses `tap`, `taps` and `tapped`; `tapping` loses `tapes` and `taped`. Once its
cross forms are gone, a word with no group left (`caring`, `mating`) goes to
misspelling tolerance, which is [fuzzy-v2](fuzzy-v2.md) since the same task.

## What it measured

J2 on `searchd` and the Python reference, which agree on every cell:

- `verbform-cross` success@1 0.667 → 1.000 and MRR@10 0.806 → 1.000 under
  `content` and `both`: `x02` `hoping` 3 → 1, `x05` `tapping` 2 → 1. These are
  the only first grade-2 ranks that move.
- Every other slice, `control` and `precision-control` among them, is
  unchanged; the S5-T6 gate passes with the allow-list untouched; the older
  packs (relevance-smoke, knowledge, mixed, tamil, semantic, family-folder)
  are identical per query.
- `negatives-heldout`, the share of questions whose first hit misleads, under
  X alone (the Phase 1 prototype): 0.588 → 0.529. With fuzzy-v2 beside it
  (what ships): 0.588 → 0.353, mean top-5 hits 3.176 → 2.294 (`content`) and
  3.059 → 2.176 (`both`).

## What the caller sees

- `retrieval.fold_policy_id` is `"fold-groups-v3"` wherever it was
  `"fold-groups-v2"`.
- The `query_term_grouped` warning's `members` no longer list another word's
  forms. There is no new warning code and no new field.

## Limits

- **The held-out set was unseen by every candidate, not by the person writing
  the definition.** The definition of a misleading hit
  (`fixtures/j2/README.md`) was written after two exploratory runs of the
  engine before S5-T8 (E1, E2), and ten `negatives-heldout` rows were run
  through that engine to name their distractors (E2). No candidate rule ran a
  held-out row before every candidate was declared ([the prototype
  record](tasks/S5-T8-prototype.md)).
- **Doubled remainders that are held words.** `shedding` keeps `shed` and
  `canned` keeps `can` (`nh10`, `nh11`): the doubling is real, and the
  remainder is another word only by meaning.
- **Two vowel groups.** `evening` still generates `even` (`x03`, `x04` rank 1
  either way): `even` is not of the doubling shape, so the rule does not
  touch it.
- **No irregular verbs**, no `-er`/`-est`, no other language, as before.

## Cost

Measured on the 10k timing corpus, `ReleaseSmall`, six interleaved rounds
against the S5-T5 library, with a second build of it as the noise reference
([S5-T8's Report](tasks/S5-T8.md)), together with fuzzy-v2:

- **The first `content` query after an open:** −0.015 to +0.023 ms (median per
  round; `hybrid retrieval`, `system`, `hashing`, `opratin`, with and without
  the filename channel).
- **A warm query with no group and no near word:** at most +0.008 ms under
  `content` and +0.006 ms under `both`.
- **`hashing`** (grouped with `hash` through R): +0.001 ms `content`, +0.002 ms
  `both`.
- **Memory:** nothing is kept. The eligible forms are computed on the stack
  beside R's; the key map is fold-groups-v1's (64 bytes on NFR-13's 10k
  corpus). On the 10k corpus R applies to 24,039 dictionary words; the rule
  changes six words' forms and drops no form the files hold.
