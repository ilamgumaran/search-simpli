# Search quality: reviewed improvements and staged design

Date: 2026-10-19 · Status: proposed, planning only · Reviewed base: `7c40937`

Objective: return a small set of authorized, cited passages that actually
supports the user's question, with measurable protection against missed answers
and unsupported confidence. This review changes documentation only. It approves
no capability, starts no implementation, and records no new benchmark result.

The parent reviewed the code and existing evidence; a separate Sol agent audited
the quality gaps and dependencies. The recommendations extend existing board
items, with one newly shaped analyzer item (F-03). The bounded work is in the
[task breakdown](tasks/search-quality-follow-ups.md).

## Evidence and priorities

| Priority / board item | Evidence on the reviewed base | Proposed improvement |
|---|---|---|
| P1 · E-02 | `validate_suite` rejects empty `relevant` lists and recall divides by the number of positives in [evaluation.py](../src/search_platform/evaluation.py). Current reports cannot represent a fully unanswerable query. | Explicit answerability judgments and separate negative-query metrics. |
| P1 · L-04, offline slice | [relevance_smoke.py](../relevance_smoke.py) gates four aggregate metrics; per-query output already exists. A mean can hide a harmed query group. | Versioned per-query and segment comparison policy, with an intentionally bad candidate that improves the mean but fails a segment. |
| P1 dependency · E-01 / E-01A | Real-folder judgment-pack specification exists, but its named maintainer approval and human-owned corpus/judgments are pending. | Implement the already specified workflow only after its gates; establish a sealed, representative baseline. |
| P2 · F-01 | On the authored 20-query diagnostic, success@1 was 0.90 for BGE vector and 0.85 for equal-RRF hybrid. On the separate 500-product WANDS profile, nDCG@10 was 0.4550 vs 0.4287. | Compare fixed fusion weights and simple query routing, keeping exact lookups protected. |
| P2 · F-03, new shaped item | Python `tokenize` uses full `casefold`; Zig's analyzer uses simple mappings. The casefold gap is carried in the project state and journey. | Pin the intended Unicode contract, demonstrate differences, then make a separately approved analyzer migration. |
| Parallel measurement · F-02 | The recorded engine ranking benchmark is in-memory, synthetic, 32-dimensional and single-query. | Measure persisted 384-dimensional open/query/RSS/concurrency before selecting any new scale mechanism. |

These are diagnostic facts, not evidence that the proposed changes will improve
representative relevance. Sources: [evaluation](evaluation.md),
[product benchmark](relevance-benchmark.md), [scale benchmark](scale-benchmark.md),
[project state](../PROJECT-STATE.md), and [board](../IMPROVEMENT-BOARD.md).
The WANDS profiles have different corpora and query counts; compare modes within
each profile only. No new dataset, timing, or model run was performed here.

## 1. E-02: distinguish missing support from a search miss

Extend CAP-11's evaluation format with a new version (proposed v3; confirm at
task design review). Preserve v1/v2 parsing and metrics exactly. A query explicitly
declares `answerable`, `unanswerable`, or `unjudged`, scoped to a specified corpus
snapshot and visibility context. Missing labels or incomplete judgments must
never silently become negative examples. Answerable rows require positive
judgments; unanswerable rows require no positives and a reviewed rationale;
unjudged rows are diagnostic and excluded from scored denominators.

Start with five reproducible case families:

1. A real answer exists and matches an exact identifier.
2. A real answer exists through a paraphrase.
3. The corpus discusses the topic but contains no answer to the question.
4. An absent entity or requested fact has no supporting passage.
5. Support exists only outside the selected path or authorized view.

For the fifth family, any authorization-bearing evaluation must use a trusted
runner configuration and the real authorization path. A query file must not
select its own principal. Do not broaden E-01A's single-owner v1 pack to fit
multi-principal cases: use separate synthetic authorization fixtures.
The evaluator currently does not pass `principal_labels` to `search`; SQ-01 must
specify a trusted runner/API parameter and SQ-02 must thread it into the real
prefilter. Bind reports and profile compatibility to the trusted visibility
context, so different contexts cannot share a regression baseline. Specify that
identity without exposing private label names/configuration in published
reports; hashing sensitive names alone is not a privacy control. Test this
through the evaluator, not only through standalone access tests.

Keep three observations separate: whether retrieval returned candidates, whether
any returned passage was judged sufficient, and whether a declared decision
policy marked support as sufficient. Nonempty hits are not proof of support;
an empty list alone is not a calibrated refusal. A negative labeled against the
authorized corpus must produce the same caller-visible diagnostics when hidden
content is replaced by absent content. Detailed private judgments remain local.

