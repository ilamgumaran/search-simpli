# Relevance evaluation

Status: binary v1 and graded v2 evaluation are implemented in
`src/search_platform/evaluation.py`. The dependency-free regression gate and
product fixture live at `relevance_smoke.py` and `fixtures/relevance-smoke/`.

Proposed next change: [SQ-01 / E-02](requirements/cap-11-e02-negative-evaluation.md)
specifies explicit negative-query labels, formulas and trusted visibility for a
future v3 suite. The current evaluator still supports v1/v2 only. SQ-02 cannot
begin until the final design receives its named maintainer approval.

## Why this exists

Hybrid search adds machinery but does not guarantee better answers. Lexical, vector, fusion, chunking, and reranking changes must run against the same explicit relevance judgments. Otherwise a compelling individual query can hide broad regressions.

## Judgment format

```json
{
  "version": 2,
  "queries": [
    {
      "id": "stable-query-id",
      "query": "How should result lists be combined?",
      "path_prefix": "optional/scope/",
      "relevant": [
        { "path": "exact-source.md", "grade": 3 },
        { "chunk_id": "optional-more-precise-id", "grade": 1 }
      ]
    }
  ]
}
```

A judgment may identify a path, a stable chunk id, or both. Path judgments
tolerate chunker changes; chunk-id judgments are more precise but must be
migrated when content or chunk boundaries change. Version 2 requires integer
grades 1–3. Version 1 remains supported as binary relevance with implicit grade
1. Duplicate judgments are rejected, and repeated chunks from one judged path
earn relevance gain only once.

## Run

```sh
python3 search.py index fixtures/knowledge --out .search/index.json
python3 evaluate.py .search/index.json fixtures/judgments.json --top-k 1
```

To exercise mechanics only:

```sh
python3 search.py index fixtures/knowledge \
  --out /tmp/search-hash-index.json \
  --vector-mode hash
python3 evaluate.py /tmp/search-hash-index.json fixtures/judgments.json --top-k 1
```

The evaluator runs lexical, vector, and hybrid by default. Repeated `--mode` selects a subset.

## Metrics

- `macro_recall_at_k`: for each query, the fraction of its judged items found in the first `k`, averaged across queries;
- `success_at_k`: fraction of queries with at least one relevant result in the first `k`;
- `mean_reciprocal_rank`: average inverse position of the first relevant result;
- `mean_ndcg_at_k`: graded gain discounted by rank and normalized to the ideal
  top-k ordering;
- per-query first relevant rank, recall, nDCG, returned paths/chunks, and matched
  grades for diagnosis.

Use graded judgments only when assessors or the source dataset define consistent
levels. Never compare scores across different corpora, sampling rules, grade
mappings, or cutoffs as though they were one scale.

## Built-in relevance smoke gate

The one-command smoke runner builds an index, evaluates selected modes, writes a
machine-readable report, and exits non-zero when a floor or same-profile baseline
tolerance fails:

```sh
python3 relevance_smoke.py \
  fixtures/relevance-smoke/corpus \
  fixtures/relevance-smoke/judgments.json \
  --mode lexical --top-k 10 \
  --min-ndcg 1 --min-mrr 1 --min-recall 1 --min-success 1
```

The profile id hashes corpus source metadata, the suite, vector/model identity,
modes, and cutoff. This prevents accidentally comparing a new sample to an old
baseline. See [the product relevance benchmark](relevance-benchmark.md) for the
WANDS adapter, research basis, actual 10k result, failure examples, and limits.

## First observed result

On the two-query fixture at `k=1`:

| Index/mode | Recall | Success | MRR |
|---|---:|---:|---:|
| no vectors, lexical | 1.0 | 1.0 | 1.0 |
| no vectors, hybrid | 1.0 | 1.0 | 1.0 |
| hash vectors, vector | 0.5 | 0.5 | 0.5 |
| hash vectors, hybrid | 0.5 | 0.5 | 0.5 |

