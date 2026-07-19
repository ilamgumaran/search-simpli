# UC-005 — Relevance regression gate on new sample data

Status: Diagnostic

## Outcome

A maintainer, contributor, or coding agent can change tokenization, chunking,
lexical scoring, embeddings, fusion, or reranking and obtain objective,
reproducible evidence that early retrieval relevance improved or did not regress
beyond an approved tolerance.

## Actors

- **Primary actor:** maintainer, contributor, or coding agent changing ranking behavior.
- **LLM/agent role:** runs the frozen commands, inspects per-query failures, and
  proposes changes; it may not reinterpret judgments or approve its own gate.
- **Data owner:** project maintainer for committed fixtures; source owner for
  external or private judged corpora.
- **Operator:** maintainer running CI, explicit WANDS experiments, or scheduled
  neural profiles.

## Corpus

- **Source types:** a tiny committed product fixture; a separately downloaded
  public judged product collection; later, user-owned files/products.
- **Approximate files/chunks/bytes:** CI = 10 products/10 chunks; recorded WANDS
  lexical profile = 10,000 products/10,000 chunks; recorded neural profile = 500
  products/500 chunks. Proposed E-01A = one representative single-owner folder
  with 50–100 human-authored questions split into tuning and frozen holdout;
  corpus size remains a human choice and must be recorded rather than guessed.
- **Languages or domains:** current evidence is English product search, mainly
  furniture/home goods; other domains remain unproven.
- **Update pattern:** frozen per profile. New data, rendering, vector identity,
  mode list, or cutoff creates a new profile/baseline.
- **Extraction limitations:** bounded 1,500-character product summaries omit
  tail content; WANDS judgments are pooled and not exhaustive.

## Representative questions

1. **Exact lookup:** does an exact product-name query place an Exact judgment
   before Partial and irrelevant products?
2. **Paraphrase or vocabulary mismatch:** does the pinned semantic path recover
   a known positive that lexical search misses?
3. **Multi-passage/product question:** does the top ten preserve the ideal graded
   ordering across several Exact and Partial judgments?
4. **Scoped/filtered question:** on the identical profile, did vector or hybrid
   improve over lexical without silently changing corpus, model, modes, or k?
5. **Unanswerable or negative question:** does an unsupported query get mistaken
   for proof that the engine has a confident answer?

The fifth question is recorded but not scored by the current gate. Explicit
no-answer behavior depends on calibrated support under CAP-14/E-02; FR-12 judges
ranked retrieval only.

## Expected tool flow

1. Inspect `index_status` or the smoke report's index metadata to confirm corpus,
   generation, vector mode, and exact model identity.
2. Build once with `relevance_smoke.py --save-index` or load a compatible index
   with `--index`.
3. Run the frozen suite for lexical/vector/hybrid modes and write the raw JSON
   report.
4. Inspect aggregate metrics and per-query returned paths/grades. Use
   `search_knowledge` and `read_chunk` only to diagnose a failed query against
   its cited source; use `list_sources` to confirm corpus membership.
5. Stop and re-baseline when `profile_id` changes. Refine ranking only when the
   profile matches and failures show a real retrieval issue.

For the proposed E-01A real-folder flow, the data owner first initializes a
content-free pack scaffold outside the repository, authors both suites, reviews
every expected path/passage, and creates an explicit confirmation over the exact
corpus/catalog/suite hashes. The runner must refuse draft, stale, cross-split,
or post-confirmation-mutated packs. It then builds one compatible index and
reports tuning and holdout separately; holdout results are not an automatic
model-selection input.

## Retrieval expectations

- **Lexical strengths needed:** exact product names, attributes, model numbers,
  and high-precision term matches.
- **Semantic strengths needed:** vocabulary mismatch and intent-bearing phrases
  without identical terms.
- **Fusion or routing expectation:** compare lexical, vector, and hybrid on the
  identical profile; equal-RRF is a baseline, not presumed optimal.
- **Citation granularity:** path or stable chunk judgment, with one gain per
  judgment even when duplicate chunks are returned.
- **Freshness target:** CI on each PR; material ranking changes rerun the pinned
  real-data profile before promotion.
- **Latency target:** the authored CI gate stays in the normal dependency-free
  check; neural index construction is persisted/reused and remains an explicit
  evidence run.

