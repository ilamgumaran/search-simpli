# Where the engine stands, and what is next (review of 22 Nov 2026)

**Purpose.** Work is paused so reviewers can read where things stand and object
to the next steps before they are built. This page is the state; the
[implementation specification](../plans/2026-11-22-text-search-implementation-spec.md)
is what is proposed. `main` is at `8ffc41c` plus the commit that adds these two
documents. Written by the orchestrator session; every number is measured and
linked to the task that measured it.

## The direction

The six objectives of the [objective plan](../plans/2026-11-16-objective-plan.md)
stand. On 22 Nov 2026 the maintainer put one outcome first
([the priority](../plans/2026-11-16-objective-plan.md#the-priority-set-by-the-maintainer-on-22-nov-2026)):
search the files on a device and in synced folders for text, find the files
relevant to a question, and answer from the relevant parts, **very well, before
other formats**. Simple token and pattern matching is the base; semantic
matching and a language model refine it. An index and prepared per-file metadata
are allowed where they serve the outcome.

## What was done since 16 Nov 2026 (series S6)

| Plan item | Tasks | Outcome |
| --- | --- | --- |
| A, B1: a front door and a checked layer boundary | [S6-T1](../tasks/S6-T1.md) | `CONTRIBUTING.md`, the layer checker in CI. |
| C: search a folder with nothing prepared | [S6-T2](../tasks/S6-T2.md) | `searchd search <folder> "<query>"` ([direct search](../direct-search.md)). |
| D: a smaller index | [S6-T3](../tasks/S6-T3.md), [T4](../tasks/S6-T4.md), [T7](../tasks/S6-T7.md), [T8](../tasks/S6-T8.md), [T9](../tasks/S6-T9.md) | Lexical section v3, text stored once, one-byte highlight offsets, state and catalog without repeats ([index size](../index-size.md)). |
| B2, B3: core, operations, interfaces as a structure | [S6-T14](../tasks/S6-T14.md), [T15](../tasks/S6-T15.md), [T16](../tasks/S6-T16.md), [T18](../tasks/S6-T18.md), [T19](../tasks/S6-T19.md) | Sources moved into `core/`, `ops/`, `interfaces/`; a public core API of 86 names in 22 namespaces ([core API](../core-api.md)). |
| Writers | [S6-T13](../tasks/S6-T13.md), [T17](../tasks/S6-T17.md), [T20](../tasks/S6-T20.md), [T21](../tasks/S6-T21.md) | A full rebuild numbers its generation under the writer lock; a caller's stale number is refused ([lifecycle](../generation-lifecycle.md), decisions [0003](../decisions/0003-full-rebuild-numbers-under-writer-lock.md), [0004](../decisions/0004-callers-generation-number.md)). |
| G: LLM follow-ups | [S6-T5](../tasks/S6-T5.md), [T10](../tasks/S6-T10.md) | Warnings under `both` and `filename` (CAP-22). |
| E: semantic, draft only | [S6-T6](../tasks/S6-T6.md) | [CAP-21](../requirements/cap-21-host-supplied-vectors.md), proposed, not approved. |
| H1: a judged set | [S6-T22](../tasks/S6-T22.md) | 181 questions scored for the right file and the right passage ([text-search-score](../text-search-score.md)). |
| Usage testing | [scenarios](../testing/scenarios-engine-2026-11-22.md) | 113 everyday scenarios: 81 pass, 25 surprise, 7 fail. |

On `main`: contracts 2.8.0, the Dart binding 0.10.0, 606 Zig tests (597 pass,
9 skip), the Python suite 616.

## In progress, not on `main`

**[S6-T23](../tasks/S6-T23.md), all the text (H2).** Built on `task/S6-T23`;
a separate verifier is running; the timing runs have not been taken (they need
an awake, quiet machine). It does not merge before both.

What it does: the walk reads every file whose bytes are text, with any extension
or none ([decision 0005](../decisions/0005-which-files-are-text.md) and CAP-24
on the branch); files not read are counted by kind in `not_read`; contract
2.9.0, additive. Measured by the builder on the judged set, complete answers of
169:

| Field | As typed | Query words |
| --- | --- | --- |
| Names and content | 100 → 109 | 109 → 127 |
| Content only | 110 → 120 | 118 → 137 |

**It is not a pure gain.** 30 questions get worse in some configuration,
because newly read files (twelve near-identical logs, one short README) now
compete in the ranking and fill the ten results. Each is listed with its cause
in the task's Report and is owned by step H5 of the specification. Two
behaviours a reviewer should weigh, both reported by the builder: a short file
with one stray control byte is now treated as binary, and a file with a known
text extension that holds a NUL byte is no longer indexed.

## What the measurements say is wrong today

From the judged set's baseline and the scenarios. Each row names the step that
owns it.

| Fault | Measured | Owner |
| --- | --- | --- |
| Text kinds that are never read | 24 of 270 files; 31 questions name an unread file | H2 (in progress) |
| An exact string cannot be searched | `142.50` becomes `142` and `50`; quotes are ignored outside `find` | H3 |
| Nothing says what a file holds | no kind, script, dates or modification time per file | H4 |
| One result per file with names and content | two-passages 0 of 11 | H5.1 |
| Copies and near copies fill the first ten | scenarios; worse after H2 | H5.3 |
| A stale copy ranks first | 10 (typed), 5 (query words) of 22 | H5.4 |
| Answers do not fit a small budget | complete within 4,096 bytes: 9 and 36 of 169 with names and content | H5.5 |
| No signal that evidence is weak | a no-answer question returns results in 11 and 8 of 12 | H5.6 |
| Question words steer ranking; `where` becomes `were` | as typed below query words in every column | H5.7 |
| Warnings reach only one interface | RPC, MCP and CLI carry none | H5.6 |
| Errors do not name the path; a README sentence is wrong; an accent in a file name is not folded | scenarios X01, X02, Q02, finding 5 | small faults S1 to S3 |
| No semantic matches for a `searchd`-built index | CAP-21 not approved | H6 |

## Pending, in order

1. **S6-T23:** the verifier's Verdict; the timing runs; merge. (In progress.)
2. **Review of the specification.** Nothing in it starts until reviewers have
   had their say and the maintainer says go.
3. Then, as the specification orders them: the small faults; warnings on every
   interface; H3 `scan`; H5 collapse and passages per file; H4 profile; the rest
   of H5; the defaults decision; H6.

### Waiting on the maintainer

| Item | What is asked |
| --- | --- |
| CAP-21 (semantic matches, host-supplied vectors) | Read and approve, change or decline; H6's semantic track waits on it. |
| CAP-13 (MCP adapter) to Validated | His reading of the S5-T10 evidence. |
| R09, R10 (11 Nov review) | Each needs a contract decision. |
| CAP-23 (keep two generations from the command line) | Approve or decline. |
| CAP-24 (which files are text) | Recorded as accepted under his direction of 22 Nov, for his review; say if logs or data files should be excluded by default. |
| `init-demo` refusing over an existing index | Acceptable, and should it have its own message? |
| An error code on a Dart import refusal | A contract change; wanted or not. |
| Two C header comments naming old paths | May the header text be corrected. |
| S6-T21's second timing cell | Whether the verifier's pooled view changes his decision to accept it as noise. |
| New defaults after H5 | His decision when the measurements exist. |

### Open follow-ups not in the specification

They stay rows in [03-next](../journey/03-next.md); none blocks the priority:
the remaining D2 items (lazy lexical reader, keeping two generations), delta
sections for `apply`, headroom past 10,000 files, the cold first file-name
query, the `busing`/`bus` miss, the J2 negatives bar, E-02 negative evaluation,
the web build (F), and the consuming application's pin bumps.

## How the work is done (for a new reviewer)

Each task is a file under [`docs/tasks/`](../tasks/) with the rulings, the
builder's Report, a separate verifier's Verdict, and the merge note. A builder
never merges its own work. Changes to the natives are timed under the rule of
2026-11-17 in [ROLES](../process/ROLES.md). A new contract field, format or
interface gets a capability document first ([process](../capability-process.md)).
The layer, requirements, home-path and test-count checks under `scripts/` run before every merge.

## Where to object

- To a **design**: the question lists in the
  [specification](../plans/2026-11-22-text-search-implementation-spec.md).
- To the **order**: its "Proposed order and size" table.
- To the **measure**: [text-search-score](../text-search-score.md) says what the
  judged set scores and what it cannot.
- To **S6-T23** before it merges: its task file and decision 0005 on the branch
  `task/S6-T23`.
