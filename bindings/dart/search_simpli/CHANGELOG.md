# Changelog

## Contract 2.0.0 (S3-T4; package version unchanged)

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
