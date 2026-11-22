# ADR 0003 · A full rebuild chooses its generation number under the writer lock

**Status:** design note of [S6-T20](../tasks/S6-T20.md), Part 1, written from `main` at `3cf188b` before any code
(21 Nov 2026). The maintainer chose the direction on 21 Nov 2026 ("choose the number under the writer lock");
this note checks it against the code. Line numbers are `main`'s at `3cf188b`. Everything here is read from the
code unless it says "measured".

## 1. Every path that publishes a generation

"Lease" is `WRITER.LOCK` taken by `lifecycle.tryAcquireWriter` (`core/lifecycle.zig` 337–345: `createFile`, then
`tryLock(.exclusive)`; `null` means another holder, which every caller turns into `WriterBusy`).

| Path | Number chosen | Lease taken | Stale between? |
| --- | --- | --- | --- |
| `ss_index_folder` without `update` (`interfaces/abi.zig` 845–846) | `abi.zig` 845, `generation_alloc.nextFreeGeneration`, **before** `indexer.indexFolder` | `core/apply.zig` 764, inside `applyParsed`, after the folder walk (`indexer.zig` 190 `walkBatch`, then 191 `applyBatch`) | **yes**: the window is `abi.zig` 845 to `apply.zig` 764 (S6-T17's Verdict, probes B and C) |
| `searchd index` without `--update` or `--generation` (`interfaces/cli.zig` 844–845) | `cli.zig` 844, the same call | `apply.zig` 764, the same | **yes**, the same window |
| `searchd index --generation N` (`cli.zig` 844, `options.generation`) | by the caller | `apply.zig` 764 | the caller's number is used as given at `apply.zig` 1224; see 4 |
| `--update`: `ss_index_folder` with `update` (`abi.zig` 799), `searchd index --update` (`cli.zig` 785) | `apply.zig` 1224 (`options.generation` is null: `indexFolderIncremental` passes `null`, `indexer.zig` 401) | `apply.zig` 764 | no: chosen and published under one lease |
| `apply_changes`: `ss_apply_changes` (`abi.zig` 525), `searchd apply` (`cli.zig` 1363), `serve --allow-write` (`rpc.zig` 299), `mcp --allow-write` (`mcp.zig` 426), all through `ops.applyChanges` (`ops/ops.zig` 1174) to `apply.applyChanges` (711) | `apply.zig` 1224 | `apply.zig` 764 | no |
| `ss_import_json` (`abi.zig` 547), `searchd import-json` (`main.zig` 128) through `importer.importJsonKeeping` | by the caller: `payload.generation` (`importer.zig` 101 refuses 0; used at 189) | at the publish: `lifecycle.publishSerializedKeepingWithSource` 305 or `publishSerializedWithFilenameKeeping` 581 (`importer.zig` 185–186) | the caller's number; see 4 |
| `searchd init-demo` (`main.zig` 153–180) | the constant 1 (`main.zig` 164–165) | `lifecycle.publishSerialized` 354 | the constant; see 4 |
| `searchd search` (`indexer.buildFolderDetached`, `apply.buildDetached` 744) | 1, in memory | none | publishes nothing |

No other non-test code publishes: `publication.publish*` is called only from `lifecycle.zig` (331, 356) and from
tests, and `tryAcquireWriter` only from `apply.zig` 764 and `lifecycle.zig` 305, 354, 581 (`grep` over `zig/src`
without tests).

So the gap is the two self-numbered full rebuilds, and only them. `apply.zig` already does what the maintainer
chose: 764 takes the lease, 765 releases it on return, 767 reads `MANIFEST`, 1224 chooses the number
(`options.generation orelse nextFreeGeneration`), 1233 publishes, 1239 writes `INDEX-STATE.json`, all inside it.

## 2. The proposed shape: confirmed, and smaller than it sounds

The orchestrator's reading is right in effect: the full rebuild should choose its number inside the lease it
publishes under, and the interfaces should pass "no number". The code needs no new lease and no change to `apply`:

- `indexer.indexFolder` already hands its number to `applyBatch` as `apply.Options.generation`, a `?u64`
  (`indexer.zig` 175, 217–234; `apply.zig` 124). Only its own parameter is a plain `u64` (`indexer.zig` 170).
- With `generation = null`, `applyParsed` chooses at 1224, after the lease at 764 and before the publish at 1233,
  one lease taken once: exactly the path `--update` and `apply_changes` take today.

The change is therefore: `indexFolder`'s `generation` becomes `?u64` (null: "the next free number, chosen under the
lease"); `abi.zig` 845 and `cli.zig` 844 stop calling `nextFreeGeneration` and pass `null` (the CLI passes
`options.generation`, which is null unless `--generation` is given). `apply.zig`, the lock and pruning are untouched
(ruling 6). `nextFreeGeneration` is then used by no file in `ops/` or `interfaces/`, so it leaves `core.api`;
`describeNoFreeGeneration` stays (`abi.zig` 495 and 759, `main.zig` 54).

