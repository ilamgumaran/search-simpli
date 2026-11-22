# ADR 0004 · A caller's own generation number at or below the current one is refused

**Status:** design note of [S6-T21](../tasks/S6-T21.md), Part 1, written from `main` at `a8fc2a2` before any code
(21 Nov 2026). The maintainer chose the direction on 21 Nov 2026 ("refuse a caller's number at or below the current
generation, as a documented new refusal"). Line numbers are `main`'s. Everything is read from the code unless it says
**measured**; the measured lines come from a scratch probe (never committed) whose diff and results are in
[`docs/evidence/s6-t21/part1/`](../evidence/s6-t21/part1/).

## 1. Every input that carries a caller's number, and where it is used

| Input | Where the number enters | Where it is used | Lease |
| --- | --- | --- | --- |
| `searchd index --generation N` | parsed at `interfaces/cli.zig` 560–565 (`0` is a usage error), held in `IndexOptions.generation` (34–40) | `cli.zig` 853 → `indexer.indexFolder` (`core/indexer.zig` 171–182) → `walkAndApply` 198 → `walkOptions` 240 → `apply.Options.generation` (`core/apply.zig` 124) → used at `apply.zig` 1224 (`options.generation orelse nextFreeGeneration`), published at 1233 | taken at 764; `MANIFEST` read at 767 |
| `searchd import-json <dir> <file>` | the payload's `generation` (`core/importer.zig` 54; `0` refused at 101) | names and manifest at 159–176 (`manifest.create`, 163–164), published at 184–186 | taken inside `lifecycle.publishSerializedKeepingWithSource` 305 or `publishSerializedWithFilenameKeeping` 581 |
| `ss_import_json` | `interfaces/abi.zig` 534–549 → `importer.importJson` 547 | as `import-json` | as `import-json` |
| Dart `importSnapshotJson` | `SnapshotInterchangeV1.generation` / `V2` (`lib/src/snapshot_interchange.dart` 46, 66, 74–75: `< 1` throws) serialized into the payload | `lib/src/search_simpli_base.dart` 503–531 → `ss_import_json` | as `import-json` |
| Python reference | `build_interchange(generation=1)` and `export_zig.py --generation` (default 1), `src/search_platform/interchange.py` 18–20, 50, 74, 82 | **writes the number into a JSON file only; it publishes nothing.** The number reaches the engine through `import-json` above | — |
| `searchd init-demo <dir>` | the constant 1 (`interfaces/main.zig` 164–169) | `lifecycle.publishSerialized` (`main.zig` 178) | taken at `lifecycle.zig` 354 |
| `searchd search` | the constant 1 (`indexer.buildFolderDetached`, `indexer.zig` 259; `apply.buildDetached` 744–745) | in memory only: `dir == null`, no lease, nothing published | — |

Not a caller's number: `ss_index_folder` (its options, `abi.zig` 688–707, have no `generation`; the JSON parser
refuses unknown fields), `--update` (`cli.zig` passes no number; `--generation` is ignored there),
`ss_apply_changes`, `searchd apply`, `serve`/`mcp` `apply_changes` (all number themselves at `apply.zig` 1224).
`expect_generation` (`apply.zig` 768–770) is a check, not a number to publish. The Python reference's folder model
numbers itself in memory (`src/search_platform/folders.py` 566).

So the check must cover three code paths: `apply.applyParsed` with `options.generation` set, and the two leased
wrappers the importer uses plus `publishSerialized` (`init-demo`).

## 2. Where the check goes

**The orchestrator's reading is right about the lease and slightly wrong about "immediately before the publish".**
Between the lease and the publish no cooperating writer can change the directory, so the check gives the same answer
anywhere under the lease. Placement then follows cost:

- **`apply.applyParsed`:** right after the `expect_generation` check (`apply.zig` 768–770), when `dir != null` and
  `options.generation != null`. That is after the lease (764) and the `MANIFEST` read (767), and **before** the files'
  bytes are read (`readContent`, ~1100) and the build. Checking at 1224 or 1233 would read and build the whole
  folder before refusing. `buildDetached` passes `dir == null` and is skipped.
- **The importer and `init-demo`:** in `lifecycle.publishSerializedKeepingWithSource` (after 305),
  `publishSerializedWithFilenameKeeping` (after 581) and `publishSerialized` (after 354), with the number decoded from
  the `manifest_encoded` they already take. Their only non-test callers are `importer.zig` 185–186 and `main.zig` 178.
  The importer builds its sections before the lease, so for it this point is the moment just before the publish.
