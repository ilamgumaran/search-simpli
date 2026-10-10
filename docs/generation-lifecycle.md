# Generation lifecycle

Status: writer serialization, conservative recovery scanning and opt-in retention pruning (`keep_generations`, S2-T5) are implemented in `zig/src/lifecycle.zig`. Nothing is deleted unless the caller asks.

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
6. (S2-T5) splits 3 and 4: a canonical `documents-N.hybseg` / `lexical-N.hyblex` whose `N` is **below** the current generation is retained history and is reported as `superseded_document_files` / `superseded_lexical_files`; only the rest (at or past the current generation, oddly named, or every section file when there is no valid `MANIFEST`) stays in `orphan_document_files` / `orphan_lexical_files`. A crash leftover older than the current generation therefore also shows as superseded, and `keep_generations` removes it with the rest. The total of unreferenced files is unchanged;
7. ignores the control files `MANIFEST`, `WRITER.LOCK`, and `INDEX-STATE.json`
   (S1-T4, `docs/tasks/S1-T4.md` criterion 3: the incremental indexer's own
   bookkeeping file is not an operator-facing anomaly, so it no longer counts
   toward "unrelated files").

If no manifest exists, every recognized generation file is classified as unreferenced. If a manifest exists but is invalid, scanning returns the validation error rather than guessing at recovery.

## Generation numbering (S2-T14)

A publish that picks its own number (`ss_index_folder`, `searchd index` without `--generation`) uses one rule, in `generation_alloc.zig`: **the highest generation the directory has any trace of, plus one.** The traces are the `MANIFEST`'s generation, every canonical `documents-N.hybseg` / `lexical-N.hyblex` present (complete or not), and the generation `INDEX-STATE.json` names; the first free pair above that is used, and a fresh directory starts at 1. A lost `MANIFEST` therefore never makes the counter start over: with only generation 2 on disk the recovery publishes generation 3, generation 2 shows as superseded (not orphaned) and `keep_generations` can prune it. At `u64` max there is no next number and the publish fails with `NoFreeGeneration` instead of overflowing. `ss_import_json` and `--generation` are numbered by the caller and are not changed by this rule.

## Retention pruning: `keep_generations` (S2-T5)

Opt-in. `"keep_generations": N` (N >= 1; `0` is an error, `InvalidKeepGenerations` / `SS_ERR_INVALID_ARGUMENT`) on `ss_index_folder`, as an optional top-level field of the `ss_import_json` payload (that function has no options argument), and `--keep-generations N` on `searchd index` and `searchd import-json`. Absent: nothing is deleted, as before.

After a **successful** publish, still holding `WRITER.LOCK`, `lifecycle.pruneSuperseded` deletes the files of generations older than the newest N:

- the kept set is the current generation plus the N-1 newest older **complete** generations (both `documents-N.hybseg` and `lexical-N.hyblex` present). An incomplete older leftover (a lone section file from a crash between the two links) is never counted toward N and is always deleted, so `keep_generations: 2` after a crash leaves the current generation plus the newest complete older one;
- only canonical `documents-<N>.hybseg` / `lexical-<N>.hyblex` names (plain decimal, no leading zeros) with `N` strictly below the current generation are ever candidates. `MANIFEST`, `WRITER.LOCK`, `INDEX-STATE.json`, temp files, oddly named files and any section file at or past the current generation (a crash leftover) are never touched;
- the current generation's two files, by the names in its manifest, are never touched;
- a failed unlink does not fail the publish: it is counted in `prune_failures` (reports carry `pruned_files` and `prune_failures` only when the option is set), the file stays, and the next pruned publish retries it;
- the directory is fsynced once more after the unlinks (best effort).

`keep_generations: 1` keeps only the current generation. `2` keeps one previous generation as a fallback for a reader that is mid-open.

### A reader holding an older generation

- **Another process, already open:** on macOS, Linux and Android, unlinking a file that is open removes the name only; the reader's descriptor, and any memory it already read, stay valid until it closes. The engine reads sections fully into memory at `ss_open`, so an opened handle is unaffected whatever pruning does afterward.
- **Another process, mid-open:** a reader that read an old `MANIFEST` and has not yet read the sections can find them gone and fail with `FileNotFound`; retry reads the new `MANIFEST`. `keep_generations >= 2` keeps the newest complete older generation, so only a reader that is a whole publish behind can lose the race.
- **Windows:** deleting an open file fails; that shows up as `prune_failures`, not as a failed publish.
- **In-process (the phone app):** the app knows when no `ss_handle` uses an old generation, and a handle holds decoded memory, not open files, so pruning never invalidates a live handle. The app can pass `keep_generations` on every import and reopen on the new generation afterwards.

The 20-generation, `keep_generations: 2` result is in the `S2-T5` Report.

## Why scanning does not delete

“Not referenced by the current manifest” does not mean “safe to remove.” A reader may have loaded generation `G` immediately before generation `G+1` replaced `MANIFEST` and may still be reading `G`’s immutable files.

Production cleanup needs one of:

- reader leases with expiration and renewal;
- process-local reference counts plus a single service owner;
- epoch-based reclamation;
- conservative time/generation retention large enough for the maximum query lifetime;
- object-store lifecycle rules combined with snapshot retention guarantees.

The scanner itself still performs no destructive action. The one deletion policy that exists is the explicit, opt-in retention above, which is generation-number based and never deletes by "unreferenced".

## Remaining recovery decisions

- whether an invalid current manifest causes fail-closed startup or rollback to the newest retained valid manifest;
- how generation numbers are allocated under writer failover;
- how long orphaned and superseded generations are retained;
- whether a manifest history or append-only commit log is maintained;
- Windows directory durability (POSIX directory fsync is done, see `docs/publication-recovery.md`).