What still runs before the lease, on `main` and after the change alike: the folder walk that lists candidate paths
(`indexer.zig` 190, `walkBatch` → `collectCandidatePaths`). It reads the user's folder, not the index directory.
A writer that publishes during the walk is seen by the number chosen afterwards, under the lease.

A side effect: `nextFreeGeneration`'s reads of `MANIFEST` and `INDEX-STATE.json` (`currentGeneration`,
`recordedGeneration`) now run under the lease for a full rebuild too, so S6-T17's item 3 (one read of the
`INDEX-STATE.json` trace lost to a concurrent publish) cannot happen between cooperating writers.

**Why this meets ruling 1 for self-numbered writers (argued; the tests in Part 2 show the interleavings).** After
the change every self-numbered publish (full rebuild, `--update`, `apply_changes`) chooses under the lease a number
above `MANIFEST`'s generation (`highestGenerationOnDisk` starts from it, `generation_alloc.zig` 124) and publishes it
under the same lease, so no cooperating writer can move `MANIFEST` in between. By induction `MANIFEST` strictly
increases over those publishes, and each new number is above every number published before it.

## 3. What changes for a caller

- **The refusals are the same set.** No new error, code or field. `WriterBusy` is already documented on every
  interface: `ss_index_folder` and `ss_apply_changes` (`ss_last_error`), `searchd index` and `searchd apply`, and
  `serve`/`mcp` `apply_changes` (`-32006`, `rpc.zig` 302, `mcp.zig` 428); `docs/generation-lifecycle.md`,
  "Single-writer rule".
- **A correction to the task's wording.** A second writer that *starts* while a full rebuild is building already gets
  `WriterBusy` on `main`: the rebuild holds the lease from `apply.zig` 764 through the build. What was wrong on `main`
  is the *rebuild's* outcome when the second writer published inside the window before 764: the rebuild then failed
  with `PathAlreadyExists` (probe B) or published a used number again and moved `MANIFEST` back (probe C). After the
  change: a second writer that tries to publish after the rebuild has chosen its number gets `WriterBusy` (the
  rebuild holds the lease); one that publishes earlier (during the walk) succeeds, and the rebuild then chooses a
  number above it.
- **Which error comes first, when several apply.** `nextFreeGeneration`'s own errors (`NoFreeGeneration`, and the
  directory-listing errors) used to come before the walk, `WriterBusy` and the build's errors; now they come after
  them. For example, a directory whose numbers are exhausted while another writer holds the lock answered
  `NoFreeGeneration` and now answers `WriterBusy`. A damaged `MANIFEST` gives the same error as before, through
  `apply.zig` 767 instead of `nextFreeGeneration` (both call `currentGeneration`). The `NoFreeGeneration` line is
  unchanged: `describeNoFreeGeneration` reads the thread-local causes set by the same call, still on the caller's
  thread.
- **Cost.** `NoFreeGeneration` is now found after the folder's files are read, not before. The lease is held for the
  extra length of `nextFreeGeneration` (one `MANIFEST` read, one `INDEX-STATE.json` read, one directory listing,
  six `stat`s per candidate); it was already held through the build.
- **What `generation-lifecycle.md` must say.** The numbering rule's race sentence ("A full rebuild that picks its own
  number can too, through a race ...") is replaced: every self-numbered publish chooses its number under
  `WRITER.LOCK`; probes B and C end in `WriterBusy` for the other writer. The caller-numbered sentence stays.

## 4. A caller-supplied number

`searchd index --generation N`, `ss_import_json`'s `generation`, `searchd import-json`, and `init-demo`'s constant 1.

