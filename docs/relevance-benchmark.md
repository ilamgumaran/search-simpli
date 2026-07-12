# Product-search relevance benchmark and smoke gate

Status: diagnostic implementation. The dependency-free CI profile is committed;
the WANDS adapter and first 10,000-product lexical run are implemented and
recorded. This is an extension of **CAP-11 / FR-12**, not a new capability.

## Objective

Prove that a ranking change improves or at least preserves early relevance on a
fixed judged corpus. The gate must catch regressions, identify which queries
failed, and remain reproducible when new sample data is supplied. It must not
turn one offline number into a claim that search is universally "good."

## Research basis

- [WANDS](https://github.com/wayfair/WANDS) is a public MIT-licensed product
  search collection with 42,994 products, 480 queries, and 233,448 human
  query-product judgments labeled Exact, Partial, or Irrelevant.
- [Amazon Shopping Queries / ESCI](https://github.com/amazon-science/esci-data)
  is the later scale profile. Its reduced ranking set has 48,300 queries and
  1,118,011 query-product judgments; its official task ranks a supplied
  candidate list and reports nDCG. That task is useful but is not directly
  score-comparable to full-catalog retrieval.
- [BEIR](https://arxiv.org/abs/2104.08663) uses nDCG@10 as its principal
  cross-domain retrieval measure and shows that BM25 remains a strong baseline;
  no retrieval family wins consistently across domains.

There is therefore no universal nDCG value that proves relevance. A credible
gate pins a dataset, sampling rule, text representation, grade mapping, cutoff,
and baseline, then blocks an unexplained regression on that same profile.

## Metrics and decision rule

Primary metric: **mean nDCG@10** with exponential gain `2^grade - 1` and
logarithmic rank discount. It captures both graded usefulness and whether the
best products appear early.

For WANDS:

| Label | Grade | Gain |
|---|---:|---:|
| Exact | 2 | 3 |
| Partial | 1 | 1 |
| Irrelevant or unjudged | 0 | 0 |

Diagnostics:

- **MRR@10**: how early the first positive appears;
- **success@10**: fraction of queries with any positive in the first ten;
- **macro recall@10**: fraction of known positives retrieved, averaged by query.

MRR and recall answer different questions. A change may improve the ordering of
many graded results while moving the first relevant result down for a few
queries, so the smoke report preserves all four metrics and per-query output.

Gate policy:

1. The tiny committed fixture has exact expected floors and runs in CI.
2. A real-data profile first records a baseline; it does not invent a target.
3. Later runs must have the same `profile_id` (suite, corpus hashes, modes,
   vector identity, and cutoff) and may regress by no more than the explicitly
   approved absolute tolerance.
4. A different dataset/sample is a new profile, never a continuation of the old
   score series.

## Benchmark tiers

| Tier | Corpus and queries | Purpose | Claim allowed |
|---|---|---|---|
| CI mechanics | 10 authored products, 4 graded queries | Formula, plumbing, deterministic regression gate | implementation works on fixture |
| WANDS sampled | 10,000 products, 47 selected queries in the current seed | Fast real-label diagnostic | comparison within this exact profile |
| WANDS neural sampled | 500 products, 11 selected queries in the current seed | Explicit local BGE/vector/fusion diagnostic | comparison within this exact smaller profile |
| WANDS full | 42,994 products, 480 queries | Product-domain baseline | comparison with identical full-corpus protocol |
| ESCI candidate ranking | 1,000+ sampled queries and their supplied candidates | Larger multilingual/ranking experiment | comparison within ESCI task protocol |

The requested 10k-products/1k-queries shape is not possible with WANDS while
preserving all known positives: WANDS has only 480 queries, and many queries have
hundreds of positive products. The deterministic 10k sampler retains a query
only if every Exact/Partial product fits. With seed `search-simpli-wands-v1`, it
retains 47 queries and 20,669 positive judgments. This is honest but biased by
the cap, so its score is not comparable to a full WANDS run.

## Run the committed smoke gate

```sh
python3 relevance_smoke.py \
  fixtures/relevance-smoke/corpus \
  fixtures/relevance-smoke/judgments.json \
  --mode lexical --top-k 10 \
  --min-ndcg 1 --min-mrr 1 --min-recall 1 --min-success 1
```

The fixture is intentionally easy and synthetic. Its `1.0` scores prove only
that the ranking/evaluation path and gate are wired correctly.

## Prepare and run WANDS

```sh
git clone --depth 1 https://github.com/wayfair/WANDS.git /tmp/WANDS

python3 scripts/prepare_wands_smoke.py \
  /tmp/WANDS/dataset /tmp/search-simpli-wands-10k \
  --max-products 10000 --max-queries 1000

python3 relevance_smoke.py \
  /tmp/search-simpli-wands-10k/corpus \
  /tmp/search-simpli-wands-10k/judgments.json \
  --mode lexical --top-k 10 \
  --output /tmp/wands-lexical.json
```

The preparer emits `manifest.json`, `judgments.json`, and a bounded product
corpus. Selection is SHA-256 deterministic. It includes all Exact/Partial
products for each retained query, then fills remaining slots with explicitly
judged negatives and stable distractors. Product summaries are capped at 1,500
characters so one product is one Search Simpli chunk.

To compare the optional pinned neural and hybrid paths, start with a separately
prepared 500-product profile. On the observed CPU environment, 10k and 2k neural
indexing exceeded a practical interactive smoke duration.

```sh
python3 scripts/prepare_wands_smoke.py \
  /tmp/WANDS/dataset /tmp/search-simpli-wands-500 \
  --max-products 500 --max-queries 1000

python3 relevance_smoke.py \
  /tmp/search-simpli-wands-500/corpus \
  /tmp/search-simpli-wands-500/judgments.json \
  --vector-mode neural --model-cache /tmp/search-fastembed-models \
  --mode lexical --mode vector --mode hybrid --top-k 10 \
  --save-index /tmp/search-simpli-wands-500-index.json \
  --output /tmp/wands-neural.json
```

Subsequent evidence runs can replace `--vector-mode neural --save-index ...`
with `--index /tmp/search-simpli-wands-500-index.json`; the runner validates that
the persisted index root matches the corpus and reconstructs the exact provider
identity for vector/hybrid queries.

## First observed lexical results

Local diagnostic run on 2026-07-12:

| Representation | Chunks | nDCG@10 | MRR@10 | Success@10 | Macro recall@10 |
|---|---:|---:|---:|---:|---:|
| Five-field multiline, failed first attempt | 41,377 | 0.5562 | 0.8830 | 0.8936 | 0.0468 |
| Bounded one-product/one-chunk summary | 10,000 | 0.6866 | 0.8574 | 0.9149 | 0.0528 |

Machine-readable evidence: [profile manifest](../benchmarks/wands-10k-profile-manifest-2026-07-12.json),
[failed multiline run](../benchmarks/wands-10k-multichunk-failed-2026-07-12.json),
and [corrected lexical run](../benchmarks/wands-10k-lexical-2026-07-12.json).

What worked: making the retrieval unit match the judged product unit removed
duplicate chunks from top-10, improved nDCG by 0.1304, improved success by
0.0213, improved recall, and reduced build/evaluation time.

What did not work: the first representation let several chunks from one product
consume the result page. MRR also decreased by 0.0255 after the correction even
while nDCG, success, and recall improved. That is why the gate reports multiple
metrics and does not compress relevance to one number.

Example failures in the corrected lexical run include `living room ideas`,
`large bases`, `promo codes or discounts`, and `white abstract`, all with no
known positive in the first ten. Exact-name queries such as `westling coffee
table` and `hulmeville writing desk with hutch` reached nDCG@10 1.0. These are
useful targets for a real semantic/hybrid comparison.

## First observed neural and hybrid result

A smaller same-seed profile retained 500 products, 11 queries, and 500 positive
judgments. It is a separate profile and its scores must not be compared directly
to the 10k table.

| Mode | nDCG@10 | MRR@10 | Success@10 | Macro recall@10 |
|---|---:|---:|---:|---:|
| Lexical | 0.4176 | 0.5909 | 0.6364 | 0.1745 |
| BGE vector | **0.4550** | **0.6169** | **0.8182** | **0.2503** |
| Equal-RRF hybrid | 0.4287 | 0.5584 | 0.7273 | 0.2048 |

The pinned `BAAI/bge-small-en-v1.5` vector path improved nDCG by 0.0374,
success by 0.1818, and recall by 0.0758 over lexical. Equal-RRF improved nDCG,
success, and recall over lexical, but underperformed vector-only and reduced MRR
by 0.0325. This repeats the earlier authored-fixture warning: semantic value is
real on this sample, while equal-weight fusion is not automatically optimal.

Neural index construction took 313.4 seconds for 500 bounded product summaries;
evaluation of all three modes took 0.934 seconds. The attempted 10k and 2k
neural builds were terminated after exceeding an interactive smoke duration
without producing reports. Neural evidence should therefore reuse a persisted
index or run as an explicit/scheduled profile, not in dependency-free PR CI.

Machine-readable evidence: [neural profile manifest](../benchmarks/wands-500-neural-profile-manifest-2026-07-12.json)
and [lexical/vector/hybrid report](../benchmarks/wands-500-neural-hybrid-2026-07-12.json).

## Limits

- The 10k selection is deterministic but not an unbiased WANDS test split.
- Unjudged products are treated as grade 0; pooled judgments are not exhaustive.
- WANDS is furniture/home-goods heavy and does not establish other domains.
- The first run has no confidence intervals or repeated sampling seeds.
- The neural sample has only 11 queries, and local model inference dominates its
  wall time; its aggregate deltas are hypotheses for a larger persisted run.
- Offline relevance does not measure conversion, satisfaction, answer
  groundedness, authorization, or latency under concurrent load.
- Negative/unanswerable behavior needs a calibrated support threshold (CAP-14 /
  E-02); absence of a judged positive is not proof the engine should return an
  explicit "no answer."

The next credible decision is to run the full WANDS profile and at least one
second domain/profile, then set held-out regression tolerances from observed
variance rather than from preference.
