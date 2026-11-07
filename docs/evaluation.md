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

**Where the surfaces may differ.** Only three reasons are accepted, and
`j2_run.py --compare A B` names one for every query whose first grade-2 rank or
top 10 differs: the analyzer (the Python reference folds case fully for body
text, `searchd` simply: `ﬁ`, `ﬂ`, `ß`), tie order on exactly equal scores (document
index in `searchd`, chunk id in Python), and f32 against f64 near-ties. At the
baseline: `a06`, `a07`, `a09` by the analyzer (`a07` and `a09` are rank 1 in Python
and not found by `searchd`); `c06`, `c07`, `c10`, `c12`, `c14`, `c21`, `o04`, `o08` by tie
order below the answer (no first grade-2 rank moves); nothing unexplained.

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
