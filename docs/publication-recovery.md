# Atomic publication and recovery protocol

Status: implemented and filesystem-tested in `zig/src/publication.zig` using Zig 0.16.0’s atomic-file API.

## Publication

For generation `G`:

1. Fully encode and validate document/vector, lexical, and manifest bytes in memory.
2. Write the generation-unique document file through an unnamed/named temporary file.
3. Sync its file contents and atomically link it without replacement.
4. Repeat for the generation-unique lexical file.
5. Write and sync the manifest through a temporary file.
6. Atomically replace the fixed `MANIFEST` filename.

Immutable generation files never overwrite an existing name. Reusing a filename fails with `PathAlreadyExists`, which protects already-published snapshots.

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
