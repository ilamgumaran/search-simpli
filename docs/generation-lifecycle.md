# Generation lifecycle

Status: writer serialization and conservative recovery scanning are implemented in `zig/src/lifecycle.zig`. Deletion remains intentionally unimplemented.

## Single-writer rule

Publishers acquire an advisory exclusive lock on the persistent `WRITER.LOCK` file. `publishSerialized` fails with `WriterBusy` when another writer holds the lease, then delegates to the validated immutable-section/manifest publication path.

The lock file itself persists; the operating system releases the lock if the process exits. The test suite opens a second handle while the first lease is held, verifies acquisition fails, releases the first lease, and verifies acquisition succeeds again.

Advisory locking protects cooperating writers. A process that ignores the protocol can still mutate the directory, so section/manifest checksums and immutable filenames remain necessary defenses.

## Recovery scan

The directory must be opened with iteration capability. The scanner:

1. attempts to load and fully validate `MANIFEST` plus both referenced sections;
2. records the selected generation and its two current files;
3. counts other `*.hybseg` files as unreferenced document generations;
4. counts other `*.hyblex` files as unreferenced lexical generations;
5. reports unrelated files separately;
6. ignores the control files `MANIFEST` and `WRITER.LOCK`.

If no manifest exists, every recognized generation file is classified as unreferenced. If a manifest exists but is invalid, scanning returns the validation error rather than guessing at recovery.

## Why scanning does not delete

“Not referenced by the current manifest” does not mean “safe to remove.” A reader may have loaded generation `G` immediately before generation `G+1` replaced `MANIFEST` and may still be reading `G`’s immutable files.

Production cleanup needs one of:

- reader leases with expiration and renewal;
- process-local reference counts plus a single service owner;
- epoch-based reclamation;
- conservative time/generation retention large enough for the maximum query lifetime;
- object-store lifecycle rules combined with snapshot retention guarantees.

Until one is chosen and tested, the scanner provides evidence for operators but performs no destructive action.

## Remaining recovery decisions

- whether an invalid current manifest causes fail-closed startup or rollback to the newest retained valid manifest;
- how generation numbers are allocated under writer failover;
- how long orphaned and superseded generations are retained;
- whether a manifest history or append-only commit log is maintained;
- platform-specific directory synchronization after atomic links/renames.
