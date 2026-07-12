# UC-005 — Relevance regression gate on new sample data

## Actor and goal

A maintainer, contributor, or coding agent changes tokenization, chunking,
lexical scoring, embeddings, fusion, or reranking and needs objective evidence
that early retrieval relevance did not silently regress.

## Corpus

- a tiny committed graded product fixture for dependency-free CI;
- a deterministic adapter over a public judged product-search collection;
- later, representative user-owned corpora with independently authored queries.

The corpus, judgments, grade mapping, selection algorithm, seed, text rendering,
retrieval modes, model identity, and cutoff are one versioned profile.

## Representative questions

1. Did this change improve or preserve graded relevance in the first ten results?
2. Did hybrid fusion beat the lexical baseline, or did it displace exact matches?
3. Which queries have no known positive in the first ten?
4. Did a data adapter keep every positive judgment for the selected queries?
5. Can a newly supplied sample reproduce the same profile and baseline?
6. Negative: does an unsupported query incorrectly get presented as proof that
   the system has a confident answer?

The sixth question is recorded but is not part of the current relevance gate:
an explicit no-answer decision depends on calibrated support behavior under
CAP-14/E-02. The current harness measures ranked retrieval only.

## Authorization and egress

- The committed fixture is public project data.
- WANDS is downloaded separately under its MIT license; the repository stores
  the adapter and benchmark results, not a copied external catalog.
- The base smoke path is local and dependency-free.
- Optional neural evaluation uses a pinned local provider and records its exact
  identity; hosted inference is not required.
- A private user corpus must never be committed with its judgments or retrieved
  text unless the owner explicitly authorizes that publication.

## Freshness

- CI runs the tiny smoke profile on each pull request.
- Material ranking changes rerun the pinned real-data profile before merge.
- New data creates a new profile and baseline rather than silently replacing the
  old one.

## Measurable acceptance

- The v2 suite validates unique query/judgment identities and grades 1–3.
- nDCG@10 uses graded judgments; MRR@10, success@10, and macro recall@10 remain
  visible diagnostics.
- One product/path earns gain only once even if multiple chunks are returned.
- The committed 10-product/4-query lexical fixture scores 1.0 on all four metrics.
- A baseline comparison fails when any metric regresses beyond the configured
  absolute tolerance and rejects a baseline from a different `profile_id`.
- A WANDS 10k request emits a manifest stating requested versus actual counts,
  selection rules, grade mapping, and limitations.
- Raw machine-readable results and a worked/failed interpretation are preserved.

## Risks and mitigations

| Risk | Mitigation |
|---|---|
| Sampling makes a score look better | mark sampled profiles non-comparable to full WANDS; preserve manifest |
| Unjudged products are treated as irrelevant | state pooled-judgment limitation; inspect failure queries |
| One easy fixture becomes a quality claim | label CI fixture synthetic/mechanical only |
| Benchmark overfitting | keep lexical baseline, held-out profiles, and more than one domain |
| One metric hides a regression | report nDCG, MRR, success, recall, and per-query output |
| External data copied into the repository | commit adapter/results only; download WANDS separately |

## Evidence

- Requirement: FR-12 / CAP-11.
- Theory, commands, and first result: [product relevance benchmark](../relevance-benchmark.md).
- Committed fixture: `fixtures/relevance-smoke/`.
- Runner: `relevance_smoke.py`.
- Adapter: `scripts/prepare_wands_smoke.py`.
