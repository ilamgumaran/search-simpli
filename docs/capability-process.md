# Capability process: how a new capability enters Search Simpli

Every new capability or use case follows this structure. The point is not
bureaucracy — it is that **all requirements end up in one place
([the requirements register](requirements/README.md)) so conflicts surface before
code is written**, and that every capability carries its *why*, its acceptance
evidence, and its compliance with the project's invariants.

This process is for humans and agents alike. An agent handed "add capability X"
should be able to execute these steps and produce the same artifacts a careful
human would.

## The eight steps

Each step names its **artifact** and its **exit gate**. Do not start a step until
the previous exit gate is met.

### 1. Propose

State the problem in a sentence: what should be possible that is not, who it
serves (human user, agent user, contributor), and the HIO tie (which
intelligence it strengthens — organic, inorganic, or the seam between them).

- **Artifact:** a short proposal (an [improvement-board](../IMPROVEMENT-BOARD.md)
  item is enough).
- **Exit:** the *why* and a one-line success notion exist. If you cannot state
  them, it is not ready.

### 2. Define the use case

Write or extend a use case with [the template](use-cases/TEMPLATE.md): actor,
corpus, at least five representative questions **including a negative/unanswerable
one**, authorization/egress expectations, freshness, and measurable acceptance
criteria.

- **Artifact:** `docs/use-cases/uc-NNN-*.md`, added to the use-case catalog.
- **Exit:** acceptance criteria are measurable, not vibes.

### 3. Draft capability requirements

Fill [the capability template](requirements/capability-template.md): the new or
changed functional requirements (FR), the non-functional impact (NFR), the
contracts (CON) touched, and the invariants (INV) the capability must comply
with.

- **Artifact:** a filled capability spec (draft).
- **Exit:** every requirement is testable and traces to the use case.

### 4. Consolidate into the register

Assign stable IDs (`CAP-NN`, new `FR-NN`/`NFR-NN` as needed) and add rows to the
[requirements register](requirements/README.md): capability catalog, FR/NFR
indexes, contracts. Add the detailed behavior to
[`specification.md`](recreation/specification.md) if it belongs there.

- **Artifact:** updated register + specification.
- **Exit:** the capability is visible alongside every existing requirement.

### 5. Conflict check — the gate that justifies this whole process

