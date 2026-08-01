# Vision — what we are building and why

## The objective, in one sentence

> Given a user question, return the **smallest set of authorized source passages
> that best supports a correct, cited answer.**

Build search **from first principles** — starting with the files and folders on
one person's machine, and evolving into a durable Zig lexical-and-semantic engine
— **without changing the logical contracts** along the way.

## The founding principle

> **Retrieval and generation stay separate.** Search finds and **cites**
> evidence. An answering model may synthesize from that evidence, but it must
> never silently become the source of truth.

Every other principle in this project exists to defend that line. It is what
keeps provenance, authorization, relevance testing, and engine replacement
inspectable instead of tangled together.

## The three forms

One contract, three progressive shapes. Each is genuinely useful on its own.

| Form | What it is | Who it serves |
|---|---|---|
| **1. Simple local reference** | Dependency-free Python: index a folder, BM25 + optional semantic + RRF, cited evidence, a small tool process | One person, one machine, thousands of files |
| **2. Durable single node** | Zig-owned immutable segments, checksummed manifests, atomic publication, deterministic hybrid ranking, a live query service | A team, a real corpus, real latency needs |
| **3. Measured scale platform** | ANN, lexical pruning, quantization, sharding, replication | Only when a *named* latency/capacity/freshness target actually fails |

The progression from form 1 to form 3 is not a rewrite. It is the same logical
document/chunk/embedding/request/result contracts, implemented with more
machinery as evidence demands.

## Home → organization → large is a *cognitive* progression

The obvious reading is capacity: more files, more queries, more nodes. That is
the shallow half.

The deeper half: going from a personal corpus to an organizational one is going
from **one mind to many minds**. It raises questions capacity alone never does —
whose knowledge is this, who vouches for it, what happens when two members'
documents disagree, and what should search do when it can see both. We frame
organizational scale as a *shared cognitive substrate* problem, not just a
sharding problem.

## The HIO framing

Search Simpli is a sibling of the
[HIO framework](https://github.com/ilamgumaran/thought-org-with-human-ai-hybrid).
Applied here:

- **Inorganic intelligence** — recall, ranking, pattern matching, consistency at
  scale. What retrieval is genuinely good at.
- **Organic intelligence** — judgment, taste, knowing which passage actually
  helped, deciding what is true.
- **Harmonization** — the two meeting at a designed *seam*, not a wall.

The retrieval/generation boundary is already an HIO principle in disguise: the
inorganic side does what it is good at, and is structurally prevented from
usurping organic authority over truth.

What is still missing is that the partnership is **one-directional**. The system
serves evidence and forgets everything. The human's reaction — which passage was
read, which answer was accepted, which query had to be rephrased — is the richest
and cheapest relevance signal available, and today it is discarded.

## The next chapter: a system that learns from use

The [learning loop](../learning-loop.md) is the missing half. Staged, so each
stage earns the next with evidence:

1. **Foundation** — works with zero learning. Always.
2. **Interaction ledger** — capture behavior. Change nothing yet.
3. **AI-assisted judgments** — the AI proposes relevance labels from behavior;
   a human confirms, corrects, or overrules.
4. **Per-context adaptation** — behavior finally reshapes ranking, per user.
5. **Shared learning** — a team's search improves collectively.

With guardrails that are not negotiable: **learning tunes ranking, never truth**;
no learned change ships that regresses the frozen holdout gate; every adaptation
is explainable and reversible; privacy is pre-retrieval and local-first;
cold-start is first-class.

## What "good" looks like

Success is **not** "it looks impressive" or "the benchmark went up." It is:

- a person finds the passage they needed, and can *see why it was returned*;
- an agent gets cited evidence it cannot fabricate around;
- an unanswerable question is **correctly refused**, not confidently answered;
- forbidden content never enters a prompt — because it never entered a channel;
- every performance or relevance claim traces to a recorded, reproducible run;
- someone new can read the docs and know exactly what is proven and what is hope.

## Principles (canonical list: INV-01…INV-11)

The full, enforced list lives in the
[requirements register](../requirements/README.md#invariants-inv). In spirit:

- Retrieval ≠ generation.
- Every passage carries stable identity and a citation.
- Authorization filters **before** ranking, in both channels.
- Model and chunker identity are index data; re-embedding is a migration.
- Exact scan stays the correctness oracle if approximate search arrives.
- The base mode runs with no third-party dependencies.
- Formats are versioned, bounded, checksummed; ordering is deterministic.
- Complexity is earned by measurement, never added in anticipation.
- Tests must actually execute; docs separate implemented / observed / hypothesis / future.
- Learning tunes ranking, never truth.

These are **non-negotiable**. A capability that appears to require breaking one
is resolved as a recorded conflict — or blocked — never quietly merged.