- **Not in `publishLeasedKeepingWithExtras`** (one place for every path): it would add a directory listing to every
  self-numbered publish (`--update`, `apply_changes`: each of the app's saves) for a case those paths cannot reach,
  and, for `--generation`, it runs after the build.

**What it compares with. Recommendation: the highest generation the directory has any trace of**
(`generation_alloc.highestGenerationOnDisk`, `generation_alloc.zig` 123–156: `MANIFEST`'s generation, the canonical
documents, lexical, file-name and state section files, and `INDEX-STATE.json`'s generation), not `MANIFEST`'s alone.
A caller's `N` is accepted only if `N > floor`. Reasons:

1. It is the self-numbering rule's floor (S2-T14, `nextFreeGeneration` starts above it), so both kinds of writer obey
   one rule: a caller's number is accepted only if the engine could have chosen it itself.
2. With `MANIFEST` present and every writer honouring the lock, the two rules give the same answer, apart from crash
   leftovers above `MANIFEST`. When `MANIFEST` is lost (`currentGeneration` returns 0, `generation_alloc.zig` 102),
   the `MANIFEST`-only rule accepts any number, for example 5 with generation 9's sections still on disk. A reader that
   opened 9 before the loss then sees the directory go back, and pruning never removes 9, since it is "at or past
   current". The trace rule refuses that.
3. It costs one `MANIFEST` read, one `INDEX-STATE.json` read and one directory listing under the lease, the same as
   `nextFreeGeneration` already pays on every self-numbered rebuild.

Consequences of the trace rule, for Part 2:

- A lone crash leftover at `N` (for example `lexical-10.hyblex` over generation 9) now gets the new refusal, not
  `PathAlreadyExists`. `PathAlreadyExists` stays for a number above the floor whose name is taken by something that
  is not a trace: a `source-N.hybsrc`, or a link or directory under a section name (S1-T23).
- **A damaged `MANIFEST`.** `highestGenerationOnDisk` fails with the decode error. `apply` already fails there (767).
  The importer and `init-demo` do not read `MANIFEST` today (`publication.publishWithExtrasRecorded` never reads
  it), so today an import over a damaged `MANIFEST` replaces it. **Recommendation:** the check counts a `MANIFEST`
  that fails to decode as absent. Its own section files are still traces, so the floor is still safe, and the
  importer's behaviour over a damaged `MANIFEST` does not change beyond this one refusal. Otherwise this task adds a
  second refusal, which belongs with "Remaining recovery decisions" in `generation-lifecycle.md`.
- Nothing on disk changes when the refusal fires. It comes after the lease and before any link. The only possible
  write is `tryAcquireWriter` creating `WRITER.LOCK` (`lifecycle.zig` 338), and only in a directory that has traces
  but no `WRITER.LOCK` (one copied by hand). This is the same as for every refusal under the lease today.

## 3. The refusal

**No existing error fits honestly:**
- `PathAlreadyExists` would name a path that does not exist.
- `NoFreeGeneration` means the numbers are exhausted, and its line says "use a fresh output directory".
- `WriterBusy` invites a retry with the same payload, which would fail forever.
- `GenerationZero` maps to `SS_ERR_CORRUPT_SNAPSHOT`.
- `apply_changes`' "stale: generation is M" is a `source.Failure` message on that one channel, not an error the
  importer can return.

**Recommendation: a new error name, `StaleGeneration`, under the existing code `SS_ERR_INVALID_ARGUMENT` (-1).** The
caller must choose another number. That is the class the header already gives a stale `expect_generation` and a
stale cursor (`zig/include/search_simpli.h` 41–44, 731–732). `SS_ERR_IO` would tell callers to retry
(`search_simpli.h` 181). No new `SS_ERR_*` code, no new function, no field. The line names the floor, so the caller
can renumber even after a lost `MANIFEST`, when `ss_open` cannot tell it the number. It is formatted like
`NoFreeGeneration`'s, from thread-local state set by the same check (`generation_alloc.zig` 37–79):

`StaleGeneration: generation 5 is not above 9, the highest generation in this directory (traces: MANIFEST, documents-9.hybseg, lexical-9.hyblex, state-9.hybstate); publish a higher number`

**What each caller sees** (measured on the probe, `probe-results.txt`, for the CLI rows):

| Interface | Today (`--generation 5` / an import numbered 5 over 9) | After |
| --- | --- | --- |
| `searchd index --generation 5`, `import-json`, `init-demo` | publishes 5; `MANIFEST` 9 → 5; exit 0 | stderr `error: StaleGeneration: …` (the line above), exit 1, empty stdout, nothing on disk changed. Without a `catch` in `main.zig`, Zig prints `error: StaleGeneration` and, in Debug, an error return trace (seen on the probe). So `main.zig` must catch it as it does `NoFreeGeneration` at 52–56, for `index` (51), `import-json` (38) and `init-demo` (37) |
| `ss_import_json` | returns 5 | returns `SS_ERR_INVALID_ARGUMENT` (-1); `ss_last_error()` `ss_import_json: StaleGeneration: …`. `abi.zig`'s `errorCode` (551–674) must list it under 648–670, or it falls to `SS_ERR_INTERNAL` |
| Dart `importSnapshotJson` | returns 5 | throws `SearchSimpliException` with that message. Its `code` getter (`search_simpli_base.dart` 26) is **null**: `ss_import_json` spells its failures `"ss_import_json: <Name>"`, without the 2.0.0 `SS_ERR_<CODE>` part, and the Dart function drops the integer code (522–526). This is unchanged and stated in the CHANGELOG |
| `ss_index_folder`, `ss_apply_changes`, `serve`/`mcp` `apply_changes`, `searchd apply`, `--update` | — | unreachable: they carry no caller's number |

**Every file a new error touches:**
- **Code:**
  - `zig/src/core/generation_alloc.zig`: the check and its describe function.
  - `zig/src/core/apply.zig`: the call after 770.
  - `zig/src/core/lifecycle.zig`: three calls.
  - `zig/src/core/core.zig`: the `api` doc comments of `indexFolder` (326–337, "a number given is published as
    given"), `importer` (387–400) and `lifecycle.publishSerialized` (455–460), plus `describeStaleGeneration` beside
    `describeNoFreeGeneration` (371–376).
  - `zig/src/interfaces/abi.zig`: `errorCode`, and `ss_import_json`'s `setLastError` (537) for the line.
  - `zig/src/interfaces/main.zig`: the three `catch`es.
  - `zig/src/interfaces/cli.zig`: the `--generation` comment (34–40) and the usage text (56, 71–73).
- **The public core API count:** one new name gives 86 names in 22 namespaces. That moves `scripts/check_layers.py`'s
  output, `tests/test_check_layers.py` 1127 and 1167 (both pin 85), and `docs/core-api.md` (tables at 97–106 and the
  refusals at 150–152).
- **Header:** `zig/include/search_simpli.h`, the Errors summary (41–48) and `ss_import_json` (455–482). Its
  documentation mirror is `bindings/dart/search_simpli/lib/src/bindings_generated.dart` 351–366 (ffigen; regenerate
  or keep it equal).
- **`contracts/`:** `snapshot-interchange.schema.json` `generation` (20–23) at most gains a `description` ("a
  publisher refuses a number at or below the target directory's highest generation"). The schema cannot express the
  rule, and a valid payload can already be refused by the directory's state (`PathAlreadyExists`, `WriterBusy`).
  `CONTRACTS_VERSION` is unchanged (section 5).
- **Dart:**
  - `lib/src/search_simpli_base.dart` 491–502: the `importSnapshotJson` doc.
  - `lib/src/snapshot_interchange.dart` 46: the `generation` doc.
  - `CHANGELOG.md` and `pubspec.yaml`.
  - The Dart package maps no error names (it passes the message through), so there is no mapping to change.
- **Python:** no mapping exists. The reference does not publish, and no Python code maps engine error names to codes
  (`git grep` over `src/`, `tests/` and `scripts/*.py`). Only `interchange.py`'s `--generation` help (74) should say
  the number must be above the target directory's.
- **Error documents:**
  - `docs/generation-lifecycle.md` 49 (the "can go backwards" sentences, "Nothing checks a caller's number").
  - `docs/zig-engine-api.md` 85.
  - `docs/publication-recovery.md` 33 (`PathAlreadyExists` stays true above the floor).
  - `docs/core-api.md`.
  - Decision 0003 sections 4 and 6 (superseded by this note; a pointer, not a rewrite).
- **Natives:** every Zig, header and `CONTRACTS_VERSION` input above is in `SOURCE-SHA256`, so the three binaries are
  rebuilt and restamped.

## 4. Who is affected: everything in the repository that passes a number at or below the current one

**Measured.** A scratch probe (`probe.diff.txt`) put the trace-rule refusal at the three places in section 2, on an
archive of `a8fc2a2`. Then:
- `zig build test --summary all` (Debug): 600 tests, **one** failure, and the probe fired **once** in the whole log.
- `zig build test-abi`: 24/24 checks pass.
- The Python suite (580 tests), which builds its own `searchd` from the probe's `zig/`: no publish failed. The three
  failures are the archive's (no `.git`, digest changed); none publishes.

Then by reading:

| Where | What it does today | What it must become |
| --- | --- | --- |
| `zig/src/tests/cli_test.zig` 929–955, "S6-T20: searchd index --generation N with N not free is refused with PathAlreadyExists …" | `--generation 10` over (a) 10 published by another writer, (b) a lone `lexical-10.hyblex` over 9, (c) a lone `state-10.hybstate` over 9; expects `PathAlreadyExists` in all three. **Measured:** (a) gets `StaleGeneration` (`n=10 floor=10`); the test stops there, so (b) and (c) did not run. Under the trace rule they are refused too (both are traces) | (a), (b), (c) expect `StaleGeneration` with the floor in the line and the directory digest unchanged. A new case keeps `PathAlreadyExists` above the floor: a lone `source-10.hybsrc` or a link named `documents-10.hybseg` over 9 |
| The verifier's two cases (S6-T20 Verdict finding 2; `docs/evidence/s6-t20/verifier/caller-and-order.txt`, `mirror.txt`) | `--generation 5` / an import numbered 5 over 9 publish 5; an import numbered 10, held before its lock while two rebuilds with `keep_generations = 1` run, publishes 10 over 11 | Part 2's new tests: both refused, nothing changed |
| Dart tests (`test/query_report_test.dart`, `search_simpli_test.dart`, `snapshot_interchange_test.dart`, `conformance_test.dart`, `folder_knowledge_test.dart`) | every `importSnapshotJson` goes into a fresh `createTempSync` directory (read; not run against the probe) | nothing |
| Scripts: `scripts/import_parity.py` 185, 230, 253–254; `scripts/capture_query_outputs.py` 227–237, 247–248 (guarded by `if not snapshot.exists()`); `tests/fixtures/gen_index_98c4a2b.sh` 43 | import generation 1 into new directories | nothing. A rerun of `import_parity.py` into a reused scratch folder would now fail with `StaleGeneration` rather than `PathAlreadyExists` |
| `tests/test_cli_process.py` 448–458 | imports 5 after `MANIFEST` is removed, with 4 the highest trace | nothing (5 > 4; **measured** passing) |
| `docs/incremental-indexing.md` 354–356 | `export_zig.py … --generation 5`, then `import-json /srv/search`, presented as the repeatable Python route | the number must be above the directory's highest generation: say how to choose it (status + 1, or the floor named by the refusal) |
| `docs/python-zig-bridge.md` 50–58, `zig/README.md` 34, `docs/recreation/specification.md` 162–169, `docs/zig-rpc-service.md` 11 (`init-demo`) | number 1 into a directory; correct only for a new directory | one clause each: run into a new directory; a second run is refused with `StaleGeneration` (today `PathAlreadyExists`) |
| `docs/generation-lifecycle.md` 49; `bindings/dart/search_simpli/CHANGELOG.md` 0.9.6 "Not changed"; `PROJECT-STATE.md` 31; `docs/journey/03-next.md` 382 | say a free low number is published and `MANIFEST` goes back | lifecycle and the state files say what is now true; the 0.9.6 entry is history and stays |
| Python reference `interchange.py` | defaults to 1 | help text only (section 3) |

Nothing else in the repository passes a caller's number at or below the current one. Everything else that passes
one (`indexFolder(…, 1 | 9 | 10, …)` in the core tests, `filename_field_test.zig` 84–99, `manifest_read_test.zig`
301, 456 and 494, `incremental_indexing_test.zig` 501–614, `cli_test.zig` 729, every `importJson` in the core tests,
`abi_test.c`) goes into a new directory or above the floor. **Measured**, by the single probe hit.

## 5. Versions, and the app

**The rule as written:**
- `CONTRIBUTING.md` 144–151: `CONTRACTS_VERSION` moves with "a new or changed field in `contracts/`", a format, a C ABI
  function or an interface.
- The header (`search_simpli.h` 5–7) "never changes shape without" a bump.
- Practice in the Dart CHANGELOG: contracts minor for additive fields (2.1.0 to 2.8.0), major for 2.0.0. Dart minor for
  a visible behaviour change without an API change (0.7.0 and 0.8.0, "minor: ranking change"), patch for a fix whose
  outcomes are otherwise the same (0.9.3, 0.9.5, 0.9.6).

**Recommendation:**
- **Contracts stay 2.8.0.** No field, code, function, format or header shape changes. The new refusal reuses
  `SS_ERR_INVALID_ARGUMENT`, and the schema only gains a description.
- **Dart 0.9.6 → 0.10.0 (minor: a new refusal).** A call that returned a generation now throws, so this is visible
  behaviour, not a patch-level fix.

**The app.** Through the Dart package's public API (`lib/search_simpli.dart`), the only way to pass a number is
`importSnapshotJson` (via `SnapshotInterchangeV1`/`V2.generation`). `IndexFolderOptions` (`lib/src/contracts.dart`
860) has no generation field. `applyChanges`' `expect_generation` is a check, not a number to publish. So the app is
affected only if it calls `importSnapshotJson`. That is not visible from here. This repository records the app's
writes as `indexFolder` and `applyChanges` with `keepGenerations = 2` (`docs/generation-lifecycle.md` 82,
`docs/index-size.md` § E). The package's example deliberately does not call `ss_import_json` on a device
(`example/lib/main.dart` 13–23). The app's pin task should `grep` for `importSnapshotJson` before taking 0.10.0.