Report positive-query nDCG/MRR/recall/success over positives only; never assign
negative queries an artificial perfect nDCG or divide by zero. Report negative
hit rate as a retrieval diagnostic. When an explicit support-decision policy is
available, report a confusion matrix, false-support rate on negatives,
false-refusal rate on positives, precision/recall/F1 of the low-support flag, and
coverage. Define every denominator; a zero denominator is `null` with its count,
not a perfect score. In the absence of a policy, decision metrics are `null` and
the report says calibration is not evaluated.

The initial implementation measures behavior; it does not change retrieval or
the evidence contract. A fixture-only empty-result policy may test the metric
plumbing if labeled as such. CAP-14's real formula, tuning-only threshold choice,
holdout evaluation and maintainer approval remain later gates. Never display a
raw BM25, cosine or RRF score as a probability that an answer is true.

## 2. L-04: a gate that cannot average away damage

Extend the existing smoke comparator rather than building another evaluator.
Allow stable segment labels (for example exact lookup, paraphrase, language and
negative type) in the new suite. Record per-query comparisons and segment means,
sample counts and deltas against the same frozen profile. Deterministic safety
fixtures can require exact equality; real-data tolerances must be set before a
candidate's held-out run. Tiny segments are flagged as insufficient evidence.

A versioned gate-policy artifact declares the metrics, query/segment guardrails,
tolerances, minimum counts and missing-data rule. Its hash is recorded separately
from the corpus/suite/model/modes/cutoff profile identity. Different policies
cannot silently produce comparable pass/fail decisions. Preserve the existing
boundary: ranker implementation is recorded for diagnosis but is not part of
the data profile, so a changed ranker can be compared to the frozen baseline.
New labels or judgment format change the suite/profile and need a new baseline;
retain old evidence intact.

Reject duplicate/missing query IDs, incompatible profiles, missing required modes
and segments, non-finite metrics, or a candidate report missing required evidence.
Test an aggregate improvement that violates one segment, plus a deliberately bad
exact-lookup change. Both must fail. Keep PR CI dependency-free and small;
representative local runs can remain opt-in and private. This delivers the
offline part of L-04; production canary, rollback telemetry and adaptation are
still separate work, not completed by this comparator.

## 3. E-01: earn relevance claims with representative judgments

Reuse [E-01A](requirements/cap-11-e01a-judgment-packs.md) and its exact acceptance
gate, rather than defining a competing pack format. Its step-6b approval over
the reviewed requirements, invariants, conflicts and pending criteria is still
required. Planning this work is not that approval. Preserve the recorded S1-T9
owner-review sequencing in the live queue before scheduling engine work.

After the E-01A gate, implement content-free inventory/validation first, then the
runner over the existing evaluator. The human supplies a single-owner folder
and independently reviews 50–100 real questions and supporting passages. Include
reviewed negative cases using E-02's format after reconciling it with the pack
specification. Any spec extension requires its own recorded review. Keep tuning
and frozen holdout disjoint, confirmed over exact hashes, fail closed on drift,
and preserve the approved export/privacy boundary. Commit only fixtures or
reports explicitly cleared for publication, never a real user's folder by default.

Compare lexical, PPMI, pinned BGE and equal-RRF with the same reviewed corpus,
suite split and cutoff under an explicit controlled comparison protocol. PPMI
and BGE have distinct provider-specific profile IDs; same-profile regression
gates compare a fixed provider only. Cross-provider tables are descriptive
comparisons, not same-profile regression decisions. Run semantic modes only
when their actual provider is available; hash
vectors may test mechanics but never stand in for semantic evidence. Missing
modes are reported as not evaluated. Human-approved AI suggestions may accelerate
judging, but the ranker's output is not its own ground truth. This phase does
not need to implement the L-01 interaction ledger or wait for behavioral signals.

## 4. F-01: inspectable fusion before another model

Treat routing as a hypothesis. On tuning data compare lexical-only, vector-only,
equal RRF, a small fixed-weight grid, and only then a small deterministic router.
Use query-visible features such as identifier shape and lexical query length;
do not use judgments, private dictionary membership or hidden document counts
at inference. Authorization still filters both channels before ranks. Record
weights, candidate depth, tie rules, route and channel availability.

Select one candidate on tuning data, freeze it and the gate policy, then evaluate
holdout once. Require an agreed measurable gain over equal RRF with no violation
of the exact-lookup, language and authorization gates. The minimum gain and any
statistical tolerance remain pending until representative tuning data exists;
do not tune them on the holdout. A losing experiment is useful: retain the
existing default, record why, and close the experiment without shipping routing.
If production routing is justified, finish the capability/conflict review for
observable mode/trace semantics and versioned knobs before implementing it.
Keep the previous ranker selectable for rollback.

## 5. F-03: explicit Unicode identity and migration

