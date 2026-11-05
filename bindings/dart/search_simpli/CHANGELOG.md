# Changelog

## 0.3.2 (S4-T6; contract 2.2.0; patch: no API change)

A crash in `searchd`, not in this package's library. No Dart API, C ABI or
contract changed (`contracts/` stays 2.2.0); the three native binaries are
byte-identical to 0.3.1's, rebuilt twice on the Mac (macOS 825,736 B,
Android 787,216 B, iOS framework binary 789,304 B); `native/SOURCE-SHA256`
changes (`7762a23a…`) because the sources it digests changed.

- **The crash.** A release build of `searchd serve --allow-write`
  (`ReleaseSmall`, `ReleaseFast`, `ReleaseSafe`) answered `apply_changes`
  and then died with signal 11 on the next call that loads a table lazily
  (`read_span`, `outline`, `find`, `search_knowledge`, `list_files`),
  without a reply. Since S4-T1 (0.2.1) the reloaded generation kept an
  allocator that pointed at a freed `ArenaAllocator`; Debug builds never
  reuse freed memory, so every Debug suite stayed green. `searchd mcp` held
  the same dangling pointer into a stack slot.
- **The fix.** The served generation owns an arena on the heap that never
  moves (`rpc.Generation`); a reload opens the new generation, then closes
  the old one, files included (the old reload also left the old
  generation's section files open, one set per write).
- **A release library's handle after a write on the same directory**
  (the contract, now stated in `search_simpli.h` and tested in Debug and
  `ReleaseSmall` by `zig/tests/abi_test.c`): a handle opened before
  `ss_apply_changes` / `SearchSimpli.applyChanges` on the same directory
  keeps answering the generation it opened, also after the write prunes
  that generation's files (`keepGenerations`); close it and open again to
  see the new generation. The library path never had the defect: the same
  test passes against the 0.3.1 library in both build modes.
- CI now runs the engine tests, the C ABI harness and the Python suites
  against a `ReleaseSmall` build too.

## 0.3.1 (S4-T4; contract 2.2.0; patch: no API change)

The cheaper edit. No Dart API, C ABI or contract changed (`contracts/` stays
2.2.0); the natives are rebuilt (`native/SOURCE-SHA256` `db21322e…`).

- **Recovery state: one copy, binary.** Each generation's bound state section
  `state-N.hybstate` is now the `HYBSTA02` binary form
  (`docs/state-section-format-v2.md`): 970,159 B on the 10k timing corpus
  against 2,522,562 B of JSON (`HYBSTA01`). `INDEX-STATE.json` becomes a
  version 3 pointer to it (generation, analyzer, section file name; 94 B
  against 2,522,530 B), so a generation writes 970,253 B of state instead of
  5,045,092 B. Writers still accept a full version 2 `INDEX-STATE.json` and a
  `HYBSTA01` section, so directories written by 0.2.x and 0.3.0 open and
  update (the first update writes the new forms).
- **One changed file in the 10k index** (`applyChanges`, `ReleaseSmall`, five
  runs, p50): 123.2 ms without filename search (0.3.0: 147.7 ms) and 141.6 ms
  with it (0.3.0: 172.0 ms). The filename sections are byte-identical to
  0.3.0's; `open` (7.12–7.23 ms against 7.19–7.22 ms) and filename queries
  (p50 0.026 ms at 10k over RPC) are unchanged.
- **Rollback rule:** a 0.3.0 library still opens and queries a directory 0.3.1
  has updated, but refuses to update it (`SS_ERR_CORRUPT_SNAPSHOT`,
  `InvalidStateSection`); a library older than 0.3.0 refuses it at `open`, as
  before. Keep the previous directory (or rebuild one with the older library)
  to roll back to; never roll the library back over a directory 0.3.1 has
  updated and keep writing to it.

## 0.3.0 (S4-T2, PR #21; contract 2.2.0; minor: new public API)

PR #21 (the filename channel, recovery bound to the commit point, scoped
writers) integrated onto main after S4-T1. Everything below is additive: code
written for 0.2.1 compiles and behaves the same against 0.3.0.

- **Contracts 2.2.0** (`contracts/CONTRACTS_VERSION`). As before the package
  accepts exactly its own contract version, so a 2.1.0 library is refused at
  `open` with `ContractsVersionMismatchException`; the natives move with the
  package.
- **Filename search (CAP-16, `filename-field-v1`), opt-in.** New:
  `SearchField` (`content`, `filename`, `both`), `query(searchField:)`
  (filename and both need `mode: RetrievalMode.lexical`; anything else throws
  `ArgumentError`), `SearchResultItem.matchedIn`, `.basename` and
  `.matchSections` (`MatchSection*`: separate filename and content
  citations), `SnapshotStatus.filenamePolicyId` (nullable; set on enabled
  directories only), `ApplyChangesOptions.filenameIndex` and
  `IndexFolderOptions.filenameIndex` (nullable: omitted keeps a directory's
  setting), and `SnapshotInterchangeV2`. The channel is chosen when a
  directory is created: pass `filenameIndex: true` to the first
  `applyChanges` (or `indexFolder`) on a new, empty directory; an existing
  directory needs a fresh one rebuilt from every file's bytes, then a switch.
  A value that differs from the directory's setting raises
  `FilenameSettingMismatch`; a filename query on a directory without the
  channel raises `FilenameIndexUnavailable`.
