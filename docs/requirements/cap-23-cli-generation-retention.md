# CAP-23 — The command line keeps two generations by default

Status: Proposed · drafted by S6-T11 (03-next row D2-5, filed by [S6-T3](../tasks/S6-T3.md) ruling 4). Not approved: the maintainer has not read it. Nothing here is built

The number: on `origin/main` at `3c353d8` the highest capability is CAP-22,
the highest functional requirement FR-31, the highest non-functional
requirement NFR-16 and the highest conflict CFT-28 (register tables and the
specification's proposed appendix; a search of every tracked file finds no
higher id). The one other open branch, `task/S6-T9`, changes nothing under
`docs/requirements/` or in `docs/recreation/specification.md`. CAP-17 and
CAP-18 were never used; as S6-T6 recorded for CAP-21, the next number follows
the highest in use. So this record takes **CAP-23**, **FR-32**, **FR-33**,
**NFR-17**, **CFT-29** and **CFT-30**.

## 1. Proposal

- **Problem / what should be possible:** every publish writes complete
  sections, so every update adds a full index, and with `keep_generations`
  unset, the command line's default today, nothing is ever deleted. Measured
  by S6-T3 on a copy of the 10k timing corpus, file-name channel on, five
  one-file `searchd index --update` runs (`docs/evidence/s6-t3/generations.txt`,
  also [`docs/index-size.md`](../index-size.md) § E):

  | After | unset: bytes | unset: files | `--keep-generations 2`: bytes | files |
  | --- | ---: | ---: | ---: | ---: |
  | first index | 32,281,645 | 9 | 32,281,645 | 9 |
  | update 1 | 64,562,727 | 15 | 64,562,727 | 15 |
  | update 2 | 96,843,957 | 21 | 64,563,102 | 15 |
  | update 5 | 193,688,535 | 39 | 64,563,990 | 15 |

  Six full generations after five small edits, three times what two
  generations take, and growing by one full index per update. A person who
  runs `searchd index --update` from a script or a scheduler fills the disk
  without being told. The orchestrator ruled (S6-T3 ruling 4, 16 Nov 2026)
  that this is a trap for a new user and that the command line should keep
  two generations by default, with an explicit option to keep all, leaving the
  C ABI and Dart defaults as they are, and that the change goes through this
  process first.
- **Who it serves:** human user (a folder indexed from the command line stays
  about two indexes in size however often it is updated) · agent user (an
  agent that runs `searchd apply` or `index --update` in a loop does not fill
  the disk) · contributor (one default to explain; the keep-all case is
  spelled out on the command line).
- **HIO tie:** the inorganic side: the cost of keeping a machine index fresh,
  so that keeping it fresh does not cost the person their disk.
- **One-line success notion:** after any number of default
  `searchd index --update` or `searchd apply` runs the index directory holds
  the current generation and one older one, `--keep-generations all` keeps
  every one as today, and no file outside the index directory's own section
  files is ever touched.

## 2. Motivating use case(s)

- Primary use case: [`UC-001`](../use-cases/uc-001-personal-files.md)
  (personal files: one person indexes and re-indexes a notes folder).
- Other affected use cases:
  [`UC-006`](../use-cases/uc-006-directory-filename-search.md) (a folder owner
  or an LLM tool keeping a directory index fresh),
  [`UC-002`](../use-cases/uc-002-codebase-agent.md) (an agent re-indexing a
  codebase after each change). Not affected:
  [`UC-007`](../use-cases/uc-007-family-folders-on-a-phone.md): the app works
  through the Dart binding, whose default does not change, and it already
  passes `keepGenerations = 2` on every change (`docs/index-size.md` § E, app
  commit `0da355a4`).

## 3. Functional requirements (new or changed)