- **It is already checked under the lease, and this does not change.** The publish runs under the lease
  (`apply.zig` 1233 inside 764; `lifecycle.zig` 305, 354, 581) and links each section with `renamePreserve`
  (`publication.zig` 135–154, 326), which fails with **`PathAlreadyExists`** when the name exists. The sections it
  had linked are deleted again (the `errdefer`s at 136–157, before the `MANIFEST` rename at 160), and
  `INDEX-STATE.json` is written only after a successful publish (`apply.zig` 1239). So a taken number publishes
  nothing and leaves the directory as it was, on `main` already. `PathAlreadyExists` is the existing error that
  fits, and it stays the refusal.
- **What "not free" means there.** The publish checks the names it writes: documents, lexical, and source, file-name
  and state sections when it writes them. `nextFreeGeneration`'s "free" is all six names. A leftover
  `filenames-N.hybseg` does not block `--generation N` for a folder without the file-name channel. Making the two
  agree would mean a check inside `applyParsed`, which ruling 6 keeps out ("changing what `apply` does").
- **A free number at or below the current generation is published as given**, so `MANIFEST` goes back, with or
  without a second writer (documented in `generation-lifecycle.md` since S2-T14). Ruling 1 as worded covers any
  two writers that honour the lock, and a writer with `--generation N` honours it, so ruling 1 cannot hold for
  caller-numbered publishes without refusing such a number. That would be a new refusal of a documented behaviour,
  on the C ABI too (`ss_import_json`), with no existing error that fits (`PathAlreadyExists` would name no path;
  `NoFreeGeneration` means something else), and the maintainer did not choose "refusing a stale number at publish
  time". **Not done; for the maintainer.** This note scopes ruling 1 to self-numbered publishes, which is what the
  task's Why is about.

**Is this a reason to stop?** No, by the task's conditions. The shape is right, needs no contract, header or format
change and no new refusal; the caller-numbered limit is pre-existing, outside the shape, and is stated here and in
the Report as a decision for the maintainer.

## 5. Readers

Readers never take `WRITER.LOCK`. The opens (`snapshot_open.open` 37, `openSource` 297, `openScoped` 340,
`openScopedWith` 348) read `MANIFEST` through `readManifest` (214–227: `openFile(MANIFEST)`, `stat`, read) and the
sections it names; none opens `WRITER.LOCK` or calls `tryAcquireWriter`, whose only callers are `apply.zig` 764
and `lifecycle.zig` 305, 354, 581 (above). `serve` and `mcp` open through `openScopedWith` (`rpc.zig` 65). The lock is
an advisory `flock` on a file only writers open, so holding it longer blocks no reader; and it is held through the
build on `main` already.

## 6. What this cannot close (known limits)

- **Caller-numbered publishes** (4): a free number at or below the current one goes back.
- **A writer that does not honour the lock:** a copy or edit by hand, another program, or an older build of this
  library or `searchd` (an older full rebuild still chooses before the lock, so a mixed pair of versions keeps the
  window on the old side).
- **A file system without working `flock`** (some network or FUSE mounts), and **two machines sharing a synced
  folder**: a lock on one machine is not seen on the other.
- **Windows:** no CI job builds or runs there; the lock's behaviour is not tested there.
- **A lost or hand-restored `MANIFEST`:** numbering then goes by the traces left (S2-T14); a number whose every trace
  was pruned can be chosen again. That is not an interleaving of two writers.
- **Two processes:** the tests run both writers in one process (two open file descriptions of `WRITER.LOCK`, which
  exclude each other, as `lifecycle.zig`'s "writer lease serializes publication attempts" shows), not two
  processes.

## 7. Timing (ruling 4)

The rule of 2026-11-17 (`docs/process/ROLES.md`) compares the head with the controls "for every request, changed path
or not", and makes no exception for a change that is on the writer's path only. The source of no open, search or
find path changes here, but the natives' compiled code moves with any rebuild (S6-T17's Verdict, finding 5). Read as
written, the rule therefore applies: five gated runs in Latin-square orders written before the first run, `main`,
`main2` and a placement control matching the head's compiled-code delta, every open, query and find cell of the
three 10k corpora (S6-T14's harness), judged by the rule.
