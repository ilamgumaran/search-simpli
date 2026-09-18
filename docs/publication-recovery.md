# Atomic publication and recovery protocol

Status: implemented and filesystem-tested in `zig/src/publication.zig`, using a portable named-temp-file-plus-rename sequence (`publication.writeAtomicFile`) rather than Zig 0.16.0's `Dir.createFileAtomic` directly.

## Publication

For generation `G`:

1. Fully encode and validate document/vector, lexical, and manifest bytes in memory.
2. Write the generation-unique document file through a named temporary file in the same directory (`Dir.createFile` with `.exclusive = true`, i.e. `open(O_CREAT|O_EXCL)`).
3. Sync its file contents and atomically rename it into place without replacement (`Dir.renamePreserve`), failing with `PathAlreadyExists` if that name is already taken.
4. Repeat for the generation-unique lexical file.
5. Write and sync the manifest through its own named temporary file.
6. Atomically rename it over the fixed `MANIFEST` filename (replacing).

Immutable generation files never overwrite an existing name. Reusing a filename fails with `PathAlreadyExists`, which protects already-published snapshots.

### No `O_TMPFILE` (S1-T3, docs/tasks/S1-T3.md criterion 6)

Zig's `Dir.createFileAtomic` opens an *unnamed* temporary file with `O_TMPFILE` on Linux whenever its `replace` option is `false` -- exactly the option every immutable-section write here uses. S1-T2's builder found this fails with `AccessDenied` on an Android emulator (API 34, Android 14): the app's SELinux policy denies `O_TMPFILE` inside the app's own private data directory, even though the identical code works on macOS, Linux desktop, and every other emulator version tested. `publication.writeAtomicFile` sidesteps the problem entirely by never calling `Dir.createFileAtomic`: it always creates a *named* temporary file (a random 16-hex-character name, `Dir.createFile` with `.exclusive = true`) and renames it into place (`Dir.rename` when replacing, `Dir.renamePreserve` when not) -- the same fallback sequence `Dir.createFileAtomic`/`File.Atomic.link` themselves only reach once a named temp file already exists. No code path here issues `O_TMPFILE`, on any platform, so behavior is identical everywhere the library runs, private Android app storage included. `incremental_state.zig`'s `INDEX-STATE.json` write (S1-T3) uses the same helper for the same reason, even though its own `replace: true` option was never affected (`Dir.createFileAtomic` only takes the `O_TMPFILE` path when `replace` is `false`) -- consistency, and one fewer thing to re-audit if that std library behavior ever changes.

This was built and its unit tests run on macOS (no Android emulator in this environment); `zig build lib` cross-compiles it clean for `aarch64-linux-android` (see `docs/tasks/S1-T3.md`'s Report), but on-device confirmation on the S1-T2 example app is left to the tester.

## Reader

1. Read `MANIFEST` once into caller-owned memory.
2. Validate its checksum, ids, counts, and safe filenames.
3. Read exactly the referenced immutable section files.
4. Validate section byte lengths, checksums, versions, and cross-section counts.
5. Decode aligned document vectors, terms, postings, and document lengths into caller-owned workspaces.
6. Query the loaded snapshot without consulting mutable source files.

Readers that already hold an older manifest and section handles can continue using that immutable generation while a new manifest is published.

## Crash visibility matrix

| Interruption point | Visible snapshot |
|---|---|
| before either generation file is linked | old `MANIFEST` |
| after only document file | old manifest; one orphan |
| after both immutable files | old manifest; two safe orphans |
| while replacing `MANIFEST` | old or new complete manifest, never partial |
| after manifest replacement | new complete generation |

The implementation uses error cleanup for newly linked files when later publication steps fail normally. Process/power interruption may leave unreferenced immutable files; readers ignore them because only `MANIFEST` grants visibility.

## Tested invariants

- generation 1 publishes, loads, decodes, scores, and returns the expected hybrid top result;
- generation 2 atomically replaces manifest selection;
- conflicting immutable filenames fail and leave generation 1 selected;
- a corrupted document section is rejected before `MANIFEST` exists;
- manifest and both sections are validated again on every load.

## Remaining durability and lifecycle work

File contents are synced before atomic materialization. Zig’s portable directory API does not currently expose directory `fsync`, so these tests establish process-level atomic visibility, not a proof against every filesystem/power-loss combination. A production Unix backend should sync the containing directory after linking section files and after manifest replacement; Windows needs equivalent platform-specific durability semantics.

Garbage collection is also intentionally absent. Safe cleanup needs a policy such as reader leases/epochs or conservative retention of recent generations. Deleting all files not named by the current manifest would race readers holding an older snapshot.

Writer serialization is now implemented through an advisory exclusive `WRITER.LOCK`; see `docs/generation-lifecycle.md`. Recovery scanning classifies unreferenced generation files but intentionally does not delete them. Reader leases/epochs, compare-and-publish generation checks for distributed failover, and safe garbage collection remain.