| ID | Requirement (testable) | New / changes | Traces to |
|---|---|---|---|
| FR-32 | `searchd index` (full and `--update`) and `searchd apply` keep two generations unless told otherwise: after a successful publish they delete the superseded generations' section files beyond the newest complete older one, by the existing retention rule (S2-T5, `lifecycle.pruneSupersededWithSource`) with N = 2. `--keep-generations N` (N ≥ 1) sets N; `--keep-generations all` deletes nothing; `0`, a negative or non-numeric value, or a missing value is a usage error (exit 2, one stderr line, nothing written). `searchd apply` gains the option, which it lacks today. A run that publishes nothing deletes nothing. `ss_index_folder`, `ss_apply_changes`, `ss_import_json` and the Dart options keep their default (absent: nothing deleted). The command list may grow by the maintainer's answer to Q2. | changes FR-20's command-line surface and the `keep_generations` default of `searchd index`, adds the option to `searchd apply` | UC-001, UC-006, UC-002 |
| FR-33 | A command-line publish says what retention did: `searchd index` prints `pruned_files` and `prune_failures` (summary line, and the `--update` JSON) whenever retention is in effect, the default included, and not under `--keep-generations all`; any command-line run that deleted at least one file prints one line on stderr naming how many files of every kind, how many bytes and which generations were removed, and how to keep all. Stdout of `searchd apply` and its JSON report (the `apply_changes` result schema under `contracts/tools/`, CON-01/CON-02) are unchanged. The exact form is the maintainer's answer to Q3. | new | UC-001, UC-006 |

**The behaviour, stated exactly (recommended answers to §11 assumed).**

1. **Which commands change their default.** `searchd index` and
   `searchd index --update` (today `--keep-generations N`, unset deletes
   nothing: `zig/src/cli.zig` lines 574–575, `indexer.Caps.keep_generations`
   default `null`) and `searchd apply` (today no option and never deletes:
   `cli.zig` lines 640–660 parse no such flag and `runApply` builds
   `apply_module.Options` with only `allow_file_reads` and `filename_index`,
   lines 1374–1377). Recommended in Q2, not in the ruling: the
   `apply_changes` of `searchd serve --allow-write` and
   `searchd mcp --allow-write` (today never delete: `rpc.zig` line 299,
   `mcp.zig` line 426). Recommended to stay as it is: `searchd import-json`
   (unset flag: the payload's own `keep_generations`, else nothing;
   `importer.zig` lines 102–105). Not applicable: `searchd search` writes
   nothing and keeps no cache (CAP-20, S6-T2 ruling 4; `apply.buildDetached`
   refuses a `keep_generations`, `apply.zig` line 745), and `init-demo`
   publishes one fixed generation.
2. **To what number.** Two: the generation just published and the newest
   *complete* older one (both its documents and lexical files present). A
   lone crash leftover is never counted and is always deleted, as today.
3. **The option to keep all.** `--keep-generations all` (Q5). A repeated
   option: the last one wins, as every option of `index` does today.
4. **Generations already on disk at the first run after the upgrade.** The
   rule is applied to the whole directory at the first successful publish,
   whoever wrote the older generations and however many there are. Reading
   the code against the evidence file (not measured): S6-T3's unset directory
   after update 5 holds generations 1–6 in 39 files; the first default run
   publishes generation 7, keeps 6 and 7, and deletes the 30 section files of
   generations 1–5 (six kinds each). Nothing asks first. A run that fails
   before its `MANIFEST` is replaced (usage error, refused `apply`, a failed
   write) deletes nothing: pruning runs only after the publish, under the
   writer lock (`lifecycle.publishLeasedKeepingWithExtras`, lines 329–335).
5. **What a concurrent reader of a pruned generation sees.**
   - *Already open* (a `serve` or `mcp` process, a C ABI or Dart handle, a
     `query` past its open): on macOS, Linux and Android it keeps answering
     its own generation. The documents and lexical sections are in memory
     from the open; the source and file-name section files are opened (not
     read) at open and read later through those descriptors, and unlinking an
     open file removes only its name (`snapshot_open.zig` around line 380,
     `scope.zig` around line 395, `docs/generation-lifecycle.md` § *A reader
     holding an older generation*). Tested in one process by
     `zig/tests/abi_test.c` (S4-T6: a cold handle opened before
     `ss_apply_changes` with `keep_generations: 1` answers `read_span`,
     `find`, `outline`, `query` and `list_files` from its pruned generation).
     No test does this across processes; acceptance test A6 adds one.
   - *Mid-open* (has read `MANIFEST` for generation G, has not yet opened its
     sections): with two kept, G survives the next publish, so the reader
     fails only if two publishes complete in that window; it then fails with
     `FileNotFound` (`searchd query` exits 1) and a retry reads the new
     `MANIFEST`. Through the command line this cannot happen today, because
     nothing is deleted; it is the one new failure a reader can see (CFT-29).
   - *Windows*: deleting an open file fails; that is counted in
     `prune_failures`, the file stays, the publish succeeds and the next
     publish retries (`docs/generation-lifecycle.md`).

