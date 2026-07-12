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

## 8b. Dependencies

- **E-02** (negative/unanswerable evaluation) and **E-01** (representative judged
  corpus) — the primary quality metric cannot be set without them.
- Open design input: the exact support formula and low-support floor (§11).

Because the primary metric depends on unbuilt work, **Step 6 is not complete for
CAP-14**: its status is `pending` and it is **not build-ready** until E-01/E-02
land and the formula/floor are fixed. What *can* be specified now is specified.

## 9. Acceptance gate

Decidable now:

- **Determinism:** identical requests yield identical support signals · exact-match test · any deviation blocks.
- **Additive compatibility:** a consumer unaware of the new field is unaffected · CON-01 versioned-field test · any break blocks.
- **Post-authorization:** the signal is computed only over authorized candidates · adversarial label test · 100%.

`pending` (blocked on E-01/E-02 — do not fabricate a threshold):

- **Primary metric:** unanswerable-class detection quality — *metric* = F1 of the
  low-support flag vs. judged unanswerable label; *baseline* = no-signal (always
  "answerable"); *fixture/split* = E-02 negatives, tuning vs. held-out; *threshold*
  = **to be set on tuning data before held-out evaluation**; *rule* = ship only if
  held-out F1 ≥ threshold with no regression on answerable queries.
- **Floor calibration:** the low-support floor is fit on tuning data, not guessed.

## 10. Evidence plan

- Tests: deterministic signal; low-support on negatives; additive-schema compatibility.
- `EXPERIMENTS.md`: hypothesis (retrieval-derived support predicts unanswerability), setup, observed precision/recall, limits (it is not a truthfulness oracle).
- `PROJECT-STATE.md`: note trust-calibration status.
- Status advances Proposed → Diagnostic → Validated (on a real negative-bearing judged corpus).

## 11. Open decisions

- Decision: exact support formula and the low-support floor (needs tuning on E-01/E-02 data).
- Owner: (maintainer).
- Evidence needed: which retrieval features best predict unanswerability on the real corpus.

## 12. Maintainer approval (process step 6b)

Required before build. Note the acceptance gate has `pending` criteria (blocked on
E-01/E-02); approval must explicitly accept deferring those.

- Approver:
- Date:
- Commit:
- Status: **Pending approval** · Step 6 gate `pending` (not build-ready)