- **Index format: manifest v2.2** (`docs/manifest-format-v2.md`). A
  filename-enabled generation sets manifest v2 flag bit 3 (same magic and
  version; PR #21's interim `HYBMAN03` is not written or read). Every
  generation `applyChanges` or `indexFolder` writes also binds its recovery
  state as its own section, `state-N.hybstate` (flag bit 4), which only the
  next writer reads; `open` never does. Indexes written by 0.2.0 and 0.2.1
  open and update. **Rollback rule:** a library older than 0.3.0 refuses
  every folder generation 0.3.0 writes (`UnsupportedFlags`, bit 4, with or
  without filename search), so do not roll the library back over a
  directory 0.3.0 has updated: keep the previous directory (or rebuild one
  with the older library) to roll back to.
- **Scoped writers** (RPC/MCP servers started with `--roots`/`--labels`)
  cannot declare roots, change label policy or read files; trusted Dart and C
  callers are unaffected.

## 0.2.1 (S4-T1; contract 2.1.0; additive)

- **`SnapshotStatus.source`** (nullable `String`): the source section's state
  from `ss_status`, `absent`, `unverified`, `verified` or `unavailable`.
  `SearchSimpli.open` no longer reads or checks the source section (nor builds
  the statistics and position tables); the first `readSpan`, `outline` or
  `listFiles` that needs it does, so a damaged source section surfaces there
  as `SS_ERR_CAPACITY` ("re-index required: source section unavailable …"),
  not at `open`. No ABI function changed.
- **Contracts 2.1.0** (`contracts/CONTRACTS_VERSION`): the status schema
  gains `source`. As before, the package accepts exactly its own contract
  version, so a 2.0.0 library is refused with
  `ContractsVersionMismatchException`; the shipped native libraries are
  rebuilt at 2.1.0.
- **Index format** (manifest v2.1, `docs/manifest-format-v2.md`): generations
  written by this release use XXH3-64 section checksums. Indexes written by
  0.2.0 still open and update (the first update writes v2.1); a 0.2.0 library
  refuses a v2.1 index (`UnsupportedFlags`).

## 0.2.0 (S3-T8; contract 2.0.0; breaking: an old library is refused)

The folder-knowledge release (CAP-19, series S3). The package version moves
from 0.1.0 to 0.2.0 because a native library older than this release is now
refused. The three shipped native libraries (macOS arm64, Android arm64, iOS
arm64 framework, 16 KiB aligned) are rebuilt from the same source
(`native/SOURCE-SHA256`), and the details below (added by S3-T4) are what
changed.

- **Six new ABI functions** (`zig/include/search_simpli.h`, contract 2.0.0):
  `ss_find`, `ss_outline`, `ss_read_span`, `ss_list_files`, `ss_roots` and
  `ss_apply_changes`. The ten functions of contract 1.x keep their signatures.
- **Contracts 2.0.0** (`contracts/CONTRACTS_VERSION`), a major: new methods and
  result fields, old requests keep working.
- **New Dart methods** on `SearchSimpli`: `find`, `outline`, `readSpan`,
  `listFiles`, `roots`, and the static `SearchSimpli.applyChanges`
  (alongside `open`, `status`, `query`, `evidence` and the static
  `indexFolder`).
- **New exception behaviour:** `ContractsVersionMismatchException` is thrown by
  `SearchSimpli.open` and `SearchSimpli.applyChanges` when the library reports
  another contract version or lacks one of the six functions.

## Contract 2.0.0 (S3-T4)

- **Requires a native library at contract 2.0.0.** `SearchSimpli.open` and
  `SearchSimpli.applyChanges` throw `ContractsVersionMismatchException` for
  an older library (it reports another version, or lacks `ss_find`,
  `ss_outline`, `ss_read_span`, `ss_list_files`, `ss_roots` or
  `ss_apply_changes`).
- New: `find`, `outline`, `readSpan`, `listFiles`, `roots` on `SearchSimpli`,
  and the static `SearchSimpli.applyChanges`, with typed results
  (`FindResult`, `FindHit`, `OutlineResult`, `SpanResult`, `FileListResult`,
  `ListedFile`, `RootsResult`, `RootInfo`, `ApplyChangesReport`,
  `ApplyChangesOptions`, `FindMode`, `FileStatus`, `ResultScope`,
  `ResultWarning`). Each result keeps the engine's JSON as `json`.
- `query` and `evidence` take `roots`; evidence items carry `rootId`,
  `sectionPath` and `neighbours` (`EvidenceNeighbours`, `ChunkRef`).
- `SnapshotStatus` gains `files`, `pending`, `truncated`, `roots`,
  `pendingPaths`, `hasSource`, `hasPositions`, `chunkers`; its counts are
  now over the default scope (every root, no labels), so a labelled file is
  not counted.
- `SearchSimpliException.code`: the `SS_ERR_*` name in the message.
- Bindings regenerated from `zig/include/search_simpli.h` (`ffigen`);
  native libraries rebuilt.

The consumer app regenerates its `search/contracts` Dart types at its pin
bump to this contract.

## Contract 1.2.0 and earlier

See `PROJECT-STATE.md` and the task files in `docs/tasks/` (S1-T2 onwards).
