# Approach — how we work

The vision says *what*. This says *how*, so that a human and an agent working
weeks apart produce compatible work.

## 1. Evidence discipline

The single most important habit in this repo.

Every claim in every document is one of four things, and says which:

| Label | Means |
|---|---|
| **Implemented** | The code exists and tests actually execute against it |
| **Observed** | A recorded run produced this number, under stated conditions and limits |
| **Hypothesis** | We believe it; we have not shown it |
| **Future option** | A path we might take; not chosen, not built |

Rules that follow from it:

- **Never replace a failed attempt with a success-only narrative.** The failed
  41,377-chunk WANDS representation stays in the record next to the corrected
  10,000-chunk run, because the comparison is the finding.
- **State what a result does *not* prove.** A sampled, cap-biased benchmark is
  not comparable to the full dataset, and the doc must say so.
- **Compilation is not test evidence.** Tests must run and be counted.

## 2. Complexity is earned, not anticipated

Before adding machinery (ANN, pruning, quantization, sharding, a cache, a new
service), there must be a **named target that is currently failing** and a
before/after measurement, plus a rollback path.

This has already paid for itself: the first real Zig bottleneck was not the
approximate-search problem everyone expects — it was `O(n²)` rank assignment.
Measuring first found it; a deterministic in-place sort fixed it (174.6 ms →
0.417 ms p50 at 8,000 candidates). ANN was never needed.

## 3. Requirements meet in one place

All requirements — capabilities, functional, non-functional, invariants,
contracts — are indexed in the
[requirements register](../requirements/README.md), whose real job is the
**conflict register**: making requirement-level clashes visible *before* code.

The register indexes and reconciles; it does not duplicate.
`specification.md` stays authoritative for behavior detail, `contracts/` for wire
payloads, `use-cases/` for scenarios.

A [CI validator](../../scripts/check_requirements.py) enforces this across
documents — unique IDs, allowed status tokens, valid CAP/UC/CON references,
one-to-one FR/NFR coverage with the specification, catalog↔spec↔index agreement,
required Dependencies and approval blocks, and the rule that an invariant
conflict is never merely "accepted". Drift fails the build.

## 4. New capability? Run the process

[`docs/capability-process.md`](../capability-process.md) — eight steps, each with
an artifact and an exit gate:

> Propose → Use case → Draft requirements → Consolidate into the register →
> **Conflict check** → Acceptance gate → *(6b: maintainer approval)* → Build →
> Record evidence

Two gates matter most:

- **Conflict check.** A conflict touching an **invariant** may only be
  *Resolved* (with evidence), *Blocked*, or an explicit *Invariant-change*
  approved by a maintainer. It may **never** be "accepted with rationale" on an
  unmeasured assertion.
- **Acceptance gate.** Each criterion must be *decidable* — exact metric,
  baseline, fixture/split, threshold, and decision rule — or explicitly marked
  `pending` with the prerequisite that unblocks it. Never fabricate a threshold.

**Short-circuit rule:** a doc fix, a new test, or a bounded refactor is not a
capability. If it introduces new observable behavior, a new requirement, or a new
contract, run the process; otherwise just land it with tests.

## 5. Agents and humans work the same board

[`IMPROVEMENT-BOARD.md`](../../IMPROVEMENT-BOARD.md) is designed to be edited by
whoever advances it. Every item states its *why* and its *exit check*. Claims
must become **centrally visible before substantive work** (an assigned issue, or
a merged claim-only change) — a local branch does not serialize anything.

**An agent may draft and recommend; it may not approve its own exception.**
Step 6b requires a named maintainer other than the author to sign off on
invariant compliance, conflict resolutions, and the acceptance gate.

## 6. Review is adversarial on purpose

The review loop on this repo has repeatedly found real defects — not style nits.
It works because reviews *test the claim*, not just read the diff:

- A reviewer ran the new validator against a mutated copy and proved it passed
  when it should have failed. Twice.
- A reviewer caught an approval block citing an *automated, changes-requested*
  comment as human approval — the exact loophole the gate exists to close.

When you review here: try to break the claim, then say precisely how you tried.

## 7. Session protocol

Because work spans CLI sessions, web sessions, and multiple agents:

**Start** — read [`01-vision.md`](01-vision.md) (if new/returning),
[`PROJECT-STATE.md`](../../PROJECT-STATE.md) (current truth),
[`03-next.md`](03-next.md) (what to do). Verify with the validator and tests.

**During** — work on a feature branch; keep the base mode dependency-free; keep
authorization pre-rank; keep formats versioned.

**End** — update `PROJECT-STATE.md`, append to `EXPERIMENTS.md` if you ran an
experiment, refresh [`03-next.md`](03-next.md), and add to
[`04-evolution.md`](04-evolution.md) *only* if direction or a durable decision
changed.

## 8. What we owe the reader

The project is a **behavioral reference and a set of durable contracts** as much
as it is code. Someone should be able to rebuild it from the docs alone
([the recreation kit](../recreation/README.md)) and get the same reasoning, the
same safety boundaries, and the same honest account of what is unproven.

If a document would mislead a stranger about what works, it is a bug.
