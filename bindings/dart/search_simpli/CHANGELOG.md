# 0.3.0

- Contracts 2.1.0: filename and combined lexical search integrated with S3 sources, positions and root scopes.
- Manifest v3 binds filename catalog and postings without changing v1/v2 readers.
- Exact committed mutation state and restricted write policies; confined file opens pin every directory component.

# Changelog

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
