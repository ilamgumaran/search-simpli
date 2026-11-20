# CAP-20 — Direct folder search

Status: Implemented and verified (S6-T2) · built by [S6-T2](../tasks/S6-T2.md) (objective 1, item C of the [objective plan](../plans/2026-11-16-objective-plan.md)); [Verdict](../tasks/S6-T2.md#verdict-verifier-fills-in) PASS on `8036a9c`, merged as `06f8c2e` on 16 Nov 2026. Not Validated: §10 asks for representative user-derived folders, and the verification used fixtures and generated corpora only

## 1. Proposal

- **Problem / what should be possible:** answer a query over a local folder
  directly, with no index directory. Before S6-T2 every query needed
  `searchd index <folder> --out X` first, which writes an index about 4.4 times
  the corpus (plan, *Disk use, measured*) and leaves it behind. For a small
  folder, or a one-off question, that is a cost with no return.
- **Who it serves:** human user (one command, nothing to clean up) · agent user
  (a tool can search a folder it was just handed) · contributor (one path, the
  same answers as the index path, so nothing new to keep in step).
- **HIO tie:** the seam — the same cited evidence the index path gives, without
  the inorganic step of building and keeping an index.
- **One-line success notion:** `searchd search <folder> "<query>"` prints byte
  for byte what `index <folder> --out X --filename-index` followed by
  `query X` / `query X --json` / `evidence X` prints, and writes nothing.

## 2. Motivating use case(s)

- Primary use case: [`UC-006`](../use-cases/uc-006-directory-filename-search.md)
  (directory content and filename search).
- Other affected use cases: [`UC-001`](../use-cases/uc-001-personal-files.md)
  (personal files), [`UC-002`](../use-cases/uc-002-codebase-agent.md) (a coding
  agent handed a folder).

## 3. Functional requirements (new or changed)

| ID | Requirement (testable) | New / changes | Traces to |
|---|---|---|---|
| FR-26 | `searchd search <folder> "<query>"` answers over the folder with no index directory, with `--top-k`, `--json`, `--evidence`, `--search-field content\|filename\|both`, `--max-file-bytes` and `--max-total-bytes`; its stdout is byte for byte that of `index <folder> --out X --filename-index` followed by `query X` (or `query X --json`, or `evidence X`) with the same options; it writes nothing in or beside the folder and leaves nothing behind; a missing folder, a file where a folder is expected and an empty query are usage errors (exit 2, one stderr line); an empty folder answers with no results and exit 0. | new | UC-006, UC-001, UC-002 |

## 4. Non-functional impact

| ID | Requirement / impact | Target or constraint |
|---|---|---|
| NFR-15 | Direct search builds in memory: it creates no file or directory anywhere (folder, its parent, the working directory, the temporary directory), and its cost against the index path is stated by measurement, not assumed. | Tested by `zig/src/tests/direct_search_test.zig` and `tests/test_direct_search.py`; crossover measured in [S6-T2](../tasks/S6-T2.md) §6 and [direct-search](../direct-search.md). No wall-clock threshold is a test (ROLES). |
| NFR-12 | Indexing time and memory: `search` pays the whole build on every call. | Not changed; the crossover table says up to what folder size that is acceptable. |
| NFR-01 / INV-06 | No dependency added. | Zig standard library only. |

## 5. Contracts touched (CON)

- New or changed schemas under `contracts/`: none. The JSON `search` prints is
  the JSON `query --json` prints (CON-01 envelope, unchanged); no wire, schema,
  C ABI or Dart change.
- Backward-compatibility plan: nothing persistent is written, so there is no
  format to version. Every other command is unchanged; the existing suites and
  the J2 gate pass without re-recording.

## 6. Invariant compliance (INV)

- INV-01 retrieval≠generation: complies; the answer is the existing retrieval
  envelope.
- INV-03 pre-rank authorization: complies within its scope; the detached build
  is one local root with no labels, exactly as `index <folder>` builds it.
- INV-06 dependency-free base: complies.
- INV-07 versioned/checksummed formats: complies; the in-memory sections are the
  same versioned, checksummed bytes `index` publishes (a test compares them) and
  are validated by the same open path.
- INV-08 deterministic ordering: complies; same engine, same generation (1),
  byte-identical output.
- INV-09 complexity earned by measurement: complies; the in-memory path reuses
  the build and open code with a directory-or-memory switch, and the crossover
  is measured before any caching is considered (none is added).
- INV-11: N/A.
- Other relevant invariants: INV-02 (stable identity and citation) holds because
  chunk ids and citations come from the same build.

## 7. Register updates (fill when consolidating — step 4)

- Capability catalog row (CAP-20): added.
- FR/NFR index rows added: FR-26, NFR-15 (and their rows in the
  specification's proposed-requirements appendix).
- Contracts rows added: none.

## 8. Conflict check (step 5 — required)

No conflicts found against the current register as of `7cd2c16` (S6-T2 base).
The one tension considered: a folder searched directly is re-read and re-built
on every call, which could be read against NFR-12's budgets; NFR-12 bounds
`index`, which is unchanged, and the cost of `search` is reported as NFR-15
requires, so it is not a conflict.

## 8b. Dependencies

- Capabilities/datasets this one depends on: CAP-01 (indexing and chunking),
  CAP-02 (lexical retrieval), CAP-05 (evidence envelope), CAP-10 (snapshot
  sections), CAP-16 (file-name channel), the J2 fixture.
- Is any acceptance criterion dependent on an unbuilt capability? No.

## 9. Acceptance gate (step 6 — decidable before building)

- Primary metric: byte equality of stdout against `index --filename-index` then
  `query` / `query --json` / `evidence`, on all 290 J2 queries × 3 fields × 3
  forms, a sample over the whole `fixtures/` folder, and a folder exercising the
  walk's rules and the byte caps · baseline `main` at `7cd2c16` · tolerance zero ·
  any difference fails.
- Citation-support behavior: unchanged (same envelope).
- Unanswerable / negative behavior: an empty folder answers as an empty index
  does, exit 0.
- Freshness target: every call reads the folder as it is.
- Performance / scale target: no threshold as a test; the crossover (wall time
  and peak memory of one `search` against `index` plus `query` and against
  `query` on an existing index, ReleaseSmall, five runs, at 100, 1,000, 5,000
  and 10,000 files and one ordinary-prose folder) is recorded in the S6-T2
  Report with the folder sizes up to which `search` answers within 100 ms and
  within 1 s.
- Security / isolation tests: the leaves-nothing tests (folder tree with sizes
  and modification times, its parent, the working directory and an empty
  temporary directory, all unchanged).
- Judged fixture / benchmark artifact: `fixtures/j2`; the timing corpus from
  `scripts/gen_timing_corpus.py`; `scripts/direct_search_crossover.py`.
- `pending` criteria: none.

## 10. Evidence plan (step 8)

- Tests to add: `zig/src/tests/direct_search_test.zig` (8 tests),
  `tests/test_direct_search.py` (7 process tests), three plants (S6-T2 Report).
- `EXPERIMENTS.md` entry planned: none; the crossover is recorded in the S6-T2
  Report and `docs/direct-search.md`.
- `PROJECT-STATE.md` update: the `search` command.
- How status advances: Diagnostic · implemented on fixtures and the generated
  corpus; Validated needs representative user-derived folders and is not
  claimed.

## 11. Open decisions

- Decision: whether to keep the built sections between calls (a cache).
- Owner: the maintainer.
- Evidence needed: the crossover; S6-T2 adds no caching.

## 12. Maintainer approval (step 6b — required before build)

- Approver: approved by the orchestrator under the maintainer's instruction of
  16 Nov 2026 (see the [plan](../plans/2026-11-16-objective-plan.md)); the
  maintainer may overrule.
- Date: 2026-11-16.
- Commit: S6-T2 task file on `main` at `7cd2c16`.
- Status: Approved (orchestrator, under instruction); not Validated.
