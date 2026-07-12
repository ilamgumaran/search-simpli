# Improvement board

A shared, living backlog for Search Simpli that **both humans and AI agents**
work from. This is the "using and building" half of the project's Harmonized
Intelligence Orchestration (HIO) idea: the same board that a person scans to
decide what to do next is the board an agent reads to pick up a well-scoped
task, do it, and record the outcome.

> **New here?** Read [`README.md`](README.md) for what the project is,
> [`PROJECT-STATE.md`](PROJECT-STATE.md) for exactly where it stands, and
> [`docs/learning-loop.md`](docs/learning-loop.md) for the adaptive-learning
> vision that most of the top items serve. This board is the *what next*;
> those are the *why* and the *where we are*.

## How to use this board

This board is meant to be **edited by whoever advances it** — a maintainer, a
contributor, or an agent given the repo. The rules keep it trustworthy as many
hands touch it.

1. **Every item states its *why*.** No item is just a task. It names the value,
   who it serves (human user, agent user, or contributor), and how we will know
   it worked. If you cannot state the why and the exit check, it is not ready
   for the board — put it under *Ideas needing shaping*.
2. **Claim before you build.** Set `Status: in-progress` and put your handle or
   agent name in `Owner` so two contributors do not collide. Work on a feature
   branch created from `main` (e.g. `git checkout -b <short-item-name> main`) and
   open a pull request; if a `CONTRIBUTING.md` is added later, follow it instead.
3. **Land with evidence, then record it.** Follow the existing project
   discipline: append an entry to [`EXPERIMENTS.md`](EXPERIMENTS.md) (hypothesis,
   setup, observation, what worked, what failed, limits, conclusion) and update
   [`PROJECT-STATE.md`](PROJECT-STATE.md). Then set the item `Status: done` here
   with a one-line result and a link. **Never** mark an item done because code
   runs — done means the exit check was met with evidence.
4. **Improve the board itself.** Sharpen a why, split an item that is too big,
   add an exit check, correct a wrong assumption, or add a new item using the
   template. That is welcome and expected — this document is a work product, not
   a fixed spec.
5. **Respect the invariants.** Nothing here may erase the retrieval-vs-generation
   boundary, ship a change that regresses the frozen judged corpus, remove
   citations/provenance, or let learning become a source of truth. If an item
   seems to require breaking one of these, stop and raise it, do not proceed.

### Status legend

| Status | Meaning |
|---|---|
| `proposed` | Shaped, has a why and an exit check, not started |
| `accepted` | Agreed as next-up; ready to claim |
| `in-progress` | Someone (named in Owner) is actively building it |
| `blocked` | A named decision or dependency prevents progress |
| `done` | Exit check met **with recorded evidence**; linked |

### Owner-type

Who is well-suited to lead an item. Most are `either`; a few genuinely need a
human's taste or decision (`human`), and a few are mechanical enough to hand
fully to an agent (`agent`).

### Item template

```
### <ID> — <short title>
- **Why:** <the value; who it serves; what breaks or stays weak without it>
- **What:** <the concrete change, scoped>
- **Exit check:** <the evidence that proves it worked>
- **HIO tie:** <build-side / use-side, and which intelligence it strengthens>
- **Owner-type:** human | agent | either
- **Status:** proposed | accepted | in-progress | blocked | done
- **Owner:** <handle/agent, or empty>
- **Links:** <experiment entry, PR, doc, judgment fixture>
```

---

## A. Learning loop — search that improves from use

The heart of the current direction. Full design in
[`docs/learning-loop.md`](docs/learning-loop.md). Build these roughly in order;
each earns the next with evidence.

### L-01 — Interaction ledger (capture, don't yet act)
- **Why:** User/agent behavior (which passage was read, which answer was cited,
  which query got rephrased) is the richest and cheapest relevance signal there
  is, and today it is discarded. Without capturing it, no learning is possible.
- **What:** A principal-scoped ledger recording each search's full **impression**
  (every candidate shown *and its position*, not just clicks), subsequent
  `read_chunk` calls, the chunk an answering model cited, explicit ratings, and
  quick re-queries. It changes no result yet. Ships with a privacy/deletion
  lifecycle: opt-in, data minimization, retention limits, deletion/export,
  encryption, and authorization-change behavior (see the doc).
- **Exit check:** A session reconstructs faithfully from the ledger; no entry
  ever crosses an authorization boundary; opt-in/retention/deletion are honored
  and a deletion request provably removes data (including derived copies);
  overhead is negligible.
- **HIO tie:** Build-side. Creates the shared memory both intelligences will edit.
- **Owner-type:** either
- **Status:** proposed
- **Owner:**
- **Links:** docs/learning-loop.md (Stage 1)

### L-02 — AI-assisted judgment loop (derive, human confirms)
- **Why:** The project's #1 blocker (E005B) is the lack of a real judged corpus;
  building one by hand is slow. Let the AI propose relevance labels from behavior
  and let a human confirm/correct — scarce human judgment applied only where it
  matters. Turns the corpus chore into a fast partnership.
- **What:** Tooling that proposes candidate relevance labels (from L-01 signal
  and top candidates) and presents them for one-tap human confirm/correct;
  confirmed labels fold into the **feedback/training** set, kept separate from
  the frozen holdout gate (three versioned datasets; see the doc).
- **Exit check:** Derived-then-confirmed judgments measurably grow the training
  set without contradicting existing hand-authored judgments and without touching
  the holdout gate; time-per-query drops materially vs. manual authoring.
- **HIO tie:** Use-side + build-side. Inorganic proposes, organic decides.
- **Owner-type:** either (human owns the confirming taste)
- **Status:** proposed
- **Owner:**
- **Links:** docs/learning-loop.md (Stage 2), PROJECT-STATE.md "best next step"

### L-03 — Per-context adaptive ranking (behavior changes results)
- **Why:** "Relevant" is personal and drifts. Once we can measure safely, tune
  inspectable knobs (fusion weights, lexical/semantic routing, per-principal
  preferences) so results get better for *this* user/agent — the payoff of the
  whole loop.
- **What:** Learn fusion weights / routing from accumulated signal, with
  position-bias correction, gated so no change ships that shows a measured
  regression on the versioned holdout gate beyond defined per-query/per-segment
  thresholds, then rolled out as a monitored canary. Every adaptation is
  explainable and reversible.
- **Exit check:** On the held-out gate the adapted ranker shows no measured
  per-query or per-segment regression within tolerance and improves the target
  context; the adaptation can be explained in one sentence and switched off.
- **HIO tie:** Use-side. Inorganic optimization steered by organic behavior.
- **Owner-type:** either
- **Status:** proposed
- **Owner:**
- **Links:** docs/learning-loop.md (Stage 3)

### L-04 — Regression gate as an automatic ratchet
- **Why:** Learning is only safe if a change that makes relevance worse is caught
  before it ships. The versioned holdout gate must act like a test suite —
  acknowledging that a finite gate bounds risk within thresholds rather than
  proving perfection, which is why per-segment checks and canary/rollback back it.
- **What:** A gate that evaluates any candidate ranking change (learned or coded)
  against the versioned holdout set — reporting per-query and per-segment deltas
  with a statistical tolerance, not just an aggregate — and blocks deployment on
  regression beyond threshold, wired so agents and humans get the same pass/fail
  signal, with a canary/rollback path for what passes offline.
- **Exit check:** A deliberately bad weight change is caught and rejected by the
  gate without human intervention, including one that improves the mean while
  regressing a single segment.
- **HIO tie:** Build-side. The shared, trustworthy referee both sides submit to.
- **Owner-type:** either
- **Status:** proposed
- **Owner:**
- **Links:** docs/learning-loop.md (guardrails), docs/roadmap.md (Phase 4 discipline)

### L-05 — Shared learning across a cognitive unit (org scale)
- **Why:** A team's search should improve collectively, not just per-person —
  the "home → medium org → large" progression is really a single-mind →
  many-minds progression.
- **What:** Aggregate appropriately-shared signal across members/agents, bounded
  by the collaborative-knowledge model (O-01) so private behavior never leaks.
- **Exit check:** Aggregate learning helps the group on judged multi-principal
  cases without crossing any authorization/privacy boundary.
- **HIO tie:** Use-side. Harmonizing many organic + inorganic actors.
- **Owner-type:** either
- **Status:** blocked
- **Owner:**
- **Links:** docs/learning-loop.md (Stage 4), item O-01

## B. The seam — where human and AI meet (use-side HIO)

### S-01 — Trust-calibration signal in the evidence pack
- **Why:** Defends the source-of-truth invariant for real users. The system
  should tell the human *when to trust vs. verify* — a confident wrong answer is
  the worst failure mode for at-home search.
- **What:** Make coverage/confidence a first-class field of the evidence
  response (not just a prompt instruction to "acknowledge insufficient support").
- **Exit check:** On unanswerable/negative judged queries, the signal correctly
  flags low support; measured, not asserted.
- **HIO tie:** Use-side. The handshake that keeps organic authority over truth.
- **Owner-type:** either
- **Status:** proposed
- **Owner:**
- **Links:** docs/architecture.md (LLM interface), item E-02

### S-02 — Plain-language "why this ranked" for end users
- **Why:** HIO win–win–win means the human grows. Surfacing *why* a result ranked
  ("matched the exact phrase" vs. "about the same thing in other words") teaches
  a non-expert to ask better questions.
- **What:** A human-readable rendering of the existing component-rank trace,
  exposed at the tool/CLI surface.
- **Exit check:** A non-expert can read why the top result won and use it to
  reformulate; verified with a couple of real users or a proxy.
- **HIO tie:** Use-side. AI teaches, human grows.
- **Owner-type:** either
- **Status:** proposed
- **Owner:**
- **Links:** docs/architecture.md ("explain why a result ranked")

## C. Interfaces — make it real for agents and people

### I-01 — MCP adapter over the existing tool contract
- **Why:** MCP is the standard way agents consume tools. The four operations
  (`search_knowledge`, `read_chunk`, `list_sources`, `index_status`) are already
  specified and served over JSON-RPC — wrapping them as MCP makes the whole
  "search as an LLM tool" thesis usable by real agents at near-zero design risk.
- **What:** An MCP-compatible adapter exposing the existing read-only tool
  surface, preserving authorization and the text-only (no caller vectors)
  boundary.
- **Exit check:** A real MCP client performs search/read/list/status against a
  published snapshot with authorization enforced.
- **HIO tie:** Use-side. Lets inorganic agents actually use the system.
- **Owner-type:** either
- **Status:** proposed
- **Owner:**
- **Links:** docs/tool-protocol.md, docs/zig-rpc-service.md, contracts/search-tool.schema.json

## D. Evaluation integrity — the ground truth everything rests on

### E-01 — Representative user-derived judged corpus (E005B)
- **Why:** Every relevance number today comes from ~20 authored queries. No
  production relevance claim is honest until a real, held-out corpus exists. This
  is the project's own stated best next step and gates L-03, S-01, and routing.
- **What:** A representative user folder, 50–100 real queries with expected
  supporting passages, split into tuning and held-out; compare BM25 / PPMI / BGE
  / fusion; save machine-readable judgments and metrics.
- **Exit check:** Held-out metrics recorded for every mode; the diagnostic neural
  gain either survives real use or is shown not to.
- **HIO tie:** Build-side. The shared ground truth for all future work.
- **Owner-type:** human (needs real corpus + judgment)
- **Status:** accepted
- **Owner:**
- **Links:** docs/roadmap.md (Phase 1), PROJECT-STATE.md "best next step"

### E-02 — Negative / unanswerable evaluation
- **Why:** Current judged sets test "did it find the right thing," not "did it
  correctly refuse when nothing supports an answer." Refusal is the empirical
  guardrail for the source-of-truth invariant.
- **What:** Add unanswerable/negative queries with expected "insufficient
  support" outcomes; measure unanswerable precision as a first-class metric.
- **Exit check:** The system's refusal behavior is measured, not assumed, and
  tracked over time.
- **HIO tie:** Use-side. Keeps the AI honest about its limits.
- **Owner-type:** either
- **Status:** proposed
- **Owner:**
- **Links:** docs/architecture.md (relevance evaluation), item S-01

## E. Organization scale — from one mind to many

### O-01 — Collaborative knowledge model
- **Why:** The jump from personal to team search is a cognitive-unit jump, not
  just a capacity jump. Needs a model of whose knowledge is whose, who vouches
  for it, and what search does when two members' documents disagree (today:
  nothing — it silently flattens conflict).
- **What:** A design note (before code) covering shared/personal/team knowledge,
  contribution/trust between members, and surfacing rather than hiding
  disagreement; builds on the existing all-required-label authorization.
- **Exit check:** A written model with acceptance criteria and at least one
  judged multi-principal conflict case.
- **HIO tie:** Use-side + build-side. Harmonizing many organic actors + agents.
- **Owner-type:** human (product/organizational judgment)
- **Status:** proposed
- **Owner:**
- **Links:** docs/authorization.md, docs/use-cases/uc-003-authorized-team-knowledge.md

### O-02 — Authenticated identity adapter
- **Why:** The caller principal is trusted configuration today. Real multi-user
  and org use needs authenticated identity feeding the same pre-retrieval filter.
- **What:** An identity/token adapter that derives the trusted principal from
  authenticated context, never from an LLM-controlled parameter.
- **Exit check:** Authenticated identity drives authorization end-to-end;
  forgery attempts are rejected, proven by tests.
- **HIO tie:** Build-side. Trust boundary for shared use.
- **Owner-type:** either
- **Status:** blocked
- **Owner:**
- **Links:** docs/authorization.md, PROJECT-STATE.md

## F. Engine and scale — only measured bottlenecks

### F-01 — Query routing to fix the equal-RRF regression
- **Why:** The 20-query diagnostic showed equal-weight hybrid (0.85) *under*
  pure BGE vector (0.90). Blind uniform fusion is wrong for some queries. Light
  routing (identifier lookup → lean lexical; concept/paraphrase → lean semantic)
  likely recovers it, is cheap, and stays inspectable — no heavy reranker needed.
- **What:** A query-feature router that adjusts channel weighting, evaluated
  against E-01's judged corpus and gated by L-04.
- **Exit check:** Routing beats equal RRF on held-out queries with no exact-match
  regression.
- **HIO tie:** Use-side. Inorganic optimization, kept transparent.
- **Owner-type:** either
- **Status:** proposed
- **Owner:**
- **Links:** README.md (measured status), items E-01, L-04

### F-02 — Persisted 384-d startup, memory, and concurrency benchmark
- **Why:** Current Zig scale evidence is synthetic, 32-dimensional, and
  single-query. This measurement decides whether the next engine work is ANN,
  lexical pruning, or just process/service management — the project refuses to
  add scale machinery without it.
- **What:** A benchmark covering snapshot bytes, open/startup time, resident
  memory, and concurrent long-lived 384-d queries.
- **Exit check:** Machine-readable results recorded with methodology and limits;
  the next engine decision is grounded in them.
- **HIO tie:** Build-side. Evidence before complexity.
- **Owner-type:** either
- **Status:** proposed
- **Owner:**
- **Links:** docs/scale-benchmark.md, docs/roadmap.md (Phase 2/4)

---

## Ideas needing shaping

Half-formed ideas live here until they have a why and an exit check. Promote to
a lettered section when shaped; delete if rejected (and say why in a commit).

- Feedback ledger surfaced back to the *user* ("this answer helped / didn't")
  as a lightweight, always-available control — relationship to L-01 to be worked out.
- Structure-aware chunking for code (UC-002) so chunks follow function/class
  boundaries rather than fixed line windows.
- Cross-encoder or LLM reranker over a small candidate set — only if routing
  (F-01) proves insufficient, and only if it preserves provenance.

## Change log for this board

Keep this short; it is a pointer to where the real record lives.

- 2026-07-12 — Board created. Seeded from the HIO review: learning loop (A), the
  human–AI seam (B), interfaces (C), evaluation integrity (D), organization
  scale (E), and measured engine work (F). See `docs/learning-loop.md`.