First pin a Unicode database version and the intended normalization → token
boundary → full-casefold order. Compare Python and Zig on whole token sequences,
not merely individual codepoints. Include `Straße`/`STRASSE`, `ﬁ`/`fi`, `ﬀ`/`ff`,
`İ` and its decomposed form, Greek sigma, Tamil marks/joiners, Hangul and ASCII
identifiers. Record matches, misses, collisions and unchanged legacy goldens.
Full casefold does not imply accent stripping, stemming, transliteration or
Turkish locale-specific casing; those would need separate judgments.

If token bytes change, assign a new analyzer identity under a maintainer ruling.
Complete the capability/requirement/conflict review and any required named
approval before building the new observable analyzer behavior (board rule 3).
Specify old-snapshot reads, query analysis by stored identity, import validation,
incremental reuse rejection and full republish. Unsupported analyzer identities
must fail closed with an actionable error; never silently analyze a v2 snapshot
as the new version. Cover both direct folder indexing and JSON import, and the
Dart/CLI/gateway surfaces. Rebuild all matching shipped libraries, including iOS
on a capable Mac, before declaring native work ready. This cloud review cannot
prove iOS runtime behavior.

An implementation should make the pinned parity corpus agree exactly, preserve
unchanged analyzer behavior, pass affected language judgments and demonstrate
that the prior mapping fails the new regression. The measured relevance gain
remains bounded to the judged languages. The first deliverable can conclude
that migration cost outweighs benefit and defer implementation with evidence.

## 6. F-02: select engine work from a current baseline

Reuse [the scale methodology](scale-benchmark.md), but measure the current
persisted engine rather than extrapolating July's in-memory ranking numbers.
Use 384-dimensional non-identical normalized vectors, plus lexical-only control,
at 10k and 100k chunks where feasible (1M explicitly optional). Record generation,
dimensions/provider identity, corpus seed/hashes, native build, hardware, OS,
compiler and optimization, repetitions and warm/cold-cache method. Synthetic
vectors measure mechanics only; record real provider costs separately.

Separate open/startup from steady-state queries. Report snapshot bytes, baseline
and peak RSS, p50/p95/p99, throughput and errors for one and several concurrent
clients, with authorization selectivity. Establish whether the current service
actually executes in parallel before calling concurrent clients parallel engine
execution. Record queues and failed/resource-limited cells; do not turn them
into zero latency. Pair timing with deterministic output/citation checks.

Before choosing an optimization, record the intended device's latency, memory
and freshness budgets. No budget or no violation means no justified optimization.
If exact vector scan fails its budget, compare ANN against exact recall; if
startup dominates, investigate loading; if sorting/postings dominate, optimize
those; if RSS grows over cycles, follow S1-T9's leak design separately. This
benchmark neither replaces that macOS soak gate nor proves leak-freedom.

## Scheduling, acceptance and deferred options

Suggested sequence, subject to existing owner gates: E-02 metric design and
synthetic mechanics → L-04 offline comparator → approved E-01A workflow and
human-confirmed baseline → F-01 experiment → separately approved production
changes. F-03 parity design and F-02 methodology can be prepared independently;
native execution retains the current S1 owner-review gate. Proposed task IDs
use `SQ-*` inside the linked task file and reserve no S1/S2 numbers.

Every implementation claim must be centrally visible before building, and must
record baseline, tests, independent verdict, limitations and rollback. Parent
planning/review stays with Sol 6.1; use a lower-cost model such as Luna for a
bounded, approved implementation and Sol 6 for independent verification. Split
ownership by files: E-02 changes the evaluator first, then L-04 changes the smoke
gate; do not have two builders edit those seams concurrently. Root reviews
requirements, data boundaries and verdicts before recommending merge.

Defer the MCP adapter until its recorded approval; trust calibration until
negative-bearing judgments and calibration gates; learned ranking until ledger
privacy/overhead and holdout gates; durable structure-aware chunking until
CFT-09's chunker identity migration. S-02 explanations can later render existing
authorized traces. No new evidence-packing layer, fuzzy expansion, reranker,
ANN, compression or sharding is justified by this review alone.

## Session handoff

- Main's S1-T21 is the verified iPhone-library task. Recovery [PR #11](https://github.com/ilamgumaran/search-simpli/pull/11) is **open**, not merged, as checked on 2026-10-19. Its branch independently used the same task number. Reconcile that numbering and integration before landing it; do not overwrite the iOS record or assume its libraries include the recovery fix.
- This proposal is based on main `7c40937`, not the recovery branch. New task plans deliberately use a distinct namespace. Read the live PR and latest main before claiming anything.
- Next useful implementation slice is SQ-01 then SQ-02 (E-02), once their scoped design review is recorded. Existing E-01A/CAP-14 approvals remain pending; this document does not supply them. An E-01A amendment requires approval over the final amended specification commit, not just an earlier version.
