# The learning loop: search that improves from use

Status: **working hypothesis and future-option design.** Nothing in this document
is implemented yet. It defines *why* Search Simpli should learn from behavior,
*what* that loop looks like, and — most importantly — the guardrails that keep
learning from violating the invariants the project already holds. Read it
alongside [`docs/architecture.md`](architecture.md) and the
[improvement board](../IMPROVEMENT-BOARD.md), which tracks the concrete tasks.

## Why this exists

Search Simpli is built on a Harmonized Intelligence Orchestration (HIO) idea:
retrieval (the **inorganic** side — recall, ranking, pattern) finds and cites
evidence, and a human or an answering model (the **organic** side — judgment,
taste, "which of these actually helped") decides what is true and useful.

Today that partnership is **one-directional**. The system serves evidence and
then forgets everything. The human's reaction — which passage they actually
read, which answer they accepted, which query they had to rephrase because the
first results missed — is thrown away. That reaction is the single richest
relevance signal the system will ever see, and it is free.

HIO is for **building and using**. On the *using* side, the system should get
better *for this particular human or agent* the more it is used, because
"relevant" is not universal — it is personal, contextual, and it drifts. On the
*building* side, that same captured behavior becomes the ground truth that
agents and humans working on the repo use to justify or reject every future
ranking change. The learning loop is the mechanism that turns use into
improvement, for both.

The goal is not a black-box model that silently reweights everything. It is a
**foundation that works with zero learning, plus a transparent, reversible,
evidence-gated loop that only ever improves it.**

## Foundation first, then adapt

The loop is staged. Each stage must earn the next with evidence, in the same
discipline the [roadmap](roadmap.md) already applies to engine complexity.

### Stage 0 — Foundation (partly present)

The cold-start system with **no behavioral learning at all**: BM25 + optional
semantic + RRF, cited evidence, authorization, and a **frozen judged corpus**
used as the regression gate. This must remain fully functional forever.
Learning is an improvement layer, never a dependency. A brand-new install, a
new user, or a new corpus works on day zero with no history.

*Evidence gate:* the existing offline evaluation (recall@k, success@k, MRR,
citation support, unanswerable precision) on a representative user-derived
corpus — this is the project's current E005B blocker and a prerequisite for
everything below.

### Evaluation datasets are kept separate (no leakage)

Learning safely requires that the data used to *tune* a ranker is never the data
used to *judge* it. The loop therefore keeps three distinct, versioned datasets,
and behavioral signal never silently crosses between them:

1. **Feedback / training judgments** — labels derived from behavior and confirmed
   by a human (Stage 2). Used to tune weights, routing, and preferences. Grows
   continuously.
2. **Frozen holdout regression set** — an immutable, versioned judged set that is
   **never** used for tuning. It is the gate: an adapted ranker is measured
   against it and cannot see it during training. This is what "the frozen judged
   corpus" means everywhere below.
3. **Audit set (optional, future)** — a periodically refreshed, held-back set for
   detecting drift and overfitting to the holdout itself.

Promotion of new examples into a *new version* of the holdout gate is an explicit,
recorded act (a dataset version bump in `EXPERIMENTS.md`), never an automatic
side effect of collecting feedback. If an example has ever influenced tuning, it
is training data and may not be added to the holdout.

### Stage 1 — Interaction ledger (foundation for learning)

Capture, but do not yet act on, a **principal-scoped interaction ledger**. For
each search record the full **impression**: every candidate that was shown and
*at what position*, not only the ones acted on. Then record which `read_chunk`
calls followed, which chunk an answering model actually cited, any explicit
rating, and whether the user re-queried shortly after (a reformulation is a
failure signal). Recording impressions and positions — not just clicks — is what
makes later position-bias correction possible (see Stage 2).

This mirrors the discipline of [`EXPERIMENTS.md`](../EXPERIMENTS.md): raw,
honest, no success-only narrative. It is the raw material; it changes no result.

**Privacy and deletion lifecycle (required before L-01 is accepted).** This
ledger holds sensitive behavioral data — raw queries, candidate history, reads,
citations, ratings, and reformulations — so it must ship with a lifecycle, not
just a schema:

- **Consent:** capture is **opt-in**, off by default, with a visible switch.
- **Data minimization:** store the least that makes the signal useful; prefer
  chunk/candidate ids and positions over free text where the id suffices;
  support query redaction/hashing for users who want signal without stored text.
- **Retention:** a configurable retention window with automatic expiry; no
  indefinite default.
- **Deletion and export:** a principal can export or delete their own ledger.
  "Append-only" refers to *integrity within the retention window* (entries are
  not silently rewritten), reconciled with deletion via tombstones and
  compaction that physically remove expired or deleted records — not an excuse
  to keep data forever.
- **Encryption and derived copies:** encrypt at rest; the deletion/retention
  policy must also cover backups and any logs that echo ledger content.
- **Authorization-change behavior:** when a principal's access is revoked or
  relabeled, their ledger entries follow the same boundary — signal derived
  under access a user no longer has must not keep influencing shared results.

*Evidence gate:* the ledger reconstructs a session faithfully, never records
across an authorization boundary, honors opt-in/retention/deletion, and a
deletion request provably removes the data (including derived copies) within the
stated window.

### Stage 2 — Derived judgments (human-in-the-loop)