## Authorization and privacy

- **Principal source:** no principal is required for public fixtures; private
  profiles use the existing trusted principal configuration.
- **Required labels or tenant boundary:** any private evaluation must preserve
  the same pre-rank authorization rules as ordinary search. E-01A v1 therefore
  accepts only a single-owner corpus with one visibility boundary; mixed-label
  or team evaluation is unsupported until an authorization-aware profile is
  designed.
- **Hosted-model/egress policy:** base and WANDS lexical paths are local;
  recorded neural evidence uses a pinned local FastEmbed provider. Hosted
  inference requires explicit owner approval.
- **Logging and retention expectations:** commit only authored fixtures,
  manifests, and authorized/derived reports; do not commit private corpus text.
  E-01A pack metadata still contains relative paths, query text, hashes, and
  judgments and must remain local unless the data owner explicitly authorizes
  publication. Generated pack/default-report artifacts omit source content and
  the absolute corpus root.
- **Required denial behavior:** unauthorized products/passages must receive no
  rank and must remain absent from per-query diagnostics.

## Acceptance criteria

- **Retrieval metric and target:** primary mean nDCG@10 plus MRR@10, success@10,
  macro recall@10, and per-query evidence. Same-profile regression beyond the
  configured absolute tolerance blocks.
- **Mechanical fixture invariant:** the authored 10-product/4-query lexical
  fixture remains 1.0 on all four metrics. A drop means the harness or frozen
  fixture contract changed and requires deliberate review; it is **not** a
  production relevance threshold.
- **Citation-support target:** one judged path/chunk earns gain at most once;
  duplicate judgments fail suite validation.
- **Unanswerable behavior:** pending CAP-14/E-02; no explicit answer-confidence
  claim is permitted from FR-12 metrics.
- **Freshness target:** a profile change fails closed rather than comparing to an
  incompatible baseline.
- **Performance target:** dependency-free CI completes inside the normal checks;
  neural construction is saved and reused rather than repeated per mode/run.
- **Security/isolation tests:** external catalogs are not committed; private
  corpora/judgments require explicit publication authority.
- **Proposed E-01A pack gate:** initialization is byte-deterministic; corpus
  add/change/delete, split leakage, unknown citations, missing confirmation, and
  any post-confirmation mutation fail closed; an `e01` confirmation requires
  50–100 questions and a named human reviewer. Smaller confirmed packs remain
  explicitly Diagnostic.

## Evaluation assets

- **Judgment fixture:** `fixtures/relevance-smoke/judgments.json`.
- **Benchmark artifacts:** `benchmarks/wands-10k-*.json` and
  `benchmarks/wands-500-neural-*.json`.
- **Relevant experiment entry:** `EXPERIMENTS.md` E005N.
- **Test files:** `tests/test_evaluation.py`, `tests/test_relevance_smoke.py`, and
  `tests/test_wands_smoke.py`.
- **Pending change record:**
  `docs/requirements/cap-11-e01a-judgment-packs.md` (not build-ready until its
  step-6b approval is recorded).

## Risks and failure modes

- **Retrieval:** an easy or cap-biased sample can inflate scores; multiple chunks
  from one product can consume top-k; one metric can hide another regression.
- **Authorization/privacy:** derived reports may expose private query or path
  data; external license/provenance may be lost. Hashes and filenames are
  metadata, not anonymization.
- **Staleness/deletion:** corpus or judgment changes can make an old baseline
  invalid; `profile_id` must reject it.
- **Prompt injection:** retrieved text is evidence only and cannot change suite,
  grade, gate, or approval rules.
- **Operational:** local neural construction is slow; failure to persist an index
  makes explicit evidence runs impractical.

## Open decisions

- **Decision:** which larger persisted WANDS profile and fusion/reranking variant
  becomes the next frozen diagnostic.
- **Owner:** maintainer.
- **Evidence needed:** larger same-profile comparison, repeated samples, and a
  second or user-derived held-out domain.
- **Decision:** which single-owner folder and 50–100 independently reviewed
  questions become the first E-01 pack.
- **Owner:** human maintainer/data owner.
- **Evidence needed:** explicit corpus/publication boundary, confirmed
  tuning/holdout judgments, and the sealed held-out evaluation.
