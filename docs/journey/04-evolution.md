# Evolution — the record

How the project's direction, principles, and working rules changed, and what
caused each change. Newest last.

**What belongs here:** a change of direction, a new or altered principle, a
durable decision, or a lesson that changed how we work.
**What does not:** routine progress (that is `PROJECT-STATE.md`) or experiment
results (that is `EXPERIMENTS.md`).

Each entry: *what changed · why · what it cost or taught.*

---

## 2026-07-12 — Baseline before this arc

**State.** A dependency-free Python behavioral reference (BM25, optional
PPMI/neural vectors, RRF, cited evidence, a JSON-lines tool process); a Zig
retrieval core with immutable checksummed segments, a manifest, atomic
publication, writer locking, and a live JSON-RPC service; pre-retrieval
authorization; content-hash incremental preparation; a Python↔Zig interchange;
a recreation kit; and recorded scale benchmarks.

**The honest gap.** Every relevance number came from ~20 authored queries. The
project knew this and said so — `PROJECT-STATE.md` named a representative judged
corpus as the single best next step. That candour is what made the rest of this
arc possible.

---

## 2026-07-12 — The partnership was one-directional (→ the learning loop)

**What changed.** Added [`docs/learning-loop.md`](../learning-loop.md) and
[`IMPROVEMENT-BOARD.md`](../../IMPROVEMENT-BOARD.md) (PR #1).

**Why.** Applying the HIO lens surfaced a structural gap rather than a missing
feature. The retrieval/generation boundary already encoded HIO thinking — but the
seam was a *wall*: the system served evidence and discarded the human's reaction.
That reaction is the richest and cheapest relevance signal available, and it was
being thrown away. So the direction became: *a foundation that works with zero
learning, plus a transparent, reversible, evidence-gated loop that improves it.*

**What review taught.** Four rounds, all substantive:

- **Train/test leakage.** Folding confirmed behavioral labels into "the judged
  corpus" while gating adaptations against "the frozen judged corpus" would let
  an adapted ranker overfit and still pass. → Three separate versioned datasets;
  an example that ever influenced tuning may never enter the holdout.
- **Position bias.** Reads and citations are conditional on what the ranker
  already surfaced; treating them naively as relevance would reinforce the
  current ranking forever. → Record full impressions *plus logging policy id and
  selection propensity* (positions alone cannot reconstruct propensities),
  inverse-propensity correction, explicit negatives, controlled exploration.
- **Overclaiming.** "Learning can only move relevance up" is stronger than a
  finite judged set can prove. → "No measured regression within defined
  per-query and per-segment thresholds," plus canary and rollback.
- **Privacy theatre.** An unkeyed hash of a natural-language query is not a
  privacy control. → Redaction or a keyed, rotatable HMAC, named as
  *pseudonymization, not anonymization*.

**Cost/lesson.** The strongest guardrails in the loop came from review, not from
the original draft. Writing "learning tunes ranking, never truth" was easy; the
hard part was every place the draft quietly failed to honour it.

---

## 2026-07-12 — Requirements needed one place to collide (→ governance)

**What changed.** Added the
[requirements register](../requirements/README.md), the
[capability process](../capability-process.md), a capability template, and a
dependency-free [CI validator](../../scripts/check_requirements.py) (PR #2).
Ran CAP-13 (MCP adapter), CAP-14 (trust calibration), and CAP-15
(structure-aware chunking) through it as worked examples.

**Why.** Requirements were spread across a specification, contracts, use cases,
and prose. Nothing forced them to *meet*, so conflicts could only be discovered
during implementation — the most expensive moment. The register's real product
is the **conflict register**.

**Immediate payoff.** Running three capabilities through it produced five genuine
requirement-level conflicts before any code — including *a confidence score could
quietly turn retrieval into generation* (CFT-04, vs INV-01), and *new chunk ids
would silently invalidate incremental reuse* (CFT-06).

**What review taught — the process failed its own bar first.** Four rounds:

- **Self-attestation.** As written, an author (or agent) could find a conflict,
  mark its own resolution "accepted", set its own gate, and build. → Step **6b**:
  a named maintainer other than the author must approve; an agent may draft but
  may never record itself as approver.
- **Invariants were bypassable.** CFT-03 "accepted" an INV-09 conflict on the
  unmeasured assertion that capture is cheap. That contradicts calling invariants
  non-negotiable. → An INV conflict may only be *Resolved with evidence*,
  *Blocked*, or an explicit maintainer-approved *Invariant-change*. CFT-03 became
  **Blocked**.
- **The worked examples missed the measurable-gate exit.** "Improves", "bounded",
  "high precision" are directions, not gates. → Every criterion states metric,
  baseline, fixture/split, threshold, and decision rule — or is explicitly
  `pending` with its unblocker. Fabricating a number is disallowed.
- **The validator was hollow.** Twice, a reviewer mutated a copy of the repo and
  the checker still passed: once by deleting an FR from the specification and
  pointing a capability at a nonexistent use case; once by changing a catalog
  requirement so catalog, index, and spec disagreed. → The validator now checks
  across every declared source of truth, with a negative unit fixture per failure
  mode. Fixing it also exposed a latent bug of my own: `FR-\d+` was matching
  inside `NFR-09`.

**Cost/lesson.** A governance layer that is only prose is decoration. It became
real when a script could fail the build — and the script itself only became real
once someone tried to beat it.

---

## 2026-07-13 — The governance met a real change by a different author

**What changed.** Graded relevance (grades 1–3, nDCG@k, one gain per judged
path/chunk), a reproducible `profile_id`, a regression gate with explicit floors
and baseline tolerances, a deterministic WANDS adapter, UC-005, and a
strengthened FR-12 (PR #3).

**Why it matters to the record.** This was the first substantive change *after*
the governance landed, authored by a different agent. It exercised the process
end to end: a CAP-11 change record, CFT-10 recorded and **Resolved with evidence**
against INV-09, a template-conformant use case, and a decidable gate. That is the
process working as intended rather than being ceremonially cited.

**What the evidence itself taught.** The first WANDS representation emitted 41,377
chunks for 10,000 products; repeated chunks from one product consumed result
slots. Aligning the retrieval unit with the *judged* unit improved nDCG, success,
and recall — **and lowered MRR**. That single disagreement is the argument for
reporting several metrics instead of one, and the failed run is preserved beside
the corrected one.

**What review still caught.** An approval block citing an *automated,
changes-requested* review comment as the human maintainer sign-off — precisely
the loophole step 6b exists to close. Flagged; the block was then explicitly
marked pending human approval.

---

## 2026-07-13 — Made public

**What changed.** MIT license on `main`; the repository announced publicly.

**Why.** The contracts, the evidence discipline, and the recreation kit are more
useful to others than to us alone, and outside scrutiny is the cheapest source of
the adversarial review that has already improved this project four times over.

---

## 2026-07-31 — The process absorbed its own past exception (E-01A)

**What changed.** Merged the
[E-01A real-folder judgment-pack specification](../requirements/cap-11-e01a-judgment-packs.md)
(PR #5) — specification only, deliberately stopping at step 6b. It records
CFT-11 (single-owner authorization scope), CFT-12 (holdout contamination), and
CFT-13 (bounded experiment with removal as rollback).

**Why it matters to the record.** Two firsts:

- **A spec that is mergeable without being build-ready.** §12 says approval is
  required *before build*, not before merge. That resolves the self-contradiction
  from PR #3, where a merged record read "must not merge." Landing a
  decision-ready specification and gating only the implementation is the right
  shape for this process.
- **The missing approval on PR #3 was recorded as a historical process
  exception rather than retroactively invented.** CAP-11 §12 now states plainly
  that PR #3 merged without qualifying step-6b evidence, and that the automated
  review was a change request, not an approval. Preserving the gap is more
  valuable than a tidy record.

**What review caught — in my own tooling this time.** The E-01A record sits in
`docs/requirements/` but was **not linked from the capability catalog**, and the
validator keyed its per-record checks on catalog links. So the first sub-record
the project ever produced was entirely unvalidated: its references, Dependencies
section, and approval block were all unchecked. The file happened to be
compliant, but the hole was real and would recur for every future tranche.

→ The validator now checks the union of **every**
`docs/requirements/cap-*.md` and every existing catalog-linked target. It
derives the capability id from the filename, rejects unknown or mismatched ids,
and limits the strict "§3 table must equal the catalog" check to canonical
catalog links because a sub-record legitimately restates a subset. Six fixtures
(five negative) cover it (18 validator tests, up from 12), and the mutations
that previously passed now fail.

**Lesson.** A validator's *coverage rule* is itself a place drift hides. Keying
checks on "is it linked?" quietly created a category of file that could not fail.
Enumerate the artifacts, do not wait to be pointed at them.

---

## 2026-07-31 — Continuity became a first-class concern

**What changed.** Added this `docs/journey/` directory — vision, approach, next,
and this record — so work can move between a CLI session, a web session, and
different agents without reconstructing context.

**Why.** The project's other records describe the system as it *is*, and
deliberately erase the path. But the path carries information the end state
cannot: which assumptions were wrong, which review caught what, and why a rule
has the shape it does. Without it, each new session re-derives the reasoning — or
worse, silently re-litigates a decision that was already settled with evidence.

---

## Lessons that changed how we work

Distilled from the entries above. These are why the rules look the way they do.

1. **Write the guardrail, then attack it.** Every serious improvement this arc
   came from someone trying to break a claim, not from reading a diff.
2. **A rule that no script can enforce will drift.** Prose governance decayed the
   moment it met a real change; CI is what made it hold.
3. **"Non-negotiable" must be unbypassable.** The instant an invariant could be
   "accepted with rationale," it was a preference, not an invariant.
4. **Never fabricate a threshold.** `pending` with a named unblocker is honest;
   an invented number is a lie with a decimal point.
5. **An agent must not approve its own exception.** Drafting and approving are
   different powers, and collapsing them removes the only real check.
6. **Keep the failures.** The 41,377-chunk run and the `O(n²)` ranking bottleneck
   are worth more in the record than any clean success narrative.
7. **Measure before adding machinery.** The first real bottleneck was never the
   one we expected.
8. **A check's coverage rule is itself a hiding place.** Validating only the
   artifacts you are *pointed at* creates a category of artifact that cannot
   fail. Enumerate them instead.
