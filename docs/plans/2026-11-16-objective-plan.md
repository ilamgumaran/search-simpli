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
3. **Delta sections** for writes (already filed in 03-next) follow D2, since both
   touch the section formats.

### E. Semantic matches for a `searchd`-built index (objective 1)

The engine already stores and scores vectors. What is missing is the way in:
the host supplies vectors per chunk through `apply`, and a query vector through
the C ABI and RPC, each bound to a model identity the engine checks (the existing
embedding boundary and INV rules). The engine does not run a model. A
dependency-free native provider (the PPMI baseline) is considered only after the
host-supplied path is measured on a judged set. Capability document first.

Drafted by S6-T6 as [CAP-21](../requirements/cap-21-host-supplied-vectors.md) (Proposed, pending approval; two-phase attach recommended; blocked on a J2 semantic slice).

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
decisions that judgment has taken so far; each can be reversed.

| Decision | Why |
| --- | --- |
| New work is filed as series S6 from this plan; the 11 Nov review's remaining items (R09, R10) stay open and are not started. | Neither serves the six objectives ahead of A–D; both still need a contract decision. |
| The `busing`/`bus` miss under fold-groups-v3 is accepted for now and stays a 03-next row. | Fixing it reopens the verb-form rule the last three tasks settled; no judged query depends on it. |
| Warnings under `both` and `filename` will be computed, not documented away (item G). | An LLM caller needs to know a word was expanded or unmatched, whatever the field. |
| The S5-T12 timing rule with placement controls stands. | Identical sources build to different timings by placement alone; the old band could not tell that from a regression. |
| CAP-13 is **not** moved to Validated here. | Its exit asks for the maintainer's reading of the S5-T10 evidence; that is not a judgment about the objective. |
| `IMPROVEMENT-BOARD.md` is still not edited by this orchestrator. | It has its own owner (review R12). |
