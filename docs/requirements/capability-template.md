# CAP-NN — Short capability name

Status: Proposed · Evidence: future option

> Copy this file when starting a new capability. Fill every section; "N/A" is a
> valid answer but a blank is not. This is step 3–6 of the
> [capability process](../capability-process.md). It ends by updating the
> [requirements register](README.md).

## 1. Proposal

- **Problem / what should be possible:**
- **Who it serves:** (human user · agent user · contributor)
- **HIO tie:** (organic · inorganic · the seam — and why)
- **One-line success notion:**

## 2. Motivating use case(s)

- Primary use case: `UC-NNN` (link)
- Other affected use cases:
- If no use case exists yet, write one first with the
  [use-case template](../use-cases/TEMPLATE.md).

## 3. Functional requirements (new or changed)

For each, give an ID (`FR-NN`, next free number), a testable statement, and
whether it is new or a change to an existing FR.

| ID | Requirement (testable) | New / changes | Traces to |
|---|---|---|---|
| FR-?? |  | new | UC-NNN |

## 4. Non-functional impact

Which NFRs does this capability add, change, or put under pressure (latency,
memory, determinism, dependency-freedom, privacy, backward compatibility)?

| ID | Requirement / impact | Target or constraint |
|---|---|---|
| NFR-?? |  |  |

## 5. Contracts touched (CON)

- New or changed schemas under `contracts/`:
- Backward-compatibility plan (versioned? migration? consumers affected?):

## 6. Invariant compliance (INV)

State, for each invariant the capability could affect, how it complies. Any
"does not comply" line is a conflict — take it to §8.

- INV-01 retrieval≠generation:
- INV-03 pre-rank authorization:
- INV-06 dependency-free base:
- INV-07 versioned/checksummed formats:
- INV-08 deterministic ordering:
- INV-09 complexity earned by measurement:
- INV-11 learning tunes ranking not truth (if applicable):
- Other relevant invariants:

## 7. Register updates (fill when consolidating — step 4)

- Capability catalog row (CAP-NN): 
- FR/NFR index rows added:
- Contracts rows added:

## 8. Conflict check (step 5 — required)

List every tension found against existing invariants/requirements. Each becomes a
`CFT-NN` row in the [conflict register](README.md#conflict-register-cft). Do not
proceed to build with an unresolved conflict.

| CFT | Between | Tension | Resolution (reconcile / scope / supersede / accept) | Status |
|---|---|---|---|---|
| CFT-?? |  |  |  | Resolved / Accepted |

If none: state explicitly "No conflicts found against the current register as of
<date/commit>."

## 9. Acceptance gate (step 6 — measurable before building)

- Retrieval metric + target:
- Citation-support behavior:
- Unanswerable / negative behavior:
- Freshness target:
- Performance / scale target:
- Security / isolation tests:
- Judged fixture / benchmark artifact:

## 10. Evidence plan (step 8)

- Tests to add:
- `EXPERIMENTS.md` entry planned (hypothesis / setup / observation / limits):
- `PROJECT-STATE.md` update:
- How status advances (proposed → diagnostic → validated → operational):

## 11. Open decisions

- Decision:
- Owner:
- Evidence needed:
