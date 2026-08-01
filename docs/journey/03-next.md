# Next — the live queue

Updated: 2026-07-19. Keep this short and current. The full backlog with *why* and
exit checks is [`IMPROVEMENT-BOARD.md`](../../IMPROVEMENT-BOARD.md); the exact
implementation state is [`PROJECT-STATE.md`](../../PROJECT-STATE.md).

## The one thing that unblocks the most

**E-01 — a representative, user-derived judged corpus.**

Every relevance number today comes from authored fixtures or a sampled public
dataset. That is honest diagnostic evidence, and it is *not* a production
relevance claim. Until a real corpus with independently authored queries exists:

- CAP-14 (trust calibration) cannot set its threshold;
- CAP-15 (structure-aware chunking) cannot prove a code-search gain;
- fusion/routing work (F-01) cannot be trusted beyond the diagnostic.

### It now has a specified path — awaiting one human decision

[**E-01A — real-folder judgment packs**](../requirements/cap-11-e01a-judgment-packs.md)
(merged as specification only) defines the privacy-bounded workflow: inventory a
real single-owner folder without copying content, separate tuning from a frozen
holdout, seal both with an explicit human confirmation over exact hashes, and
fail closed on drift, split leakage, or post-confirmation edits.

> **Blocking action, and it is a human one.** Implementation cannot begin until a
> maintainer posts an explicit step-6b approval covering §6 (invariants), §8
> (CFT-11–13), and §9 (the acceptance gate and its named `pending` criteria), and
> the approval block cites that comment. An agent may not supply this.

The leverage move remains **L-02** — do not hand-label from zero. Let the system
propose labels from behavior and have a human confirm, correct, or overrule.
That turns the corpus chore into a partnership and builds the Stage-2 machinery
at the same time. E-01A is the safe intake half of exactly that.

## Ready to build now

| Item | Why it is ready | Note |
|---|---|---|
| **CAP-13 / I-01 — MCP adapter** | Requirements, conflicts (CFT-02, CFT-08), and a fully decidable acceptance gate are recorded. **Dependencies: none** — scoped to parity with current behavior. | Needs step-6b maintainer approval before build |
| **E-02 — negative / unanswerable evaluation** | Small, self-contained, and it is the empirical guard on the source-of-truth invariant | Feeds CAP-14 |

## Blocked, with the named unblocker

| Blocked | Blocked by | Unblocker |
|---|---|---|
| **CFT-03** — CAP-12 interaction ledger vs INV-09 | The "capture is cheap and reversible" claim is unmeasured | Measure Stage-1 capture overhead, then a maintainer confirms INV-09 compliance |
| **CFT-09** — CAP-15 durable path vs INV-04 | `CON-03` and the Zig manifest/`index_status` do not carry a chunker id/version | Add a versioned chunker-identity field through interchange → manifest/status, with a migration plan. Until then CAP-15 is **Python-only** |
| **CAP-14 threshold** | No negative-bearing judged corpus | E-01 + E-02 |

## Open loose ends

- **CAP-11 §12 approval block** still reads *pending* even though the change
  merged. Either record the approval that occurred or note explicitly that the
  merge itself was the maintainer decision — the written record should not
  contradict the merged state.
- **Persisted 384-d startup / memory / concurrency benchmark** remains the gate
  that decides whether the next engine work is ANN, lexical pruning, or simply
  better process management. No scale machinery before it.

## Standing candidates (not yet scheduled)

From the board, in rough value order: **S-01** trust-calibration signal ·
**S-02** plain-language "why this ranked" · **F-01** query routing to address the
observed equal-RRF regression · **O-01** collaborative knowledge model ·
**L-01** interaction ledger (after CFT-03) · **O-02** authenticated identity.

## How to pick

1. Prefer the item that **unblocks the most other items**.
2. Prefer the item whose **acceptance gate is already decidable**.
3. Do not start anything whose gate depends on an unbuilt capability — rescope it
   or mark the criterion `pending` first.
