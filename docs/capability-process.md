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
[conflict register](requirements/README.md#conflict-register-cft) with the
tension and a resolution (reconcile, scope, supersede, or *accept with
rationale*). A capability may not proceed to build while it has an **unresolved**
conflict.

Ask specifically:

- Does it weaken any **invariant** (retrieval≠generation, citations, pre-rank
  authorization, determinism, dependency-free base, earned complexity, learning
  tunes ranking not truth)?
- Does it contradict an existing **FR/NFR** (e.g. a new latency target vs. an
  exact-scan correctness requirement)?
- Does it change a **contract** in a way that breaks a consumer?
- Does it overlap another capability such that two features now own the same
  behavior?

- **Artifact:** conflict-register rows, all *resolved* or *accepted*.
- **Exit:** no unresolved conflict remains.

### 6. Set the acceptance gate

State the evidence that will prove the capability works: retrieval metric +
target, citation-support behavior, unanswerable behavior, freshness, performance,
and security/isolation tests. Reuse the [evaluation](../EXPERIMENTS.md) and
benchmark discipline; name the judged fixture or benchmark artifact.

- **Artifact:** an acceptance gate in the capability spec and the use case.
- **Exit:** passing is defined in measurable terms *before* building.

### 7. Build

Claim the work centrally first (assigned issue or a merged claim-only change —
see the [improvement board](../IMPROVEMENT-BOARD.md) rules), branch from `main`,
and implement. Keep the base mode dependency-free; keep authorization pre-rank;
keep formats versioned/checksummed.

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
[ ] 5. Conflict check done; every CFT resolved or accepted with rationale
[ ] 6. Acceptance gate defined in measurable terms before building
[ ] 7. Built on a claimed branch; invariants held (auth pre-rank, deps, formats)
[ ] 8. EXPERIMENTS.md + PROJECT-STATE.md + register status updated
```

## When to short-circuit

Small, invariant-preserving changes (a doc fix, a new test, a bounded refactor)
do **not** need the full eight steps — they are not new capabilities. Use
judgment: if it introduces new observable behavior, a new requirement, or a new
contract, run the process. If it only clarifies or hardens existing behavior,
record it as an ordinary change with tests.
