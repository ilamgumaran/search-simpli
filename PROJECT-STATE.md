# Project state and continuation handoff

Last updated: 2026-11-13 (S5-T8 re-ruled before its merge: fold-groups-v3 alone, fuzzy-v1 unchanged, reviews R05 and R06; contracts 2.7.0, Dart 0.8.0; verified and merged 2026-11-12 EST)

Project: **Search Simpli** (`search-simpli`)

> **Resuming a session (CLI or web)?** Start at
> [`docs/journey/`](docs/journey/README.md) — vision, how we work, the next task,
> and the evolution record. This file remains authoritative for *exact current
> behavior and commands*.

**11 Nov documentation review (source `f2d6f6c`):**
[Search improvement TODOs](docs/reviews/2026-11-11-search-improvement-todos.md)
and [review evidence](docs/reviews/2026-11-11-search-review-evidence.json)
record proposals and their validation steps. They are not accepted capabilities
or implementation tasks; current search behavior and native artifacts are unchanged.

## Fewer misleading hits for unanswerable questions: fold-groups-v3 (S5-T8, reviews R05 and R06; re-ruled before its merge; verified and merged)

Verified and merged: the verifier judged the reworked head from its own builds (J2 against `main`: only `x02` and `x05` move; `negatives-heldout` 0.588 → 0.529; natives `cmp`-equal; the rejected prefix rule, planted on the head, fails the gate through `misspelling-opening`). Before the rework the verifier measured what the Phase 2 fuzzy floor (fuzzy-v2, Fp2) gave up: of 16 second-letter typos
two edits from a 6 or 7 letter word, 13 found their file first under fuzzy-v1 and none under fuzzy-v2. The
orchestrator's re-ruling ([task](docs/tasks/S5-T8.md), "Re-ruling after the verifier's measurement") withdrew fuzzy-v2;
fold-groups-v3 ships alone and misspelling tolerance stays [fuzzy-v1](docs/fuzzy-v1.md). Fp2's measurements are kept as
a rejected candidate in [the prototype record](docs/tasks/S5-T8-prototype.md). Query side only: no index format, writer
or analyzer change; an index written before answers under the new policy with no rebuild. `find` and the `filename`
field are unchanged.

**fold-groups-v3** ([docs/fold-groups-v3.md](docs/fold-groups-v3.md)): a word's verb forms are R's eligible forms only.
A base of the doubling shape (one vowel group, ending consonant, vowel, consonant, the last not `w`/`x`/`y`) loses its
undoubled `-ed`, `-ing` and (unless it ends `s`, `x`, `z`, `ch`, `sh`) `-es`, which are b + `e`'s; when the word is
r + `ing` or r + `ed` with r of that shape, the base r is left out (`hoping` is not `hop`'s). The Zig engine
(`verb_forms.eligibleForms`) and the Python mirror (`verb_forms.eligible_forms`) are held equal by
`fixtures/verb-forms-golden.json` (2,978 terms listed with forms and eligible forms, 16,214 off, a digest over 49,471
terms). `fixtures/fuzzy-golden.json` names `fuzzy-v1` (120 of 292 queries expanded) and is what `main`'s reference
writes over this fixture.

**The contract.** Contracts **2.7.0**: `retrieval.fold_policy_id` is `"fold-groups-v3"`; `retrieval.fuzzy_policy_id`
stays `"fuzzy-v1"`; no new warning code, field or request option. Dart **0.8.0**. Natives: macOS 953,848 B, Android
`arm64-v8a` 916,304 B, iOS framework binary 918,576 B; `native/SOURCE-SHA256`
`8ea110b0c09692c93e66b4f3e78f5f932670770aaf87125fe96d22cb4d28da4b`.

**J2 (290 queries), `searchd` and the reference equal on every cell:** against `main` (`68e77da`) on the same fixture
only `verbform-cross` moves, 0.667 → 1.000 success@1 under `content` and `both` (`x02` 3 → 1, `x05` 2 → 1); every
other slice and the overall are unchanged. `misspelling-short` (13 held-out two-edit typos of 6 and 7 letters) stays at
0.923. `misspelling-opening` (25 rows added by the re-ruling: the verifier's 16 second-letter and 9 first-letter typos,
two edits from a 6 or 7 letter word with no one-edit route) is the bar for any later fuzzy floor: success@1 0.120,
MRR@10 0.214 (`content`) and 0.219 (`both`), equal to `main`. `negatives-heldout` misleading-first share 0.588 → 0.529,
mean top-5 hits 3.176 → 2.941 (`content`) and 3.059 → 2.824 (`both`). The older packs are identical per query. Stop
words (W, Wb) and a fuzzy floor were measured and not shipped (03-next).

## A real agent answers through `searchd mcp` (S5-T10, review R11, 2026-11-12; verified and merged 2026-11-12)

**Verified and merged 2026-11-12** ([task, Report and Verdict](docs/tasks/S5-T10.md),
[record](docs/evidence/s5-t10/README.md)); the verifier re-ran the checks, the agent-log summaries and the parity
replay on its own `ReleaseSmall` `searchd` and reproduced every committed record. Evidence only: no engine, contract,
skill, binding, fixture or CI change, and no native rebuild or app pin.

- **What ran.** Ten Claude Sonnet 5.5 agent sessions answered 30 frozen questions about J2 in two runs. Each used only a
  command-line MCP client that starts `searchd mcp <index> --roots school,home` per call; the third root, `laptop`,
  was hidden.
- **Scope.** The server returned no hidden content in any of the 154 calls: 0 scope failures. One agent answer holds
  five words that also stand in a hidden file: an agent-text coincidence, explained (ruling 1's condition met).
- **Counts (read).** Supported 19 and 19 by evidence, 19 and 17 by the skill's read-before-quoting rule (ruling 2: both
  stated, neither called the result); 0 wrong source; 11 negatives handled in each run.
- **Machine checks.** 154 of 154 tool calls equal `searchd serve`. Freshness held at generations 2 and 3.
- **Limit.** Isolation was by instruction: the agents had a shell (ruling 3). A run with the server as the agent's only
  tool is a 03-next row and what a maintainer should ask for before *Validated*.
- **CAP-13 status.** It stays *Diagnostic*. The Report says what a maintainer would need to decide for *Validated*.

## The folder lifecycle helper ranks through the reference (S5-T9, review R04, 2026-11-12; verified and merged 2026-11-12)

**Verified and merged 2026-11-12** ([Verdict](docs/tasks/S5-T9.md)); the verifier's own `ReleaseSmall` `searchd`,
comparative cases, plants and pack runs (mixed, semantic and Tamil-absent included) agree with the Report.

Built on `task/S5-T9` ([task and Report](docs/tasks/S5-T9.md)); Python helper and tests only (`folders.py`, a new
test file): no `core.py`, native, contract, Dart or app pin change. `FolderIndex.search` no longer keeps its own BM25
from before the title field: it hands its authorized snapshot (the visible chunks of the roots named and those roots'
ids; labels as the caller holds them) to `core.search`, lexical, so the title field, fuzzy-v1 and fold-groups-v2
reach it and the snapshot is the statistics, as in the engine. `roots`, `principal_labels`, `conjunctive` (the chunks
holding every query word as typed, now in the current rank order), `top_k` and the result fields are kept; `score` is
the chunk's `ranking.lexical.score` (BM25 plus the title part it received); no path-prefix parameter.
`tests/test_folder_ranking.py` feeds an invented folder (two roots, one labelled file) through an update, a rename
and a delete and compares the helper with `core.search` (equal) and with `searchd` ReleaseSmall (same hits, same
order, largest difference 1.58e-06; tolerance 1e-4 · max(1, |reference|)) on a title question, a misspelt word, a
verb form, a plural and the scope. The family-folder pack (its three lifecycle scenarios run through the helper)
gives an identical report; J2 does not use the helper and is unchanged on both surfaces.

## CI that cannot pass by skipping: Unicode golden freshness and the native J2 gate (S5-T6, 2026-11-12; verified and merged 2026-11-12)

**Verified and merged 2026-11-12** ([Verdict](docs/tasks/S5-T6.md)); the verifier's own runs of both scripts, its own
plants and its reads of the cited CI runs agree with the Report, and the branch run on the merge of `main` was green.
[Report](docs/tasks/S5-T6.md); review items R01 and R02. CI and tests only: no digest-covered file, no native rebuild,
no contract or binding change, no app pin; `fixtures/j2/baseline.json` and `fixtures/j2/allow.json` unchanged.

- **The push trigger** includes `task/**`, so a task branch is checked before it merges.
- **`unicode-13-goldens`** (Python 3.9 through `actions/setup-python`; Unicode 13.0.0, asserted in its own step; no
  Zig, none of its generators uses it): `scripts/ci_unicode_goldens.py` runs `tests.test_goldens_fresh`,
  `tests.test_analyzer_v3` and `tests.test_tokenize` whole, counts nine checks by name (the `_fold.py`, `_marks.py` and
  `zig/src/unicode_tables.zig` tables, the marks guard, the analyzer-v3, title, BM25, fuzzy and verb-forms goldens) and
  fails on a missing check, any skip or a failure, each annotated with the stale file and its first differing lines.
  The three table checks ignore only the generating Python's patch version in their header
  (`tests/unicode_tables_header.py`; the runner's 3.9 is 3.9.25, the files say 3.9.6).
- **`native-linux-release`** runs J2 through the `ReleaseSmall` `searchd` it builds (`scripts/ci_j2_native.py run`: 198
  queries, `content` and `both`, no skip, the binary, commit and policy ids named), lists every cell that differs from
  the macOS arm64 baseline (none on x86_64 at S5-T6), gates it (`j2_gate.py --annotate`) and checks that the same gate
  fails a planted regression (every graded answer removed from the real run).
- **Annotations.** Each new step reports what failed as workflow annotations (at most 30 a step; GitHub keeps 10 of
  each level a step, so the tenth of a level says how many more the log holds), which the unauthenticated check-runs
  API returns; job logs need a sign-in.

## The reference scores `content` under a path prefix as the engine does (S5-T7, review R03, 2026-11-12; verified and merged 2026-11-12)

**Verified and merged 2026-11-12** ([Verdict](docs/tasks/S5-T7.md)); the verifier's own `searchd` ReleaseSmall build
and runs reproduced every number below. Built on `task/S5-T7` ([task and Report](docs/tasks/S5-T7.md)); Python reference and tests only, so no native,
contract, Dart or app pin change. `core.search`'s `content` body BM25 (`_bm25_scores(..., statistics=visible)`) now
takes N, the average length and every document frequency over the chunks the caller may see (roots and labels),
and the path prefix narrows only the candidates, as `Engine.queryTraced` has since S3-T3. A grouped term (fuzzy-v1,
fold-groups-v2) scores at the largest visible df among the members some candidate holds (`Group.bodyFrequency`).
Before, the reference took all three statistics over the chunks under the prefix: on the new fixture its raw scores
were 0.12–1.29 away from `searchd`'s and one rank order differed; now the largest difference is 1.07e-07 (tolerance
1e-4 · max(1, |reference|)). `filename` and `both` keep their prefix-scoped body and file-name statistics, unchanged.
No prefix, no change: J2's every run (per-hit scores included) is identical before and after on the reference, and
the gate passes on both surfaces. `FolderIndex.search` (review R04) passes no prefix and is untouched.

## Verb forms: a query word is also searched as its `-ing` and `-ed` forms that the files hold (S5-T5, 2026-11-09; verified and merged 2026-11-10)

**Verified and merged 2026-11-10** ([Verdict](docs/tasks/S5-T5.md)); the verifier's own runs gave every J2 cell below on
both surfaces, the plants and the natives byte for byte. [Report](docs/tasks/S5-T5.md). `fold-groups-v2` ([docs/fold-groups-v2.md](docs/fold-groups-v2.md)), over
`fold-groups-v1` unchanged.

**R** generates a word's verb forms: for u = A(F(t)) of 4 to 49 letters a–z, the bases (the plural stem; the `-ing` or
`-ed` remainder of at least 3 letters with a vowel, plus `e` and undoubled; `-ied` → `y`) and their relatives (`s`,
`es`, `ed`, `ing`, the `e`, doubling and `y` shapes), one exact dictionary lookup each (at most 19 for a J2 word, 45 by
construction). The Zig engine (`zig/src/verb_forms.zig`, used by `zig/src/fold.zig`) and the Python mirror
(`src/search_platform/verb_forms.py`) are held equal by `fixtures/verb-forms-golden.json` (2,856 terms listed, 16,211
listed as off, a digest over 49,347 terms).

**The groups.** Query side only: no index format, writer or analyzer change, and no rebuild. A form joins a word's
fold-groups-v1 group when it is a member by v1's own test (in-scope body, or a visible title under the prefix). A word
no chunk in scope and no visible file name holds takes every such form at 1.0 and is not also fuzzy-expanded; a word
the files hold takes a form at 0.5 only when the form's key document frequency is no higher than its own (visible
chunks; a prefix narrows membership, not statistics). Scoring and order are v1's.

**The contract.** Contracts **2.6.0**, additive: `retrieval.fold_policy_id` is `"fold-groups-v2"`; R's forms appear in
the existing `query_term_grouped` warning's `members` (no new code or field). Dart **0.7.0**. Natives: macOS 953,800
B, Android `arm64-v8a` 915,744 B, iOS framework binary 918,536 B (+17,008 / +4,800 / +632 B over 0.6.0);
`native/SOURCE-SHA256` `cb7e1ae8b3c32c86ef3f3cffcd74a9343b9af2738b6cf7edc5607825d95c2e0b`. The `NoFreeGeneration`
line now names a `source-N.hybsrc` entry (`docs/generation-lifecycle.md`).

**J2, `searchd`, success@1 under `content` and `both`, before → after:** morphology 0.538 → 0.692; morphology-heldout
0.571 → 0.714; verbform-heldout (19 rows judged before R) 0.263 → 0.947; control 1.000; every other slice unchanged;
overall 0.811 → 0.832. The two surfaces agree on all 1,720 per-query cells. The gate passes with nothing added to the
allow-list. The older packs do not move. Step 0 (the regrade of `m03`, `m04`, `m15`, `m16`) moved 12 MRR, nDCG and
recall cells and no success@1.

**Cost** (10k timing corpus, `ReleaseSmall`, six interleaved rounds under the gate, a second S5-T4 library as the
noise reference): the first `content` query after an open +0.039 to +0.088 ms (bound ≤ +0.30); warm queries with no
form −0.012 to +0.002 ms (bound ≤ +0.03); `hashing` (grouped with `hash`, 1,239 postings) +0.034 ms `content`, +0.035
ms `both`; nothing kept beyond fold-groups-v1's 64 B key map; NFR-13 at 10k and 15k under 64 MiB.

**For the consumer app:** the Report's "What M16 carries".

## Symlinked generation slots: PR #11's regressions on current `main` (S1-T23, 2026-11-09; verified and merged)

**Verified and merged 2026-11-09** ([Verdict](docs/tasks/S1-T23.md)); the verifier's own runs gave the same counts.