Read the new requirements against **every** invariant and existing requirement
in the register. For each real tension, add a `CFT-NN` row to the
[conflict register](requirements/README.md#conflict-register-cft).

**Resolution types are constrained by what the conflict touches:**

- A conflict **between non-invariant requirements** may be `Resolved` (reconcile,
  scope, supersede) or `Accepted with rationale` (a deliberate tradeoff).
- A conflict **involving an invariant (INV)** may **not** be `Accepted`.
  Invariants are non-negotiable, so an INV conflict must be either `Resolved`
  with evidence that the capability actually complies, `Blocked` until such
  evidence exists, or explicitly changed via an `Invariant-change` decision that
  a named maintainer signs off (step 6b). "Accepted with rationale" on an
  unmeasured assertion is not permitted for an INV.

A capability may not proceed to build while it has an **unresolved** conflict, or
any INV conflict that is not `Resolved` or an approved `Invariant-change`.

Ask specifically:

- Does it weaken any **invariant** (retrieval≠generation, citations, pre-rank
  authorization, determinism, dependency-free base, earned complexity, learning
  tunes ranking not truth)?
- Does it contradict an existing **FR/NFR** (e.g. a new latency target vs. an
  exact-scan correctness requirement)?
- Does it change a **contract** in a way that breaks a consumer?
- Does it overlap another capability such that two features now own the same
  behavior?
- Does its acceptance gate **depend on another capability that is not yet built**
  (see step 6 dependencies)?

- **Artifact:** conflict-register rows, each `Resolved` / `Blocked` /
  `Accepted with rationale` (non-INV only) / `Invariant-change` (approved).
- **Exit:** no unresolved conflict, and no INV conflict left as a bare acceptance.

### 6. Set the acceptance gate

State the evidence that will prove the capability works. It is not enough to name
a direction ("improves", "bounded", "high precision"); each criterion must be
**decidable**, meaning it states:

1. the **exact metric** (e.g. success@3, unanswerable-class F1, p95 overhead ms);
2. the **baseline** it is compared against;
3. the **fixture and split** (which judged corpus, tuning vs. held-out);
4. the **threshold or tolerance** that counts as pass;
5. the **decision rule** (what result ships, what blocks).

**Dependencies.** List any capability or dataset the gate depends on. A capability
whose gate depends on another *proposed/unbuilt* capability is **not build-ready**;
either rescope the gate to current behavior, or record the dependency and mark
the gate `pending` (blocked) until the prerequisite lands. Model this explicitly
so nothing is declared ready while its evidence rests on something that does not
exist yet.

If a threshold genuinely cannot be set until a corpus exists (e.g. E-01/E-02),
mark that criterion `pending` and the capability's Step 6 as **not complete** —
do not fabricate a number.

- **Artifact:** a decidable acceptance gate + a dependencies list in the
  capability spec; each criterion is either fully specified or explicitly `pending`.
- **Exit:** every criterion is decidable or marked `pending`; no fabricated targets.

### 6b. Maintainer approval gate

Governance requires an **independent** check: the capability author (human or
agent) does not approve their own exceptions. Before step 7, a **named
maintainer/reviewer** (not the author) must approve, in the capability spec:

- invariant compliance (§6 of the spec);
- every conflict resolution, especially any `Blocked`, `Accepted`, or
  `Invariant-change`;
- the acceptance gate (and that any `pending` criteria are acceptable to defer).

Record **approver, date, and commit** in the spec's approval block. An agent may
draft and recommend, but may not record itself as the approver.

- **Artifact:** an approval block (approver · date · commit) in the capability spec.
- **Exit:** a maintainer other than the author has signed off.

### 7. Build

Only after the maintainer approval gate (6b). Claim the work centrally first
(assigned issue or a merged claim-only change — see the
[improvement board](../IMPROVEMENT-BOARD.md) rules), branch from `main`, and
implement. Keep the base mode dependency-free; keep authorization pre-rank; keep
formats versioned/checksummed.

- **Artifact:** the implementation on a feature branch + PR.
- **Exit:** the acceptance gate is met with recorded evidence.

### 8. Record evidence and close the loop

Append an [`EXPERIMENTS.md`](../EXPERIMENTS.md) entry (hypothesis, setup,
observation, what worked, what failed, limits, conclusion), update
[`PROJECT-STATE.md`](../PROJECT-STATE.md), and flip the capability/requirement
**status** in the register (proposed → diagnostic → validated → operational as
evidence warrants). Never replace a failed attempt with a success-only narrative.

- **Artifact:** experiment entry + updated register status + updated project state.
- **Exit:** another session (human or agent) can continue without reconstructing history.

## Checklist (copy into the capability PR)

```text
[ ] 1. Proposal: why + who + HIO tie stated
[ ] 2. Use case written with measurable acceptance + a negative question
[ ] 3. Capability requirements drafted (FR/NFR/CON/INV), all testable
[ ] 4. Register updated: CAP + FR/NFR rows + contracts
[ ] 5. Conflict check done; non-INV = resolved/accepted, INV = resolved/blocked/
      invariant-change (never a bare "accepted")
[ ] 6. Acceptance gate is decidable (metric/baseline/fixture-split/threshold/
      rule) or explicitly pending; dependencies on unbuilt capabilities listed
[ ] 6b. Maintainer (not the author) approved invariants, conflicts, and the gate;
      approver + date + commit recorded
[ ] 7. Built on a claimed branch; invariants held (auth pre-rank, deps, formats)
[ ] 8. EXPERIMENTS.md + PROJECT-STATE.md + register status updated
```

## When to short-circuit

Small, invariant-preserving changes (a doc fix, a new test, a bounded refactor)
do **not** need the full eight steps — they are not new capabilities. Use
judgment: if it introduces new observable behavior, a new requirement, or a new
contract, run the process. If it only clarifies or hardens existing behavior,
record it as an ordinary change with tests.