The hash channel displaced a correct lexical top result. This is direct evidence that vector-shaped data is not semantic relevance and that fusion can make a good lexical system worse. Consequently, index creation now defaults to `vector_mode=none`; hash vectors are opt-in and every evaluation containing them emits a warning.

The corpus is far too small for general conclusions. Its purpose is to prove the
harness catches a regression. A first real-label WANDS diagnostic now exists;
its capped sample is still not representative enough for a production claim.

A second controlled suite exercises the dependency-free ground-up PPMI semantic baseline; see `docs/cooccurrence-semantics.md`. It proves vocabulary-mismatch retrieval mechanics but is also explicitly synthetic.

## Twenty-query mixed-domain diagnostic

`fixtures/mixed-knowledge` and `fixtures/mixed-judgments.json` add 13 documents and 20 paraphrased queries spanning search, storage, agents, operations, systems programming, and several general domains. The exact output is saved in `benchmarks/mixed-diagnostic-2026-07-11.json`; see [the neural provider report](neural-embedding-provider.md) for the full interpretation.

At k=1, BM25 scored 0.60 success, PPMI vector 0.70, local BGE neural vector 0.90, and equal-weight neural RRF 0.85. At k=3 both neural vector and hybrid found relevant evidence for all queries, but vector-only had higher MRR. This demonstrates both pretrained semantic value and a fusion regression. It remains diagnostic rather than representative because its documents and questions were authored together for this project.

## J2: the judged fixture (S5-T1)

`fixtures/j2/` is the harder judged benchmark the agreed order has named since
4 Oct 2026 ("then a harder judged benchmark"): invented family folders (school,
home, laptop; 68 files) and 109 judged queries that say **where keyword search
loses**, slice by slice. It is diagnostic evidence written against this
engine's analyzer and chunkers, not a production relevance claim: the content
and the questions were authored together, and each miss is made real by a
generator check, not sampled from use.

**Slices** (task minimums in brackets): control 23 (20), misspelling 16 (15;
8 transpositions), morphology 13 (12; 5 where only the form differs), accent and
compatibility 9 (6), Tamil 13 (10; two inflectional suffix guards and one
derivational guard kept for information), title intent 11 (10; three where only
the folder carries the words), phrase and adjacency 10 (8; `p07` reversed), and
14 negatives (two per slice). Grades: 2 the answer, 1 useful context, 0 a named
distractor. Title intent grades the whole file (the intent is "open that file").
`fixtures/j2/README.md` lists every query; `judgments.json` holds every row.

**Checks.** `fixtures/j2/generate.py` asserts, before it writes, that each miss
is real, using the analyzer-v2 simple case fold: a misspelt word is in no file
and is one or two edits (Damerau) from a word in the answer; a morphology, accent
or Tamil row's answer holds the other form and not the query's; a guard's
homograph stem is in its distractor; a title row's words sit in the file name
(stem) or only its folder, at most once in the body; a phrase row's words are
adjacent in one row and apart in the other; a negative has no relevant row and a
query word that occurs; and no chunk overlaps a grade-2 and a grade-0 row of one
query.

**Two surfaces, two variants.** `scripts/j2_run.py` indexes J2 through the
shipped `searchd` (`index EMPTY --filename-index`, then `apply` with three host
roots: `apply` cannot turn the file-name channel on for a new directory, so the
index also holds an empty `r-legacy` root; every request names the three roots)
and `python3 scripts/relevance_smoke.py --pack j2` runs the Python reference.
Knowledge rows run `search_knowledge` (lexical, top 10) twice, with
`search_field: content` (the primary number, the one later bars are written
against unless a task's bar says `both`) and `both`; find rows (`find:words`,
`find:phrase`, `find:prefix`) run once. Both surfaces score with the same code
in `relevance_smoke.py`.