## 4. Non-functional impact

| ID | Requirement / impact | Target or constraint |
|---|---|---|
| NFR-17 | Bounded retention, confined deletion: with the command line's defaults an index directory holds at most two complete generations after any successful publish, and a publish deletes only the engine's own superseded section files directly inside that index directory: regular files named `documents-N.hybseg`, `lexical-N.hyblex`, `source-N.hybsrc`, `filenames-N.hybseg`, `filename-lexical-N.hyblex` or `state-N.hybstate`, `N` canonical decimal and below the published generation. Never a file of the indexed folder, a control file, a link, a directory or any other name. | File counts after repeated updates equal S6-T3's `keep2_files` column (9, then 15); the indexed folder's tree (names, sizes, modification times, SHA-256) is identical before and after; planted files with near names survive (§9). |
| NFR-12 | Indexing time: pruning adds a directory listing and up to one unlink per removed file to a publish, under the lock. | Not a threshold (ROLES); the builder reports update wall time with and without the default, five runs each, on the 10k timing corpus. |
| NFR-01 / INV-06 | No dependency added. | Zig standard library only. |

## 5. Contracts touched (CON)

- New or changed schemas under `contracts/`: none. The `apply_changes`
  request and result schemas (`contracts/tools/`, CON-01/CON-02) are closed
  (`additionalProperties: false`) and are not extended: neither a retention
  field in a request nor `pruned_files` in its result. CON-03's
  `keep_generations` payload field and its description ("a publisher …
  deletes the section files of generations older than the newest N") stay
  true; if Q2 brings `import-json` in, "absent" would mean two for
  `searchd import-json` and none for `ss_import_json`, and the description
  would gain one sentence.
- C ABI, Dart: no declaration, option, default or report field changes.
  `ss_index_folder`, `ss_apply_changes` and `ss_import_json` with no
  `keep_generations` still delete nothing (`abi.zig` lines 693 and 771,
  `ops.zig` lines 1216–1219, `importer.zig` lines 102–105); the Dart
  `IndexFolderOptions.keepGenerations`, `ApplyChangesOptions.keepGenerations`
  and `SnapshotInterchangeV1.keepGenerations` stay `null` by default. One
  comment in `zig/include/search_simpli.h` says `ss_apply_changes` publishes
  "exactly as `searchd apply` does"; it gains a clause naming the different
  default (comment only, as CAP-22 treated its header note).
- Formats: none. Retention works by file name, whatever version wrote the
  sections, so an index directory moves between a pruning and a
  non-pruning `searchd` in both directions.
- Versions: `contracts/CONTRACTS_VERSION` stays 2.8.0 and the Dart package
  stays 0.9.2, since no wire or library behaviour changes. `cli.zig` is under
  `zig/src/`, which `native/SOURCE-SHA256` hashes (S6-T3 ruling 7), so the
  builder rebuilds and restamps the native libraries with
  `tool/build_native.sh`, as S6-T2 did for a CLI-only change.

## 6. Invariant compliance (INV)

- INV-01 retrieval≠generation: N/A.
- INV-02 stable identity and citation: complies; the current generation is
  never touched, so every answer and citation is unchanged.
- INV-03 pre-rank authorization: complies; nothing about scope changes. With
  Q2's `serve`/`mcp` answer, retention is the operator's option on the
  command line and never a field a caller sends.
- INV-06 dependency-free base: complies.
- INV-07 versioned/checksummed formats: complies; no format changes, and
  backward compatibility in both directions holds because retention is by
  name only.
- INV-08 deterministic ordering: complies; answers unchanged.
- INV-09 complexity earned by measurement: complies; the cost is measured
  (193,688,535 B against 64,563,990 B, `docs/evidence/s6-t3/generations.txt`)
  and the change reuses the retention code that exists since S2-T5; it adds
  a default and a word, no new mechanism.
- INV-11: N/A.

## 7. Register updates (fill when consolidating — step 4)

- Capability catalog row (CAP-23): added, Proposed.
- FR/NFR index rows added: FR-32, FR-33, NFR-17 (and their rows in the
  specification's proposed-requirements appendix).
- Contracts rows added: none.
- Conflict rows added: CFT-29, CFT-30.

## 8. Conflict check (step 5 — required)

| CFT | Between | Tension | Resolution | Status |
|---|---|---|---|---|
| CFT-29 | CAP-23 ↔ FR-11 / FR-20 (atomic publication; readers of a published generation) | A reader that has read `MANIFEST` but not yet opened the sections can now find them deleted through the command line, where today nothing is deleted. | Scope: two kept, so only a reader two publishes behind loses, and it fails with `FileNotFound` and succeeds on retry; an open reader is unaffected on macOS, Linux and Android (S4-T6 test; A6 adds a cross-process one); `--keep-generations all` restores today's behaviour. | Resolved (scope) |
| CFT-30 | CAP-23 ↔ FR-24 / FR-20 (one `apply` behaviour across the CLI, the C ABI and MCP) | `searchd apply` would prune by default while `ss_apply_changes`, whose header says it publishes "exactly as `searchd apply` does", would not. | Accepted with rationale: ruling 4 keeps the C ABI and Dart defaults; the host app already passes 2; the command line is what a new person meets. The header comment names the difference; the published generation and the report are the same on both surfaces. | Accepted with rationale |

No invariant conflict. Checked against the register at `3c353d8`.

## 8b. Dependencies

- Capabilities/datasets this one depends on: CAP-10 (durable snapshot,
  publication), CAP-19 FR-20 (`apply`), S2-T5's retention
  (`lifecycle.zig`), S4-T6's handle-across-write behaviour, S6-T3's
  generations measurement and its script inputs (`scripts/gen_timing_corpus.py`).
- Is any acceptance criterion dependent on an unbuilt capability? No.

## 9. Acceptance gate (step 6 — decidable before building)

Every test runs in Debug and ReleaseSmall (ROLES, 2026-11-05). Baseline:
`main` at the task's base. Tolerance zero unless stated.

- **A1 Default retention, `index`.** On a fixture folder, `index` then five
  `index --update` runs (each after editing one file), and separately five
  plain `index` re-runs into the same directory: after each run the directory
  holds exactly the current generation's and the newest complete older
  generation's section files plus `MANIFEST`, `INDEX-STATE.json`,
  `WRITER.LOCK`; `pruned_files` and `prune_failures` are printed.
- **A2 Default retention, `apply`.** The same with five `searchd apply` runs;
  `--json` output keys identical to `main`'s for the same requests.
- **A3 Keep all.** `--keep-generations all` on `index` (both modes) and
  `apply`: every earlier section file still present byte for byte (the
  existing check in `tests/test_cli_process.py` around line 269, then run
  with the option, as its comment states "the CLI's default retention keeps
  every generation").
- **A4 Usage errors.** `--keep-generations` with `0`, `-1`, `two`, `ALL`, an
  empty value or no value, on `index` and `apply`: exit 2, one stderr line
  naming the option, the directory byte-identical before and after.
- **A5 First run after the upgrade.** A directory with six complete
  generations (written with `all`), one lone leftover, and planted
  `notes.txt`, `documents-x.hybseg`, `documents-04.hybseg`, a symbolic link
  named `lexical-2.hyblex`, a subdirectory named `source-3.hybsrc`: one
  default `index --update` keeps generations 6 and 7, removes every canonical
  section file of 1–5 and the leftover, and leaves every planted entry and
  control file in place. The stderr line (FR-33) names the 30 files of
  generations 1–5 and their bytes, summed with `stat` by the test.
- **A6 Concurrent reader, two processes.** `searchd serve <dir>` answers a
  query, `read_span`, `find` and `outline` on generation G; two default
  `index --update` runs in another process delete G's files; the same `serve`
  process answers the same four requests with G's bytes; a fresh `query`
  answers the newest generation. macOS and Linux CI.
- **A7 The indexed folder is never touched.** Tree listing with sizes,
  modification times and SHA-256 identical before and after A1 and A5,
  including when the folder holds files named like section files in its
  subfolders.
- **A8 Surfaces that do not change.** Every existing C ABI and Dart test of
  `keep_generations` (`abi.zig` "keep_generations prunes through
  ss_index_folder and ss_import_json; zero is rejected", whose "Default:
  nothing deleted" step stays; `zig/tests/abi_test.c` S4-T6;
  `index_recovery_test.dart`) passes unedited; `CONTRACTS_VERSION` and the
  Dart version unchanged; `import-json` without the flag deletes nothing
  (unless Q2 says otherwise).
- **A9 Prune failure.** A deletion that fails (a section file the user cannot
  delete) leaves the publish successful, exit 0, `prune_failures` ≥ 1, the
  file in place; the next run retries it.
- **A10 Answers unchanged.** The captured-answers comparison
  (`scripts/capture_query_outputs.py`) and the J2 gate identical to `main`
  without re-recording.
- **A11 Size, re-measured.** S6-T3's procedure
  (`docs/evidence/s6-t3/generations.txt` header) with the new default and no
  option: file counts 9, 15, 15, 15, 15, 15, equal to its `keep2_files`
  column; bytes recorded (not compared: D2 steps 1–3 changed the formats
  since).
- **Plants** (each must fail a test above): default left `null` (A1); `all`
  parsed as 2 (A3); pruning handed the indexed folder's handle (A7); the
  stderr line counting only documents and lexical files (A5).
- Citation-support, unanswerable, freshness, judged-fixture criteria: N/A
  (no answer changes; A10).
- `pending` criteria: none.

## 10. Evidence plan (step 8)

- Tests to add: A1–A7 and A9 as process tests next to
  `tests/test_cli_process.py`, A6 in a process test, parser cases in
  `zig/src/cli_test.zig`; the four plants.
- `EXPERIMENTS.md` entry planned: none; A11's table goes in the task's Report
  beside S6-T3's.
- `PROJECT-STATE.md` update: the default, the option, and the line that
  says "the CLI's and the binding's default" becomes the binding's only.
  `docs/generation-lifecycle.md` § *Retention pruning* also needs the
  command-line default and two corrections found while drafting: pruning
  removes the source, file-name and state sections too (not only documents
  and lexical), and the source and file-name sections are opened at open and
  read later, not read fully at `ss_open`.
- How status advances: Proposed → Implemented and verified on fixtures and the
  generated corpus; Validated is not claimed.

## 11. Open decisions — questions for the maintainer

Each with the options and the drafter's recommendation; none is decided here.

- **Q1. How many generations by default?** (a) 2; (b) 1; (c) 3.
  *Recommended: (a) 2.* It is what the ruling names, what the app runs, and
  what S6-T3 measured (64,563,990 B after five updates). One halves the disk
  again but removes the margin for a reader mid-open; three costs a further
  full generation (the first index alone is 32,281,645 B at 10k timing) for a
  reader two publishes behind.
- **Q2. Which commands follow?** (a) `index` and `apply` only, as ruled;
  (b) also `import-json`; (c) also the `apply_changes` of `serve --allow-write`
  and `mcp --allow-write`, with the same option on those commands.
  *Recommended: (a) and (c), not (b).* `serve` and `mcp` with writes publish
  through the same `apply` from a command-line process, and an agent editing
  through MCP accumulates generations as fast as a script does; the option
  belongs to the operator on the command line, never to a request (the
  request schema stays closed). `import-json` callers number their own
  generations and already have a payload field; it is a pipeline and test
  tool rather than what a new user meets, and leaving it keeps "absent means
  none" the same for `searchd import-json` and `ss_import_json`.
  `searchd search` has nothing to prune.
- **Q3. What does a run say about what it removed?** (a) only the existing
  `index` fields, now printed whenever retention is in effect;
  (b) (a) plus one stderr line on every run that deleted something (files of
  every kind, bytes, generations, "keep all with --keep-generations all");
  (c) a message on the first pruning run only.
  *Recommended: (b).* Deleting files by default should never be silent, and
  the existing `pruned_files` counts only documents and lexical files (two of
  the six a channel-on generation has; `lifecycle.PruneReport.deleted`,
  `apply.zig` line 1254), so it understates what went. A stderr line leaves
  stdout and the `apply` JSON (closed schema) unchanged. (c) needs a new
  marker file to know a run is the first, which is more state for one
  message.
- **Q4. Should an environment variable or a config file also set it?**
  (a) no; (b) an environment variable such as `SEARCHD_KEEP_GENERATIONS`;
  (c) a config file. *Recommended: (a) no.* The command line has no setting
  of this kind today (the only environment variable it reads,
  `SEARCH_SIMPLI_APPLY_STAGES`, is a diagnostic timer); a hidden setting that
  decides what is deleted is harder to see in a script than a flag, and one
  can be added later without breaking anything.
- **Q5. How is "keep all" spelled?** (a) `--keep-generations all`;
  (b) a separate flag such as `--keep-all-generations`; (c)
  `--keep-generations 0`. *Recommended: (a).* One option with one meaning;
  `0` stays invalid everywhere, as the C ABI (`InvalidKeepGenerations`) and
  Dart (`ArgumentError`) treat it, so the command line does not give 0 the
  opposite meaning.
- **Q6. Release note.** Whether the change is announced as a behaviour change
  in `README.md` and the `--help` text in the same task. *Recommended: yes*,
  both, since the `--help` text is the first place a new user reads.

## Migration and rollback

- **A user who relied on every generation staying** passes
  `--keep-generations all` on every `index` and `apply` (and `serve`/`mcp`
  under Q2 (c)). On an older `searchd` that word is a usage error (exit 2,
  nothing written), so a script fails safely rather than deleting. A script
  that must run on both versions can pass a very large number instead (for
  example `--keep-generations 1000000`), which both accept and which deletes
  nothing in practice; on today's binary it also prints the prune fields.
- **Before the first upgraded run**, a user who wants the older generations
  copies the index directory (or its older section files) elsewhere: the
  first default run deletes every superseded generation but one, and that
  cannot be undone. No `searchd` command, C ABI call or Dart method opens a
  generation other than the one `MANIFEST` names (`snapshot_open.zig` lines
  171 and 275), so an older generation is today reachable only by replacing
  `MANIFEST` by hand.
- **Rollback of the change itself**: revert the commit. The index format is
  unchanged, so every index directory keeps working with the reverted
  binary, which simply stops pruning. Files already deleted stay deleted.
- **The app and other hosts** need no change: their defaults and options are
  unchanged.

## Risks

- **Data loss, stated exactly.** Pruning deletes files, and with this change
  it does so without being asked. What can be deleted
  (`lifecycle.pruneSupersededWithSource`, `zig/src/lifecycle.zig` lines
  168–275; the one unlink is `dir.deleteFile` at line 264): regular files
  (not links, not directories) directly inside the index directory (`--out`
  for `index`, `<dir>` for `apply`), not in its subdirectories, named
  `documents-N.hybseg`, `lexical-N.hyblex`, `source-N.hybsrc`,
  `filenames-N.hybseg`, `filename-lexical-N.hyblex` or `state-N.hybstate`
  with `N` plain decimal without leading zeros and below the generation just
  published, and not among the newest complete older generations kept, nor
  the files the new `MANIFEST` names. Never deleted: `MANIFEST`,
  `WRITER.LOCK`, `INDEX-STATE.json`, temporary files, any other name, any
  section at or above the published generation (tested by
  `zig/src/incremental_indexing_test.zig`, "pruning touches only superseded
  canonical section files").
- **Source files are never touched.** The indexed folder is opened for
  reading and walking only (`cli.runIndex`, `openDir` with iterate); pruning
  is handed only the index directory's handle; the only other deletions
  outside tests are a publish removing the files it itself just wrote when
  it fails (`zig/src/publication.zig` lines 136–156 and 314). `searchd apply`
  reads host-named files only with `--allow-file-reads` and deletes none of
  them. The one way a person's own file could be deleted: placing a file with
  exactly one of the six section names directly inside the index directory,
  for example by pointing `--out` at the folder being indexed. That is true
  of `--keep-generations` today; the change makes it the default.
- **A reader two publishes behind** fails once with `FileNotFound` (CFT-29).
- **Scripts that parse `index` output** see two more fields when retention is
  in effect (FR-33), appended at the end of the summary line and as JSON keys.

## 12. Maintainer approval (step 6b — required before build)

- Approver: none yet.
- Date: —
- Commit: draft on `task/S6-T11` from `3c353d8`.
- Status: Pending approval. The maintainer's answers to Q1–Q6 are needed
  before a build task is filed.
