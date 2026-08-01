# The journey — start here

This directory is the **continuity layer** for Search Simpli. It exists so that
any session — Claude Code CLI, a web session, another agent, or a human picking
this up months from now — can start in one place, understand *what we are
building and why*, and continue without reconstructing history.

It does not duplicate the repo's other records. It connects them.

## Read in this order

| # | Document | Answers |
|---|---|---|
| 1 | [`01-vision.md`](01-vision.md) | **What** we want to achieve, and the principles that constrain it |
| 2 | [`02-approach.md`](02-approach.md) | **How** we work — evidence discipline, governance, session protocol |
| 3 | [`03-next.md`](03-next.md) | **What's next** — the live queue and current blockers |
| 4 | [`04-evolution.md`](04-evolution.md) | **How we got here** — the record of decisions and course corrections |

## Where everything else lives

The journey directory is deliberately thin. These remain authoritative:

| Need | Go to |
|---|---|
| Exact current implementation state + resume commands | [`PROJECT-STATE.md`](../../PROJECT-STATE.md) |
| What was tried, what failed, what it proved | [`EXPERIMENTS.md`](../../EXPERIMENTS.md) |
| The shared human + agent backlog | [`IMPROVEMENT-BOARD.md`](../../IMPROVEMENT-BOARD.md) |
| Every requirement in one place + conflicts | [`docs/requirements/`](../requirements/README.md) |
| How a new capability enters the system | [`docs/capability-process.md`](../capability-process.md) |
| Required behavior in detail | [`docs/recreation/specification.md`](../recreation/specification.md) |
| Design reasoning | [`docs/architecture.md`](../architecture.md), [`docs/theory.md`](../theory.md) |
| The adaptive-learning direction | [`docs/learning-loop.md`](../learning-loop.md) |

**Rule of thumb:** *journey* = why, how, next, and history. *Everything else* =
current truth. If they disagree, the authoritative doc wins and the journey doc
is corrected.

## Resuming a session

Works the same in CLI or web.

### Starting

1. Read [`01-vision.md`](01-vision.md) and [`02-approach.md`](02-approach.md) if
   you are new to the project (or returning after a gap).
2. Read [`PROJECT-STATE.md`](../../PROJECT-STATE.md) for exact current behavior
   and the commands that work today.
3. Pick work from [`03-next.md`](03-next.md) — it names the next task and why.
4. Confirm the ground is where you think it is:

   ```sh
   python3 scripts/check_requirements.py          # requirements consistency
   python3 -m unittest discover -s tests           # behavioral tests
   ```

### Working

- Small, invariant-preserving change? Just do it with tests.
- New capability, requirement, or contract? Run the
  [capability process](../capability-process.md) — it ends in the requirements
  register with a conflict check.
- Never claim more than the evidence supports. Label
  *implemented / observed / hypothesis / future option*.

### Ending

Before the session ends (this is what makes the next one cheap):

1. Update [`PROJECT-STATE.md`](../../PROJECT-STATE.md) — exact behavior, evidence, next step.
2. Append to [`EXPERIMENTS.md`](../../EXPERIMENTS.md) if you ran an experiment —
   including what failed.
3. Update [`03-next.md`](03-next.md) — what is now next, what got unblocked.
4. Add a dated entry to [`04-evolution.md`](04-evolution.md) **only if the
   direction, a principle, or a durable decision changed.** Routine progress does
   not belong there; that is what the other records are for.

## Why keep an evolution record at all

The other documents describe the system as it *is*. They deliberately erase the
path — a spec should not read like a diary. But the path carries information the
end state cannot: which assumptions turned out wrong, which review caught what,
why a rule exists in the shape it does.

[`04-evolution.md`](04-evolution.md) preserves that, so a future contributor can
see not just the rules but the *pressure that produced them* — and so we can tell
whether we are actually improving or just moving.