**Metrics** per slice and overall (the mean over the 95 graded queries, not a
mean of slices): success@1 (grade 2 at rank 1), MRR@10 (first hit of grade 1 or
more), nDCG@10 (gain 2^g − 1, as above), recall@5 (rows of grade 1 or more found
in the top 5), every query's first grade-2 rank, and for negatives the hit count,
the top hit and whether it is a named distractor. A hit takes the highest-grade
unmatched row it overlaps; each row counts once, so a second hit in the same
title-intent file counts nothing.

**The gate.** `scripts/j2_gate.py RUN.json` compares a run with the same surface
in `fixtures/j2/baseline.json`, variant by variant. It fails when a slice's
MRR@10 drops by more than 0.02, when a control query loses rank 1 (never
excused), or when a query's first grade-2 rank worsens by more than three places
(not in the top 10 counts as 11) and the run's allow-list does not name it. The
allow-list is a file the task that moves a judgment commits beside it. CI runs
the Python reference through the gate in the Zig-less `checks` job with
`PYTHONHASHSEED=0`; the `searchd` numbers are recorded on macOS arm64.

**How J2 is gated on each surface (S5-T6, review R01 and R02).** One baseline,
two surfaces, both in CI on every push to `main` and to `task/**` and on every
pull request:

| Surface | Where | What runs | What fails it |
| --- | --- | --- | --- |
| Python reference | `checks` (Python 3.11, no Zig) | `relevance_smoke.py --pack j2`, then `j2_gate.py` | the gate's rules (a), (b), (c) |
| `searchd` | `native-linux-release` (Linux x86_64, the job's own `ReleaseSmall` build) | `scripts/ci_j2_native.py run`, `differences`, then `j2_gate.py --annotate` | a run that is not whole and native (the pack is not 198 queries, a query has no record in `content` or `both`, the surface is not `searchd`, the binary is not the job's), or the gate's rules |
| the gate itself | `native-linux-release` | `ci_j2_native.py plant` on the real native run, then `j2_gate.py` | the gate *passing* the planted run (every graded query's grade-2 answer removed, scored again with the same code) |

The native run names the binary (SHA-256, size, optimize mode, Zig version), its
source commit, the natives digest and the policy ids it ran under (`analyzer_id`,
`chunkers`, `filename_policy_id`, `title_policy_id`, `fuzzy_policy_id`,
`fold_policy_id`); the reference's report names its commit, Python and the same
policy ids. `differences` lists, as warnings, every baseline cell the x86_64 run
moved (first grade-2 ranks with the query's top 10 and scores, slice metrics,
negatives); it never fails the job, the gate decides. At S5-T6 it listed none:
x86_64 equals the macOS arm64 baseline on every cell the baseline holds. The
baseline holds no per-hit scores, so scores are not compared across platforms
here; the Zig tests that read the BM25, title and fuzzy goldens compare the
engine's scores with the reference's within their stated tolerances, and they run
on Linux x86_64 in both native jobs (`zig build test`, Debug and `ReleaseSmall`). Each check reports its failures as workflow
annotations (`::error`, at most 30 a step; GitHub keeps 10 of each level a step,
so the tenth of a level says how many more the log holds), which the public
check-runs API returns without a sign-in; when a step fails the run files are kept as the
`j2-native-reports` artifact.

**The goldens behind both surfaces** are generated with Unicode 13.0.0. CI's
`unicode-13-goldens` job runs their regeneration checks on Python 3.9 (Unicode
13.0.0; the job asserts it) through `scripts/ci_unicode_goldens.py`, which counts
nine checks by name and fails on a skip: the `_fold.py`, `_marks.py` and
`zig/src/unicode_tables.zig` tables, the marks guard, and the analyzer-v3, title,
BM25, fuzzy and verb-forms goldens. The three table checks compare every byte but
the generating Python's patch version in their header (the runner's 3.9 is not
the Mac's 3.9.6; `tests/unicode_tables_header.py`). The 3.11 jobs still skip
these checks; this job is where they run.

**Where the surfaces may differ.** Only three reasons are accepted, and
`j2_run.py --compare A B` names one for every query whose first grade-2 rank or
top 10 differs: the analyzer (the Python reference folds case fully for body
text, `searchd` simply: `ﬁ`, `ﬂ`, `ß`), tie order on exactly equal scores (document
index in `searchd`, chunk id in Python), and f32 against f64 near-ties. At the
baseline: `a06`, `a07`, `a09` by the analyzer (`a07` and `a09` are rank 1 in Python
and not found by `searchd`); `c06`, `c07`, `c10`, `c12`, `c14`, `c21`, `o04`, `o08` by tie
order below the answer (no first grade-2 rank moves); nothing unexplained.
A path prefix is not a fourth reason (J2 uses none; S5-T7): under one, both
surfaces score `content` with BM25's count, average length and document
frequencies (a group's shared df too) over the chunks the caller may see (roots
and labels) and let the prefix narrow only the candidates, while the body and
file-name channels of `filename` and `both` take theirs over the chunks and files
under the prefix and the title part, in every mode, over the visible files
(`tests/test_prefix_statistics.py` holds both surfaces to it).

**The baseline** (6 Nov 2026, engine `6ef4c3b`, `searchd` ReleaseSmall; MRR@10,
with success@1 in brackets):

| Slice | n | searchd content | searchd both | Python content | Python both |
|---|---:|---:|---:|---:|---:|
| control | 23 | 1.000 (1.000) | 0.924 (0.870) | 1.000 (1.000) | 0.924 (0.870) |
| misspelling | 16 | 0.199 (0.062) | 0.156 (0.062) | 0.199 (0.062) | 0.156 (0.062) |
| morphology | 13 | 0.362 (0.154) | 0.295 (0.077) | 0.362 (0.154) | 0.295 (0.077) |
| accent | 9 | 0.255 (0.111) | 0.220 (0.111) | 0.485 (0.333) | 0.337 (0.222) |
| Tamil | 13 | 0.308 (0.231) | 0.256 (0.231) | 0.308 (0.231) | 0.256 (0.231) |
| title intent | 11 | 0.258 (0.000) | 0.685 (0.545) | 0.258 (0.000) | 0.685 (0.545) |
| phrase | 10 | 0.900 (0.800) | 0.900 (0.800) | 0.900 (0.800) | 0.900 (0.800) |
| overall | 95 | 0.516 (0.400) | 0.520 (0.421) | 0.538 (0.421) | 0.531 (0.432) |

Read it as a map, not a score. Keyword search answers the control slice and
nothing past an exact token: a misspelt, inflected, accented or Tamil-suffixed
word is simply dropped, and the answer survives only where another query word
carries it (Tamil's three successes are the guards, which must stay as they
are). Title intent is lost in the body (no answer at rank 1) and mostly
recovered by `both`, except where only the folder carries the words. `both` costs
control three rank-1 answers (`c02`, `c06`, `c07`: a one-word file-name match on
`pe-kit`, `emails-to-school` and `fish-tank` fuses above a full body answer). The
phrase slice is weaker than it was meant to be: in eight of ten rows BM25 already
puts the adjacent answer first, because the answers are short sections that
repeat the words in their heading; a proximity change has little to win there,
and `p07` (the reversed row) is the one it must not flip.

**Written against the code as of `6ef4c3b`**, where
`docs/research/2026-10-luxir-learnings.md` is out of date on four points:
§2/§5 describe Tamil words split at every vowel sign (S1-T14 keeps them whole,
so a Tamil inflection is a clean miss, not fragment noise); §3.0/§8 predate
`find` with positions, phrase and prefix modes (S3-T2), so phrase rows use the
knowledge query, where proximity is absent, and keep one `find:phrase` row;
learning 7's additive file-name weight is not what shipped (S4-T4's channel is
stem only and `both` fuses per file with RRF); and the apostrophe already splits
a singular possessive (`dinosaur's` → `dinosaur`, `s`), so the loss is the plural
form, not the possessive. The research doc itself is not edited.