Turn behavior into weak relevance labels, then let a human confirm them. The
**inorganic** side proposes ("these three passages were read and cited for this
query, so they were probably relevant"); the **organic** side confirms,
corrects, or overrules — applying scarce human judgment only where it matters.
Confirmed labels fold into the **feedback / training judgment set** — never
directly into the frozen holdout gate (see *Evaluation datasets are kept
separate* above).

This is the AI-assisted judgment loop from the improvement board (item L-02). It
converts the corpus-building chore into a fast partnership and is the bridge
from "we captured behavior" to "we can safely learn from it."

**Guard against the exposure/position-bias feedback loop.** Reads and citations
are conditional on what the current ranker put near the top, so treating them
naively as relevance would just reinforce the ranking we already have and never
discover relevant passages that were never shown. Mitigations, all resting on the
recorded impressions/positions from Stage 1:

- **Position-bias correction** when converting behavior to labels (e.g. weight a
  read by the inverse propensity of its shown position), rather than counting a
  click at rank 1 the same as a click at rank 8.
- **Explicit negatives and skips:** a shown-but-skipped high position is signal
  too; let the human mark "shown, not relevant," not only "relevant."
- **Controlled exploration:** occasionally surface lower-ranked or
  alternately-retrieved candidates so the system can *learn about* passages the
  current ranker would never expose. Human confirmation (above) keeps this cheap
  and safe.

*Evidence gate:* derived-then-confirmed judgments measurably grow the training
set without contradicting existing hand-authored judgments, and the frozen
holdout gate remains untouched.

### Stage 3 — Per-context adaptation (the payoff)

Only now does behavior change results. Tune **inspectable** parameters —
fusion weights, lexical/semantic routing, per-principal or per-profile
preferences — from the accumulated signal. Two hard rules:

1. **No learned change ships unless it shows no measured regression on the
   versioned holdout gate, within defined thresholds.** This is the existing
   before/after discipline applied to learning. The check is not a single
   aggregate number: it includes per-query and per-segment (per-principal)
   deltas and a statistical tolerance, so an improvement in the mean cannot hide
   a regression for one query or one user. A change that fails is rejected
   automatically, the same way a code change that fails tests is; a change that
   passes offline is still rolled out as a monitored canary with a fast rollback,
   because a finite gate cannot prove the absence of every regression.
2. **Every adaptation is explainable and reversible.** "Your results lean
   lexical because your queries are mostly exact identifier lookups" — a
   sentence the user can read, and a switch they can flip back.

The equal-RRF-vs-BGE regression already observed (hybrid 0.85 vs vector 0.90 in
the 20-query diagnostic) is exactly the kind of thing this stage fixes: it is a
signal that blind, uniform fusion is wrong for some queries, and that routing
learned from behavior can recover it.

*Evidence gate:* on held-out queries, the adapted ranker beats the static
ranker for the target user/context, with no regression on the frozen gate.

### Stage 4 — Shared learning across a cognitive unit (org scale)

Aggregate signal across the members and agents of a team ("cognitive unit," in
HIO terms) so the group's knowledge search improves collectively — bounded by
the collaborative-knowledge trust and authorization model (improvement board
item O-01). One member's private behavior never leaks to another; only
appropriately shared signal aggregates.

*Evidence gate:* aggregate learning helps the group without crossing any
authorization or privacy boundary, proven on judged multi-principal cases.

## Guardrails (non-negotiable)

These keep the loop aligned with the project's founding invariants.

- **Learning tunes ranking, never truth.** The loop may reorder, route, or
  reweight *evidence*. It may never invent, fabricate, suppress, or edit a
  passage. Retrieval stays separate from generation; behavior never becomes a
  source of truth. It changes *which* real, cited passages surface first —
  nothing else.
- **The versioned holdout gate is the ratchet.** No learned change is deployed if
  it shows a measured regression on the gate beyond defined per-query and
  per-segment thresholds. This bounds relevance to "no measured regression within
  tolerance," not the stronger and unprovable "can only ever improve" — a finite
  judged set and aggregate metrics cannot guarantee the latter, so learned
  changes also ride a monitored canary with rollback.
- **Everything is inspectable and reversible.** Every learned adjustment can be
  explained in plain language and turned off. This extends the existing
  "explain why a result ranked" trace to "explain why the ranking adapted."
- **Privacy is pre-retrieval and local-first.** The interaction ledger is
  principal-scoped and never crosses an authorization boundary. Personal
  behavior stays local unless explicitly shared. Sharing is opt-in, not default.
- **Cold-start is first-class.** Zero history must always produce good results.
  Learning is strictly additive; it is never required to get a useful answer.
- **Honest evidence, always.** Every stage records what worked, what failed, and
  its limits in `EXPERIMENTS.md`. No stage is called "validated" because its
  code runs; only representative, held-out evidence validates it.

## How this maps to HIO

| HIO element | In this loop |
|---|---|
| Inorganic intelligence | Ranking, candidate generation, deriving weak labels, tuning weights |
| Organic intelligence | Confirming relevance, deciding what helped, choosing to trust or verify |
| Harmonization | The ledger + judged corpus as the shared, inspectable memory both sides edit |
| Win–win–win | The user gets better results, the system gets ground truth, the repo gets a durable evaluation asset that every future contributor — human or agent — can build on |

The loop is where the two intelligences stop meeting at a wall and start meeting
at a handshake that both of them improve over time.