A publish that numbers itself (`ss_index_folder`, `searchd index` without `--generation`) treats a dangling link, or a
link to itself, under any of the six names it probes (`documents-N.hybseg`, `lexical-N.hyblex`, `source-N.hybsrc`,
`filenames-N.hybseg`, `filename-lexical-N.hyblex`, `state-N.hybstate`) as an occupied slot and takes the next number; the
link and its absent target are left as they are, and a link is never a numbering trace. This behaviour has been on `main`
and in the natives since S4-T3 (PR #21); S1-T23 lands PR #11's tests for it, widened to all six names, a C ABI update and
two real `searchd` runs, and records PR #11's branch in history (`-s ours`: its 19 Oct natives are not taken). No
digest-covered file changes (`native/SOURCE-SHA256` stays `81f9c76b…`); no contract, Dart or version change. On this Mac:
Zig 418/426 (8 scale skips) in Debug and `ReleaseSmall`, C ABI 24/24, Python 335 OK; with the probe returned to following
links 5 Zig tests and both `searchd` tests fail. Known gap (a `03-next` row): at the exhausted `u64` candidate a lone
`source-N.hybsrc` entry gives a `NoFreeGeneration` line with an empty trace list. Lifecycle rule:
[docs/generation-lifecycle.md](docs/generation-lifecycle.md). [S1-T23](docs/tasks/S1-T23.md)

## Word-form groups: a query word is also searched as the words the files hold that share its fold key (S5-T4, 2026-11-07; verified and merged)

**Verified and merged 2026-11-07** ([Verdict](docs/tasks/S5-T4.md)). Every check below is from the verifier's own builds
and runs:
- **J2.** A fresh `ReleaseSmall` `searchd` (1,078,504 B, `bc716140…`) and the Python reference (3.9.6, `PYTHONHASHSEED` 0
  and 1) reproduce every cell of the re-recorded `fixtures/j2/baseline.json` (0 differ on each surface). The S5-T1 gate
  against the baseline as extended at `a7f50db` passes on both surfaces and both variants with `fixtures/j2/allow.json`
  holding `ah11` alone (the declared accent merge guard).
- **The plants.** All nine (the two keep lists, Porter `-ed`, marks after any base, no re-split, fuzzy-v1 on grouped
  words, no scope filter, no title terms in the key map, the use-after-free) are caught by the tests the Report names.
- **The captures.** The 16,508-case capture against `main` explains all 350 differences by a group; 0 unexplained.
- **The writer.** Every file the writer writes is byte-identical to `main`'s (10k corpus and family folder, off and on).
- **The natives.** Rebuilt twice, they are `cmp`-equal to the committed ones.
- **The goldens.** The analyzer-v3, title, bm25 and fuzzy goldens regenerate byte for byte. The title golden was stale
  at the first pass (J2 had grown); it was regenerated, and `tests/test_goldens_fresh.py` now fails on any stale golden.
  It runs only on a Python whose Unicode is 13.0.0 (this Mac's 3.9.6), so CI's Python 3.11 skips it.
- **The suites.** Python 333 OK (with Zig; and against a `ReleaseSmall` `searchd`) and 297 run, OK (38 skipped, no
  Zig). `zig build test` 414/422 (8 scale skips; 422/422 with `SEARCH_SIMPLI_NFR13_SCALE=1`) and `test-abi` 24/24, in
  Debug and in `ReleaseSmall`. Dart +90.
- **The old packs.** Identical to `main`'s except mixed: MRR 0.833 → 0.796, success@1 0.70 → 0.65, with the five named
  moves (true singular/plural pairs).

[Report](docs/tasks/S5-T4.md). `fold-groups-v1` ([docs/fold-groups-v1.md](docs/fold-groups-v1.md)).

**The key K** maps an analyzer-v2 term to its key: F (NFKC case fold through a 3,746-entry table, then analyzer-v2's
split, Unicode 13.0.0) → A (combining marks after a–z dropped, eight letters mapped) → S (English plural, a 50-word keep
list) → T (seven Tamil suffix rules, an 8-word keep list, two Tamil letters kept). The Zig engine (`zig/src/fold.zig`)
and the Python mirror (`src/search_platform/analyzer_v3.py`) agree on 49,122 golden terms.

**The groups.** Query side only: no index format, writer or analyzer change, and no rebuild. The key map (the terms
whose key is not themselves) is built once per opened generation at the first `content` or `both` query. A query word's
group is the in-scope body terms and visible title terms with its key; it is used when it is not the word alone, scores
as one word through fuzzy-v1's machinery (one df, the best member per chunk or file), and a grouped word is not also
fuzzy-expanded. `find` and the `filename` field are not grouped.

**The contract.** Contracts **2.5.0**, additive: `retrieval.fold_policy_id` is `"fold-groups-v1"`; the warning
`query_term_grouped` (with `term` and `members`) in `ss_query` and `searchd query`; JSON-RPC `search_knowledge` carries
no warnings. Dart **0.6.0**. Natives: macOS 936,792 B, Android `arm64-v8a` 910,944 B, iOS framework binary 917,904 B
(+52,160 / +52,720 / +52,808 B over 0.5.0); `native/SOURCE-SHA256`
`81f9c76b90aad0b21709af002c0344c0ef12fcf044e2f8024c4c38042bd7d48c`. A 0.5.x library still opens every index.

**J2, `searchd`, `content` success@1 · MRR@10, before → after:** morphology 0.308 · 0.429 → 0.538 · 0.718; accent
0.444 · 0.551 → 0.778 · 0.846; Tamil 0.231 · 0.308 → 1.000 · 1.000; misspelling 0.500 · 0.593 → 0.562 · 0.649;
control, title and phrase unchanged; overall 0.632 · 0.700 → 0.811 · 0.872 (`both` 0.632 · 0.683 → 0.811 · 0.857).
The held-out slices, judged before K: morphology-heldout 0.214 → 0.571, accent-heldout 0.455 → 0.909, tamil-heldout
0.154 → 0.923, on both surfaces.

**Cost** (10k timing corpus, `ReleaseSmall`, six interleaved rounds under the gate, the verifier's medians): the first
`content` query after an open +1.05 to +1.11 ms (the key map build 1.06 ms, 114 B kept); warm queries with no group
+0.0004 to +0.012 ms; the grouped `system` +0.056 ms `content` and **+0.067 ms `both` (bound ≤ +0.03: missed, recorded,
orchestrator ruling 1)**; an unmatched word with a group −0.455 to −0.477 ms; `ss_open` −0.015 to −0.020 ms. NFR-13 at
10k and 15k under 64 MiB. A generated Tamil-heavy 10k corpus: key map 445,993 B kept, first query 3.13 → 12.97 ms.

**For the consumer app:** M16-T33, as the Report's "What M16-T33 carries" and orchestrator ruling 9 state.

## Misspelling tolerance: a query word that nothing visible holds is also searched as its nearest dictionary words (S5-T3, 2026-11-07; verified and merged)

**Verified and merged 2026-11-07** ([Verdict](docs/tasks/S5-T3.md)). Every check below is from the verifier's own builds
and runs:
- **J2.** A fresh `ReleaseSmall` `searchd` (1,026,904 B, `3e700dc4…`) and the Python reference (3.9.6, `PYTHONHASHSEED`
  0, 1, 2) reproduce every cell of the re-recorded `fixtures/j2/baseline.json` (0 differ on each surface). The S5-T1 gate
  against the S5-T2 baseline (as extended at `7ccf33f` with the held-out misspelling slice) passes on both surfaces and
  both variants with no allow file.
- **The plants.** All eight (title guard, df ≤ 1, weight 0, Latin check, first letter, 3 code points, whole-index df,
  the unmatched warning) are caught by the tests the Report names.
- **The captures.** The 16,508-case capture against `main` explains all 516 differences by an expansion, and every
  random-vocabulary 10k case is identical.
- **The writer.** Every file the writer writes is byte-identical to `main`'s.
- **The natives.** Rebuilt twice, they are `cmp`-equal to the committed ones.
- **The suites.** Python 306 OK (with Zig; and against a `ReleaseSmall` `searchd`) and 270 run, OK (38 skipped, no Zig).
  `zig build test` 398/404 (6 scale skips; 404/404 with `SEARCH_SIMPLI_NFR13_SCALE=1`) and `test-abi` 24/24, in Debug
  and in `ReleaseSmall`. Dart +87.
- **The old packs.** Identical to `main`'s except mixed: MRR 0.775 → 0.833, with the four named moves, `latency-breakdown`
  1 → 2 among them.

[Report](docs/tasks/S5-T3.md). `fuzzy-v1` ([docs/fuzzy-v1.md](docs/fuzzy-v1.md)).

**When a word triggers.** All four of these hold:
- it has 5 or more code points;
- it is all Latin letters and digits (ruling 2's table);
- no chunk in scope holds it (roots, labels, path prefix);
- no visible file's title field holds it (roots and labels).

**The candidates and the score.**
- The candidates are the in-scope body words and the visible title words that keep its first code point, within an OSA
  distance of 1 (5 code points) or 2 (6 or more).
- They are ordered by distance, key df descending (the roots-and-labels df: a prefix narrows membership, not
  statistics), then bytes, and 3 are kept.
- They score as one word: one group df (the largest), each chunk or file its best member, weighted 1.0 at distance 1
  and 0.5 at distance 2.
- This applies in the lexical channel and in the title field, under `content` and `both` (one set of groups). It never
  applies to `filename`, `find`, vector retrieval or an analyzer-v1 index.

**The contract.** Contracts **2.4.0**, additive:
- `retrieval.fuzzy_policy_id` is `"fuzzy-v1"`;
- the warning `query_term_expanded` (with `term` and `expansions`) follows the word's `query_term_unmatched` in `ss_query`
  and `searchd query`;
- JSON-RPC `search_knowledge` carries no warnings.

Dart **0.5.0**. Natives: macOS 884,632 B, Android `arm64-v8a` 858,224 B, iOS framework binary 865,096 B;
`native/SOURCE-SHA256` `8f73bf9c3f874e98197c98c0b23237cc49358f028025a18ff35fef2934142055`. No index format, writer or
analyzer change; no phone rebuild.

**J2, `searchd`, success@1 · MRR@10, before → after:**

| Slice | `content` | `both` |
|---|---|---|
| misspelling | 0.062 · 0.199 → 0.500 · 0.593 | 0.062 · 0.156 → 0.500 · 0.539 |
| the held-out misspelling slice | 0.333 · 0.558 → 0.917 · 0.958 | 0.333 · 0.465 → 0.917 · 0.958 |
| morphology | 0.154 · 0.349 → 0.308 · 0.429 | (moves too) |
| accent | 0.111 · 0.255 → 0.444 · 0.551 | (moves too) |
| control, Tamil, title intent, title-heldout | unchanged | unchanged |
| overall | 0.505 · 0.595 → 0.632 · 0.700 | 0.505 · 0.579 → 0.632 · 0.683 |

Two rows get worse, both within the gate's limit: `m15` 5 → 8 and `o10` 2 → 4.

**Cost.** 10k timing corpus, `ReleaseSmall`, six interleaved rounds against the untouched `main` under the gate; the
median per-round difference:

| Measure | Bound | Measured |
|---|---|---|
| one misspelt word, `content` | ≤ +0.70 ms | **+0.559 ms** |
| two misspelt words | ≤ +1.40 ms | **+1.124 ms** |
| one misspelt word, `both` | ≤ +0.75 ms | **+0.627 ms** |
| the S4 query set, `content` (nothing triggers) | ≤ +0.02 ms | **+0.0003 to +0.013 ms** |
| `ss_open` | unchanged | **−0.003 ms** |

Measured, with no bound:
- a `both` query whose word does not trigger costs +0.032 ms (the 03-next row: `bothGroups` builds its scope view on
  every query);
- the first `content` query after a cold open costs +0.07 ms.

Memory: nothing is kept between queries (the live bytes are equal before and after a triggering query), and one scan
peaks at 435 B. NFR-13 on one handle: 10k 38,054,528 B and 15k 55,850,030 B peaks, both under 64 MiB.

**For the consumer app:** M16-T32, as the Report's section 13 and ruling 8 on it state:
- Dart 0.5.0;
- the `SearchWarningCode` switch must accept `queryTermExpanded`;
- re-centre the dylib-size band on 884,632 B;
- regenerate the contracts and the skill text;
- no index rebuild.

## The title field: a file's folder names and file name count toward its words, and `both` merges per file (S5-T2, 2026-11-07; verified and merged)

**Verified and merged 2026-11-07** ([Verdict](docs/tasks/S5-T2.md)): a fresh `ReleaseSmall` `searchd` (1,008,920 B,
`cf17c735…`) and the Python reference (3.9.6, `PYTHONHASHSEED` 0, 1, 2) reproduce every cell of the re-recorded
`fixtures/j2/baseline.json` (758 cells each, 0 differ); the S5-T1 gate against the S5-T1 baseline passes on both surfaces
and variants with no allow file; the surfaces differ only by the analyzer (`a06`, `a07`, `a09`) and by tie order; the
five plants (coverage removed, folders dropped, weight 0, statistics over all files, the root id kept) fail as the Report
says; the 16,490-case capture against `main` explains every difference (3,568 `both` merges without a title word, 2,026
cases with a title word; every `filename` case and every random-vocabulary 10k case identical; a weight-0 build gives
every `content` case identical to `main`); every section a generation writes is byte-identical to `main`'s (10k corpus
with file names off and on, the family folder through `index` and `ss_apply_changes`); the natives rebuilt twice are
`cmp`-equal to the committed ones; Python 283 OK (with Zig; against a `ReleaseSmall` `searchd`) and 247 OK (37 skipped,
no Zig), `zig build test` 382/386 (4 scale skips; 386/386 with `SEARCH_SIMPLI_NFR13_SCALE=1`) and `test-abi` 24/24 in
Debug and `ReleaseSmall`, Dart +84; the old Python packs' metrics and first ranks identical to `main`'s.

[Report](docs/tasks/S5-T2.md). `title-field-v1` ([docs/title-field-v1.md](docs/title-field-v1.md)): each file's
root-relative folder names and its stem (Python's `Path.stem`), tokenized with analyzer-v2, the root id never a word; its
score is 2.5 × BM25 (k1 1.2, b 0.75, over the files the request can see: roots and labels narrow the statistics, a path
prefix does not) × coverage (the share of the query's distinct terms the field holds). Under `content` the part is added
to the file's best in-scope body chunk (a title-only file's first chunk) before `candidate_k` cuts; `both` is a
score-level merge, one result per file (best body chunk plus the part; ordered by score, path, chunk id; `candidate_k`
validated but cutting nothing); `filename` is unchanged. `zig/src/title_field.zig` derives the field from the documents
section at the first `content` or `both` query of an opened generation (`scope.Folder.titleField`, under the `Loads`
lock), never at `ss_open` and never written: **no index format, manifest or writer change, and no phone rebuilds**.
Contracts **2.3.0** (additive: `retrieval.title_policy_id` `"title-field-v1"`, `ranking.title {score}`;
`ranking.lexical.score` is body plus part); no request field, no C ABI signature change. J2 gains a held-out slice
`title-heldout` (8 rows written and judged before any ranking code).

**J2, before (S5-T1 baseline) → after**, success@1 · MRR@10:

| Slice | n | searchd content | searchd both | Python content | Python both |
|---|---:|---|---|---|---|
| control | 23 | 1.000 · 1.000 → 1.000 · 1.000 | 0.870 · 0.924 → **1.000 · 1.000** | 1.000 · 1.000 → 1.000 · 1.000 | 0.870 · 0.924 → **1.000 · 1.000** |
| misspelling | 16 | 0.062 · 0.199 → 0.062 · 0.199 | 0.062 · 0.156 → 0.062 · 0.156 | 0.062 · 0.199 → 0.062 · 0.199 | 0.062 · 0.156 → 0.062 · 0.156 |
| morphology | 13 | 0.154 · 0.362 → 0.154 · 0.349 | 0.077 · 0.295 → 0.154 · 0.346 | 0.154 · 0.362 → 0.154 · 0.349 | 0.077 · 0.295 → 0.154 · 0.346 |
| accent | 9 | 0.111 · 0.255 → 0.111 · 0.255 | 0.111 · 0.220 → 0.111 · 0.220 | 0.333 · 0.485 → 0.333 · 0.481 | 0.222 · 0.337 → 0.222 · 0.337 |
| Tamil | 13 | 0.231 · 0.308 → 0.231 · 0.308 | 0.231 · 0.256 → 0.231 · 0.269 | 0.231 · 0.308 → 0.231 · 0.308 | 0.231 · 0.256 → 0.231 · 0.269 |
| title intent | 11 | 0.000 · 0.258 → **0.909 · 0.955** | 0.545 · 0.685 → **0.909 · 0.955** | 0.000 · 0.258 → **0.909 · 0.955** | 0.545 · 0.685 → **0.909 · 0.955** |
| phrase | 10 | 0.800 · 0.900 → 0.800 · 0.900 | 0.800 · 0.900 → 0.800 · 0.900 | 0.800 · 0.900 → 0.800 · 0.900 | 0.800 · 0.900 → 0.800 · 0.900 |
| overall | 95 | 0.400 · 0.516 → 0.505 · 0.595 | 0.421 · 0.520 → 0.505 · 0.579 | 0.421 · 0.538 → 0.526 · 0.616 | 0.432 · 0.531 → 0.516 · 0.590 |
| **title-heldout** | 8 | 0.375 · 0.375 → **1.000 · 1.000** | 0.500 · 0.500 → **1.000 · 1.000** | 0.375 · 0.375 → **1.000 · 1.000** | 0.500 · 0.500 → **1.000 · 1.000** |

The held-out bar (success@1 ≥ 0.667 under `content`, w not re-tuned) is met at 1.000 on both surfaces. Known residuals
for S5-T3: no stop words in names (`on2` "painting the fence" now tops `pets/biscuit-the-dog.md`), a half-covered name
(`p06` 1 → 2). `fixtures/j2/baseline.json` is re-recorded at the S5-T2 engine (`replaces` names the S5-T1 baseline and
why; from now on a re-recording needs `scripts/j2_run.py --why`).

**Cost** (10k timing corpus, `ReleaseSmall`, interleaved with the untouched `main` under the gate; the verifier's six
rounds): `ss_open` −0.056 ms; the first content query after a cold open +3.18 ms (the derive; bound +5.0); the five
file-naming queries `content` +0.098..+0.177 ms (bound +0.20) and `both` +0.094..+0.187 (bound +0.25); the S4 research
queries `content` +0.001 and +0.002, and **+0.026 (`how does the hybrid retrieval work for a search`) and +0.034 (`the and
of to in`) against a bound of +0.02: two misses, recorded, not re-drawn** (no title word in either; the extra follows code
placement: +0.036 / +0.037 in the symbols-kept layout; the 03-next row holds it); `both` research queries +0.000..+0.020
(bound +0.10). Memory at 10k: 691,584 B kept, the derive's working arrays peak 1,541,164 B (whole derive peak 2,153,560
B); NFR-13 one handle: 10k 38,424,836 B, 15k 56,407,378 B, under 64 MiB.

Dart **0.4.0** (`SearchRetrieval.titlePolicyId`, `SearchResultItem.titleScore`); `skills/folder-knowledge/SKILL.md` gains
one sentence (a title part equal to the lexical score means only the name matched: navigation, not evidence). Natives
rebuilt (macOS 866,168 B, Android 842,272 B, iOS framework binary 846,680 B), `native/SOURCE-SHA256`
`62c37f1f5a769dbacc7c0a059a1565cd1fb4c835a1939e7b616a6ee79ab3477e`.

**Consumer pin:** M16-T31, the `03-next.md` "pin bump to S5-T2" row (filed by the orchestrator after this merge):
contracts 2.3.0, Dart 0.4.0, the natives above (the macOS dylib 22,928 B larger unsigned than 0.3.12's: re-centre the
dylib-size band), regenerated `tool_contracts.g.dart` and skill text, the accuracy pack rerun for `content` and `both`;
no index rebuild on either phone.

## J2, the judged fixture that says where keyword search loses (S5-T1, 2026-11-06; verified and merged)

**Verified and merged 2026-11-06** ([Verdict](docs/tasks/S5-T1.md)): `fixtures/j2/` regenerates byte for byte
(`judgments.json` `fc081a1c…`); every generator check holds on an independent re-check (0 failures over 109 queries); a
fresh `ReleaseSmall` `searchd` (969,688 B, `1799d0c1…`) through `scripts/j2_run.py` reproduces every `searchd` cell of
`fixtures/j2/baseline.json` (298 cells: both variants, every slice and metric, every first grade-2 rank, every negative), and
`relevance_smoke.py --pack j2` on Python 3.9.6 every Python cell under three hash seeds; the two surfaces differ only by the
analyzer (`a06`, `a07`, `a09`) and by tie order (`c06`, `c07`, `c10` at the cut, `c12`, `c14`, `c21`, `o04`, `o08`); the
four plants (BM25 `b` = 0, case folding off, a doctored baseline, a hand-edited judgment) fail as the Report says; the
family-folder, relevance-smoke and mixed outputs are identical to `main`'s; Python 229 OK (no Zig) and 265 OK (with Zig;
against a `ReleaseSmall` `searchd`), `zig build test` 362/364 (2 gated skips) and `test-abi` 24/24 in Debug and
`ReleaseSmall`, Dart +83. No ranking, analyzer, format, contract, C ABI or Dart API change; natives unchanged
(`native/SOURCE-SHA256` `7a8f13ff…`).

[Report](docs/tasks/S5-T1.md). J2 is a second judged pack beside the family-folder one: 68 invented files in three roots
(`school/`, `home/`, `laptop/`: the Varnells of Thistlecombe; CRLF, a BOM, no final newline, an empty file, a Tamil file in
each root, a Tamil file name, a 397-line diary) and 109 queries: 95 graded 0–2 in seven slices plus 14 negatives.
`fixtures/j2/generate.py` writes the files, `judgments.json` and the README from `content.py` and `queries.py`, computes
every line range, and before it writes asserts the checks that keep each miss real (a misspelt word in no file at
Damerau distance 1–2; a morphology, accent or Tamil answer holding the other form and not the query's; a title word where
the file name carries it and at most once in the body; a phrase distractor holding the words apart; no chunk holding a
grade-2 and a grade-0 row of one query). `scripts/j2_run.py` indexes through the shipped CLI (`searchd index EMPTY
--filename-index`, then `apply` of the three roots) and runs every knowledge row with `search_field` `content` (the
primary number) and `both`, and the `find` rows once; `relevance_smoke.py --pack j2` runs the same pack through the Python
reference; both score with one implementation (success@1, MRR@10, nDCG@10, recall@5, the first grade-2 rank per query,
the negatives' top hit). The Python reference's BM25 sums its terms in sorted order (`src/search_platform/core.py`, one
line), so its ties no longer depend on `PYTHONHASHSEED`.

**The baseline** (engine `6ef4c3b`; success@1 · MRR@10):

| Slice | n | searchd content | searchd both | Python content | Python both |
|---|---:|---|---|---|---|
| control | 23 | 1.000 · 1.000 | 0.870 · 0.924 | 1.000 · 1.000 | 0.870 · 0.924 |
| misspelling | 16 | 0.062 · 0.199 | 0.062 · 0.156 | 0.062 · 0.199 | 0.062 · 0.156 |
| morphology | 13 | 0.154 · 0.362 | 0.077 · 0.295 | 0.154 · 0.362 | 0.077 · 0.295 |
| accent | 9 | 0.111 · 0.255 | 0.111 · 0.220 | 0.333 · 0.485 | 0.222 · 0.337 |
| Tamil | 13 | 0.231 · 0.308 | 0.231 · 0.256 | 0.231 · 0.308 | 0.231 · 0.256 |
| title intent | 11 | 0.000 · 0.258 | 0.545 · 0.685 | 0.000 · 0.258 | 0.545 · 0.685 |
| phrase | 10 | 0.800 · 0.900 | 0.800 · 0.900 | 0.800 · 0.900 | 0.800 · 0.900 |
| overall | 95 | 0.400 · 0.516 | 0.421 · 0.520 | 0.421 · 0.538 | 0.432 · 0.531 |

**The gate** (`scripts/j2_gate.py RUN.json [--baseline fixtures/j2/baseline.json] [--allow FILE]`) compares a run with the
same surface of the baseline, variant by variant, and exits 1 if (a) any slice's MRR@10 drops by more than 0.02 (negatives
excluded); (b) a control query at rank 1 in that variant's baseline loses rank 1 (the allow-list never excuses this; under
`both`, `c02`, `c06` and `c07` are not at rank 1 today, so (c) guards them there); (c) any query's first grade-2 rank worsens
by more than 3 (not in the top 10 counts as 11; a `null` baseline cannot worsen) unless the run's allow-list (a file the task
that moves a judgment commits beside it) names it. Exit 2 on a usage error, a judgments sha256 mismatch or a missing
surface, variant, slice or query; otherwise it prints each slice's deltas and exits 0. CI's `checks` job (Python 3.11)
runs the Python reference through it against the committed baseline (`PYTHONHASHSEED=0`). Since S5-T6, `native-linux-release` also runs
`searchd` (Linux x86_64, `ReleaseSmall`) through it (`docs/evaluation.md`, "How J2 is gated on each surface"). The pack is frozen: a later
change to a judgment is a reviewed commit that says why, with the baseline update, named in that task's Report.

**What it says, for S5:** keyword search answers in the file's own words and little else: misspelling, morphology,
accents and compatibility forms, and Tamil inflections (seven of ten inflection rows return nothing) are where it loses;
title intent is never rank 1 under `content` and 0.55 under `both`, which costs control three rank-1 answers; the phrase
slice has little headroom (S5-T4 extends it first). The two analyzers' folding differs (worth 0.22 success@1 on the accent
slice) and must agree before analyzer-v3 is specified (S5-T3).