### S5-T2: the title field

[S5-T2](tasks/S5-T2.md) adds the [title field](title-field-v1.md) (a file's
root-relative folder names and stem, BM25 times coverage, weight 2.5) to the
lexical channel under `content` and makes `both` a score-level merge per file.
J2 gained the slice **`title-heldout`** (8 rows, judged before any ranking code
existed, its cells with the engine before S5-T2 recorded as an extension of the
baseline): the weight was chosen on `title` and checked, not re-tuned, there.
The overall line stays the mean over S5-T1's 95 graded queries; `title-heldout`
has its own line. At S5-T2 (`searchd` ReleaseSmall; MRR@10, success@1 in
brackets; S5-T1's baseline above):

| Slice | n | searchd content | searchd both | Python content | Python both |
|---|---:|---:|---:|---:|---:|
| control | 23 | 1.000 (1.000) | 1.000 (1.000) | 1.000 (1.000) | 1.000 (1.000) |
| misspelling | 16 | 0.199 (0.062) | 0.156 (0.062) | 0.199 (0.062) | 0.156 (0.062) |
| morphology | 13 | 0.349 (0.154) | 0.346 (0.154) | 0.349 (0.154) | 0.346 (0.154) |
| accent | 9 | 0.255 (0.111) | 0.220 (0.111) | 0.481 (0.333) | 0.337 (0.222) |
| Tamil | 13 | 0.308 (0.231) | 0.269 (0.231) | 0.308 (0.231) | 0.269 (0.231) |
| title intent | 11 | 0.955 (0.909) | 0.955 (0.909) | 0.955 (0.909) | 0.955 (0.909) |
| phrase | 10 | 0.900 (0.800) | 0.900 (0.800) | 0.900 (0.800) | 0.900 (0.800) |
| overall | 95 | 0.595 (0.505) | 0.579 (0.505) | 0.616 (0.526) | 0.590 (0.516) |
| title-heldout | 8 | 1.000 (1.000) | 1.000 (1.000) | 1.000 (1.000) | 1.000 (1.000) |

(`title-heldout` before S5-T2: 0.375 (0.375) under `content` and 0.500 (0.500)
under `both` on both surfaces.) Title intent goes from no answer at rank 1 to
ten of eleven under `content`, and `both` no longer costs control (`c02`,
`c06`, `c07` back at rank 1). The ranks that move otherwise are the ones the
plan predicted: `content` `o06` 2 → 3, `o08` 1 → 2, `o13` 2 → 1, `p02` 2 → 1,
`p06` 1 → 2 and, in Python only, `a06` 5 → 6 (`searchd` keeps 8); `both` `o13`
3 → 1, `t06` 3 → 2, `ti09` 1 → 2. Among the negatives the top hit of `cn1`,
`mn2`, `on2` and `tin1` changes (under `both`, the first three): `on2`
("painting the fence") now tops `pets/biscuit-the-dog.md` through the word
`the` in its name, the known residual of a field without stop words. The
surfaces still differ only by the analyzer on a first grade-2 rank (`a06`,
`a07`, `a09`) and by tie order below the answer. The baseline is re-recorded at
S5-T2 in its own commit.

### S5-T3: misspelling tolerance

[S5-T3](tasks/S5-T3.md) adds [fuzzy-v1](fuzzy-v1.md): a Latin query word of 5
or more code points that no chunk in scope and no visible file's name holds is
also searched as up to 3 dictionary words sharing its first letter, within one
edit (5 code points) or two (6 or more), scored as one word. J2 gained the
slice **`misspelling-heldout`** (12 rows, judged before any ranking code
existed; bar: `content` success@1 ≥ 0.40, no row at rank 1 lost). At S5-T3
(`searchd` ReleaseSmall; MRR@10, success@1 in brackets; S5-T2's cells above):

| Slice | n | searchd content | searchd both | Python content | Python both |
|---|---:|---:|---:|---:|---:|
| control | 23 | 1.000 (1.000) | 1.000 (1.000) | 1.000 (1.000) | 1.000 (1.000) |
| misspelling | 16 | 0.593 (0.500) | 0.539 (0.500) | 0.593 (0.500) | 0.539 (0.500) |
| morphology | 13 | 0.429 (0.308) | 0.404 (0.308) | 0.429 (0.308) | 0.404 (0.308) |
| accent | 9 | 0.551 (0.444) | 0.553 (0.444) | 0.667 (0.556) | 0.559 (0.444) |
| Tamil | 13 | 0.308 (0.231) | 0.269 (0.231) | 0.308 (0.231) | 0.269 (0.231) |
| title intent | 11 | 0.955 (0.909) | 0.955 (0.909) | 0.955 (0.909) | 0.955 (0.909) |
| phrase | 10 | 0.900 (0.800) | 0.900 (0.800) | 0.900 (0.800) | 0.900 (0.800) |
| overall | 95 | 0.700 (0.632) | 0.683 (0.632) | 0.711 (0.642) | 0.683 (0.632) |
| title-heldout | 8 | 1.000 (1.000) | 1.000 (1.000) | 1.000 (1.000) | 1.000 (1.000) |
| misspelling-heldout | 12 | 0.958 (0.917) | 0.958 (0.917) | 0.958 (0.917) | 0.958 (0.917) |

(`misspelling-heldout` before S5-T3: 0.558 (0.333) under `content` and 0.465
(0.333) under `both` through `searchd`.) The S5-T1 gate passes on both
surfaces and both variants with an empty allow-list. Two ranks worsen, as the
plan measured: `m15` 5 → 8 under `content` (exactly the gate's three-place
limit: `science` also lifts `ideas/kitchen-science.md`) and `o10` 2 → 4 in both
variants (`boxes` is not in J2 and expands to `bones`). `m03`, `m04`, `m15`
and `m16` reach the right file through its intro chunk, which J2 grades 0.
Tamil and the title slices do not move. The surfaces differ on a first
grade-2 rank only by the analyzer (`a06`, `a07`; `a09` now agrees through the
expansion `strasse` → `straße` in the engine). The baseline is re-recorded at
S5-T3 in its own commit.

The older packs do not move, except mixed, which moves exactly as the plan
named (Python reference): MRR 0.775 → 0.833, nDCG 0.833 → 0.876, success@1
0.60 → 0.70. `bread-rises`, `combine-exact-and-meaning` and
`crash-safe-snapshot` gain, and `latency-breakdown` goes 1 → 2, because
`inference` is also searched as `influence` (distance 2). That loss was
accepted as a named move (S5-T3 ruling 1).

### S5-T4: word-form groups

[S5-T4](tasks/S5-T4.md) adds [fold-groups-v1](fold-groups-v1.md): at query time
a word is also searched as the words the files hold that share its key (K:
fold, Latin marks, English plural, Tamil suffixes), scored as one word, before
fuzzy-v1 runs on the words without a group. J2 gained three held-out slices,
**`morphology-heldout`** (14 rows), **`accent-heldout`** (11) and
**`tamil-heldout`** (13), judged before any K code existed, their cells with
the engine before S5-T4 recorded in that commit. The Python reference's v2 body
fold was made the engine's simple fold first (the `ß` row; mirror follows
engine), so the two surfaces now agree on every accent cell. At S5-T4
(`searchd` ReleaseSmall; MRR@10, success@1 in brackets; S5-T3's cells above):

| Slice | n | searchd content | searchd both | Python content | Python both |
|---|---:|---:|---:|---:|---:|
| control | 23 | 1.000 (1.000) | 1.000 (1.000) | 1.000 (1.000) | 1.000 (1.000) |
| misspelling | 16 | 0.649 (0.562) | 0.594 (0.562) | 0.649 (0.562) | 0.594 (0.562) |
| morphology | 13 | 0.718 (0.538) | 0.679 (0.538) | 0.718 (0.538) | 0.679 (0.538) |
| accent | 9 | 0.846 (0.778) | 0.847 (0.778) | 0.846 (0.778) | 0.847 (0.778) |
| Tamil | 13 | 1.000 (1.000) | 1.000 (1.000) | 1.000 (1.000) | 1.000 (1.000) |
| title intent | 11 | 0.955 (0.909) | 0.955 (0.909) | 0.955 (0.909) | 0.955 (0.909) |
| phrase | 10 | 0.900 (0.800) | 0.900 (0.800) | 0.900 (0.800) | 0.900 (0.800) |
| overall | 95 | 0.872 (0.811) | 0.857 (0.811) | 0.872 (0.811) | 0.857 (0.811) |
| title-heldout | 8 | 1.000 (1.000) | 1.000 (1.000) | 1.000 (1.000) | 1.000 (1.000) |
| misspelling-heldout | 12 | 0.958 (0.917) | 0.958 (0.917) | 0.958 (0.917) | 0.958 (0.917) |
| morphology-heldout | 14 | 0.690 (0.571) | 0.714 (0.571) | 0.690 (0.571) | 0.714 (0.571) |
| accent-heldout | 11 | 0.955 (0.909) | 0.909 (0.909) | 0.955 (0.909) | 0.909 (0.909) |
| tamil-heldout | 13 | 0.962 (0.923) | 0.962 (0.923) | 0.962 (0.923) | 0.962 (0.923) |

(The held-out slices before S5-T4, through `searchd`: `morphology-heldout`
0.369 (0.214) under `content` and 0.393 (0.214) under `both`;
`accent-heldout` 0.500 (0.455) and 0.455 (0.455); `tamil-heldout` 0.192
(0.154) both ways.) The S5-T1 gate passes on both surfaces and both variants
with one row allowed, `ah11`, by orchestrator ruling 3 (`fixtures/j2/allow.json`
says why: the declared merge guard: `méla` groups with `mela`, which the
answer's other section holds). Four ranks
worsen by one place, within the gate's limit: `a06` (8 → 9 under `content`,
7 → 8 under `both`), `m03` 6 → 7 and `m16` 3 → 4 under `content`. `o10`
returns to rank 1 (`boxes` now searches `box`, not `bones`), and `m07`
(`libary books`) reaches rank 1. The surfaces differ only in tie order below the answer (13 `content`
rows, no `both` row). The baseline is re-recorded at S5-T4 in its own commit.

The older packs do not move, except mixed, which moves exactly as Phase 1
traced (Python reference): MRR 0.833 → 0.796, success@1 0.70 → 0.65, above the
bars (0.775, 0.60). Each move is S grouping a true singular and plural and
another chunk's BM25 winning, none a stemmer error, and all were accepted as
named moves (S5-T4 orchestrator ruling 4 on Phase 1):

| Query | First relevant rank | Group | The chunk that passes, through |
|---|---|---|---|
| `crash-safe-snapshot` | 1 → 2 | `readers` → `reader` | `storage/compaction.md`, `reader` |
| `permission-filter-order` | 1 → 2 | `candidates` → `candidate` | `search/hybrid.md`, `candidate` |
| `avoid-full-corpus-scan` | 2 → 3 | `file` → `files` | `storage/compaction.md`, `files` |
| `malicious-indexed-instructions` | 3 → 4 | `document` → `documents` | `storage/compaction.md`, `documents` |
| `safe-old-file-cleanup` | 2 → 1 (gain) | `readers` → `reader` | the answer, `storage/compaction.md`, `reader` |

### S5-T5: verb forms

[S5-T5](tasks/S5-T5.md) first graded the intro chunks of `m03`, `m04`, `m15`
and `m16` 1 (step 0, S5-T3 ruling Q3's regrade): 12 of 484 cells moved per
surface, all MRR@10, nDCG@10 and recall@5 of the misspelling slice and of
overall (misspelling MRR@10 0.649 → 0.859 under `content`, 0.594 → 0.844 under
`both`), and no success@1 cell or first grade-2 rank. J2 then gained
**`verbform-heldout`** (19 rows and 2 negatives in three new files: 12 verb
rows, 5 look-alike guards, 2 rows whose typed word the files hold), judged
before any R code existed. The task adds
[fold-groups-v2](fold-groups-v2.md): a query word is also searched as its `-ing`
and `-ed` forms that the files hold, at 1.0 for a word no file holds and at 0.5,
under a cap on the form's key document frequency, for one they do. At S5-T5
(`searchd` ReleaseSmall; MRR@10, success@1 in brackets):

| Slice | n | searchd content | searchd both | Python content | Python both |
|---|---:|---:|---:|---:|---:|
| control | 23 | 1.000 (1.000) | 1.000 (1.000) | 1.000 (1.000) | 1.000 (1.000) |
| misspelling | 16 | 0.859 (0.562) | 0.844 (0.562) | 0.859 (0.562) | 0.844 (0.562) |
| morphology | 13 | 0.808 (0.692) | 0.795 (0.692) | 0.808 (0.692) | 0.795 (0.692) |
| accent | 9 | 0.846 (0.778) | 0.847 (0.778) | 0.846 (0.778) | 0.847 (0.778) |
| Tamil | 13 | 1.000 (1.000) | 1.000 (1.000) | 1.000 (1.000) | 1.000 (1.000) |
| title intent | 11 | 0.955 (0.909) | 0.955 (0.909) | 0.955 (0.909) | 0.955 (0.909) |
| phrase | 10 | 0.900 (0.800) | 0.900 (0.800) | 0.900 (0.800) | 0.900 (0.800) |
| overall | 95 | 0.920 (0.832) | 0.915 (0.832) | 0.920 (0.832) | 0.915 (0.832) |
| title-heldout | 8 | 1.000 (1.000) | 1.000 (1.000) | 1.000 (1.000) | 1.000 (1.000) |
| misspelling-heldout | 12 | 0.958 (0.917) | 0.958 (0.917) | 0.958 (0.917) | 0.958 (0.917) |
| morphology-heldout | 14 | 0.833 (0.714) | 0.857 (0.714) | 0.833 (0.714) | 0.857 (0.714) |
| accent-heldout | 11 | 0.955 (0.909) | 0.909 (0.909) | 0.955 (0.909) | 0.909 (0.909) |
| tamil-heldout | 13 | 0.962 (0.923) | 0.962 (0.923) | 0.962 (0.923) | 0.962 (0.923) |
| verbform-heldout | 19 | 0.974 (0.947) | 0.947 (0.947) | 0.974 (0.947) | 0.947 (0.947) |

(`verbform-heldout` before S5-T5, through `searchd`: 0.377 (0.263) under
`content`, 0.263 (0.263) under `both`. Before S5-T5, after step 0: morphology
0.718 (0.538) / 0.679 (0.538), morphology-heldout 0.690 (0.571) / 0.714
(0.571), overall 0.907 (0.811) / 0.900 (0.811).) The two surfaces agree on all
1,720 per-query cells. The first grade-2 rank moves on 18 rows under `content`
and 17 under `both`, every move a gain: `o06` 3 → 1 (outside the top 10 → 1
under `both`), `o11` 2 → 1, `oh11` and `oh12` outside → 1, the twelve verb rows
`vh01`–`vh12` to rank 1, `vt2` 3 → 1 (outside → 1 under `both`) and `vt1` 3 → 2
under `content`. The five guards `vg1`–`vg5` and `c22` stay at rank 1. `o05`
stays at 3, `o12` at 6 under `content` and outside the top 10 under `both`, and
`vt1` outside the top 10 under `both`. The S5-T1 gate passes on both surfaces
and both variants with nothing added to the allow-list; with R's cap removed
(a plant) `c22` drops to rank 2, control MRR@10 to 0.978, and the gate fails.
The negative `on2` (`painting the fence`) now tops `projects/pip-planet-model.md`
through `paint` (recorded, not gated: S5-T5 ruling 5). The older packs do not
move (Python reference: every pack's metrics and per-query ranks equal
fold-groups-v1's). The baseline is re-recorded at S5-T5 in its own commit.
