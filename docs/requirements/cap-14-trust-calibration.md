# CAP-14 — Trust-calibration signal

Status: Proposed · Evidence: future option

> Run through the [capability process](../capability-process.md), steps 1–6.

## 1. Proposal

- **Problem / what should be possible:** The evidence pack tells the answer model to "acknowledge insufficient support," but that is a prompt instruction, not data. A caller (human or agent) cannot see *how well supported* an answer is, so a confident wrong answer is indistinguishable from a well-grounded one. Surface an explicit coverage/confidence signal so the caller knows when to trust vs. verify.
- **Who it serves:** human users first (at-home search), and agent users.
- **HIO tie:** the seam — it is the handshake that keeps organic authority over truth (INV-01) usable in practice.
- **One-line success notion:** every evidence response carries a support signal that correctly flags weakly-supported and unanswerable queries.

## 2. Motivating use case(s)

- Primary: [`UC-001`](../use-cases/uc-001-personal-files.md) (trust matters most for a lone user with no reviewer)
- Cross-cutting: UC-002, UC-003; closely tied to board item E-02 (negative/unanswerable evaluation)

## 3. Functional requirements (new or changed)

| ID | Requirement (testable) | New / changes | Traces to |
|---|---|---|---|
| FR-14 | Every evidence response includes a first-class **support signal** computed deterministically from retrieval features only — e.g. top fused score, score gap to the next candidate, lexical/semantic rank agreement, and count of supporting chunks above threshold. It is advisory metadata: it never adds, removes, edits, or reorders evidence, and it is **not** produced by a generative model judging truth. When support is below a configured floor the response is explicitly marked low-support. | changes FR-06 | UC-001, E-02 |

## 4. Non-functional impact

| ID | Requirement / impact | Target or constraint |
|---|---|---|
| NFR-03 / INV-08 | The signal is a deterministic function of scores/ranks; equal inputs give equal signal. | Constraint |
| NFR-08 | Docs/response must label the signal as *advisory retrieval-derived*, not a truth guarantee. | Constraint |

## 5. Contracts touched (CON)

- `CON-01` (`search-tool.schema.json`): add an **optional, versioned** `support`/`confidence` field to the result/response. Older consumers ignore it (INV-07). This is an additive, backward-compatible change.

## 6. Invariant compliance (INV)

- INV-01 retrieval≠generation: **complies by construction** — the signal is a function of retrieval scores/ranks, never a generative judgment of truth. This is the crux; see CFT-04.
- INV-02 citations: complies — the signal augments, never replaces, citations.
- INV-08 determinism: complies — deterministic function of component scores.
- INV-10 evidence honesty: complies — labeled advisory; validated against negative queries, not asserted.
- Others: no impact.

## 7. Register updates (done in step 4)

- Capability catalog: add CAP-14.
- FR index: add FR-14 (changes FR-06). Contracts: note CON-01 gains optional `support` field.

## 8. Conflict check (required)

| CFT | Between | Tension | Resolution | Status |
|---|---|---|---|---|
| CFT-04 | CAP-14 ↔ INV-01 (retrieval≠generation) | A "confidence" score could drift into an LLM judging whether the answer is true, blurring the retrieval/generation line. | Define the signal strictly as a deterministic function of retrieval features (scores, rank agreement, gaps, supporting count). No model call. It calibrates *evidence strength*, not *answer truth*. | Resolved |
| CFT-05 | CAP-14 ↔ CON-01 / INV-07 (contract backcompat) | Adding a field to the evidence response could break existing consumers. | Add it as an optional, versioned field; unaware consumers ignore it. | Resolved |

No other conflicts found against the register as of this commit.

## 9. Acceptance gate

- Retrieval metric + target: on a judged set including **negative/unanswerable** queries (E-02), low-support flagging has high precision/recall for the unanswerable class.
- Citation-support: unchanged; signal is additive.
- Unanswerable/negative behavior: absent-topic queries are marked low-support at the configured floor.
- Determinism: identical requests yield identical signals (test).
- Security/isolation: signal computed only from authorized candidates (post-authorization).
- Fixture: extend judged fixtures with unanswerable cases and expected support bands.

## 10. Evidence plan

- Tests: deterministic signal; low-support on negatives; additive-schema compatibility.
- `EXPERIMENTS.md`: hypothesis (retrieval-derived support predicts unanswerability), setup, observed precision/recall, limits (it is not a truthfulness oracle).
- `PROJECT-STATE.md`: note trust-calibration status.
- Status advances Proposed → Diagnostic → Validated (on a real negative-bearing judged corpus).

## 11. Open decisions

- Decision: exact support formula and the low-support floor (needs tuning on E-01/E-02 data).
- Owner: (maintainer).
- Evidence needed: which retrieval features best predict unanswerability on the real corpus.
