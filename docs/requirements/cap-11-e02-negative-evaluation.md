# CAP-11 / E-02 — Explicit negative-query evaluation

Status: Proposed · SQ-01 design only · Date: 2026-10-19

Claim: [issue #13](https://github.com/ilamgumaran/search-simpli/issues/13).
Base: `89fadce`. No evaluator, ranking, evidence-contract or native changes are
implemented by this record. SQ-02 requires the approval in §12 before build.

## 1. Proposal

Current suite v2 requires at least one positive judgment per query and divides
recall by that count. It cannot describe a question with no answer in the
authorized corpus. Extend CAP-11 / FR-12 with explicit answerability, diagnostic
negative metrics and a deliberately limited offline decision-policy interface.
This measures retrieval behavior; it does not claim answer truth or implement
CAP-14 support metadata. Human reviewers retain authority over the labels.

## 2. Motivating use cases

Primary: [UC-005](../use-cases/uc-005-relevance-regression-gate.md); affected:
UC-001 personal files and UC-003 authorized knowledge. Use small authored files
with these five representative questions before any private-corpus experiment:

| Question / family | Reviewed expectation |
|---|---|
| Where is the WATER-17 filter replacement procedure? | Answerable; exact identifier and a supporting path/chunk. |
| How can I make creek water safe to drink? | Answerable paraphrase when the fixture contains the procedure. |
| Who installed the water filter? | Unanswerable if the procedure discusses maintenance but never names an installer. |
| What is the warranty of SKY-99? | Unanswerable absent-entity question. |
| When was the cabin's private filter reset? | Unanswerable in the public view when only a restricted synthetic file contains the date. |

Do not infer unanswerability from an unjudged result or an empty judgment list.
A reviewer must check the specified corpus and visibility view. A negative
judgment is scoped to that frozen view, not all knowledge everywhere.

## 3. Functional requirements

| ID | Proposed extension | Traces to |
|---|---|---|
| FR-12 | Add strict suite v3 with explicit answerable/unanswerable/unjudged labels; preserve default v1/v2 behavior; score positive retrieval separately from negative hit diagnostics and optional offline policy decisions; bind v3 evaluation profiles to a trusted authorized view; return counts, defined denominators and explicit unavailable metrics. | UC-005, UC-001, UC-003 |

FR-08 remains authoritative: the evaluator passes a trusted principal into the
existing pre-rank filter. Suite content cannot set or override that principal.
FR-06 and FR-14 do not change; no production confidence field is introduced.

### Suite-v3 grammar and validation

Top-level object has exactly `version: 3` and a nonempty `queries` array.
Each query has exactly these required fields: nonempty unique string `id`,
nonblank string `query`, `answerability`, and array `relevant`. Optional fields
are `path_prefix` (string), `rationale` (nonblank string), and `segments` (array of
unique nonempty strings). Reject unknown fields at both levels, including
`principal`, `principal_labels`, context, predictions or policy fields. Segments
are metadata for SQ-03; they do not change scoring in SQ-02.

| Label | `relevant` | Other rule | Scored as |
|---|---|---|---|
| `answerable` | Nonempty v2-style positive judgments, integer grades 1–3 (booleans invalid). | Each judgment contains only nonempty `path` and/or `chunk_id`, plus `grade`; at least one identity required, duplicate identity pairs rejected. | Positive retrieval metrics and decision outcomes. |
| `unanswerable` | Exactly `[]`. | Nonblank rationale required, e.g. reviewed topic-without-requested-fact. | Negative hit diagnostics and decision outcomes. |
| `unjudged` | Exactly `[]`. | Nonblank rationale required, e.g. incomplete review. | Diagnostic row only; excluded from every scored denominator. |

The v3 `version` value must be the JSON integer 3, not a boolean or string.
Reject unsupported labels, ambiguous combinations and a suite containing no
scored queries. Negative-only suites are valid: positive metrics are `null` with
positive count zero. Never upgrade a v1/v2 suite by guessing its labels.

`path_prefix` retains the existing search prefix semantics; it is a narrowing
filter, not an authorization grant. Positive citations must resolve to the
selected index's authorized chunks within that prefix. Fail before scoring if
a positive path/chunk is missing, mismatched or invisible; use one generic
`judgment_unavailable_in_view` error for those cases, without identifying hidden
paths. A partial review belongs in `unjudged`, not a false negative.

Example of the proposed format (not accepted by the current evaluator):

```json
{
  "version": 3,
  "queries": [
    {"id": "procedure", "query": "WATER-17 replacement", "answerability": "answerable", "relevant": [{"path": "water.md", "grade": 3}], "segments": ["exact"]},
    {"id": "installer", "query": "Who installed the water filter?", "answerability": "unanswerable", "relevant": [], "rationale": "Reviewed authorized procedure contains no installer identity."},
    {"id": "pending", "query": "How often should it be inspected?", "answerability": "unjudged", "relevant": [], "rationale": "Source review incomplete."}
  ]
}
```

### Trusted visibility and profile identity

SQ-02 adds a trusted context argument to evaluator entry points and passes its
normalized labels to `core.search(principal_labels=...)`. A local operator may
provide a versioned context file through a new `--evaluation-context-file`
option; it is outside the suite. No arbitrary executable policy or model call
is loaded from that file. An LLM-facing tool must never expose this option.
This file is a privileged local operator's assertion of labels, not an
authentication mechanism. The runner is not exposed to untrusted/remote callers;
deployments requiring authenticated identity still need the separate O-02 work.

Context-file v1 has exactly `version: 1`, `principal_labels` (an array validated
by `normalize_labels`) and, for nonempty labels, `profile_key_hex` (a locally
generated 32-byte secret encoded as 64 hex characters). Reject unknown fields.
No file means empty labels, preserving least privilege; no ambient principal is
inherited. A supplied empty-label file has no secret field and uses the same
public binding as omission. Context errors never echo labels, key or file body.
Key creation/storage is the operator's responsibility in this bounded slice;
there is no new key service. Document local file protection and do not commit it.

Restricted-context binding is HMAC-SHA256 of the UTF-8 bytes
`search-eval-context-v1`, one NUL byte, and canonical JSON of normalized labels,
under that local key. Canonical JSON uses `ensure_ascii=False`, sorted object
keys and compact `(',', ':')` separators, encoded as UTF-8. Empty labels use
the fixed public binding `public-empty-labels-v1`. Raw labels/key are never
reported. Same key and labels give the same binding; changed labels or rotated
key give a different binding and require a new baseline. An unkeyed label hash
is not an acceptable privacy substitute. These bindings do not anonymize the
suite, authorized paths or other report metadata; publication still needs consent.

For suite v3 only, smoke profiles use `profile_version: 2`, hashing suite bytes,
authorized corpus identity, vector mode/exact provider identity, selected modes,
cutoff, visibility binding and the offline policy identifier. Authorized corpus
identity is a canonical list sorted by chunk id: id, relative citation path,
start/end lines and SHA-256 of source text for each visible chunk. Hidden chunks,
absolute roots and raw labels do not enter the public report. Changing visible
content or visibility context rejects baseline reuse. Ranking/analyzer code
remains outside profile identity so the gate can compare implementations; record
its identity separately. SQ-03 adds its gate-policy identity separately.

V3 default reports omit `index.root`, source text, rationale, raw query text and
hidden/global chunk counts. Authorized returned paths/chunk IDs, query IDs,
answerability and visible chunk counts are retained for local diagnosis. Reports
remain sensitive even with these omissions. V1/v2 invocation without a context
keeps existing profiles/report semantics; reject a context-file option with
v1/v2 rather than changing their interpretation silently. Exact serialization
and float ordering use the current canonical JSON profile encoding.

### Retrieval and decision metrics

Positive nDCG/MRR/recall/success retain the v2 graded formulas and one gain per
judgment. Their denominator is the number of `answerable` rows only. A positive
judgment hit means a judged relevant result was retrieved, not that a generated
answer is entailed. Negative/unjudged rows have `null` per-row positive metrics.
Report total/answerable/unanswerable/unjudged counts and scored count explicitly.

`negative_hit_rate` = negatives with at least one returned candidate / negatives.
Return its numerator and denominator. Nonempty irrelevant candidates may expose
a retrieval problem; this rate is not a claim that the engine asserted support.

The trusted runner selects `decision_policy="none"` (default) or
`"empty-results-v1"` (diagnostic only). The latter defines `low_support` as
`len(results) == 0`, using authorized results only. It cannot read judgments,
rationale or answerability. It is not a calibrated support model. Other policy
IDs or suite-supplied predictions are rejected. A future policy extension
requires separate review; CAP-14 is not smuggled in as a callback.

When a policy is selected, the positive class for the confusion matrix is
**unanswerable / flagged low support**:

| Outcome | Reviewed label | Policy flags low support |
|---|---|---|
| TP | Unanswerable | Yes |
| FN | Unanswerable | No (false support) |
| FP | Answerable | Yes (false refusal / missed answer opportunity) |
| TN | Answerable | No |

- False-support rate = FN / (TP + FN).
- False-refusal rate = FP / (FP + TN).
- Low-support precision = TP / (TP + FP); recall = TP / (TP + FN).
- Low-support F1 = 2TP / (2TP + FP + FN).
- Coverage = (TN + FN) / (TP + FN + FP + TN), the fraction marked sufficient.

Every fraction includes numerator and denominator. A zero denominator produces
`null` and reason `zero_denominator`, never NaN/infinity or a perfect score.
With policy `none`, confusion matrix, per-row `low_support` and all decision
metrics are `null` with reason `policy_not_evaluated`. Unjudged rows never enter
the matrix or coverage; their policy result is also `null`.

### V3 report shape

The new outer evaluator report has `report_version: 2`, `suite_version: 3`,
`index`, `warnings` and `reports`. `index` contains the existing `version`,
`vector_mode` and `embedding` metadata plus `visible_chunks`; it omits `root`
and global chunk counts. It records analyzer/ranker identity when available as
diagnostic metadata outside the comparison-profile hash. Static existing
hash/PPMI limitations remain in `warnings` without including source content.

Each mode report contains `mode`, `top_k`, `query_count`, `scored_count`,
`answerable_count`, `unanswerable_count`, `unjudged_count`, `queries`, the four
existing positive metric names, `positive_totals`,
`positive_metrics_unavailable_reason`, `negative_hit_rate` and `decision`.
`positive_totals` records `recall_sum`, `successful_queries`,
`reciprocal_rank_sum` and `ndcg_sum`; `answerable_count` is their denominator.
Positive values are numbers when that count is nonzero, otherwise `null` with
reason `zero_denominator`. A per-query row contains `id`, `answerability`,
`first_relevant_rank`, `recall`, `ndcg_at_k`, `returned`, `returned_paths`,
`returned_relevance_grades` and `low_support`. For unanswerable/unjudged rows,
rank/recall/nDCG and grades are `null`; result identities may still be returned.
The absence of grades means unknown/not applicable, not an asserted zero grade.

`negative_hit_rate` and each decision fraction use the record
`{value, numerator, denominator, unavailable_reason}`. Available fractions have
numeric values/counts and null reason; zero denominators have null value and
`zero_denominator`. A policy-not-evaluated fraction has null value/numerator/
denominator and reason `policy_not_evaluated`. This record convention makes the
nulls specified above unambiguous without encoding them as strings.

`decision` contains `policy_id`, `diagnostic: true`, `unavailable_reason`,
`confusion`, `false_support_rate`, `false_refusal_rate`, `low_support_precision`,
`low_support_recall`, `low_support_f1` and `coverage`. `confusion` is
`{tp, fn, fp, tn}` for a selected policy, otherwise null. The object-level reason
is `policy_not_evaluated` for policy none, otherwise null. Each fraction has its
own denominator availability. The smoke wrapper supplies `profile_version: 2`
and `profile_id`; direct evaluator reports cannot be treated as compatible
baselines without that identity. Default v1/v2 report shapes are unchanged.
The v3 smoke wrapper also omits its legacy absolute `corpus`, `suite` and
`index_path` fields; retain `index_source` and timings without host paths.
V3 error handling must not echo roots, private context fields or suite content.

### V3 smoke gate and unavailable metrics

Extend the existing smoke comparator only enough to handle the new format:

- A requested positive floor with zero positives is a failed criterion
  (`metric_unavailable`), never a zero score, silent skip or TypeError.
  Every requested floor counts as a checked criterion, including this failure.
- Same-profile baseline comparisons require matching row IDs/modes and counts.
  Numeric/numeric positive metrics use the existing absolute-regression rule;
  all numbers must be finite. One null and one numeric value is an incompatible
  report error. Null/null with matching zero counts is recorded as not evaluated,
  not a passing comparison. Profiles must match before inspecting metrics.
- If no floor or numeric comparison was evaluated, v3 `gate.passed` is null,
  `gate.status` is `not_evaluated` and `gate.checked_metrics` is empty. A valid
  diagnostic-only invocation exits 0 but cannot be presented as a passing quality
  gate. If actual criteria were checked, status is `passed`/`failed` and `passed`
  is boolean. Failed criteria exit 1; invalid context/profile/report inputs exit 2.
- Record skipped null/null comparisons in `gate.not_evaluated` with the metric
  and reason. Negative diagnostics are reported without an invented threshold;
  extending their regression policy belongs to the next scoped gate design.

The direct evaluator and smoke runner accept the same trusted
`--evaluation-context-file` and `--decision-policy {none,empty-results-v1}`
options. Their API counterparts are `evaluation_context` and `decision_policy`;
context decoding is shared, not a separate authorization implementation.

### Hand-computable acceptance example

Six diagnostic queries at k=2; A2's sole positive has grade 2:

| ID | Label | Returned grades / state | Empty-results low support |
|---|---|---|---|
| A1 | Answerable | [3] | false |
| A2 | Answerable | [0, 2] | false |
| A3 | Answerable | [] (known positive missed) | true |
| N1 | Unanswerable | One irrelevant candidate | false |
| N2 | Unanswerable | [] | true |
| U1 | Unjudged | One candidate, relevance unknown | null |

Positive recall/success = 2/3; MRR = (1 + 1/2 + 0)/3 = 0.5;
nDCG = (1 + 1/log2(3) + 0)/3 ≈ 0.5436432512. Negative hit rate = 1/2.
TP=1, FN=1, FP=1, TN=2. False support/refusal = 1/2 and 1/3;
precision/recall/F1 = 1/2 each; coverage = 3/5. U1 changes no scored result.
With policy `none`, positive/negative retrieval values are identical and all
decision values are unavailable. These are expected arithmetic, not measured
results from the current evaluator.

## 4. Non-functional impact

NFR-01: standard library only, including `hmac`; no provider download in base CI.
NFR-07: tests demonstrate predecessor rejection of negatives and the new metric
edge cases. NFR-08: every v3 report labels the suite authored/diagnostic unless
an independently confirmed representative workflow establishes a broader claim.
No new latency or production relevance target is invented by this design.

## 5. Contracts touched

Only local suite/report/profile formats and evaluator runner/API grow; public
CON-01 evidence, CON-02 tools, CON-03 interchange and native ABI remain unchanged.
Suite v1/v2 and profile v1 stay readable with their existing default behavior.
V3 adds a new report version and profile version; incompatible baselines fail.

## 6. Invariant review

| Invariant | Design compliance / required evidence |
|---|---|
| INV-01 | Retrieval measurements only; no generated truth score or production refusal. |
| INV-02 | Preserve authorized path/chunk/line identities and existing duplicate-gain rules. |
| INV-03 | Trusted context feeds real prefilter; unknown principal fields rejected; hidden/absent diagnostics tested. |
| INV-04 | Exact embedding identity remains in the profile; provider changes require a new profile. |
| INV-05 | Exact vector search remains the oracle; no approximate channel or retrieval optimization is added. |
| INV-06 | No nonstandard base dependency or hosted inference. |
| INV-07 | New suite/report/profile versions; preserve legacy defaults and reject incompatible contexts. |
| INV-08 | Canonical identities, deterministic counts and no random policy behavior; supplied local key is stable per baseline. |
| INV-09 | Bound to existing evaluator/smoke seams and synthetic fixtures addressing an inspected representational gap. No ledger, calibration service or engine machinery. |
| INV-10 | Counts and null reasons distinguish unknowns, no policy, diagnostics and actual evidence. |
| INV-11 | Reviewer labels are fixed; policy cannot read labels or train from holdout. |

These are proposed resolutions to be tested, not statements that implementation
has passed. No invariant exception is requested.

## 7. Register updates

Record this as a proposed CAP-11 / FR-12 extension alongside E-01A; retain the
implemented catalog entry and add a proposal in the specification appendix.
New conflicts CFT-14–16 below do not retroactively alter earlier approvals.

## 8. Conflict check

| CFT | Tension | Proposed resolution | Status |
|---|---|---|---|
| CFT-14 | CAP-11 / FR-12 positive-only metrics vs INV-10: treating unknowns or negatives as positives misstates quality. | Explicit labels, positive-only denominators, separate diagnostics, null reasons and exact arithmetic tests. | Resolved (design; evidence pending) |
| CFT-15 | CAP-11 evaluator vs FR-08 / INV-03: query-controlled principals or reports can leak hidden data. | Trusted context only, real prefilter, keyed private-context binding, visible corpus identity, redacted v3 defaults and hidden/absent tests. | Resolved (design; evidence pending) |
| CFT-16 | CAP-11 extension vs INV-07 and E-01A's fixed format: v3 could invalidate legacy runs or silently widen sealed packs. | Preserve legacy defaults; version new formats; E-01A remains unchanged and rejects v3 until its own amended specification receives final-commit approval. | Resolved (scope/design; evidence pending) |

No accepted invariant conflict or self-approved exception. FR-03–05 scoring,
FR-09–11 publication and CAP-14's calibrated support requirements remain intact.

## 8b. Dependencies and classification

This is a capability extension under board rule 3: new observable evaluation
behavior and versioned local formats, not a small invariant-preserving tweak.
The capability process applies, including its named maintainer approval.

Existing Python evaluator/access/provider paths suffice for the bounded
mechanics gate. SQ-01 can complete as a reviewed design; SQ-02 is not build-ready
until §12 approval. E-01A tooling and a representative corpus are not dependencies
of synthetic E-02 mechanics, and E-02 does not approve or amend E-01A. CAP-14
calibration and any production support claim remain blocked on their own gates.
The separate native recovery PR #11/iOS rebuild is not a code dependency here.

## 9. Acceptance gate for SQ-02

| Metric | Baseline / fixture | Threshold / decision |
|---|---|---|
| Legacy compatibility | Existing v1/v2 evaluator and smoke fixtures, default invocation | Exact equality of semantic report fields and profile IDs; any change blocks. |
| V3 validation | Valid three-label suites, negative-only suite and malformed/ambiguous examples from §3 | All valid cases accepted, all invalid cases rejected; any mismatch blocks. Old evaluator must reject a valid v3 negative case. |
| Arithmetic | Six-query example above plus all-negative, no-decision, no-predicted-negative and no-judged-negative cases | Counts exact, fractions within 1e-9, unavailable values/reasons exact; any error blocks. |
| Null-aware smoke | Negative-only v3 with requested floor, no criteria, null/null baseline, mixed null/numeric and non-finite report inputs | Respect the explicit fail/error/not-evaluated rules above; zero crashes or fabricated passes. |
| Judgment integrity | Missing, hidden, out-of-scope and mismatched positive path/chunk; generic diagnostics | Every invalid positive rejected before scoring; no hidden identity exposed. |
| Authorization | Evaluate restricted synthetic fixture through runner/API and real prefilter | Zero forbidden hits/identities. Adding a suite principal field cannot broaden access; reject it. |
| Non-disclosure | Public-view hidden-vs-absent twin fixtures, lexical mode, fixed visible content/provider | Newly added counts, warnings, per-row diagnostics and visible-profile identity identical; any difference blocks. No claim of hiding distinct embedding models. |
| Profile isolation | Change visible source, labels, key, policy, suite, mode, k or exact provider; reorder labels only | Each substantive change rejects baseline reuse; label reordering preserves identity; hidden-only corpus changes preserve the same visible identity. |
| Context/report privacy | Synthetic key/label/root/content sentinels, malformed context | Zero secret/root/content/rationale/query occurrences in v3 default reports/errors; authorized relative citations may appear. |
| No-policy semantics | Same retrieval fixture with `none` and diagnostic empty-results policy | Retrieval metrics identical; absent decision metrics explicitly null; policy labeled diagnostic. |

All mechanics thresholds are fixed above. Representative unanswerability quality,
calibrated floors and production usefulness are **pending E-01 / CAP-14**, outside
this slice; no synthetic pass can mark them validated.

## 10. Evidence and task split

SQ-01 design review completed with a separate Sol reviewer: hand arithmetic,
legacy-version boundary, null-aware gates, trusted context and approval scope
reviewed; no material outstanding findings. Existing evaluator/smoke/access/
privacy checks pass (18 tests), the requirements/path/whitespace checks pass,
and the proposed JSON example parses while the current evaluator rejects v3.
These verify the design and unchanged baseline, not a v3 implementation.

SQ-02 builder implements validation/metrics, then trusted-context/profile/CLI
plumbing as sequential reviewable commits. Record deviations before expanding
scope. Independent verifier runs evaluator, access and smoke regressions, legacy
goldens, privacy/requirements checks, and the dependency-free Python suite.
No native rebuild is needed unless the implementation exceeds this Python scope.
Append actual results to EXPERIMENTS and update state when implementation lands.
Do not report the arithmetic table as a performed search experiment.

## 11. Rollback and open decisions

Revert optional v3 support and preserve v1/v2 and their original fixtures/profiles.
Keep frozen reports; never relabel a changed corpus or key as the old profile.
No retrieval ranker or public production response changes require rollback.
The bounded `empty-results-v1` policy is fixed for this proposal; selecting a
calibrated future formula is CAP-14's open decision, not a missing mechanics gate.
Maintainer review may rescope the trusted-context slice before approving §12;
if it changes this design, approval must cover the final amended commit.

## 12. Maintainer approval

Required by [capability process step 6b](../capability-process.md#6b-maintainer-approval-gate)
before SQ-02. A human maintainer/reviewer other than the implementing agent must
approve §6, CFT-14–16 in §8, and §9 including its expressly deferred production
criteria. Merging the earlier roadmap is not approval of this subsequent design.

- Approver: Pending.
- Date: Pending.
- Reviewed commit: Pending; cite the final specification commit.
- Evidence: Pending; explicit maintainer approval/comment required.
- Status: **Pending approval — SQ-02 not build-ready.**