## The library's `memcpy`, `memmove` and `memset` copy 16 bytes at a time (S4-T18, 2026-11-06; verified and merged)

**Verified and merged 2026-11-06** ([Verdict](docs/tasks/S4-T18.md)): on the 10k timing corpus (`ReleaseSmall`, two code
layouts: shipped and symbols kept; *before* `2e09650` and *before2* interleaved; gate recorded at every timed start) the
documents section's 9.27 MB copy 2.02–2.07 → 0.141 ms warm and 2.44–2.49 → 0.59–0.62 ms cold; one changed file 6.61–7.45 ms
below *before* (47.2–47.6 → 40.4–40.7 ms off, 56.0–56.9 → 49.4–50.1 on); `find` (`the`, words, 20 a page) 3.42–3.44 →
3.004–3.035 ms in both layouts; `search_knowledge`'s content query 0.40 → 0.140–0.144 ms; the full 10k build −7.5 % off
and −7.3 % on; the first content query after a cold open 0.086–0.092 → 0.059–0.066 ms, the first filename query 3.80–3.85
→ 3.19–3.25 ms (one symbols-kept round of sixteen at 3.321), and **the first `both` query 3.90–3.96 → 3.244–3.322 ms,
missing its 3.3 ms line by up to 0.022 ms in half the shipped rounds** (recorded as ruled; the 03-next row "What remains of
a cold first filename or `both` query" holds the rest); `ss_open`, `read_span` and `outline` where they were. Every
section a generation writes, every query answer (2,762 `cf5f8575…`, 16,490 `09770196…`) and every `find` page (829
cases, `0e368a62…`; S4-T16's 84 pages `dadf5f4f…`) byte-identical to *before*; the randomized harness with the verifier's
seed in Debug and `ReleaseSmall`; NFR-13 15k one handle passes with every peak unchanged (`find` 60,915,647 B); `zig
build test` 362/364 (2 gated skips) and `test-abi` 24/24 in Debug and `ReleaseSmall`; Python 241 OK against a
`ReleaseSmall` `searchd`; Dart +83; five plants caught as ruled.

[Report](docs/tasks/S4-T18.md). Zig 0.16 bundles `compiler_rt` into every shared library and executable, and in
`ReleaseSmall` its `memcpy`, `memmove` and `memset` are byte loops (about a cycle per byte); `bundle_compiler_rt = false`
is not available (the library needs `compiler_rt`'s f128 helpers, which no platform library provides). `zig/src/fastmem.zig`
now defines the three, strong and hidden, 16-byte vector windows that overlap for short lengths and the last bytes,
`memmove` exact both ways; `zig/build.zig` compiles it as its own object (`-fno-builtin`; `ReleaseFast` and stripped in a
`ReleaseSmall` build, because the outliner gave `memcpy` a frame and calls for its short paths) and links it into every
library, `searchd` and the test binaries. The iOS link localizes `compiler_rt.o`'s three with `xcrun nmedit -R`
(`tool/build_native.sh`); `tool/check_native.sh` checks that `memcpy` in all three natives moves 16-byte registers and has
no byte loop (0.3.11's fail). `bzero` stays `libSystem`'s on Apple targets; `strlen` stays `compiler_rt`'s. Format,
manifest, contracts 2.2.0, C ABI and Dart API unchanged; Dart 0.3.12; natives rebuilt (macOS 843,240 B, Android 806,544 B,
iOS framework binary 807,624 B), `native/SOURCE-SHA256` `7a8f13ff7c5bb5a38d777c1fa6cdeaf3d4409740295b44976d9c6a062eb7b7bd`.

**Consumer pin:** the `03-next.md` "pin bump to S4-T18" row, at the app's convenience; the macOS dylib's size is 0.3.11's
(new bytes), and the pin task builds the app's apk and iOS app with these natives and launches each once before its chain.

## `find` ranks its hits by sorting a list of positions and checks scope by pointer (S4-T17, 2026-11-06; verified and merged)

**Verified and merged 2026-11-06** ([Verdict](docs/tasks/S4-T17.md)): on the 10k timing corpus (`ReleaseSmall`, filename
channel on, `scripts/source_read_parity.py time --filename --samples 30 --rounds 2`, two interleaved runs, two processes per
build and run, gate recorded) `find` (`the`, words, 20 a page) p50 7.78–7.81 ms (the shipped layout of `c53c953`) and
7.04–7.59 ms (the same source with symbols kept, a second code layout) → **3.44–3.47 ms in both layouts of the merge**,
the two layouts within 0.030 ms. `ss_open` (medians within 0.1 ms, no round above 0.2, as restated), the reads, outlines,
the three queries, the first `read_span` and the first query after a cold open where they were; every `find` page byte
for byte the same (`scripts/capture_find_pages.py`: 829 cases, 1,568 pages, `0e368a62…`; S4-T16's 84 pages `dadf5f4f…`;
the verifier's own 81 cases), both query captures (2,762 `cf5f8575…`, 16,490 `09770196…`); the writer identical
(`s4t11_budgets.py compare`) and its stages within tolerance; NFR-13 15k one handle passes, `find`'s peak 61,221,729 →
60,915,647 B; `zig build test` 356/358 (2 gated skips) and `test-abi` 24/24 in Debug and `ReleaseSmall`; Python 241 OK
against both `searchd` builds; the judgment pack passes; three plants as the Report says.

[Report](docs/tasks/S4-T17.md). `find` sorts a `u32` list of the kept hits' positions under the unchanged `rankedBefore`
(score, root, path, start line, record number: a strict total order, one hit per record) and copies each hit once in rank
order; sorting the 64-byte records made `pdq`'s swap move a byte at a time, which the `ReleaseSmall` outliner turned into a
call per byte in some layouts. The whole order is kept (`files` lists every file in the order of its first appearance).
`documentInScope` and `termInScope` take the engine and the request by pointer. Format, manifest, contracts 2.2.0, C ABI
and Dart API unchanged; Dart 0.3.11; natives rebuilt (macOS 843,240 B, Android 805,744 B, iOS framework binary 807,624 B),
`native/SOURCE-SHA256` `2c4014315c655492b34f7b14f3e666beaea66708b29f6792f2587a56155c28d1`.

**Consumer pin:** due now, one pin for S4-T16 and S4-T17 together (the `03-next.md` "pin bump to S4-T17" row); the macOS
dylib is 16,704 B larger than 0.3.10's unsigned, so the app re-centres its signed-dylib band.

## One changed file: the documents pass, `loadPrevious` and the documents encode stop re-doing every unchanged file (S4-T16, 2026-11-06; verified and merged)

**Verified and merged 2026-11-06** ([Verdict](docs/tasks/S4-T16.md)): on the 10k timing corpus (`ReleaseSmall`, one changed
file, `scripts/s4t4_budgets.py profile`, p50 of ten, two interleaved runs, stage timers on in all three builds)
`load_previous` + `build_documents` + `encode_sections.documents` 20.3–20.6 → 8.60–8.68 ms, and the call's stages (`total`)
58.8–61.4 → 47.0–47.1 ms with the filename channel off and 67.6–71.6 → 55.8–55.9 ms on (at least 11.6 ms below the untouched
before); with the timers off (`budgets`, p50 of five) 57.4 → 45.9 and 65.7 → 55.6 ms. The untouched stages, the full 10k
build (1.004 / 1.002), `ss_open`, the first query after an open, the queries and the reads where they were; every section
an update writes byte-identical to before's and to a fresh index (`s4t11_budgets.py compare`; 120 randomized rounds of the
verifier's seeds in Debug and `ReleaseSmall`, half with the filename sections; a `0f07746` generation in four cells; both
captures, 2,762 `cf5f8575…` and 16,490 `09770196…`); NFR-13 15k one handle unchanged (open 49,139,017 B); `zig build test`
355/357 (2 gated skips) and `test-abi` 24/24 in Debug and `ReleaseSmall`; Python 241 OK against both `searchd` builds;
seven plants caught. **`find`** (`the`, words, 20 a page) measures 5.83–5.89 → 7.79–7.82 ms with its code unchanged: the
`ReleaseSmall` outliner turned the byte step of its sort's 64-byte swap into a call per byte (bar 5(e) re-ruled; the fix
is S4-T17).

[Report](docs/tasks/S4-T16.md). `PreviousDocs` maps each path to one range of the previous documents section when its
runs ascend strictly by path (every generation `buildGeneration` has written since S3-T3), else the list per path as
before; `loadPrevious` sizes its tables once, fills `initial` with `files`, answers "has previous records" by a forward
walk and skips the not-in-state loop when the walk matched every path; the documents pass merges the batch's files into
the state's order (`orderedFiles`, equal to the sort) and reads the previous source section with a cursor
(`SourceWalk`); `segment.encodeAllocV4` validates the documents section once. Format, manifest, contracts 2.2.0, C ABI and
Dart API unchanged; Dart 0.3.10; natives rebuilt (macOS 826,536 B, Android 804,560 B, iOS framework binary 807,088 B),
`native/SOURCE-SHA256` `1a7887aae8834dbbb95f77574889f94f29960391fd4a5ed96e1beb29ba62a631`.

**Consumer pin:** not yet: the app pins once for S4-T16 and S4-T17 together, after S4-T17 merges (the `03-next.md` row),
so no consumer sees `find`'s 7.8 ms level.

## The `both` and filename queries keep a bounded top `candidate_k` per channel (S4-T15, 2026-11-06; verified and merged)

**Verified and merged 2026-11-06** ([Verdict](docs/tasks/S4-T15.md)): on the 10k timing corpus (filename channel on,
`ReleaseSmall`, warm p50, two interleaved 20-round runs) the `both` query 3.245–3.267 → 0.487–0.500 ms against the untouched
before (one level, spread 0.010 / 0.013 ms) and the filename query 0.762–0.774 → 0.251–0.256 ms; the content query, `ss_open`,
`find` and the reads unchanged; `scripts/capture_query_outputs.py` byte-identical before and after (2,762 queries
`cf5f8575…`; with `--filename-fields` 16,490 `09770196…`); NFR-13 15k one handle passes (`both` peak 58,866,083 → 57,696,077 B);
`zig build test` 346/348 (2 gated skips) and `test-abi` 24/24 in Debug and `ReleaseSmall`; Python 241 OK against both
`searchd` builds; four plants caught. Bar 5(a)(i) was re-ruled against the untouched before (the first-form Verdict missed
one round of forty against *before2*'s low level).

[Report](docs/tasks/S4-T15.md). `filename_field.queryDecoded` no longer sorts every scored file: each channel keeps its top
`min(candidate_k, candidates)` in `hybrid.BoundedTop` (the generic form of the content query's `TopK`) under exactly
`lessCandidate`'s order, a strict total order over a channel's candidates, so the kept list is the full sort's prefix and
every hit is unchanged. The profile put 2.98 ms of the 3.25 ms call in the two full sorts and the call's two levels
(S4-T12's layout row) in the body sort, which is gone. Format, manifest, contracts 2.2.0, C ABI and Dart API unchanged;
Dart 0.3.9; natives rebuilt (macOS 825,976 B, Android 798,960 B, iOS framework binary 806,416 B), `native/SOURCE-SHA256`
`1f27e1b10c14e5329d298bcd89d7e72e5845867aa5cd77bda465da354c2f9177`.

**Consumer pin:** the S4-T15 merge on `main` (contracts 2.2.0, Dart 0.3.9; the signed macOS dylib should land near
844,256 B, outside the band M16-T27 re-centred on 861,920 B: the pin task re-centres it).

**Gap in this file:** no entry was written for S4-T7 to S4-T14 (all verified and merged 5–6 Nov 2026); their Reports and
Verdicts are in `docs/tasks/S4-T7.md` … `docs/tasks/S4-T14.md`, and `docs/journey/03-next.md` carries their top entries.
From S4-T15 the verifier adds the entry at each merge again.

## A read after `apply_changes` no longer crashes a release `searchd serve` (S4-T6, 2026-11-05; verified and merged)

**Verified and merged 2026-11-05** ([Verdict](docs/tasks/S4-T6.md)): `zig build test` 315/315 and `zig build test-abi` 24/24 in Debug and
`ReleaseSmall`; the Python suites 241 OK, 0 skipped, against a Debug and a `ReleaseSmall` `searchd`; the before `ReleaseSmall` `serve`
dies by signal 11 on all six reads after `apply_changes`, the after one answers them (also through `mcp`); the old reload put back
fails or crashes the new test in both modes; 6 → 1 source descriptors held after five writes; natives `cmp`-equal to S4-T4's;
`ss_open` within 0.02 ms and one changed file within 0.3 ms of before.

[Report](docs/tasks/S4-T6.md). Since S4-T1's lazy open, `searchd serve --allow-write` built `ReleaseSmall`, `ReleaseFast` or
`ReleaseSafe` answered `apply_changes` and then died (signal 11, no reply) on the next `read_span`, `outline`, `find`,
`search_knowledge` or `list_files`: the reload opened the new generation into an `ArenaAllocator`, moved it by value and freed
the struct, and the generation's `scope.Loads` allocated through the freed one (Debug's allocator never reuses a freed block, so
the Debug suites and CI passed). `searchd mcp` had the same pattern with a stack local. The fix (`zig/src/rpc.zig`
`Generation`, `Served`): the served generation owns a heap arena that never moves; a reload opens the new generation, then
closes the old one with its section files (the old reload leaked one set of descriptors per write). Tests:
`zig/src/reload_test.zig` (Debug and `ReleaseSmall`, a poisoning wrapper over the testing allocator and the C allocator), an
`abi_test.c` check that a handle opened before `ss_apply_changes` on the same directory keeps answering its own generation
(the C ABI never had the defect: the same check passes against the S4-T4 library), and a CI job `native-linux-release` that
runs the engine tests, the ABI harness and the Python suites against `ReleaseSmall`. Budgets unchanged (the library is
byte-identical); Dart 0.3.2, contracts 2.2.0, natives byte-identical to S4-T4's, `native/SOURCE-SHA256`
`7762a23a714f79c91828e0dd455a9779a202be6c8e950e3f50ddd8cfe6495c4f`.

**Consumer pin:** the S4-T6 merge on `main` (contracts 2.2.0, Dart 0.3.2, the same three native binaries as S4-T4).

## The skill names the file-name field (S4-T5, 2026-11-05; verified and merged)

**Verified and merged 2026-11-05** ([Verdict](docs/tasks/S4-T5.md)): Debug suite 241 OK, 0 skipped; judgment pack 0 skipped; the
verifier corrected one sentence (a name-only result carries the file's first passage, marked as not matched). With a
`ReleaseSmall` `searchd`, `serve` dies (signal 11) on `read_span` after `apply_changes`, back to at least `f45c06d`: S4-T6.

[Task](docs/tasks/S4-T5.md). `skills/folder-knowledge/SKILL.md` documents `search_field` (`content`, `filename`, `both`;
`filename` and `both` need `retrieval_mode: lexical`), the result's `matched_in`, `basename` and `match_sections`, a
file-name-only hit as navigation (read `outline` and `read_span` before quoting, cite the file without lines), the error an
index built without `--filename-index` returns, and a file-name try before "that file does not exist". `tests/test_example_loop.py`
gains a file-name question over `fixtures/family-folder/school` (`geography-coast.md`, a word found only in its name, index built
with `searchd index --filename-index`) and a test that the skill keeps those field names. No change under `zig/`, `contracts/`,
`bindings/` or `native/`; the Dart package has no CHANGELOG entry.

## The cheaper edit: one copy of the recovery state, binary (S4-T4, 2026-11-05; verified and merged)

**Verified and merged 2026-11-05** ([Verdict](docs/tasks/S4-T4.md)): the verifier's own runs (`ReleaseSmall`, 10k, two
driver runs at load 2.1–2.7) give one changed file p50 123.3–124.1 ms off and 141.1–141.9 ms on (596032c 147.1–147.4
and 171.4–173.0), `ss_open` within 0.14 ms of before, 970,253 B of state per generation; the natives rebuilt with
fresh caches are byte-identical to the committed ones.

[Report](docs/tasks/S4-T4.md). `INDEX-STATE.json` is now a version 3 pointer (94 B: the
generation, the analyzer and the bound section's file name) to the generation's state
section, and that section is the `HYBSTA02` binary form
([format](docs/state-section-format-v2.md)): 970,159 B on the 10k timing corpus against
2,522,562 B of `HYBSTA01` JSON, so a generation writes 970,253 B of state instead of
5,045,092 B. Writers still read a full version 2 file and a `HYBSTA01` section (directories
written by 0.2.x and 0.3.0 open and update; the first update writes the new forms).
`generation_alloc` reads only the generation from `INDEX-STATE.json` (it parsed the whole
v2 file, 8.5 ms at 10k, on every write). The writer checks the filename sections it just
encoded by decoding them and comparing with the structures it built (3.7 ms against the
8.2 ms re-tokenization), and skips the sort when the documents already come in path order;
the sections are byte-identical to S4-T2's. One changed file in the 10k index
(`ReleaseSmall`, five runs, p50): 123.2 ms filename off, 141.6 ms on (596032c: 147.7 and
172.0); `ss_open` and filename queries unchanged. Contracts 2.2.0; Dart 0.3.1; natives
rebuilt on this Mac twice, byte-identical (benchmark rows marked S4-T4).

**Rollback rule (new):** the 0.3.0 library opens and queries a directory this release has
updated but refuses to update it (`SS_ERR_CORRUPT_SNAPSHOT`, `InvalidStateSection`); keep
the previous directory to roll back to.

**Consumer pin:** the S4-T4 merge commit on `main` (the head of `main` after it), contracts
2.2.0, Dart 0.3.1, `native/SOURCE-SHA256`
`db21322e2333423cf45e7c0343ea63a81a989e6aebc7df904ccad88bb70663bc`, iOS framework binary
789,304 B (sha256 `4c39e8f6…6e563c31`). The Dart API did not change since 0.3.0.

## Filename complexity guard adopted, natives rebuilt on the Mac (S4-T3, 2026-11-02)

[Report](docs/tasks/S4-T3.md). PR #23 (merged to `main` at 94c6071 by its author) adds the
filename-query complexity guards (`zig/src/filename_complexity_test.zig`: the body records
made inaccessible with `mprotect` while filename scoring runs, and a fixed-buffer scratch
bound) and a three-line comparator fix; contracts 2.2.0, Dart 0.3.0 and the index format
are unchanged. S4-T3 ran the suites here (Zig 297/297, ABI 23/23), showed a restored
catalog × body anchor scan dies at the guard (SIGBUS on macOS), and rebuilt the natives on
this Mac twice, byte-identical. The macOS dylib (808,408 B) and the Android `.so`
(777,672 B) equal CI's bytes; the iOS framework binary is the Mac build (iPhoneOS SDK 27.0,
789,368 B), replacing CI's SDK 17.5 build (1,051,512 B). The gates are unchanged against
S4-T2 (benchmark rows marked S4-T3).

**Consumer pin:** the S4-T3 merge commit on `main` (the head of `main` after it), contracts
2.2.0, Dart 0.3.0, `native/SOURCE-SHA256` `139bd8af4b3293bcb0e4a078a188c40bb3f6da31a1e4f2bd62add5443a672feb`,
iOS framework binary 789,368 B (sha256 `40070681…660226dc`). Nothing in the Dart API
changed since S4-T2, so the S4-T2 opt-in recipe and rollback rule below still hold.

## Filename channel, bound recovery, scoped writers (S4-T2, 2026-11-01)

**Verified and merged** (fast-forward of `main`; the verifier re-measured every gate:
[Verdict](docs/tasks/S4-T2.md#verdict-verifier-fills-in)).
[Report](docs/tasks/S4-T2.md), review [REVIEW-PR21](docs/tasks/REVIEW-PR21.md). PR #21
(another agent's work on `improve/recovery-and-filename`) is merged onto S4-T1's `main`
with its author's commits kept, and its costs fixed in the integration. Contracts 2.2.0,
Dart package 0.3.0, natives rebuilt (`native/SOURCE-SHA256` `978c0e57...63d4dd`).

- **CAP-16 filename search, opt-in** (`filename-field-v1`): `search_field`
  `content|filename|both` (filename and both need lexical retrieval), separate filename
  and content citations. The channel is the directory's: chosen when it is created
  (`--filename-index`, `filename_index: true`, Dart `filenameIndex: true` on a new,
  empty directory); omitting the setting keeps it on every later update or rebuild;
  enabling it on an existing index needs a fresh directory.
- **Manifest v2.2**: the filename sections are flag bit 3 (`HYBMAN02`, 48 more header
  bytes; PR #21's interim `HYBMAN03` is not read); every folder generation binds its
  recovery state as its own section `state-N.hybstate` (flag bit 4, `HYBSTA01`,
  XXH3-64), which only writers read. The MANIFEST stays under 1 KiB (576 B, 696 B with
  filename sections, on the 10k index).
- **Lazy filename load**: an open reads neither filename section; the first filename or
  both query on a handle loads and checks them once. The filename query is linear
  (p50 0.023 ms over RPC at 10k files, was 276 ms in PR #21 as reviewed).
- **Scoped writers**: a server with `--allow-write` and `--roots`/`--labels` feeds bytes
  only (no root declarations, file reads or label changes). File reads open the root
  once following links in its own path, then no-follow below.
- **Rollback rule**: a library older than 0.3.0 refuses every folder generation 0.3.0
  writes (`UnsupportedFlags`, bit 4), with or without filename search. Keep the
  directory from before the upgrade to roll back to.

Numbers in the benchmark table below (rows marked S4-T2); "upgrade" = this library on
an index f45c06d wrote, from its first update on. The consumer app's pin bump is the
app's task (contracts 2.2.0, Dart 0.3.0).

## Phone-side costs (S4-T1, 2026-11-01)

[Report](docs/tasks/S4-T1.md). `ss_open` is lazy: it validates the manifest and the
document and lexical sections and decodes what `index_status` needs; the source section
loads at the first `read_span`/`outline` that needs it and the statistics and position
tables at first use, once per handle (`index_status` gains `source`, contracts 2.1.0).
Folder-written sections carry XXH3-64 checksums (manifest v2.1, segment v4.1; indexes
written before still open, and a 292cb568 reader refuses v2.1 with `UnsupportedFlags`).
NFR-12's one-changed-file bound now holds in `ReleaseSmall`; NFR-13 has its 64 MiB
arena-cap test (`zig/src/nfr13_arena_test.zig`); the lexical-only fuse skips two sorts.
Dart package 0.2.1, natives rebuilt (`native/SOURCE-SHA256` `41ef1574...714e`). Numbers
in the benchmark table below (rows marked S4-T1); "upgrade" = the new library on an
index written before S4-T1 (FNV-1a sections), until its first update.
Verified and merged 2026-11-01 by fast-forward of `main` ([Verdict](docs/tasks/S4-T1.md)):
the verifier re-measured `ss_open` 110 -> 7.6 to 9.1 ms and one changed file p50 232 -> 149 ms
(`ReleaseSmall`, load average 3.3 to 5.4) and rebuilt the natives byte-identical. The
consumer app pins the head of `main` after that fast-forward (the verifier's commit,
named in its message: a commit cannot name its own hash), contracts 2.1.0, Dart 0.2.1.


Series S3 (CAP-19, [plan](docs/plans/folder-knowledge-plan.md)) is complete on `main`
through S3-T7; S3-T8 rebuilt the three native libraries, bumped the Dart package to
0.2.0 (contracts 2.0.0; an older library is refused) and filed the consumer hand-off
([Report](docs/tasks/S3-T8.md)). What exists: `md-section-v1` and the retained source
(S3-T1), `HYBLEX02` positions with `find` words/phrase/prefix (S3-T2), roots and
`apply_changes` (S3-T3), six more ABI functions on every surface (S3-T4), nine tool
schemas and the skill document (S3-T5), `searchd mcp` pinned to MCP revision
**2025-11-25** (S3-T6), the family-folder fixture (S3-T7). Register: CAP-19 and
FR-17 to FR-25, NFR-10 to NFR-12, NFR-14 are `Diagnostic · implemented`; NFR-13 too
since S4-T1 (its 64 MiB arena-cap test); CFT-09 stays Blocked (interchange
carries no chunker id).

**Benchmark profile** (docs/folder-knowledge-implementation.md section 13): MacBook Pro,
Apple M5 Pro (18 cores), 48 GB, macOS 26.6.2 (25G83); Zig 0.16.0. "10k" = the
`scripts/gen_timing_corpus.py <dir> 10000` corpus (10,000 Markdown files, 7,269,199
bytes, sha256 of the files in sorted path order `3a520dd5...ed96e38`; 19,959 chunks
after S3-T1, 10,003 before). "Before" is the tree before the named task; the shipped
mode is `ReleaseSmall`. Other sessions were running (load average 1.2 to 2.6). Every
cell is a measured number; the last column names the task whose Report or Verdict
holds it (S3-T8 = measured by this task's builder).

| Measure (10k corpus unless named) | Before | After | Mode | Measured by |
|---|---|---|---|---|
| `searchd index` wall time, 3 runs | 0.55 s (0.72 first) | 0.69 s (0.85 first) | ReleaseSmall | S3-T8 |
| `searchd index` wall time (ReleaseFast) | 0.46 / 0.45 / 0.45 s | 0.61 / 0.43 / 0.43 s (after S3-T2); 0.42 to 0.43 s (after S3-T3) | ReleaseFast | S3-T2, S3-T3 |
| `searchd index` peak RSS | 249,413,632 B | 130,416,640 B | ReleaseSmall | S3-T8 (S3-T2: 266,076,160 to 118,390,784 B in ReleaseFast) |
| Documents section | 7,949,951 B | 9,273,775 B (+16.7 %) | any | S3-T1 |
| Lexical section | 8,177,741 B (`HYBLEX01`, 10,003 chunks) | 12,487,753 B (`HYBLEX02`, 19,959 chunks) | any | S3-T1, S3-T2, S3-T8 |
| `HYBLEX02` / `HYBLEX01` on the same chunks | | 12,487,753 / 9,000,597 = 1.39x (target at most 2.5x) | any | S3-T2 |
| Retained source section | none | 8,279,041 B (1.14x the 7,269,199 B of text) | any | S3-T1 |
| INDEX-STATE.json | 1,182,387 B | 2,522,530 B | any | S3-T8 |
| MANIFEST | 153 B | 540 B | any | S3-T8 |
| Whole generation (documents + lexical + source + manifest) | 16,127,845 B | 30,041,109 B (1.86x) | any | S3-T1, S3-T8 |
| `find` words p50 / p95 | | 6.5 / 245.8 us (ReleaseFast 5.6 / 223.7) | ReleaseSmall | S3-T2 |
| `find` phrase p50 / p95 | | 23.1 / 888.5 us (ReleaseFast 17.6 / 750.3) | ReleaseSmall | S3-T2 |
| `find` prefix p50 / p95 | | 744.7 / 2,953.3 us (ReleaseFast 663.9 / 2,599.9) | ReleaseSmall | S3-T2 |
| `search_knowledge` p50 / p95 | 86.6 / 126.0 us (ReleaseFast 65.4 / 105.2) | 48.2 / 132.3 us (ReleaseFast 31.5 / 102.1) | ReleaseSmall | S3-T2 |
| `search_knowledge`, union fixture (998 chunks) p50 | 30.3 to 30.8 us | 35.5 to 36.8 us (+6 us, S3-T4); 20.5 to 21.3 us after S4-T1's fuse fix (pre-S3-T2 tree 29.8 to 31.3 us in the same rounds) | ReleaseSmall | S3-T4, S4-T1 |
| `search_knowledge` p50, 10k corpus (`find_bench knowledge`) | 48.0 to 50.6 us | 32.2 to 33.6 us (ReleaseFast union fixture 20.0 to 21.3 -> 16.2 to 17.3 us) | ReleaseSmall | S4-T1 |
| `read_span` p50 / p95, 10k corpus | | 708 / 1,208 ns | ReleaseSmall | S3-T1 |
| `read_span` p50 / p95, line 9,000 deep in the 15,500-line file | 32.6 / 67.5 us | 1.08 / 1.71 us (sparse line index) | ReleaseSmall | S3-T4 |
| `apply_changes`, full 10k index (10,000 `content_base64` adds) | | 326 ms, 144 MB (ReleaseFast); 573 ms, 144 MB (ReleaseSmall) | both | S3-T3 (NFR-12 at most 3 s and 300 MB: met) |
| `apply_changes`, one changed file in the 10k index | | 163 ms (ReleaseFast, bound 200 ms: met); 215 ms ReleaseSmall (missed by about 15 ms, bound amended) | both | S3-T3 |
| `apply_changes`, one changed file in the 10k index, 5 runs | 243.4 to 249.1 ms (ReleaseFast 172.4 to 179.1) | 154.0 to 158.4 ms, p50 157.3 (ReleaseFast 87.9 to 90.8); upgrade 184.5 to 189.9 ms; bound 200 ms in ReleaseSmall: met | ReleaseSmall | S4-T1 |
| `apply_changes`, full 10k index, 1 run | 617.8 ms (ReleaseFast 352.7) | 557.4 ms (ReleaseFast 293.7) | ReleaseSmall | S4-T1 |
| MCP adapter overhead p95 over the direct call (`find` / `search_knowledge`) | | 25.0 to 28.9 / 42.4 to 44.9 us (gate 5 ms) | ReleaseSmall | S3-T6 |
| MCP start-up, spawn to `initialize` | | p50 21.0 ms, p95 21.2 ms | ReleaseSmall | S3-T6 |
| `ss_open`, 10k index (p50 of 30 opens, 3 rounds) | 47.5 ms (pre-S3 library and index) | 102.0 to 102.8 ms | ReleaseSmall | S3-T8 |
| `ss_open`, 10k index (p50 of 30 opens, 2 rounds) | 102.2 to 103.2 ms | 7.16 to 7.44 ms; upgrade 24.95 to 25.38 ms | ReleaseSmall | S4-T1 |
| `ss_open` + first `read_span` (first op p50) | 102.5 to 102.9 ms (0.07 ms) | 19.2 to 19.3 ms (11.9 ms: the source loads); upgrade 50.5 to 50.6 ms (25.3 ms) | ReleaseSmall | S4-T1 |
| `ss_open` + first scored query naming a root (first op p50) | 102.2 to 102.7 ms (0.05 ms) | 8.29 to 8.30 ms (1.13 ms: the statistics load); upgrade 26.1 ms | ReleaseSmall | S4-T1 |
| `ss_open` + first `find` (first op p50) | 103.0 to 103.2 ms (0.02 ms) | 14.4 to 15.3 ms (7.2 to 7.9 ms: the position tables load); upgrade 31.9 to 32.9 ms | ReleaseSmall | S4-T1 |
| NFR-13 peak live bytes under a 64 MiB cap (open and each operation) | | family folder 9.4 MB; 10k 60.6 MB (`list_files`), 59.7 MB (`find`), 53.5 MB (open) | ReleaseSmall (10k), Debug (fixture) | S4-T1 |
| `ss_open`, family-folder fixture | 13.0 ms | 18.4 ms | ReleaseSmall | S3-T4 |
| Native library, macOS dylib | 435,048 B | 697,544 B (S3-T8); 714,328 B (S4-T1); 808,408 B (S4-T2; S4-T3 the same bytes as CI's); 825,736 B (S4-T4) | ReleaseSmall | S3-T8, S4-T1, S4-T2, S4-T3, S4-T4 |
| Native library, Android `.so` | 427,760 B | 676,752 B (S3-T8); 684,128 B (S4-T1); 777,672 B (S4-T2; S4-T3 the same bytes as CI's); 787,216 B (S4-T4) | ReleaseSmall | S3-T8, S4-T1, S4-T2, S4-T3, S4-T4 |
| Native library, iOS framework binary | 430,688 B | 677,448 B (S3-T8); 677,744 B (S4-T1); 789,368 B (S4-T2); 789,368 B (S4-T3, SDK 27.0; CI's SDK 17.5 build was 1,051,512 B); 789,304 B (S4-T4, SDK 27.0) | ReleaseSmall | S3-T8, S4-T1, S4-T2, S4-T3, S4-T4 |
| `ss_open`, 10k index (p50 of 30, 2 rounds) | 7.35 / 7.33 ms (f45c06d) | filename off 7.35 / 7.31 ms; on 7.39 / 7.36 ms; upgrade 7.34 / 7.36 ms | ReleaseSmall | S4-T2 |
| `ss_open` + first query (first op p50, 2 rounds) | content 0.094 ms | content 0.093 / 0.093 ms; filename 4.78 / 4.78 ms and both 4.87 / 4.89 ms (the filename sections load) | ReleaseSmall | S4-T2 |
| `apply_changes`, one changed file in the 10k index, 5 runs | 140.1 to 142.8 ms, p50 141.3 (f45c06d) | filename off 147.2 to 150.4, p50 148.3; on 170.8 to 173.6, p50 172.6; upgrade 147.9 to 150.8, p50 148.3 | ReleaseSmall | S4-T2 |
| `ss_open`, 10k index, and one changed file (S4-T2's driver) | b45b1c4: open 7.21 to 7.28 ms, one changed file p50 148.3 ms | open off 7.20 to 7.36 ms, on 7.28 to 7.41 ms; one changed file p50 148.0 off, 171.3 on (worst 175.9); filename query p50 0.027 ms at 10k (RPC) | ReleaseSmall | S4-T3 |
| MANIFEST, 10k index | 540 B (flags `0x0007`) | 576 B (`0x0017`); 696 B with filename sections (`0x001f`) | any | S4-T2 |
| State section `state-N.hybstate` / filename catalog / filename lexical | | 2,522,562 B / 780,036 B / 490,091 B per generation | any | S4-T2 |
| State per generation, 10k index (`state-N.hybstate` + `INDEX-STATE.json`) | 2,522,562 + 2,522,530 = 5,045,092 B (`HYBSTA01`, v2; 596032c) | 970,159 + 94 = 970,253 B (`HYBSTA02`, v3 pointer); filename sections unchanged | any | S4-T4 |
| `ss_open`, 10k index, and one changed file (S4-T4's driver, 2 runs) | 596032c: open 7.19 to 7.36 ms; one changed file p50 147.7 off, 172.0 on | open 7.12 to 7.23 ms; one changed file p50 123.2 off (worst 125.2), 141.6 on (worst 142.7); upgrade from 596032c p50 141.7 off, 159.4 on; filename query p50 0.026 ms at 10k (RPC) | ReleaseSmall | S4-T4 |
| `search_knowledge` over RPC, 30 queries, p50 (`scripts/benchmark_filename_field.py`, 10k) | content 0.018 ms (f45c06d) | content 0.017; filename 0.023; both 0.043 ms (PR #21 as reviewed: filename 276 ms) | ReleaseSmall | S4-T2 |
| NFR-13 peak live bytes under a 64 MiB cap | family folder 9.42 MB; 10k 60.7 MB (`list_files`), 53.6 MB (open) | family folder 7.98 MB; 10k 52.3 MB (`list_files`), 45.2 MB (open); 10k with filename sections 57.2 MB (`list_files`), 51.6 MB (`both`), 50.1 MB (open) | Debug (test suite) | S4-T2 |

Notes. The pre-S3 index (S3-T8, built from `86096e9`) has about one chunk per file of the 10k corpus
where `md-section-v1` makes about two, so the lexical and document rows compare
different chunk counts; the `HYBLEX02`/`HYBLEX01` row holds the chunks equal. The 10k
`ss_open` doubles because the open now also validates the 8.3 MB source section and
builds the statistics, path, sparse line and position tables; the consumer app measures
it on the phones. The costs S3 added are the `ReleaseSmall` `search_knowledge` regression
on a small corpus, the `ReleaseSmall` one-file bound and `ss_open`; of these only the
one-file bound has a stated target, which it missed by about 15 ms in `ReleaseSmall`
(amended to `ReleaseFast`). S4-T1 removed all three: the open is lazy, the bound holds in
`ReleaseSmall` again (XXH3 section checksums), and the small-corpus query is faster than
before S3-T2. The S4-T1 rows ran with load average 1.6 to 2.7.

**Pinned MCP revision:** `2025-11-25` (`zig/src/mcp.zig`, `protocol_version`;
[docs/mcp-server.md](docs/mcp-server.md)).

**Fixture metrics** (`fixtures/family-folder/`, S3-T7 with S3-T1 to S3-T6):
42 invented files in three roots (`school` 16, `home` 16, `laptop` 10; 34 Markdown, 8 text),
one 1,133,158 B file, 1,150,039 B of text in all, 12 files with front matter, two files with
equal content; 998 chunks (143 `md-section-v1`, 855 `line-window-v1`). `judgments.json`
version 2: 13 scenarios, 5 phrase, 5 prefix, 5 outline, 8 `read_span`. Results through the
Python reference and the Zig core: words recall@5 1.000; phrase and prefix precision 1.00
and recall 1.00 (expected engine misses p3 and x1's front-matter line found);
outline 7/7; `read_span` 9/9 (sha256 and byte length); lifecycle 3/3; 0 skipped.
MCP: 66 parity requests 100 % equal to RPC, conformance client 27/27 checks.

## S3-T8: native rebuild, digests and the consumer pin (2026-10-31)

The three native libraries rebuilt from the merged source are byte-identical to
S3-T6's (macOS dylib 697,544 B, Android `.so` 676,752 B, iOS framework binary
677,448 B; four iOS segments 16 KiB aligned; `native/SOURCE-SHA256`
`9f9a58d6…ae871`). The Dart package is 0.2.0 (contracts 2.0.0; an older library
is refused with `ContractsVersionMismatchException`). The "Folder knowledge (S3)"
section above holds the benchmark table, the pinned MCP revision and the fixture
metrics; CAP-19's rows are `Diagnostic · implemented`, NFR-13 stays Proposed and
CFT-09 Blocked (both accepted). The Linux CI job runs the MCP, surface and CLI
process tests by name and fails on a skip; the conformance client's
`resources/read` size check is BOM-aware. `ss_open` on the 10k index rose from
47.5 to about 102 ms (accepted for the pin; a NEXT row asks for lazy loading).
The consumer app pins the merge commit of `verify/S3-T8` in its M16-T1.
Verified and merged 2026-10-31. [Task](docs/tasks/S3-T8.md).

## S3-T6: the MCP server, `searchd mcp` (2026-10-31)

`searchd mcp <index-dir> [--roots a,b] [--labels l1,l2] [--baseline]
[--allow-write] [--allow-file-reads]` serves one published index to an MCP
host over stdio (newline-delimited JSON-RPC 2.0, pinned revision
`2025-11-25`): `initialize`, `ping`, `tools/list`, `tools/call`,
`resources/list`, `resources/read`, `resources/templates/list`
(`search://{root_id}/{path}`). `--baseline` lists exactly CAP-13's four
tools and no resources; the default lists the eight read tools; only
`--allow-write` adds `apply_changes`, confined to `--roots`. Each tool's
`inputSchema`/`outputSchema` is its `contracts/tools/` file; a result
carries the canonical JSON as `structuredContent` and as one text block,
equal to `searchd serve`'s `result` for all 66 fixture-judgment requests; a
refusal is an `isError` result holding the RPC error object. The scope comes
from the command line only (a call carrying `principal_labels` or
`query_vector` is refused). `resources/read` reads a whole file through
`read_span`'s limits. `search_knowledge` (RPC and MCP; not `ss_query`) adds
`root_id`, `section_path`, `truncated` and `pending_files`. Adapter overhead
p95 26–46 µs (ReleaseSmall) against CAP-13's 5 ms gate; start-up 21 ms.
`tests/mcp_client.py` is a standard-library conformance client (27 checks).
CAP-13 is Diagnostic, realized by S3-T6; board I-01 done. Verified and
merged 2026-10-31. [Task](docs/tasks/S3-T6.md), [MCP server](docs/mcp-server.md).

## S3-T5: tool schemas and the folder-knowledge skill (2026-10-31)

`contracts/tools/` holds a JSON Schema 2020-12 request and result file for each
of the nine tools (`search_knowledge`, `read_chunk`, `list_sources`,
`index_status`, `find`, `outline`, `read_span`, `list_files`,
`apply_changes`), closed (`additionalProperties: false`) and described; the
request schemas omit `principal_labels` and `query_vector` (the host's, CAP-13).
`src/search_platform/schema_check.py` validates the subset the schemas use and
raises on any other keyword; the tests validate real `searchd serve`, CLI
`--json` and apply responses on the fixture. `skills/folder-knowledge/SKILL.md`
teaches a model the loop (status, `find` or `search_knowledge`, confirm with
`read_span`/`read_chunk`, answer with `[n]`, cite `root/path › section ·
lines`), the exact negative sentence "I found no matching indexed passages in
the selected folders." and never to call `apply_changes`;
`skills/folder-knowledge/example_loop.py` runs it against `searchd serve` on
the fixture. `docs/tool-schemas.md` shows the `input_schema`, `parameters` and
MCP `inputSchema` wrappings. No engine change. Verified and merged
2026-10-31. [Task](docs/tasks/S3-T5.md).

## S3-T4: folder knowledge on every surface, contract 2.0.0 (2026-10-31)

The C ABI gains `ss_find`, `ss_outline`, `ss_read_span`, `ss_list_files`,
`ss_roots` and `ss_apply_changes` (the ten v1 functions keep their signatures;
`ss_query`/`ss_evidence` take `roots`; `ss_status` and `ss_evidence` append the
2.0.0 fields after the v1 ones). `searchd` gains `find`, `outline`,
`read-span`, `list-files`, `roots` and `apply` (text or `--json`), and
`searchd serve` the methods `find`, `outline`, `read_span`, `list_files`,
`roots` and, with `--allow-write`, `apply_changes`; the scope comes from
`--roots`/`--labels` (the raw service still accepts bounded request labels
when `--labels` is absent). One module, `zig/src/ops.zig`, writes the JSON for
all three, and the Dart binding (`find`, `outline`, `readSpan`, `listFiles`,
`roots`, static `applyChanges`, typed results) refuses a pre-2.0.0 library with
`ContractsVersionMismatchException`. `ss_status`, `ss_evidence` and RPC
`index_status`/`read_chunk` are scoped (a hidden file or chunk reads as
absent); a lost or damaged source section no longer fails the open (only
`read_span`/`outline` answer `CAPACITY`); the source section gets a sparse
line index at open (deep `read_span` p95 about 60-100 us to 2-3 us,
ReleaseSmall). `contracts/CONTRACTS_VERSION` 2.0.0. Native libraries rebuilt
(SOURCE-SHA256 `e30b9e9a...`; macOS 697,544 B); `ss_open` on the fixture 13.1
to 18.4 ms. The consumer app regenerates its contract types at its pin bump.
Verified and merged 2026-10-31. [Task](docs/tasks/S3-T4.md).

## S3-T3: roots, apply_changes, visible-scope statistics (2026-10-31)

A generation now holds several roots (`meta.roots`: `root_id`, `label`, `kind`,
`required_labels`, `retain_source`, `origin`); records are `root_id/relative`,
except `r-legacy` (the `index_folder` root), which keeps bare paths so existing
chunk ids and citations do not change. `apply.applyChanges` (core only; ABI,
CLI, Dart and RPC in S3-T4) applies host-fed `add | change | remove | move |
pending | remove_root` batches: strict `content_base64` or a `file` under a
declared local root (no symlinks, file reads opt-in), sha256 verified, caps of
10,000 changes and `max_total_bytes`, `expect_generation` first ("stale:
generation is M"), `conflicts`, rename detection with sorted pairing and
`ambiguous_moves`, `pending` dropping chunks, one atomic publication with
`INDEX-STATE.json` v2 written after it. `index_folder` is a walk over the same
path and its report is unchanged. BM25 statistics, prefix expansion and every
scoped core operation (`service.ScopedService`) see only the visible scope
(roots named and labels); a hidden label domain is indistinguishable from an
absent one in every payload (timing is not equal; disclosed in
`docs/authorization.md`). The unscoped C ABI/RPC `index_status` still report
whole-index counts until S3-T4. Measured on the 10k corpus: full index through
`apply_changes` 0.31-0.34 s, 145 MB (ReleaseFast); one changed file 168 ms
ReleaseFast, 220 ms ReleaseSmall (NFR-12 amended to ReleaseFast). Native
libraries rebuilt (SOURCE-SHA256 `6b7ae4fe...`). Verified and merged
2026-10-31. [Task](docs/tasks/S3-T3.md).

## S3-T2: positions, phrase, prefix, conjunctive words, snippets (2026-10-31)

`searchd index` (full and `--update`) now writes the lexical section as `HYBLEX02`
(80-byte header, a sorted dictionary, section 4 token ordinals delta-LEB128 per
posting, section 5 per-token codepoint offsets into the chunk text); the v2
manifest sets `has_positions`. `import-json` keeps `HYBLEX01` under its v1
manifest; both open. `find` (Zig core `zig/src/find.zig`, Python reference
`src/search_platform/find.py`) answers `words` (conjunctive, BM25), `phrase`
(adjacent ordinals within one chunk; a quoted query forces it) and `prefix`
(last token only, at most 1,000 visible expansions, else `CAPACITY`) with
`match_offsets`, snippets (at most 240 codepoints, `snippet_offsets`,
`snippet_start`), `exact_match`, `coverage`, per-file counts and a
generation-bound cursor ("stale cursor"); a `HYBLEX01` generation answers
`phrase` with `CAPACITY` "re-index required: positions absent".
`search_knowledge` is unchanged. Not yet on the ABI, CLI, Dart or RPC (S3-T4).
Measured on the 10k corpus: `HYBLEX02` 1.39x `HYBLEX01`, phrase p50 about 18 us,
words about 5 us (ReleaseFast), index peak RSS 266 to 118 MB. Native libraries
rebuilt (SOURCE-SHA256 `eea716c6...`). Format: `docs/lexical-segment-format-v2.md`;
tables: `docs/scale-benchmark.md`. Verified and merged 2026-10-31. [Task](docs/tasks/S3-T2.md).

## S3-T1: manifest v2, md-section-v1, records v4, retained source (2026-10-31)

`searchd index` / `ss_index_folder` now publish manifest v2 (`HYBMAN02`, 104-byte
header binding a third section and a `meta` JSON with `chunkers[]` and one
`r-legacy` root), document records v4 (`chunker_index`, `section_path`,
`heading_line`, `source_doc_index`) and a source section `source-N.hybsrc`
(`HYBSRC01`: every indexed file's original bytes with delta-coded line maps).
`.md`/`.markdown` files are chunked by `md-section-v1` (front matter out of the
body, ATX/Setext headings, fences kept whole when they fit); everything else
keeps `line-window-v1`, whose golden is unchanged. `read_span` (byte-exact, 400
lines / 256 KiB) and `outline` exist in the Zig core and the Python reference
only (CLI/ABI/Dart/RPC in S3-T4); without a source section both answer
`CAPACITY` "re-index required: source absent". `import-json` still writes v1/v3.
v1 generations open; `--update` over one re-chunks Markdown and publishes v2.
Measured on the 10k corpus: generation 16,127,845 to 26,553,935 bytes (source
1.14x the text), index 0.37 to 0.42 s. Native libraries rebuilt (SOURCE-SHA256
`9ba263a2...`). Formats: `docs/manifest-format-v2.md`, `docs/segment-format-v4.md`,
`docs/source-section-v1.md`. Verified and merged 2026-10-31. [Task](docs/tasks/S3-T1.md).

## S3-T7: family-folder fixture and frozen judgments (2026-10-31)

`fixtures/family-folder/` (three roots, 42 files, 34 Markdown, one 1.1 MB file, all
invented) and `judgments.json` version 2 (the 13 UC-007 scenarios plus five phrase,
five prefix, five outline and eight `read_span` cases) are frozen as the oracle for
S3-T1..T6. `fixtures/family-folder/generate.py` writes the files, the judgments and
the README deterministically. `python3 scripts/relevance_smoke.py --pack family-folder`
runs what the Python reference can answer today and counts the rest as skipped; CI runs
it. No engine behaviour changed.
Verified and merged 2026-10-31 (round 2; round 1 rejected on the `read_span` sha256 convention, now from the start of `start_line` to the start of the line after `end_line`); front-matter-only matches are expected engine misses (Post-build ruling 2). [Task](docs/tasks/S3-T7.md).

## Directory search audit and filename design (2026-10-25)

The current Python/native Zig engines search supported UTF-8 document **body
content** and return stored paths/line citations. Filenames are metadata, not
indexed search terms. (Superseded: the opt-in filename channel is implemented, PR #21
integrated by [S4-T2](docs/tasks/S4-T2.md).) PDF/Office/OCR require external extraction; HTML is read as
source text. Quoted queries do not enforce phrase order or adjacency.

[CAP-16 / FR-16](docs/requirements/cap-16-directory-filename-search.md),
[UC-006](docs/use-cases/uc-006-directory-filename-search.md) and the
[DS-00–DS-05 task split](docs/tasks/directory-search.md) propose an independent
file-level lexical field over the existing engine. Current defaults, body
postings, formats, contracts and shipped libraries are unchanged. The initial
SQLite suggestion is superseded by the actual native-index audit. The design
claim is [#15](https://github.com/ilamgumaran/search-simpli/issues/15).

Baseline main `9c3265a` passes 176 Zig tests, 16 ABI checks, 97 Python tests
with 4 skips, native CLI build and the 4-query relevance mechanics gate. The
repeatable invented-directory diagnostic verifies content/citations and explicit
refresh, while recording filename misses and phrase limitations. No real-folder
relevance, device performance or filename implementation is claimed.
DS-01 exact format/fixture freeze and final named maintainer step-6b approval
are required before the new runtime capability is built. Existing SQ-02,
E-01A/CAP-14, S1-T9 owner review and PR #11 equipped-Mac integration retain their
separate gates; none is completed by this design/probe.

## Standalone platform plan (2026-09-13)
ADR 0002 and `docs/tasks/S1-T*.md`: C ABI + libraries, native indexing with a Unicode analyzer, standalone CLI, Dart FFI binding, incremental folder indexing. The family app (`simpli-helper`, M12-T0) then replaces its Dart port with the core.

## Proposed search quality work (2026-10-19, documentation only)

SQ-01 now has a [concrete E-02 design candidate](docs/requirements/cap-11-e02-negative-evaluation.md)
under [claim #13](https://github.com/ilamgumaran/search-simpli/issues/13): strict
v3 labels, exact metric arithmetic, trusted visibility and versioned profiles.
This is documentation only; SQ-02 remains pending named maintainer approval over
the final spec. [Recovery integration handoff](docs/tasks/recovery-pr11-integration.md)
records why PR #11 still needs the equipped Mac before merge. Planning PR #12
is merged as `89fadce`; that merge did not land the recovery fix.

The [quality review and design](docs/search-quality-plan-2026-10.md) and
[SQ-01–SQ-10 task breakdown](docs/tasks/search-quality-follow-ups.md) extend the
existing backlog: negative evaluation first, per-query/segment gates, an approved
real-folder baseline, then measured fusion and Unicode parity/migration. The
persisted 384-d benchmark remains the scale gate. SQ-01's design is claimed as
noted above; no implementation task is claimed or built.
E-01A/CAP-14 approvals and the recorded S1-T9 owner sequencing remain pending.
The review used main `7c40937` and a separate Sol audit; no new benchmark was run.
Recovery [PR #11](https://github.com/ilamgumaran/search-simpli/pull/11) remains open
as checked on this date. Its separate use of S1-T21 must be reconciled before
landing; main's S1-T21 below is the iPhone task, not the recovery fix.

## The iOS framework page-aligned as built (S1-T22, 2026-10-22)

**S1-T22 is `verified` and merged to `main` (2026-10-22, Xcode Mac verifier Opus 5.5).** The app (M8-T5) found the Zig-linked iOS dylib's `__TEXT`, `__DATA_CONST` and `__DATA` sizes not multiples of the 16 KiB page, which iOS code signing refuses on the phone; the app rounded them itself. Now `tool/build_native.sh` links `native/ios-arm64/search_simpli.framework/search_simpli` with Apple's linker from the iPhoneOS SDK over the Zig-built static library (way (b); Zig 0.16's Mach-O linker has no option for it, measured), and `tool/check_native.sh` checks every segment. [Task and Report](docs/tasks/S1-T22.md).

- **Build** (Xcode Mac, by hand; CI is Ubuntu only and never builds iOS): `source ~/development/env.sh`, then in `bindings/dart/search_simpli`: `tool/build_native.sh` (runs `zig build lib -Doptimize=ReleaseSmall --summary all` in `zig/`, then for iOS: `ar x zig-out/lib/aarch64-ios/libsearch_simpli.a` into a temporary directory, `xcrun --sdk iphoneos clang -target arm64-apple-ios17.0 -dynamiclib <objects> -install_name @rpath/search_simpli.framework/search_simpli -compatibility_version 1.0.0 -current_version 1.0.0 -Wl,-dead_strip -Wl,-no_adhoc_codesign`, exports checked equal to the macOS dylib's `_ss_*` set). `zig/build.zig` bundles compiler_rt into the iOS static library only.
- **Check:** `tool/check_native.sh` → `check_native: ok (macos-arm64, android-arm64, ios-arm64 framework; 4 segments 16 KiB aligned)`. Every segment's `fileoff`, `vmsize`, `filesize` a multiple of `0x4000`; `__LINKEDIT`'s filesize exempt (it ends the file, unrounded, in Apple-linked iOS dylibs too).
- **Binary:** 430688 B, sha256 `8364159c89f5e100393a1de0d3d136804425c20fcf97894264ba34214a1cdfff`; `__TEXT` 0/0x58000/360448, `__DATA_CONST` 360448/0x4000/16384, `__DATA` 376832/0x44000/16384, `__LINKEDIT` 393216/0xc000/37472 (fileoff/vmsize/filesize). Platform IOS, minos 17.0, arm64, unsigned, install name unchanged. macOS dylib and Android `.so` byte-identical. `native/SOURCE-SHA256` `c4e153af932dec77ef8282f0ee788395d9b67a5b9292de999a4422ecf943cbc9` (moved: `zig/build.zig` changed, and since the verifier's edit `tool/source_digest.py` also digests `tool/build_native.sh`, whose link flags shape the iOS binary).
- **Verify** (exact commands): `cd ~/workspace/repos/search-simpli && git fetch origin && git worktree add -b verify/S1-T22 ~/workspace/repos/search-simpli-wt/verify-S1-T22 origin/main`, `git merge --no-ff origin/task/S1-T22`; `source ~/development/env.sh`; in `bindings/dart/search_simpli`: `tool/build_native.sh` (exit 0, tree unchanged), `tool/check_native.sh` (ok); plant: `cp ../../../zig/zig-out/lib/aarch64-ios/libsearch_simpli.dylib native/ios-arm64/search_simpli.framework/search_simpli && tool/check_native.sh` (FAIL lines for `__TEXT`, `__DATA_CONST`, `__DATA`, exit 1), `git checkout` it back; in `zig/`: `zig build test -j2 --summary all`, `zig build test-abi -j2 --summary all`; at the root: `python3 -m unittest discover -s tests`, `python3 scripts/check_requirements.py`, `python3 scripts/check_no_home_paths.py`; in the package: `dart test`, `dart analyze lib test`. [Verdict](docs/tasks/S1-T22.md).
- **Suites (on the merge):** Zig 176/176, ABI 16/16, Python 101 (one new digest test), Dart 61/61.
- **App follow-up (its own task):** re-pin `packages/vizhi_core/pubspec.yaml` to this task's merge sha and `searchSimpliCoreIdentity` (`packages/vizhi_core/lib/src/search/engine/core_identity.dart`) to `c4e153af932dec77ef8282f0ee788395d9b67a5b9292de999a4422ecf943cbc9`; delete the rounding step in `tools/ios/bundle_native_libs.sh` (the alignment test in `ios_bundle_test.dart` stays as the guard); republish once.

## The search core for the iPhone (S1-T21, 2026-10-18)

**S1-T21 is `verified` and merged to `main` (2026-10-18, Xcode Mac verifier Opus 5.5).** The iOS library is built on the Xcode Mac by hand (`tool/build_native.sh`); CI (Ubuntu only) never builds it. `zig build lib` now builds `aarch64-ios` (iPhoneOS SDK through a libc paths file; one skip line without Xcode); `tool/build_native.sh` wraps it as `native/ios-arm64/search_simpli.framework` (arm64, iOS 17.0, unsigned, install name `@rpath/search_simpli.framework/search_simpli`); `tool/check_native.sh` checks the three shipped binaries and the plist; the Dart loader opens `search_simpli.framework/search_simpli` on iOS. Zig 176/176, ABI 16/16, Python 100, Dart 61/61. The app embeds and signs the framework in its task M8-T5. [Task and Report](docs/tasks/S1-T21.md).

## NoFreeGeneration names every trace (S1-T20, 2026-10-15)

**S1-T20 is `verified` and merged to `main` (2026-10-15, Xcode Mac tester Opus 5.5; merge `15d2c8e922d1459e3820cdc81c49596019959702`).** Built in the owner's Codex cloud session on 13–14 Oct (branch `task/S1-T20`, stacked on S1-T19; [claim issue #9](https://github.com/ilamgumaran/search-simpli/issues/9); no PR). It closes the S1-T18 Verdict findings 1 and 2. [Task, rulings and Verdict](docs/tasks/S1-T20.md). No device deployment performed.

- **One line, every trace.** At an exhausted `u64` generation, `searchd index` (full or `--update`) exits 1 with empty stdout and one stderr line listing every canonical trace at the top number, in the fixed order `MANIFEST`, `INDEX-STATE.json`, `documents-N.hybseg`, `lexical-N.hyblex`, file names only: `error: NoFreeGeneration: no generation number above 18446744073709551615 (traces: MANIFEST, INDEX-STATE.json, documents-18446744073709551615.hybseg, lexical-18446744073709551615.hyblex); use a fresh output directory; inspect listed traces before repair`. `ss_index_folder` puts the same text in `ss_last_error` after `ss_index_folder: `. Lower generations, leading-zero or malformed names and directories found by the scan are not listed. The S1-T18 advice "delete or rename that file" is withdrawn; `docs/generation-lifecycle.md` says what the line lists and that a fresh output directory works. The failed call leaves every snapshot file byte-identical. Numbering rule unchanged.
- **How.** `generation_alloc.zig` keeps a thread-local four-bit mask and the top number, reset at each scan, no second scan or allocation; the longest list is 102 bytes in a 160-byte buffer, the line 245 bytes.
- **Evidence on this Mac.** Zig 176/176, C ABI 16/16, Python 100 (no skips), Dart 57/57 with clean analysis before and after the rebuild, relevance mechanics passed, privacy and requirements checks clean. Plants in fresh-cache scratch copies: the parent diagnostic fails 3 Zig tests and the 2 new CLI tests; a no-op reset fails 3; non-thread-local cause variables fail the ABI thread-isolation assertion. GitHub: the push of `verify/S1-T20` triggered no run (the workflow runs on pull requests and on pushes to `main`); the push of the merge ran [38840149959](https://github.com/ilamgumaran/search-simpli/actions/runs/38840149959): completed / success, head `15d2c8e`, jobs `checks` and `native-linux` both success in every step.
- **Libraries.** macOS dylib 435048 B `23f4bd5de00579ccac19d451e812855741634753b035742e4566d9e4d2ef47ba` (byte-identical to the cloud's); Android arm64 427760 B `9c9461fbbbc83ac30511fb15dd8bfea1659a378b457282a16a6355ac788a6c5d` (this Mac's rebuild, and its identical example copy); source stamp `f12cb3d3cc7a493d508c8934c595cc55053084271599191805f09e9753ce1802`. Contract `1.2.0` unchanged.
- **Carried (Verdict findings).** With traces at `u64` max − 1, a directory or symlink with an exact canonical name at max is named by the post-scan overflow branch, though the scan excludes it (ruling 2: a finding); the million-attempts fallback reports the scan's top number; literal mask values in the formatter.
- **Next.** The app (`simpli-helper`, `packages/vizhi_core/pubspec.yaml`) re-pins to `15d2c8e`. S1 is idle until the owner reads S1-T9.

## Linux native validation (S1-T19, 2026-10-13; merged 2026-10-15)

**S1-T19 is `verified` and merged to `main` (2026-10-15, Xcode Mac tester, round 2).** Built in the owner's Codex cloud session on 13 Oct (branch `task/S1-T19`, runtime/artifact `90f57673b94c2271063c94856a2a537e067dc609`, based on main `b722c45`; [PR #8](https://github.com/ilamgumaran/search-simpli/pull/8), [ownership issue #7](https://github.com/ilamgumaran/search-simpli/issues/7)). Round 1 on this Mac was rejected because the harness's `_POSIX_C_SOURCE` line hid `mkdtemp` on macOS; the round-2 harness fix (`c67ca44`, `zig/tests/abi_test.c` only) also defines `_DARWIN_C_SOURCE` on Apple. The packaged Android library that merged is this Mac's rebuild. [Task, rulings and both Verdicts](docs/tasks/S1-T19.md). No device deployment performed.

- **Fixed publication on Linux/Android.** Zig 0.16 opens non-iterable directory handles with `O_PATH`; the old `fsync` call returned `EBADF`. Reopening `.` with iteration enabled gives a readable descriptor for the same directory. Both durability barriers sync it and close it on every exit. macOS behavior and genuine error propagation are preserved.
- **Native CI gate.** A separate Ubuntu 24.04 job downloads checksum-verified Zig 0.16.0, runs existing engine/C ABI tests and the Python process suite without the native opt-out. The Python-only job remains. The C harness now declares its POSIX APIs under C11 on Linux and macOS (`_POSIX_C_SOURCE` plus, on Apple, `_DARWIN_C_SOURCE`).
- **Local evidence.** Zig 173/173, C ABI 16/16, Python 94 pass/4 skip, Dart 57/57 plus clean analysis, relevance mechanics 4/4. The old-call plant fails the existing real-directory regression. Injecting a real `fsync` EIO at the final barrier exits 1 while retaining a queryable complete generation and closing the descriptor. See the task for exact outputs and skips. GitHub-hosted CI status is recorded there separately.
- **Matching libraries.** macOS stays byte-identical (434888 B, `4f8f9044…`); Android rebuilt (427152 B). The merged Android library (and its identical example copy) is the Xcode Mac's rebuild, `4c8476c5…`; the cloud's `e6920eb9…` differed only in 2 bytes of the NDK toolchain comment string. Source stamp `276e7bae…`; contract 1.2.0 unchanged. Linux Dart checks use a fresh default-loader library outside Git; this is not macOS/Android device evidence.
- **Resume.** Read the task and live queue before new work. Use Zig 0.16.0, Dart 3.13.2 and NDK r28c for these checks. Unset `SEARCH_SIMPLI_LIBRARY_PATH`, `SEARCH_SIMPLI_NO_ZIG`, and `SEARCHD_BINARY` so the process tests build the current CLI and bindings use the matching library. Run `dart --suppress-analytics pub get --no-example` for the standalone package; the Flutter example requires its own SDK. Regenerate shipped libraries with `tool/build_native.sh` after native source changes.

## Standalone platform status (S1-T18, 2026-10-10)

**S1-T18 is `verified` and merged to `main`** (branch `task/S1-T18` `417ed00`; Verdict in `docs/tasks/S1-T18.md`). The contract is unchanged (`1.2.0`), with no ABI change.

- **`NoFreeGeneration` names its cause.** `searchd index` (full or `--update`) prints one line naming the file that supplied the top number (file name only) and that number, then exits 1: `error: NoFreeGeneration: no generation number above 18446744073709551615 (read from lexical-18446744073709551615.hyblex); delete or rename that file to publish here`. `ss_index_folder` puts the same text in `ss_last_error` (prefix `ss_index_folder: `), and the Dart `SearchSimpliException` carries it. The numbering rule of S2-T14 is unchanged.
- **Dart:** the public `SearchSimpli.indexFolder(dirPath, folderPath, {options, library})` is back to its pre-S2-T14 signature. The counting-allocator seam is `indexFolderWithAllocator` in `lib/src/search_simpli_base.dart`, not exported; the leak test imports it from `src/`.
- **Libraries:** dylib 434,888 B `4f8f9044…`, `.so` 427,008 B `fa4faf44…`, stamp `9d1813e5…`.
- **Open (non-blocking):** Verdict finding 1: when several files carry the top number, only the first is named, and "delete that file" does not get a publish through. Findings 2-4 are a doc sentence, an unreachable exit and cosmetics.

## Standalone platform status (S2-T14, 2026-10-10)

**S2-T14 is `verified` and merged to `main`** (branch `task/S2-T14` `ed41c86`; Verdict in `docs/tasks/S2-T14.md`). The contract is unchanged (`1.2.0`), with no ABI change.

- **Self-numbered generations never go backwards.** `generation_alloc.nextFreeGeneration` is the one place: `ss_index_folder`, `searchd index` without `--generation`, and every `--update`. It starts above the highest of the `MANIFEST`'s generation, every canonical section file present (complete or not) and `INDEX-STATE.json`'s generation. A lost `MANIFEST` with only generation 2 on disk now publishes 3 (was 1). Generation 2 is superseded, and `keep_generations` prunes it after the new `MANIFEST`. At `u64` max the publish fails with `NoFreeGeneration` (was a CLI panic, and `GenerationZero` in the shipped library).
- **Dart:** `SearchSimpli.indexFolder` encodes its options before any native string, so nothing leaks on the `ArgumentError` path. New optional `Allocator allocator = malloc` parameter, for tests.
- **Caller-numbered publishes are not checked** (`ss_import_json`, `--generation`). A free lower number is published as given, and a taken one fails with `PathAlreadyExists`; `generation-lifecycle.md` now says so. After a lost `MANIFEST`, the app's `ss_open`-based numbering gets stuck on `PathAlreadyExists` (Verdict finding 1, for M12-T10).
- **Libraries:** dylib 434,696 B `bdcd6fe1…`, `.so` 426,192 B `30c6a4a8…`, stamp `b2cf76ee…`.
- **Open (non-blocking):** Verdict findings 2-6: a huge trace blocks numbering; the public `allocator` seam; the free-pair loop has no test; "an arena is fine"; `--update` ignores `--generation`.

## Standalone platform status (S1-T17, 2026-10-10)

**S1-T17 is `verified` and merged to `main`** (branch `task/S1-T17` `c30d74b`; Verdict in `docs/tasks/S1-T17.md`). The contract is unchanged (`1.2.0`), the analyzer id stays `analyzer-v2`, and no output moved (`nfc_compare.py` 0, goldens identical).

- **The NFC timing test now guards `compose` itself.** `zig/src/nfc_timing_test.zig` gains a second family: one line of decomposed jamo with no spaces (a single region of 256 KB and 1 MB) against the same jamo with a space after each triple; growth below 5x and at most 2x the twin. With the old shifting `compose` put back it fails at 15.8-16.0x (the S1-T16 line alone did not catch that); on `main` it passes at 3.77-4.13x at rest and under load.
- **Comments:** `nfc.zig`'s header (syllables are kept whole since S1-T16), the U+D55C test comment (an LVT syllable), `gen_nfc_timing.py`'s docstring; `gen_nfc_timing.py DIR --jamo` writes the jamo lines.
- **Libraries:** the same bytes as S1-T16's (dylib 434,728 B `f46b91ef…`, `.so` 425,904 B `b5f9932e…`); the stamp moved with the comment change: `477e39a3…`.
- **Open (non-blocking):** comment nits for the next task that touches these files (the timing test's syllable-twin sentence; 9 of 27 T jamo in the line; `gen_unicode_tables.py`'s docstring still says Hangul decomposition). From S1-T16, still open: `canonicalOrder` on long runs of stacked marks.

## Standalone platform status (S1-T16, 2026-10-10)

**S1-T16 is `verified` and merged to `main`** (branch `task/S1-T16` `9bc2297`; Verdict in `docs/tasks/S1-T16.md`). The contract is unchanged (`1.2.0`), and the analyzer id stays `analyzer-v2`: NFC output is byte-identical to before, and no golden, captured output or index moved.

- **NFC is linear in the text length.** `compose` works in place with a write cursor (no `orderedRemove`); precomposed Hangul syllables are no longer decomposed and recomposed; the slow path normalizes only the regions around non-ASCII, non-syllable codepoints and copies the rest. A 1 MB Korean line with one mark: 11.7 s → 2.2 ms (the same line without the mark: 2.2 ms); `searchd index` on it 13.2 s → 35 ms. One 1 MB line of precomposed French: 5.9 s → 40 ms.
- **Unchanged output, checked:** `scripts/nfc_compare.py` 0 of 1,136,505; the tester's own oracle, 931,699 edge-targeted strings × 2 seeds, 0 differences from Python and from the previous code; the new `scripts/nfc_random_compare.py` 0.
- **New:** `zig/src/nfc_timing_test.zig` (growth 256 KB → 1 MB below 5×, and the line with a mark at most 2× its mark-free twin, in one run; fails with the old code at 15.5×), `zig/src/nfc_bench.zig`, `scripts/gen_nfc_timing.py`, `scripts/nfc_random_compare.py`, and four Tamil blocking cases in `nfc_compare.py`.
- **Libraries:** dylib 434,728 B (`f46b91ef…`), `.so` 425,904 B (`b5f9932e…`), stamp `8afa730e…`.
- **App:** re-pin when convenient; nothing to republish (output identical), only faster.
- **Open (non-blocking):** the timing test guards the Korean line but not `compose` on a long single region (the old `compose` alone passes it); add an NFD-jamo line with no spaces. `canonicalOrder` is still quadratic within one run of stacked marks (crafted input only: 64 KB, 0.8 s). Plant runs outside a worktree need fresh Zig cache dirs: the global cache once served the tester another directory's test binary.

## Standalone platform status (S1-T15, 2026-10-10)

**S1-T15 is `verified` and merged to `main`** (branch `task/S1-T15` `89da8c7`; Verdict in `docs/tasks/S1-T15.md`). The contract is unchanged (`1.2.0`), and the analyzer id stays `analyzer-v2`: no golden, captured output or snapshot of the fixtures moved.

- **Zig's NFC is complete.** Singleton decompositions (CJK compatibility ideographs, U+212B, Greek oxia letters) and Hangul composition are in; two-part vowels whose second part is a starter (Tamil `U+0BC6 U+0BBE`) now compose even when nothing else in the text needs normalizing, and a mark between a starter and a class-0 second now blocks them. Zig equals Python's `unicodedata` NFC on every codepoint (`scripts/nfc_compare.py`: 23,422 cases differed, now 0) and on 220,000 random strings of the tester's own.
- **Variation selectors are dropped from tokens** in Zig and Python: `1️⃣` is `1`, and `a`+FE0F+`b` is `ab`.
- **Libraries:** dylib 434,776 B (`609a1090…`), `.so` 425,760 B (`c0afbd66…`), stamp `817b1f70…`.
- **App:** re-pin when convenient. Snapshots change only for text with Hangul, CJK compatibility ideographs, variation selectors, other singletons, or a two-part vowel written decomposed in a chunk without any other mark. A Tamil query typed with a decomposed `ொ` now finds the precomposed text with no republish.
- **Open (non-blocking):** the NFC composition step is quadratic, and it now reaches Korean that takes the slow path (256 KB on one line 11 ms → 1.1 s); fold it into S2-T11's "linear NFC step" candidate. The casefold gap (104 letters with multi-codepoint folds) is documented in `docs/python-zig-bridge.md`, for its own task. `NormalizationTest.txt` has not been run.

## Standalone platform status (S1-T14, 2026-10-10)

**S1-T14 is `verified` and merged to `main`** (branch `task/S1-T14` `dc18bd3`; Verdict in `docs/tasks/S1-T14.md`). The contract is unchanged (`1.2.0`), and the analyzer id stays `analyzer-v2`.

- **Tamil words stay whole.** An `analyzer-v2` token is now a run of letters and digits together with the combining marks (Mn/Mc) and inner ZWJ/ZWNJ attached to them. `கணினி` was `கண`, `ன` and is now one token. Zig and the Python reference read the same generated mark table, and Python now applies NFC first.
- **Absent words match nothing.** 12 judged absent Tamil words had hits on 11 queries (106 hits) and now have 0; the existing Tamil set stays at success@1 1.00.
- **ASCII and precomposed Latin are byte-identical:** chunk golden, BM25 `app_text`, 2,732 of 2,762 captured `ss_query` outputs (the 30 others are Tamil), and published snapshots.
- **Libraries:** dylib 418,440 B (`aa748b65…`), `.so` 412,880 B (`70f94615…`), stamp `eead6954…`.
- **App:** re-pin, then **republish every snapshot once**. A Tamil snapshot published by the previous library answers nothing under the new one (success@1 0/10), because the id did not change.
- **Open (non-blocking):** Zig's NFC skips singleton decompositions and Hangul recomposition, which Python's new NFC now exposes (1,020 codepoints, no fixture). Thai, Khmer and Chinese are one run per space-delimited stretch. Tamil matches exact forms only. `import_parity.py` still generates fragment queries for Tamil.

## Standalone platform status (S2-T11, 2026-10-08)

**S2-T11 is `verified` and merged to `main`** (branch `task/S2-T11` `6ee394f`, merge `54bea4c`; Verdict in `docs/tasks/S2-T11.md`). The contract is unchanged (`1.2.0`). **Series S2 is closed:** S2-T1..T5 and S2-T11..T13 are on `main`, and S2-T14 is ready.

- **A query can no longer hang.** `ss_query` checks `query_text` as UTF-8 before any analysis, in every mode and analyzer. Invalid text returns `NULL` with `ss_query: query_text is not valid UTF-8 (SS_ERR_INVALID_ARGUMENT)`. Before this, an `analyzer-v2` snapshot looped forever, and an `ascii-alnum-v1` snapshot echoed `query` as a byte array.
- **The same check everywhere.** `Engine.queryTraced` repeats the check, and `nfc.normalize` validates, so the analyzer ends on any byte string. `searchd query`/`evidence` exit 2 with one line. `serve` answers `-32700` and keeps serving.
- **Valid queries are byte-identical** to the previous library (capture with profile off and on).
- **Libraries:** dylib 418,232 B, stamp `a9ea4c22…7b8e`.
- **Open (non-blocking):** the `rpc.zig` `-32602` guard is unreachable through JSON and untested. Dart turns lone surrogates into U+FFFD rather than erroring. `analyzer-v2` query time grows quadratically with non-ASCII length (13 s for 1 MB, older than this task).

## Standalone platform status (S2-T13, 2026-10-08)

**S2-T13 is `verified` and merged to `main`** (branch `task/S2-T13` `56432cf`; Verdict in `docs/tasks/S2-T13.md`). The contract is unchanged (`1.2.0`).

- **What a valid vector is.** Every component is finite, and the sum of squares accumulated in `f32` does not overflow (norm below about 1.8e19). All zeros is valid.
- **Query.** `ss_query` returns `NULL` with `ss_query: invalid query vector: … (VectorNormNotFinite)` for an invalid vector in vector, hybrid and default mode. `serve` answers `-32602`. Lexical mode does not read the vector and still reports `vector_ignored`.
- **Import.** `ss_import_json` returns `SS_ERR_INVALID_ARGUMENT` and `searchd import-json` exits 1 for an invalid document vector. Nothing is published either way.
- **Cosine.** It is bit-identical for every valid pair. It falls back to a clamped `f64` only when the `f32` sums overflow, which only snapshots imported before this task can contain; there it replaces `NaN` and `0` with the true cosine.
- **Libraries:** dylib 418,168 B, stamp `861bb2c6…6aad`.
- **Open (non-blocking):** no unit test covers the `serve` check. The `f32` cosine is inaccurate for vectors with norm below about 1e-19 (unchanged). The all-zero vector still gets no warning.

## Standalone platform status (S2-T4, 2026-10-08)

**S2-T4 is `verified` and merged to `main`** (branch `task/S2-T4` `6428d3e`, second round; Verdict in `docs/tasks/S2-T4.md`). **The contract is now `1.2.0`.**

- **What the `ss_query` report carries.** It always has `warnings` (`{code, message, term?}`) and `request` (`analyzer_id`, `retrieval_mode`, `top_k`, `candidate_k`, `path_prefix` as used, defaults filled in). With `"profile": true` it also has `profile` (`tokenize_us`, `score_us`, `rank_us`, `serialize_us`, `matched_chunks`). The three keys come after `answer_policy`, and removing them gives the previous output byte for byte.
- **The four codes.** `query_term_unmatched` holds the analysed query term (lowercased under `ascii-alnum-v1`, folded under `analyzer-v2`), once per term, in query order. It uses one message whether the word is absent or only in chunks outside `path_prefix` or the caller's labels. `query_empty_after_analysis`. `vector_ignored`. `candidate_depth_cut` appears only in hybrid with both channels offering candidates. `matched_chunks` counts in-scope chunks only. Vector mode reports no term warnings. `serve` and the CLI carry none of the new keys.
- **The app re-pins once to this merge commit or later** (the commit that adds this entry). Its contracts pin becomes `1.2.0`, or `SearchSimpli.open` throws `ContractsVersionMismatchException`. The Dart types are `SearchWarning`, `SearchWarningCode` (with an `unknown` fallback), `SearchRequestEcho`, `SearchProfile`, and `query(profile: ...)`.
- **Libraries** (rebuilt on the merge with S2-T2 and S2-T12): dylib 418,200 B, stamp `0d0c2a08…9f19`.
- **Open (non-blocking):** with `profile` on, a word hidden in thousands of chunks shows in `tokenize_us`/`score_us`. Its wall-time cost was already visible before this task. Candidate for `docs/authorization.md` "Known limits". `analyzer-v2` does not fold U+1E9E. There is no `--json` parity for `serve`/CLI.

## Standalone platform status (S2-T2, 2026-10-08)

**S2-T2 is `verified` and merged to `main`** (branch `task/S2-T2` `7f69688`, second round; Verdict in `docs/tasks/S2-T2.md`).

- **The app's import door is now linear-time.** `ss_import_json` / `searchd import-json` with `ascii-alnum-v1` build through `lexical_build.buildAscii` (one hash-map pass) instead of `postings.build`: 10k documents import in ~0.2 s (was ~110 s), 1k in ~0.04 s (was ~12.5 s).
- **Byte-identical output.** The published files and the query results are the same as the old build's (`import_parity.py --baseline` 10/10; 218 CLI queries and 654 `ss_query` calls at 1k, 0 differences; `diff -r` empty at 1k and 10k). No contract change.
- **Plant:** `zig/src/import_build_timing_test.zig` checks the growth from 125 to 1,000 documents (interleaved runs, best of five, `< 24x`). It gives 7.1 to 8.1x under load and about 51x on the old build.
- **Libraries:** dylib 417,464 B, stamp `788f5e3f…2bba`.

## Standalone platform status (S2-T12, 2026-10-08)

**S2-T12 is `verified` and merged to `main`** (branch `task/S2-T12` `2df286b`; Verdict in `docs/tasks/S2-T12.md`).

- **No empty generation after a lost `MANIFEST`.** If `MANIFEST` is missing, `--update` / `ss_index_folder` update mode no longer loads `INDEX-STATE.json`. It re-indexes every file, publishes a full generation and reports `"recovered": "missing_manifest"` when a state file was present. A fresh directory reports no `recovered`. With `keep_generations`, pruning runs only after the full generation is published.
- **Dart:** `IndexFolderOptions.keepGenerations` (checked at use: `ArgumentError` below 1, before any native call); `IndexFolderReport.recovered` (`IndexRecovery`, with an `unknown` fallback), `recoveredRaw`, `prunedFiles`, `pruneFailures`.
- **Libraries:** dylib 417,496 B, stamp `7c21ea77…d496bb`.
- **Open (non-blocking):** generation numbers can go backwards after a lost `MANIFEST` (older than this task); the Dart `indexFolder` leaks two small native strings on the `ArgumentError` path.

## Standalone platform status (S2-T5, 2026-10-08)

**S2-T5 is `verified` and merged to `main`** (branch `task/S2-T5` `41a0186`, second round; Verdict in `docs/tasks/S2-T5.md`).

- **Directory sync.** Every publish path (`index`, `index --update`, `import-json`, `ss_index_folder`, `ss_import_json`, `init-demo`) now fsyncs the directory after the section renames and again after the `MANIFEST` rename. If the first sync fails, `MANIFEST` is untouched and the new sections are removed. If the second fails, the error is returned and nothing is deleted.
- **`keep_generations: N`** (opt-in, N >= 1). It is set through `ss_index_folder`'s options, a top-level field in the `ss_import_json` payload (a publication option, not snapshot content; the contract stays `1.1.0`), and `--keep-generations` on the CLI. After a successful publish it deletes generations older than the newest N, and only complete generations count toward N. Reports then carry `pruned_files`/`prune_failures`.
- **`"recovered": "missing_section"`** (additive). An `--update` whose `MANIFEST` names a missing or unreadable section re-indexes every file instead of publishing an empty generation.
- **`lifecycle.scan`** now separates `superseded_*` from `orphan_*`.
- **Libraries:** dylib 417,496 B, stamp `a80c90b9…ef55`.
- **Open (non-blocking):** with `MANIFEST` missing but `INDEX-STATE.json` present, `--update` still publishes an empty generation (older than this task). The Dart wrapper does not yet expose `keepGenerations` on `IndexFolderOptions` or `recovered` on the report.

## Standalone platform status (S2-T1, 2026-10-08)

**S2-T1 is `verified` and merged to `main`** (branch `task/S2-T1` `ff8a902`; Verdict in `docs/tasks/S2-T1.md`). `ss_import_json` / `searchd import-json` now accept `"analyzer_id": "analyzer-v2"`. They build the same index `searchd index` builds from the same chunks: 33/33 published files are byte-identical, and 814/814 full ranked lists are identical over 11 corpora. `ascii-alnum-v1` imports are byte-identical to before (21/21). The Tamil fixture through import is success@1 0.00 → 1.00.

**The contract is now `1.1.0`.** The schema's `analyzer_id` is an `enum`; `ss_version()` and the Dart `expectedContractsVersion` are `1.1.0`. The shipped libraries were rebuilt: dylib 382,328 B `94915340…`, `.so` 383,840 B `406ea699…`, stamp `a55edf92…3e3b`. The package also exports `SnapshotInterchangeV1` / `InterchangeAnalyzer`.

**What the app must change:**
1. Send `analyzer-v2` (its `SnapshotInterchangeV1` hard-codes `ascii-alnum-v1`).
2. Re-pin the core to this `main` or later; its contracts pin becomes `1.1.0`, or `SearchSimpli.open` throws `ContractsVersionMismatchException`.
3. Republish once, so on-device snapshots stop being ASCII-only.

## Standalone platform status (S2-T3, 2026-10-08)

**S2-T3 is `verified` and merged to `main`** (branch `task/S2-T3` `26f959e`, merged over `dde0f15`; Verdict in `docs/tasks/S2-T3.md`). A query now ranks only the chunks that matched. It uses a bounded top-`candidate_k` heap per channel and fuses over the union with the same `document_index` tiebreak. The semantic pass is skipped in lexical mode and for zero-dimension snapshots, and `ss_query` no longer allocates anything per chunk. Output is byte-identical to the dense path: 43,154 tester `ss_query` calls (fixtures, tie-heavy snapshots, labels, prefixes, depths around the matched-set size, hybrid at 10k), 2,784 `searchd serve` requests and 18 CLI runs. Lexical p50 at 10k chunks is 0.016–0.61 ms, down from 9–13 ms; hybrid at 10k is 0.37 ms, down from 9.4 ms. `tests/test_query_latency.py` guards it, using best-of-five, 10k/1k growth ≤ 8 and 10k p50 ≤ 2 ms. The dense `Engine.query`/`hybrid.search*` stay as the reference oracle. `Engine.queryTokenized`, `Service.searchKnowledge` and `rpc.Workspaces` lost their lexical-score buffer. The merge also updated S2-T1's `import_analyzer_test.zig` call. **Suites on the merge:** `zig build test` 116/116, `test-abi` 12/12, `lib` 15/15 with the NDK, Python 82, `dart test` 35. The libraries were rebuilt (dylib `b3e08379…`, stamp `a7583d1e…`). **Open (non-blocking):** NaN cosine scores (only from vectors whose squared norm overflows f32) are ordered differently from before, and neither order is defined. `benchmark.zig` still times the dense path.

## Standalone platform status (S1-T7, 2026-09-30)

**S1-T7 is `verified` and merged to `main`** (branch `task/S1-T7` `335ca2e`; Verdict in `docs/tasks/S1-T7.md`). The freshness digest (`tool/source_digest.py`) now also covers `contracts/CONTRACTS_VERSION`, so a version bump without a rebuild fails `tests/test_native_freshness.py`; the stamp is `4d79c55d…c615`, and a tester NDK rebuild is byte-identical to the committed libraries (dylib `cbaaa9f6…10f9`, `.so` `c5f0b056…0aac4`; the CLI is not part of the library). `searchd index --max-file-bytes/--max-total-bytes` with a value that is not a non-negative whole number (`-1`, `abc`, `10k`, empty, past u64) prints one line naming the option and the value and exits 1 with no stack trace. **Suites on the merge:** `zig build test` 103/103, `test-abi` 12/12, `lib` 10/10 (15/15 with the NDK), Python 71/71, `dart test` 18/18. **Open (non-blocking):** an unknown command or a bare `searchd` exits 0; other bad arguments (unknown flag, missing value or folder) still print a stack trace after their message; `+5`, `-0` and `1_000` are accepted as byte counts.

## Standalone platform status (S1-T6, 2026-09-30)

**S1-T6 is `verified` and merged to `main`** (branch `task/S1-T6` `1ff7ee8`; Verdict in `docs/tasks/S1-T6.md`). `searchd index` without `--update` now prints `budget_exhausted=` on its summary line (three 41-byte files with `--max-total-bytes 50` give `files_indexed=1 … budget_exhausted=2`). The README timing table keeps only generated-corpus rows. `scripts/check_no_home_paths.py` lists files from the repository root whatever the caller's directory. `docs/incremental-indexing.md` §Caps says the table's last two columns describe `--update`. **Freshness guard:** `tool/build_native.sh` writes `bindings/dart/search_simpli/native/SOURCE-SHA256`, and `tests/test_native_freshness.py` fails when the Zig source moves on without a rebuild. The prebuilt libraries were **not** stale: a tester rebuild with the NDK is byte-identical (dylib `cbaaa9f6…10f9`, `.so` `c5f0b056…0aac4`). The two S1-T5 `dart test` failures came from `SEARCH_SIMPLI_LIBRARY_PATH`, which `simpli-helper/tools/env.sh` exports, so run the suites with it unset (`docs/process/ROLES.md`). **Suites on the merge:** `zig build test` 98/98, `test-abi` 12/12, `lib` 10/10 (15/15 with the NDK), Python 70/70, `dart test` 18/18. **Open (non-blocking):** the digest omits `contracts/CONTRACTS_VERSION`, which is compiled into `ss_version()`.

## Standalone platform status (round D/E, 2026-09-26)

**S1-T5 is `verified` and merged to `main`** — merge `c4cd8d0` over the round-E rework `b65f0f3` and the verdict `1e9d20a` (round D was `rejected`; both verdicts are in `docs/tasks/S1-T5.md`): `--max-file-bytes`/`--max-total-bytes` now apply on a full rebuild exactly as on `--update`, the non-`--update` CLI line reports `too_large`/`unreadable` separately, a full rebuild writes `INDEX-STATE.json` so the next `--update` reports `unchanged`, and no tracked file carries a spelled-out home path (`scripts/check_no_home_paths.py` runs in the Python suite). Suites 97/97, 12/12, 15/15, 68, 18/18; shipped libraries rebuilt byte-identical (`dylib` 382,088 B `cbaaa9f6…`, `.so` 382,288 B `c5f0b056…`); `ss_index_folder`'s signature and `CONTRACTS_VERSION` (`1.0.0`) unchanged.

## Standalone platform status (round C, 2026-09-17)

**S1-T4 is `verified` and merged to `main`** — merge commit `d860bb1` (branch `task/S1-T4` `0bcc446`, which continued a rate-limited builder's `wip` `60be2dc`), then the verdict commit `ddb72a6`, which is `main`'s head. Round C is hardening only: it closes the round-B verdicts' non-blocking findings rather than adding a capability. The owner has paused this work after round C until later in the weekend.

- **`ss_index_folder` is bound in Dart.** `SearchSimpli.indexFolder(dirPath, folderPath, {options, library})` → a typed `IndexFolderReport`; `IndexFolderOptions` carries `analyzer`, `maxChars`, `overlapLines`, `update`, `maxFileBytes`, `maxTotalBytes`. A static method, not an instance one, because it takes a directory rather than an open handle (same shape as `importSnapshotJson`/`ss_import_json`). Proven by the tester on the Mac and **on the API 34 emulator against the app's own private storage** (`/data/user/0/<pkg>/files`), where it published generation 1, answered a query, tombstoned a file grown past the cap, and published an empty generation when the last file was deleted.
- **The Dart package loads its library package-relatively.** `library_loader.dart` finds the nearest `.dart_tool/package_config.json` and reads `search_simpli`'s own `rootUri` out of it (read directly rather than via `Isolate.resolvePackageUri`, which is `Future`-returning and would force `SearchSimpli.open` to become async). A `path:` dependency now works from any working directory with **no environment variable** — verified by the tester from a fresh consumer package outside the checkout, following the README literally with `SEARCH_SIMPLI_LIBRARY_PATH` unset. `SEARCH_SIMPLI_LIBRARY_PATH` still overrides, on every platform. Inside a built macOS app (`Platform.resolvedExecutable` sits directly in `*.app/Contents/MacOS/`) only the override and the exact `<executable dir>/../Frameworks/libsearch_simpli.dylib` are tried; no bare name, and a missing library is a `StateError` saying the app did not ship it (S1-T12). In a development checkout the order is: the override; the package's own `native/` copy (package config); the cwd- and script-relative `native/` candidates; then the bare name last (on Linux the exact order is `<exe dir>/lib/...so`, then the package copy, then cwd/script, then the bare name). The exact claim: inside an app only the shipped copy is ever loaded; in a checkout the package's own copy is preferred, and the bare name is the last fallback. A sandboxed process starts in its container, not in the cwd it was launched from.
- **The report JSON names files instead of only counting them, and `skipped` is gone.** One shape for both entry points: `generation`, `analyzer_id`, `added`, `changed`, `removed`, `unchanged`, `budget_exhausted`, `too_large`, `unreadable`, `too_large_paths`, `unreadable_paths`, `documents`, `terms`, `postings`. `unchanged` ("hash matched, nothing to do") and `budget_exhausted` ("left for a later run because `--max-total-bytes` ran out") are now distinct numbers, and `too_large`/`unreadable` files come with relative-path arrays (properly JSON-escaped — the tester checked quotes, backslashes, tabs, newlines, Cyrillic and emoji in filenames).
- **An empty folder, or a folder that lost its last file, publishes an empty generation.** Measured against the previous binary built from the same tree: `origin/main` exits 1 with `error: NoDocuments` in both cases, the merge publishes a real, openable generation with 0 documents/terms/postings that answers `query` and `evidence` with empty arrays.
- **A file grown past `--max-file-bytes` is reported *and* tombstoned.** It is named in `too_large_paths`, its previous chunks and its `INDEX-STATE.json` entry are dropped, it stays dropped on the next run, and it comes back as `added` if it shrinks below the cap — while an unrelated file in the same run stays `unchanged`. (An *unreadable* file keeps its chunks; the two policies differ by design, and `docs/incremental-indexing.md` now tabulates all six outcomes.)
- **`lifecycle.scan` knows `INDEX-STATE.json`.** Over the same incrementally indexed directory, the previous binary reports `unknown_files=1` and this one `unknown_files=0`.
- **Docs.** `docs/incremental-indexing.md` is rewritten to the shipped native design (and keeps the separate Python `--incremental-from` path clearly labelled as a different system); the four live "API 37" labels now read API 34 / Android 14 (package README, `example/lib/main.dart`, `docs/publication-recovery.md`, `zig/src/publication.zig`); `docs/generation-lifecycle.md` lists the third control file; `scripts/gen_timing_corpus.py`'s dead `shuffled` copy is gone; and the four schema-optional fields (`index.root`, `retrieval.vector_mode`, `retrieval.candidate_k`, `retrieval.embedding`) have Dart members that round-trip and are omitted when absent.
- **Timings re-measured by the tester on the merge** (ReleaseSafe, `/usr/bin/time -p`, 1,000-file / 3.9 MB corpus with **24,057** independently counted distinct terms): full rebuild **0.12 / 0.11 / 0.11 s** over three fresh `--out` dirs · re-index into the same `--out` **0.11 s** · `--update` with no prior state **0.12 s** · `--update` with one file changed of 1,000 **0.08 s**. The README's old 0.30 s full-rebuild figure is replaced; its "this repository's own tree" row measures **216 files / 1,471 documents / 14,137 terms / 0.17 s** on a tracked-files-only export (the row in the README reads 1,462 / 14,099 / 0.20 s — it was measured before the task file it indexes had finished growing).
- **Prebuilt libraries shipped with the Dart package** (ReleaseSmall, rebuilt by the tester from the merge with `tool/build_native.sh` and **byte-identical** to the committed files): macOS arm64 `.dylib` **381,592 B** (`sha256 6a0bfc87…673233`), Android arm64 `.so` **381,728 B** (`sha256 caf7c367…6cee00`, the same bytes as the example app's `jniLibs` copy). Both export 10 `ss_*` symbols; `lib/src/bindings_generated.dart` regenerates byte-identically from the changed header.
- **Known gaps carried forward** (detail in `docs/tasks/S1-T4.md`'s Verdict): `--max-file-bytes`/`--max-total-bytes` are silently ignored on a non-`update` run, though the header and the new Dart doc comment read as unconditional; a full rebuild writes no `INDEX-STATE.json`, so the first `--update` after one reports everything as `added` (true and tested, but not stated where a reader would look); the README's repository-tree row is self-referential and will keep drifting; leak-freedom is still a code-review claim with nothing measuring it; the binding's conformance test still asserts top-1 only; judged-relevance fixtures are still uncovered (no vectors from `searchd index`); case folding is still simple, not full; the Linux binary is still never executed.
- **Suites on the merge**: `zig build test` **94/94** (87 + 7 new), `zig build test-abi` **12/12**, `zig build lib` **15/15** (all three ADR-0002 targets), `python3 -m unittest discover -s tests` **67/67**, `dart analyze` clean, `dart test` **16/16**, `flutter analyze` (example) clean, Android instrumentation **2/2** on the emulator.

## Standalone platform status (round B, 2026-09-17)

**S1-T3 and S1-T2 are `verified` and merged to `main`** (merge commits `beb4e4a` and `4ac5b3e`, on branches `task/S1-T3` `fc74854` and `task/S1-T2` `116a67a`), followed by `3602ebd`, which rebuilds the Dart package's prebuilt libraries from the merged engine. Search Simpli can now update an index in place, and a Dart program — including a Flutter app on an Android device — can use the engine in process.

- **Incremental folder indexing** (`ss_index_folder`, `searchd index --update`, `zig/src/indexer.zig`): per-file SHA-256 content hashes persisted in `<out>/INDEX-STATE.json`, unchanged files skipped (neither chunked nor re-analyzed — their tokens are reconstructed from the previous generation's postings), deleted files tombstoned, and the new generation published through the existing atomic path. One report JSON shape for both entry points: `generation`, `analyzer_id`, `added`, `changed`, `removed`, `skipped`, `too_large`, `unreadable`, `documents`, `terms`, `postings`. Caps: `--max-file-bytes` (default 10 MiB, over-cap files are never opened) and `--max-total-bytes` (default 512 MiB). Verified by the tester step by step: add → `added:1, skipped:2`; edit → `changed:1`; delete → `removed:1`; rename → `added:1, removed:1`; oversize → `too_large:1`, with the expected query result after each.
- **Re-publishing works.** `searchd index --out <existing dir>` now publishes the next free generation (`generation_alloc.nextFreeGeneration`) instead of failing with `PathAlreadyExists` — round A's sharpest rough edge, closed. An explicit `--generation N` is still honoured, collision and all.
- **Indexing is no longer superlinear in vocabulary.** `lexical_build.build` and `lexical_segment.zig`'s `validateIndex`/`decode` all replaced O(terms²) scans with hash lookups. Measured by the tester on one 1,000-file / 3.9 MB / **24,057-distinct-term** corpus (`scripts/gen_timing_corpus.py`, which now guarantees ≥20,000 distinct terms; the old generator produced 57): the pre-S1-T3 binary takes **7.10 s**, the merged one **0.12 s** — ~59×.
- **Timings** (ReleaseSafe, `/usr/bin/time -p`, tester-measured on the merge): full index 0.13 s · full re-index into the same `--out` 0.11 s · `--update` baseline with no prior state 0.13 s · `--update` with one file changed of 1,000 0.07 s · `--update` with nothing changed 0.07 s · this repository's own tree (208 files, 1,384 chunks, 13,819 terms) 0.18 s. Two independent runs over the same corpus produce byte-identical sections and manifest.
- **Crash-safe publication is portable now.** `publication.writeAtomicFile` (named temp file with `O_CREAT|O_EXCL`, write, `fsync`, `rename`/`renamePreserve`) replaces `Dir.createFileAtomic` for *every* file a publish writes — both immutable sections, `MANIFEST`, and `INDEX-STATE.json`. **This is the Android fix:** Zig 0.16's `createFileAtomic` uses `O_TMPFILE` when not replacing, and an app's SELinux policy denies that inside its own private directory, so `ss_import_json` failed there with `AccessDenied`. Proven on the emulator by the tester, before and after: the pre-S1-T3 library fails with `ss_import_json: AccessDenied`; the rebuilt one publishes generation 1 into `/data/user/0/…/files/…`, opens it, answers a query, and re-publishes generation 2. `ss_index_folder`, called through raw FFI on a folder in the same private storage, published generation 1 (`added:2`) then generation 2 (`added:1, skipped:2`) with `INDEX-STATE.json`.
- **Crash recovery, proven by killing a real process**: `SIGKILL` during publication left `documents-2.hybseg` orphaned with `MANIFEST` still at generation 1; `lifecycle.scan` reported `current_generation=1, orphan_document_files=1`; the previous generation still opened (1,002 documents) and answered queries; the next `--update` published generation 3 around the orphan.
- **Dart FFI package** (`bindings/dart/search_simpli/`): `ffigen`-generated bindings (regenerated by the tester, byte-identical), a `SearchSimpli` class (`open`/`query`/`evidence`/`status`/`close`) plus `importSnapshotJson`, typed results matching `contracts/search-tool.schema.json` field for field, and `CONTRACTS_VERSION` asserted against the native `ss_version()` at open (proven by building a library with a planted `9.9.9` and catching `ContractsVersionMismatchException`). `dart test` 12/12. Conformance, re-measured more strictly than the committed test asserts: **18/18 complete rankings** identical to the Python golden and **34/34 full top-5** identical to the `searchd` CLI, including 16 tester-invented queries. The Android instrumentation smoke test loads the library and answers a query on the `vizhi-phone` emulator (Android 14, API 34 — the "API 37" labels several files carried at the time were corrected in round C).
- **Prebuilt libraries shipped with the Dart package** (ReleaseSmall, rebuilt from the merge with `tool/build_native.sh`): macOS arm64 `.dylib` **381,000 B** (`sha256 89845bc3…9826b4`), Android arm64 `.so` **379,808 B** (`sha256 14665ece…81d4b3`, byte-identical to the example app's `jniLibs` copy). Both export 10 `ss_*` symbols, `ss_index_folder` included. A binding that ships binaries goes stale the moment the engine merges — rebuilding them is now part of the tester's merge routine.
- **Known gaps carried forward** (detail in each task file's Verdict): `--update` on a folder whose last indexable file was deleted fails with `NoDocuments` instead of publishing an empty generation; `lifecycle.scan` counts `INDEX-STATE.json` as an unknown file; a file that grows past `--max-file-bytes` loses its existing chunks while being reported only as `too_large`; unreadable/too-large files are counted but not listed by path; `skipped` conflates "unchanged" with "budget exhausted"; the macOS Dart library loader searches the working/script directory rather than the package root, so the README's path-dependency install needs `SEARCH_SIMPLI_LIBRARY_PATH`; the binding's conformance test still asserts top-1 only; judged-relevance fixtures are not covered by any binding conformance test (no vectors in `searchd index` yet); case folding is still simple, not full; the Linux binary is still never executed.
- **Suites on the merge**: `zig build test` **87/87**, `zig build test-abi` **12/12**, `zig build lib` **15/15** (all three ADR-0002 targets), `python3 -m unittest discover -s tests` **67/67**, `dart test` **12/12**, Android instrumentation **1/1**.

## Standalone platform status (round A, 2026-09-17)

**S1-T0 and S1-T1 are `verified` and merged to `main`** (merge commits `3466083` and `3a17af8`, on branches `task/S1-T0` `20750b9` and `task/S1-T1` `cbf2607`). Search Simpli now indexes and queries a folder with no Python in the loop, and exposes the engine over a C ABI.

- **C ABI** (`zig/include/search_simpli.h`, `zig/src/abi.zig`): `ss_open`/`ss_close`/`ss_status`/`ss_query`/`ss_evidence`/`ss_import_json`/`ss_free`/`ss_version`/`ss_last_error`. `ss_query` and `ss_evidence` reuse the JSON-RPC service's own writers, so their output is byte-identical to a `search_knowledge`/`read_chunk` response for the same request — asserted against golden JSON captured from a real `init-demo` + `serve` session (`zig build test-abi`, 12/12). No global mutable state beyond the handle; `ss_last_error` is a thread-local diagnostic. `contracts/CONTRACTS_VERSION` is `1.0.0` and is what `ss_version()` returns.
- **Libraries** (`zig build lib`, static + shared for `aarch64-macos`, `aarch64-linux-android` via `SS_ANDROID_NDK`, `x86_64-linux`). ReleaseSmall, measured on the merge: macOS `.a` 428,296 / `.dylib` 342,264; Android `.a` 389,226 / `.so` 326,976; Linux `.a` 403,114 / `.so` 340,168 bytes. (Each grew ~60 KB over S1-T0 alone once the Unicode tables joined the engine.)
- **Native indexing**: `line-window-v1` ported to Zig on codepoints, with a golden test against the live Python reference — 56 files, 85 chunks, **85/85 identical**, regenerable with `scripts/gen_chunk_golden.py`.
- **`analyzer-v2`**: NFC (complete since S1-T15: singletons and Hangul; variation selectors dropped) + Unicode letter/digit categories, with the combining marks (Mn/Mc) and inner ZWJ/ZWNJ attached to them (S1-T14) + simple case folding, from tables generated by `scripts/gen_unicode_tables.py` out of Python's `unicodedata` (Unicode 13.0.0); `analyzer-v1` (ASCII) stays available, and the analyzer id is recorded in the manifest so query time picks the matching tokenizer — through the CLI, the RPC service, and the C ABI alike. Full BM25 rankings (path, lines, raw score) are identical between Python and Zig on **36/36 queries** measured at verification; Tamil runs end to end at **10/10** judged top-1.
- **`searchd`** gained `index`, `query`, `evidence`, and `serve --http 127.0.0.1:<port>` (loopback-only, verified bound to `127.0.0.1` and unreachable from the LAN address). One static binary per platform, ReleaseSafe: macOS arm64 **851,096 B**, Linux x86_64 (musl) **5,294,368 B**.
- **Timing**: 1,000 files / 3.9 MB / 1,021 chunks index in **0.27 s** cold and **0.08 s** warm — but that corpus has only 57 distinct terms. `lexical_build.build` scans the term list linearly per token, so the same 1,000 files with a realistic 20,000-word vocabulary take **9.69 s**, and this repository itself (202 files, 13,297 terms) takes 0.77 s. A hash map there is the first performance fix before the CLI meets a real corpus.
- **Known gaps carried forward** (detail in each task file's Verdict): `searchd index` cannot re-publish into an output directory that already holds that generation (`error: PathAlreadyExists`; `--generation N` works) — S1-T3's job; case folding is simple, not full, so `ß`, `ﬁ`, `ﬀ` and `İ` do not fold; `scripts/gen_bm25_golden.py` needs `PYTHONHASHSEED` pinned to regenerate byte-identically; the Linux binary is cross-compiled but has never been executed.
- **Suites on the merge**: `zig build test` **77/77**, `zig build test-abi` **12/12**, `python3 -m unittest discover -s tests` **67/67**.

## Goal

Build toward a search solution that begins with files/folders and an LLM-friendly tool boundary, then evolves into a ground-up Zig hybrid lexical/semantic indexing platform.

## Current state

- The workspace began empty and is now a Git repository on `main`, published at `github.com/ilamgumaran/search-simpli`.
- A dependency-free Python behavioral reference is runnable.
- The reference scans selected UTF-8 text/source formats, makes cited chunks, calculates BM25, supports an offline vector channel, fuses by RRF, filters by path prefix, and emits an LLM evidence envelope.
- A Zig 0.16.0 in-memory retrieval core implements ASCII analysis, corpus-level BM25, exact cosine scoring for supplied vectors, independent candidate ranks, candidate cutoffs, RRF, deterministic top-k, and component explanations.
- Zig also has a versioned, checksummed immutable document/vector segment with caller-owned encoding/decoding and a golden ranking round trip.
- An in-memory inverted term dictionary and postings index calculates BM25 without scanning non-matching documents, then feeds the shared hybrid fusion path. Integrated golden tests cover segment decode through final ranking.
- A separate `HYBLEX01` immutable lexical section persists document lengths, dictionary terms/ranges, document frequency, and postings. Decoding it reproduces BM25 and final hybrid ordering without re-tokenizing stored text.
- `HYBMAN01` binds document/vector and lexical sections by generation, filenames, byte lengths, internal checksums, counts, analyzer id, and embedding model id.
- Filesystem publication syncs and atomically links generation-unique sections, then atomically replaces `MANIFEST`. Loading a published generation through both decoders and querying it is covered by integration tests.
- `WRITER.LOCK` provides advisory exclusive publication serialization. A recovery scanner reports current, unreferenced document/lexical, and unknown files without unsafe deletion.
- Current document segments are v3 and persist source path/start/end lines plus canonical required labels; the reader remains compatible with v1/v2 records.
- `Engine.open/query/evidence` turns a loaded published snapshot into cited lexical+semantic+RRF results using only caller-owned workspaces.
- Zig `Service` and JSON-RPC layers expose `search_knowledge`, scoped `read_chunk`, `list_sources`, and `index_status`. `searchd init-demo` publishes a snapshot and `searchd serve` runs the live stdin/stdout process.
- Query vectors are explicit for vector/hybrid RPC calls and validated against manifest dimensions; `candidate_k` is explicit and bounded.
- A versioned neutral interchange exports Python chunks, citations, vectors, analyzer id, and model id. `searchd import-json` validates it, builds both Zig sections, and atomically publishes a queryable generation.
- `embed_query.py` reproduces query vectors from the exact model stored in a Python index. In the live cross-language test, Zig imported 5 PPMI documents with 34 dimensions and returned `target/automobile.md:1-2` at vector rank 1 for `car`.
- Corpus-trained models now use a deterministic SHA-256 instance fingerprint, not only the `cooccurrence-ppmi-v1` family label. Legacy reference indexes derive it on load.
- `zig_gateway.py` exposes text-only agent/tool requests, verifies model fingerprint and dimensions against Zig status at startup, injects vectors for semantic modes, passes lexical/read/list/status through, and forbids callers from overriding vectors.
- Live gateway requests returned `automobile` for `car`, `physician` for `doctor`, and exact lexical evidence for `automobile`. A different folder model was rejected before serving with exit code 2.
- An optional provider-neutral neural path now batches document and query embeddings separately. The first adapter pins FastEmbed 0.8.0 with `BAAI/bge-small-en-v1.5`, validates a 384-dimensional conformance fingerprint, and keeps the base mode dependency-free.
- The 20-query mixed-domain diagnostic measured success@1 of 0.60 for BM25, 0.70 for PPMI vector, 0.90 for neural vector, and 0.85 for equal-weight neural RRF. At k=3 neural vector and hybrid both reached 1.0 success; vector MRR was higher.
- A neural snapshot completed the full Python → interchange → Zig generation 3 → gateway path. Live `car` and `doctor` queries returned the cited `automobile` and `physician` passages from 384-dimensional vectors.
- Path rules now assign canonical all-required access labels. Python and Zig filter both retrieval channels before ranks, then enforce the same principal on source listing and chunk reads. The gateway injects trusted labels and rejects caller forgery.
- `HYBSEG01` v3 persists required labels while reading v1/v2 as unlabeled/public. A live generation-4 run proved anonymous, tenant, and engineering views across search/list/read.
- Reference indexes now record chunker identity and per-file SHA-256 hashes. Compatible incremental builds reuse unchanged extraction/vectors, relabel ACL-only changes, remove deleted files, preserve transiently unreadable prior files as reported stale data, and embed only changed/new neural chunks.
- A real BGE update reused 11/13 files, embedded only two changed/new chunks, removed one deleted path, and published the complete result as Zig generation 5. The new rollback passage ranked first in Python and Zig.
- A reproducible files/folders scale harness now measures full and unchanged Python builds, vector movement, embedding-call avoidance, and JSON artifact size. At 5,000 one-chunk Markdown files, no-vector preparation took 591.6 ms/3.31 MB; synthetic 384-dimensional preparation took 4.54 s/10.98 MB, while unchanged preparation took 2.02 s and embedded zero chunks.
- A real Zig engine benchmark now reports total, lexical, and ranking p50/p95 timings. It exposed quadratic rank assignment as the first query bottleneck: hybrid p50 at 8,000 exhaustive 32-dimensional candidates was 174.6 ms.
- An allocation-free heap-sort rewrite improved complexity but still spent 43.0 ms median in ranking at 8,000 candidates. Deterministic in-place pdq ordering reduced the equivalent final p50 to 0.417 ms and continued to 1.69 ms at 32,000 candidates. Raw before/intermediate/after evidence and limits are preserved.
- A recreation kit now preserves the objective, executable functional/non-functional specification, acceptance gates, and staged coding-agent prompts. A use-case library provides a durable catalog, contribution template, and initial personal-files, codebase-agent, and authorized-team scenarios.
- Python and Zig now share the `candidate_k >= top_k` fusion-depth rule. A live Zig request with `candidate_k=2` returned `hybrid-guide` with both component ranks equal to 2.
- The root test harness explicitly loads every engine module; 57/57 Zig tests actually execute and pass using the temporary official toolchain. Live process tests cover Python export, Zig import/publication, semantic query, and principal-isolated authorization.
- A local JSON-lines tool process exposes `search_knowledge`, `read_chunk`, `list_sources`, and `index_status` for an LLM/skill/agent wrapper.
- Retrieval can run as lexical-only, vector-only, or hybrid. Evaluation suite v2 adds graded 1–3 judgments and nDCG@k while retaining recall@k, success@k, MRR, returned paths, matched grades, and per-query failures. Version 1 binary suites remain supported.
- `relevance_smoke.py` binds corpus hashes, suite, model identity, modes, and cutoff into a profile id; it enforces explicit floors or same-profile baseline tolerances. The 10-product/4-query dependency-free fixture scores 1.0 on nDCG@10, MRR@10, success@10, and macro recall@10 and runs in CI.
- Expensive smoke profiles can save a newly built index and reuse it later; prebuilt reuse validates the corpus root and reconstructs the exact neural provider identity before semantic evaluation.
- A deterministic WANDS adapter downloads no external data into the repository. A requested 10,000-product/1,000-query cap honestly produced 10,000 products and 47 queries because WANDS has only 480 queries and the sample preserves every Exact/Partial product for each retained query.
- The corrected one-product/one-chunk WANDS lexical run scored nDCG@10 0.6866, MRR@10 0.8574, success@10 0.9149, and macro recall@10 0.0528. The failed first representation produced 41,377 chunks and nDCG@10 0.5562 because duplicate chunks consumed result slots; both raw runs are preserved.
- A 500-product/11-query WANDS neural profile completed with nDCG@10 lexical/vector/hybrid of 0.4176/0.4550/0.4287. BGE vector improved every aggregate over lexical; equal-RRF improved nDCG, success, and recall but regressed MRR and underperformed vector-only. Neural construction took 313.4 seconds while three-mode evaluation took 0.934 seconds. Larger 10k and 2k neural attempts were stopped after exceeding an interactive smoke duration.
- The dependency-free Python suite now executes 67/67 tests; the latest recorded
  pinned-toolchain Zig run executes 87/87 tests (57 before round A, 59 with the
  C ABI, 77 with the native chunker/analyzer-v2/CLI, 87 with round B's
  incremental indexing and portable publish), plus `zig build test-abi`'s
  12/12 C-ABI conformance checks and the Dart package's 12/12.
- The CAP-11 graded-relevance extension now has a formal capability change record,
  template-aligned UC-005, and resolved CFT-10 against INV-09. Process step 6b
  did not receive qualifying approval before PR #3 merged as `2a512cb`; the
  record now preserves that historical process exception rather than inventing
  retroactive approval.
- E-01A real-folder judgment packs are claimed in issue #4 and specified through
  capability-process step 6. Implementation is intentionally paused at step 6b
  until a human maintainer approves its invariants, CFT-11–13 resolutions, and
  acceptance gate on the final specification commit.
- The first judged run showed hash-vector hybrid retrieval regressing from 1.0 to 0.5 at `k=1`, so new indexes default to no vectors; hash mode is explicit test-only behavior.
- A dependency-free `cooccurrence-ppmi-v1` distributional model provides real corpus-trained semantic vectors. On two controlled vocabulary-mismatch queries, lexical scored 0.0 and vector/hybrid scored 1.0 at `k=1`; this is synthetic evidence, not a modern embedding benchmark.
- There is no representative user-derived judged corpus, authenticated identity/token adapter, label-aware BM25 statistics, directory-sync backend, reader-safe generation GC, WAL/delta-segment writer, filesystem watcher, MCP/network adapter, or direct LLM generation call yet. WANDS is real-label product-domain evidence but the 10k capped profile is biased and not score-comparable to full WANDS. Incremental preparation still publishes a complete Zig snapshot. Scale evidence is synthetic and does not yet cover 384-dimensional Zig queries, persisted startup/memory, or concurrency.

## Important decisions

1. Retrieval and generation remain separate.
2. Python is the behavioral/evaluation reference; Zig is the durable engine path.
3. Embedding inference starts outside the Zig engine.
4. BM25 and vector candidates are retrieved independently and fused with RRF.
5. Citations, authorization scope, and embedding/index versions are first-class data.
6. Complexity such as HNSW, WAND, quantization, or sharding requires benchmark evidence.

## Resume commands

```sh
cd <home>/workspace/search-platform-exploration
python3 -m unittest discover -s tests -v
python3 search.py index fixtures/knowledge --out .search/index.json
python3 search.py context .search/index.json "How should hybrid search combine results?"
python3 knowledge_tools.py .search/index.json
python3 evaluate.py .search/index.json fixtures/judgments.json --top-k 1
python3 relevance_smoke.py fixtures/relevance-smoke/corpus \
  fixtures/relevance-smoke/judgments.json --mode lexical --top-k 10 \
  --min-ndcg 1 --min-mrr 1 --min-recall 1 --min-success 1
python3 scripts/prepare_wands_smoke.py /tmp/WANDS/dataset \
  /tmp/search-simpli-wands-10k --max-products 10000 --max-queries 1000
python3 benchmark_scale.py --sizes 100 1000 5000 --dimensions 384
python3 search.py index fixtures/semantic-knowledge --vector-mode cooccurrence --out /tmp/python-index.json
python3 search.py index fixtures/semantic-knowledge --vector-mode cooccurrence \
  --incremental-from /tmp/python-index.json --out /tmp/python-index-next.json
python3 export_zig.py /tmp/python-index.json --generation 1 --out /tmp/zig-snapshot.json
python3 embed_query.py /tmp/python-index.json car
python3 zig_gateway.py /tmp/python-index.json /tmp/search-snapshot

# Optional neural environment after installing fastembed==0.8.0:
.search/fastembed-env/bin/python search.py index fixtures/mixed-knowledge \
  --vector-mode neural --model-cache .search/models --out /tmp/mixed-neural-index.json
.search/fastembed-env/bin/python evaluate.py /tmp/mixed-neural-index.json \
  fixtures/mixed-judgments.json --top-k 3 --model-cache .search/models
```

If `/tmp/zig-aarch64-macos-0.16.0` still exists:

```sh
cd <home>/workspace/search-platform-exploration/zig
/tmp/zig-aarch64-macos-0.16.0/zig build \
  --global-cache-dir /tmp/zig-global-cache \
  --cache-dir /tmp/search-zig-test-cache test

/tmp/zig-aarch64-macos-0.16.0/zig build run -- \
  import-json /tmp/search-snapshot /tmp/zig-snapshot.json

/tmp/zig-aarch64-macos-0.16.0/zig build -Doptimize=ReleaseFast
./zig-out/bin/searchd benchmark 8000 32 51 hybrid
```

Otherwise repeat the official download commands in `EXPERIMENTS.md`, or install Zig 0.16.0 and run `zig build test`.

## Best next step

Complete the E-01 real-folder relevance sequence before making production claims:

1. Review and explicitly approve the pending E-01A specification on its final
   commit, covering invariant compliance, CFT-11–13, and the acceptance gate.
2. Implement and verify the content-free judgment-pack workflow described there.
3. Select one representative single-owner folder and have a human data owner
   author/confirm 50–100 tuning/holdout questions with expected passages.
4. Compare BM25, PPMI, BGE, and equal-RRF on the sealed pack, preserving
   per-query wins/losses; only then test weighted fusion or routing.
5. Use WANDS full/larger repeated profiles as a complementary product-domain
   check, not a substitute for the intended files-and-folders evidence.

This sequence determines whether semantic retrieval produces enough value on
the real target corpus to justify the vector infrastructure and default mode.

In parallel, the next self-contained scale milestone is a persisted 384-dimensional benchmark covering snapshot bytes, open/startup time, resident memory, and concurrent long-lived queries. That evidence decides whether the next engine feature should be candidate-union fusion, ANN, lexical pruning, or only better process/service management.

## Choices still needed

- corpus type: personal documents, source repositories, mixed, or another domain;
- embedding preference: local/private versus hosted;
- LLM preference and whether generation may send retrieved content to a hosted service;
- target scale and freshness: approximate files/chunks, update rate, and latency goal;
- initial interface: CLI, local HTTP API, or MCP-compatible tool adapter.

These choices do not block the current reference. They materially affect E005B and the service boundary.

## 2026-11-01 — Recovery/filename integration candidate

(Integrated by [S4-T2](docs/tasks/S4-T2.md); the two sections below describe PR #21 as
it stood before the integration.)

Owner-authorized follow-up on `improve/recovery-and-filename`, claim #20.
Contract 2.1.0 integrates filename search with S3 via manifest v3 (superseded by S4-T2: contract 2.2.0, manifest v2.2), exact
manifest-bound recovery state, restricted write policy and no-follow directory
handles. Native packages were rebuilt and checked on macOS; 82 Dart tests
pass, alongside 263 Zig and 22 C ABI checks. This is not merged or a phone
release. See
[task/evidence](docs/tasks/recovery-filename-integration.md).

## S4/recovery/filename integration candidate

PR #21 combines main `f45c06d` with recovery/filename work at contract 2.2.0
and Dart 0.3.0. It preserves lazy loads and XXH3, checks actual source length,
caches filename tables and removes recovery JSON trees from query readers.
The unchanged 10k 64 MiB gate passes after allocator work; source capacity is
reserved at open, while source I/O and validation remain lazy. This candidate
is unmerged; see [current evidence and follow-ups](docs/reviews/2026-11-01-s4-integration.md).

The S4 integration candidate's final native build at `dc800e3` passes all
platform checks, clean Dart analysis and 83 Dart tests; packages are rebuilt
at contract 2.2.0. Source tests pass 282/282 and ABI 22/22. The combined
10k cap regression peaks at 63,859,306 bytes; 15k/20k require further memory
work. Physical phone validation and E-02/real-folder evaluation are pending.

## Filename complexity guard candidate

Owner-authorized objectives review; claim #22, based on S4-T2 main `b45b1c4`.
Protected-memory and bounded-scratch tests guard filename query behavior at
1k/10k files without a timing threshold. A sort self-comparison now avoids
an unnecessary body-id read. No API/contract/format changes; packages are
rebuilt from the changed source. Verified: 297 Zig, 23 ABI, 238 Python (four skips), 83 Dart; genuine native
packages adopted. See [task/evidence](docs/tasks/filename-complexity-guard.md)
for OS guard limits and the iOS SDK/layout difference. PR #23 was merged at 94c6071
and adopted by [S4-T3](docs/tasks/S4-T3.md), which rebuilt the natives on the Mac.
