# Atomic publication and recovery protocol

Status: implemented and filesystem-tested in `zig/src/publication.zig`, using a portable named-temp-file-plus-rename sequence (`publication.writeAtomicFile`) rather than Zig 0.16.0's `Dir.createFileAtomic` directly.

## Publication

For generation `G`:

1. Fully encode and validate document/vector, lexical, and manifest bytes in memory.
2. Write the generation-unique document file through a named temporary file in the same directory (`Dir.createFile` with `.exclusive = true`, i.e. `open(O_CREAT|O_EXCL)`).
3. Sync its file contents and atomically rename it into place without replacement (`Dir.renamePreserve`), failing with `PathAlreadyExists` if that name is already taken.
4. Repeat for the generation-unique lexical file.
5. **fsync the directory** (S2-T5), so both section renames are durable before `MANIFEST` can name them.
6. Write and sync the manifest through its own named temporary file.
7. Atomically rename it over the fixed `MANIFEST` filename (replacing).
8. **fsync the directory again**, so the `MANIFEST` rename is durable before the publish returns.

Every publish path (`searchd index`, `searchd index --update`, `searchd import-json`, `ss_index_folder`, `ss_import_json`, `init-demo`) goes through `publication.publish`, so the order above holds for all of them. `INDEX-STATE.json` is written with the same temp-file-plus-rename helper but is not a publish step: if its rename is lost in a power cut the next `--update` re-indexes instead of skipping, which is slower, not wrong.

### Directory sync: what the code does where

Zig 0.16's `std.Io.Dir` has no sync method, and `File.sync` documents that it does not make the containing directory's metadata durable. A `Dir.Handle` is the plain POSIX descriptor, so `publication.syncDirectory` calls `fsync(dir.handle)` itself (retrying `EINTR`) rather than going through `File.sync`, which treats `EINVAL` as a programmer bug and panics in Debug builds.

- **Linux and Android:** `fsync` on a directory descriptor is the documented way to make renames in it durable (ext4, f2fs, xfs). It is a full barrier there.
- **macOS:** the same `fsync` call is used, for consistency with the file syncs. `F_FULLFSYNC` (which also flushes the drive's write cache) is **not** used: macOS is a development host here, the file syncs use plain `fsync` too, and mixing a stronger directory sync with weaker file syncs would not make the sequence stronger.
- **A filesystem that cannot sync a directory** (some FUSE, network and overlay mounts) answers `EINVAL`, `ENOTSUP` or `EOPNOTSUPP`. Those three are ignored; any other error (`EIO`, `ENOSPC`, `EDQUOT`, anything unexpected) fails the publish, with cleanup that depends on *when* it happens:
  - **First directory sync fails** (before `MANIFEST` moves): `MANIFEST` is untouched and still names the previous generation; the two section files this call created are removed. Test `failed directory sync before MANIFEST leaves it untouched and cleans new sections`.
  - **Second directory sync fails** (after the `MANIFEST` rename): the error is returned to the caller, because the new generation is visible but not known to be durable, but **nothing is deleted**. `MANIFEST` names the new generation and both of its sections stay, so `loadCurrent`/`ss_open` work. (An earlier build deleted the sections here, leaving a `MANIFEST` that named missing files; the cleanup is now disarmed once `MANIFEST` is renamed in.) Test `failed directory sync after MANIFEST keeps the new generation complete`.
- **Windows and WASI:** the function does nothing. NTFS journals directory metadata and a directory cannot be flushed by handle the POSIX way; WASI has no directory durability to ask for. The ordering of the renames is unchanged.

The test `publish syncs the directory after the section renames and again after MANIFEST` runs the real publish with a `publication.Recorder` and asserts the exact sequence: file sync, rename documents, file sync, rename lexical, **directory sync**, file sync, rename `MANIFEST`, **directory sync**.

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

File contents are synced before atomic materialization and the directory is synced after the section renames and after the `MANIFEST` rename (S2-T5, above). The tests establish the call order and process-level atomic visibility; they are not a proof against every filesystem/power-loss combination (no power was cut). Windows has no directory sync.

### Recovering an update (`"recovered"`)

`--update` / `ss_index_folder` with `"update": true` never trusts `INDEX-STATE.json` without a previous engine to load. The report field `"recovered"` is absent on an ordinary run and otherwise one of:

- `"missing_section"`: `MANIFEST` exists but a section it names is missing or unreadable. Cost: every file is read and indexed again (a full index), and a full generation is published.
- `"missing_manifest"` (S2-T12): no `MANIFEST`, but `INDEX-STATE.json` exists (an outside deletion, or a filesystem that ignored directory sync). Cost: the same full re-index. Earlier builds published an empty generation here. With `keep_generations`, older generations are pruned only after the full generation has been published.

An update publishes zero documents only when the folder holds zero indexable files. Details: `docs/incremental-indexing.md`.

Garbage collection is opt-in and conservative (S2-T5): `keep_generations: N` deletes section files of generations older than the newest N after a successful publish; see `docs/generation-lifecycle.md`. By default nothing is deleted. Deleting all files not named by the current manifest would still race readers holding an older snapshot, which is why the policy is retention by generation number, not "everything unreferenced".

Writer serialization is now implemented through an advisory exclusive `WRITER.LOCK`; see `docs/generation-lifecycle.md`. Recovery scanning classifies unreferenced generation files but intentionally does not delete them. Reader leases/epochs, compare-and-publish generation checks for distributed failover, and safe garbage collection remain.
