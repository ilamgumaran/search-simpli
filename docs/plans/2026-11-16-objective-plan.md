# Objective plan, 16 Nov 2026: a light engine with a separated core

**Status:** plan, written by the Xcode Mac orchestrator (Claude Fable 5.2) on the
maintainer's instruction of 16 Nov 2026 to review the project against its
objective, plan, and carry the plan out. Measured facts are marked *measured*;
everything else is a proposal until its task merges. The maintainer may overrule
any part of it; decisions taken under this instruction are listed in
[Decisions taken under the instruction](#decisions-taken-under-the-instruction).

## The objective

A search engine that:

1. is **light**, and can search local files **directly** for term matches and,
   where possible, semantic matches;
2. builds a **local index when the number of documents is high**, and that index
   is efficient to **read**, to **write** and in **disk use**;
3. gives an **LLM** what it needs to answer questions about the content and to
   find the specific passages, and serves ordinary **keyword search** for apps;
4. is usable from **desktop, web and native mobile**, so it is flexible and easy
   to interface with;
5. keeps the **core libraries separate from the interfaces**, so each can be
   improved without breaking the other;
6. is **documented** so that others can review it and contribute.

This restates the [vision](../journey/01-vision.md); it does not replace it. The
invariants (INV-01…INV-11) and the [capability process](../capability-process.md)
stay in force.

## Where the engine stands against it

Measured on `main` at `efbdd0e`, 16 Nov 2026, macOS arm64, `ReleaseSmall`, on the
generated timing corpus (`scripts/gen_timing_corpus.py`, invented high-vocabulary
text), one run each, so the timings are indications and the byte counts are exact.

| Objective | State | Evidence |
| --- | --- | --- |
| 1. Light | **Met.** One binary, `searchd`, of 1,095,880 B (`ReleaseSmall`, macOS arm64, measured by S6-T1; not fully static: it links `libSystem` on macOS); arm64 libraries 916,928–954,120 B; no third-party dependencies. | `bindings/dart/search_simpli/native/` |
| 1. Search files directly | **Met since S6-T2** (16 Nov). `searchd search <folder> "<query>"` answers with no index directory, within 100 ms up to about 1,000 files and 1 s up to about 10,000. At `efbdd0e` it was a gap: every query needed a published index directory first. | [direct-search](../direct-search.md) |
| 1. Semantic matches | **Partial.** The engine scores vectors and fuses by rank, but only for snapshots imported from the Python reference. A folder indexed by `searchd` is lexical only. | [roadmap](../roadmap.md) Phase 1 |
| 2. Index read | **Met at 10k files.** A whole `searchd query` process on the 10,000-file index takes about 0.02 s; warm queries are 0.1–0.2 ms. | this review; `docs/evidence/s5-t12/` |
| 2. Index write | **Met for small changes** (one changed file in the 10k index was about 46 ms, 66 ms with the file-name channel, at S4-T16), but every publish writes complete sections. Delta sections are filed, not built. | [03-next](../journey/03-next.md) |
| 2. Disk use | **Gap.** The index is **4.4 times the corpus** at 10,000 files (see below). | this review |
| 3. LLM use | **Met in the main.** Cited evidence envelope, nine tools, an MCP server, a skill, and a recorded agent run (S5-T10). Follow-ups are small and listed in 03-next. | [mcp-server](../mcp-server.md) |
| 3. Keyword search for apps | **Met.** `content`, `filename`, `both`, `find`, word-form groups, misspelling tolerance; one app ships on it. | contracts 2.7.0 |
| 4. Desktop and mobile | **Met.** CLI, JSON-RPC over stdio and loopback HTTP, MCP, a C ABI, a Dart binding on macOS, Android and iOS. | `zig/src/abi.zig`, `bindings/dart/` |
| 4. Web | **Gap.** No WebAssembly build and no JavaScript binding. | no `wasm` target in `zig/build.zig` |
| 5. Core apart from interfaces | **Holds in fact, not in structure.** No core file imports an interface file, but all 78 files (45 without tests and benchmarks) sit in one flat `zig/src/`, and nothing stops a future change from crossing the line. | import graph, this review |
| 6. Contributor documents | **Gap.** No `CONTRIBUTING.md`; the README carries task history ahead of what the project is and how to use it; the roadmap predates most of the engine. | `README.md`, [roadmap](../roadmap.md) |

### Disk use, measured

| Files | Corpus bytes | Index bytes | Index ÷ corpus |
| ---: | ---: | ---: | ---: |
| 200 | 328,342 | 2,014,996 | 6.14 |
| 1,000 | 916,353 | 4,560,085 | 4.98 |
| 10,000 | 7,269,199 | 32,281,645 | 4.44 |

The 10,000-file index, with the file-name channel on, one generation:

| Section | Bytes | Share |
| --- | ---: | ---: |
| `lexical-1.hyblex` (terms, postings, positions) | 12,487,753 | 38.7 % |
| `documents-1.hybseg` (chunk records with their text) | 9,273,775 | 28.7 % |
| `source-1.hybsrc` (file text for exact reads) | 8,279,041 | 25.6 % |
| `state-1.hybstate` | 970,159 | 3.0 % |
| `filenames-1.hybseg` + `filename-lexical-1.hyblex` | 1,270,127 | 3.9 % |

The text is stored twice (chunks and source), each copy larger than the corpus.
The timing corpus has an unusually large vocabulary, which inflates the lexical
section; ordinary prose must be measured before a target is fixed.

**After D2 step 1** (lexical v3, [S6-T4](../tasks/S6-T4.md), 16 Nov 2026): the
same 10,000-file index is 24,793,305 B, **3.41** times its corpus;
`lexical-1.hyblex` 5,396,552 B and `filename-lexical-1.hyblex` 92,952 B, every
other section unchanged ([`docs/index-size.md`](../index-size.md#landed)).

## The work, in order

Each item becomes one or more task files under `docs/tasks/` (series **S6**),
built and verified by different agents as [ROLES](../process/ROLES.md) requires.
An item that changes a contract, a format or the C ABI gets its capability
document first.

### A. A front door for contributors (objective 6)

- `CONTRIBUTING.md`: how to build, run the five suites, what a task file is, the
  evidence rule, the privacy and invented-names rules, how to propose a capability.
- `README.md` rewritten as a front door: what it is, a five-minute start, the
  interface table, the layer map, where the plan and the next work are. The
  history now in the README moves to a status document, unchanged.
- `docs/roadmap.md` brought up to date and pointed at this plan.

### B. The core and the interfaces, made a structure (objective 5)

Today's layers, by the import graph:

| Layer | Files | May import |
| --- | --- | --- |
| **Core** | analysis, chunking, postings, segments, manifest, publication, lifecycle, indexer, apply, engine, scoring, hybrid, find, fold, fuzzy, filename and title fields, scope, source, state | core only |
| **Operations** | `service.zig`, `ops.zig`, `report.zig`: the one seam every interface calls | core |
| **Interfaces** | `cli.zig` + `main.zig` (process), `rpc.zig` (JSON-RPC), `mcp.zig` (MCP), `abi.zig` (C ABI) | operations and core |
| **Bindings** | `bindings/dart/`; later JavaScript, Swift, Kotlin, Python over the C ABI | the C ABI only |

1. **B1:** `docs/layers.md` states this map, and a checker run in CI fails when a
   core file imports an operations or interface file, or operations imports an
   interface. No Zig file changes.
2. **B2:** the files move into `zig/src/core/`, `zig/src/ops/` and
   `zig/src/interfaces/`, and `zig/build.zig` builds the core as its own module
   that the interfaces depend on. A mechanical move with no behaviour change;
   the libraries are rebuilt and re-stamped because the digest covers the paths.
3. **B3:** a small, documented public core API (`core.zig`): open, search, find,
   read, apply. A new interface is written against it and the operations layer,
   never against internals.

### C. Search a folder directly (objective 1)

`searchd search <folder> "<query>"`: read the folder, build the index in memory,
answer, write nothing. Same analysis, ranking, citations and JSON evidence as an
indexed query, so a caller can move to an index without changing what it parses.
The task measures at what folder size the direct search stops being the better
choice and documents the number; a later step can keep a cache directory
automatically past that size.

**Done 16 Nov 2026** ([S6-T2](../tasks/S6-T2.md), merged as `06f8c2e`):
[`docs/direct-search.md`](../direct-search.md). The answer is byte for byte
`index --filename-index` then `query`/`evidence`; nothing is written. Measured
on this Mac (`ReleaseSmall`, five runs, medians; builder and verifier agree):
within **100 ms up to about 1,000 files** (83 ms builder, 79.5 ms verifier;
24 MiB) and within **1 s up to about 10,000 files** (624 ms builder, 599 ms
verifier; 149 MiB). One `search` costs about what `index` plus one `query`
costs, so from the second question on an index wins. No cache was added;
whether to keep one is the maintainer's decision (03-next).

### D. A smaller index (objective 2)

1. **D1, measure and design, no format change:** the byte budget per section on
   three corpora (the timing corpus, ordinary English prose, a Tamil corpus);
   what each candidate would save and cost in read and write time: store the
   text once (chunk records refer to the source section), tighter position
   coding, block-compressed text, an option to leave positions out. Ends with a
   recommendation and a target ratio.
   **Done 16 Nov 2026** ([S6-T3](../tasks/S6-T3.md), merged as `1884dea`):
   [`docs/index-size.md`](../index-size.md). Ruled order for D2, one format
   version per step: (1) lexical v3 (C2b, C1, C3, and the file-name lexical
   section); (2) text once by A′ with record coding; (3) offsets at one byte
   per token (C5b); (4) state and catalog without repeats (D, F). Block
   compression is revisited after them; D2-5 changes the CLI's
   `keep_generations` default (03-next).
2. **D2 onward:** the chosen changes, one format version at a time, each with a
   reader for the previous version, a migration note and before/after numbers
   for size, open, query and one-file update.
   **Step 1, lexical v3, done 16 Nov 2026** ([S6-T4](../tasks/S6-T4.md),
   verified on `59f25e1` and merged into `main` as `f3e354e` on the maintainer's decision,
   with the timing rule not passed): both lexical sections `HYBLEX03` under
   manifest v2.3; the index 22–24 % smaller on the timing and prose corpora
   (10 % on Tamil), the open 17–26 % faster, every answer unchanged; on Tamil
   warm queries about 0.1–0.3 µs and two `find` requests 0.011–0.017 ms slower,
   accepted by the maintainer; one way for a consumer (an older library cannot
   open an index after its first v3 publish).
   **Step 2, text once, done 17 Nov 2026** ([S6-T7](../tasks/S6-T7.md), merged as
   `a02b2cc`): documents record v5, source `HYBSRC02`, manifest v2.4; the index
   33.3–44.5 % smaller on the six corpora, every answer unchanged; the second
   one-way step for a consumer.
   **Step 3, highlight offsets at one byte per token, done 18 Nov 2026**
   ([S6-T8](../tasks/S6-T8.md), merged as `7c088a3`): lexical section `HYBLEX04`,
   manifest v2.5; the index 7.6 % (timing 10k), 9.2 % (prose 10k) and 3.3 %
   (Tamil 10k) smaller, every answer unchanged; the third one-way step for a
   consumer.
   **Step 4, state and catalog without repeats, done 20 Nov 2026**
   ([S6-T9](../tasks/S6-T9.md), merged on the maintainer's go-ahead, squashed onto
   `main` after S6-T13): state section `HYBSTA03`, file-name catalog record v6,
   manifest v2.6; the index 6.2 % (timing 10k), 3.6 % (prose 10k) and 2.5 %
   (Tamil 10k) smaller, 1.89 times the timing corpus, every answer unchanged;
   the fourth one-way step for a consumer (Dart 0.9.4; the app needs a second
   pin). D2's four format steps are merged; B2 (the file move) is merged ([S6-T14](../tasks/S6-T14.md), 20 Nov 2026); B3, the small public core API, is next in B.
3. **Delta sections** for writes (already filed in 03-next) follow D2, since both
   touch the section formats.

### E. Semantic matches for a `searchd`-built index (objective 1)

The engine already stores and scores vectors. What is missing is the way in:
the host supplies vectors per chunk through `apply`, and a query vector through
the C ABI and RPC, each bound to a model identity the engine checks (the existing
embedding boundary and INV rules). The engine does not run a model. A
dependency-free native provider (the PPMI baseline) is considered only after the
host-supplied path is measured on a judged set. Capability document first.

**Capability drafted (CAP-21, Proposed), awaiting the maintainer.** Drafted by S6-T6 as [CAP-21](../requirements/cap-21-host-supplied-vectors.md) (pending approval; two-phase attach recommended; blocked on a J2 semantic slice); verified 16 Nov 2026.

### F. Web (objective 4)

A `wasm32` build of the core with an in-memory index and a small JavaScript
wrapper, after B2 has made the core a module with no file-system or process
dependencies in its query path. Capability document first.

### G. LLM use, the open follow-ups (objective 3)

From S5-T10 and S5-T12, already in 03-next: warnings under `both` and
`filename`; the skill's `read_span` wording; a name-only match's passage quoted
as content; an agent run with the MCP server as the only tool.

**Order:** A and B1 first (documents and a checker, no engine change), with C and
D1 alongside them since they touch different files. Then B2, D2, G. Then E and F,
each behind its capability document.

## Decisions taken under the instruction

The maintainer said to use best judgment toward the objective. These are the
decisions that judgment has taken so far; each can be reversed. Rows marked as
the maintainer's decision are his, not this judgment's.

| Decision | Why |
| --- | --- |
| New work is filed as series S6 from this plan; the 11 Nov review's remaining items (R09, R10) stay open and are not started. | Neither serves the six objectives ahead of A–D; both still need a contract decision. |
| The `busing`/`bus` miss under fold-groups-v3 is accepted for now and stays a 03-next row. | Fixing it reopens the verb-form rule the last three tasks settled; no judged query depends on it. |
| Warnings under `both` and `filename` will be computed, not documented away (item G). | An LLM caller needs to know a word was expanded or unmatched, whatever the field. |
| The S5-T12 timing rule with placement controls stands. | Identical sources build to different timings by placement alone; the old band could not tell that from a regression. |
| CAP-13 is **not** moved to Validated here. | Its exit asks for the maintainer's reading of the S5-T10 evidence; that is not a judgment about the objective. |
| `IMPROVEMENT-BOARD.md` is still not edited by this orchestrator. | It has its own owner (review R12). |
| **The maintainer's decision, 16 Nov:** S6-T4 merges as built, with its measured cost (two Tamil `find` cells fail clause (1) of the five-run timing rule, 18 small cells clause (2)); accepted, not passing. | The maintainer's replies of 16 Nov to the orchestrator's recommendation; see [S6-T4](../tasks/S6-T4.md#maintainers-decision-16-nov-2026). |
| **The maintainer's decision, 16 Nov:** a request on a code path the task did not change is judged by clause (1) only; clause (2), the controls' band, is still reported but no longer fails it. Changed paths keep both clauses. | The same replies; see [S6-T4](../tasks/S6-T4.md#maintainers-decision-16-nov-2026) and the dated rule in [`ROLES.md`](../process/ROLES.md). |
| **The maintainer's go-ahead, 17 Nov:** S6-T7 (D2 step 2, text once) merges with ruling 13's open-time expectation missed on prose-10k by 0.017–0.031 ms; it passes the 2026-11-17 rule. | His reply of 17 Nov to the orchestrator's question; see [S6-T7](../tasks/S6-T7.md). |
| **The maintainer's go-ahead, 18 Nov:** S6-T8 (D2 step 3, one-byte highlight offsets) merges with the prose-10k `both` cells 5–7 % slower (they pass the 2026-11-17 rule as written; they fail under the verifier's original three controls alone) and audit items 5, 9, 14, 16, I5 and I6 filed as follow-up. | His reply of 18 Nov to the orchestrator's question; see [S6-T8](../tasks/S6-T8.md). |
| **The maintainer's decision, 17 Nov:** the timing rule, for every request, changed path or not: a cell fails only if the five-run median of (head − `main`) is at or above T (the larger of 0.010 ms and 1 % of `main`'s median) and exceeds by at least T the largest five-run median of `main2` and of each placement control (at least one matching the task's compiled-code delta). The band clause is tabulated, no longer a failing test. Chosen after seeing S6-T5's data. | The maintainer's reply of 17 Nov ("go with your recommendation and keep the work saved pls") to the orchestrator's recommendation; under the rule then in force builds with no change failed more cells than S6-T5 (37, 16 and 2 against 23, of 163). See [S6-T5](../tasks/S6-T5.md#maintainers-decision-17-nov-2026) and the dated rule in [`ROLES.md`](../process/ROLES.md). |
| **The maintainer's decision, 17 Nov:** S6-T5 (item G, warnings under `both` and `filename`) merges (merged as `423b2e9`); under the rule of 17 Nov its five runs give no failing cell. Both FAIL Verdicts stand as the record of the measurement under the rule then in force. | The same reply; see [S6-T5](../tasks/S6-T5.md#maintainers-decision-17-nov-2026). |
| **The maintainer's go-ahead, 20 Nov:** S6-T9 (D2 step 4, state and catalog without repeats) merges with the Verdict's F1 (three warm `find` cells on timing-10k failed timing set 1 by +34.5, +14.3 and +11.9 µs against T 10.0 and passed set 2, all 25 cells) and F2 (a damaged file-name catalog is refused by readers and rebuilt at the next publish, as on `main`) put to him. Squashed onto `main` after S6-T13 and renumbered to Dart 0.9.4. | His answer "Merge" of 20 Nov to the orchestrator's question "Merge it to the engine's main?"; see [S6-T9](../tasks/S6-T9.md#maintainers-go-ahead-and-merge-20-nov-2026). |
