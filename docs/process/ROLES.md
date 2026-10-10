# Process for Search Simpli tasks (from 2026-09-13)

Same loop as `simpli-helper/docs/process/ROLES.md` (read it): the orchestrator
writes a task file with acceptance criteria; a Sonnet 5 builder implements it in
its own git worktree (`task/<id>`), fills the Report from real output, runs the
check after writing the Report; an Opus 5 tester verifies every criterion from
its own output, writes the Verdict, merges to `main` with `--no-ff`.
Check command here: `python3 -m unittest discover -s tests` plus `zig build test`
in `zig/` with the pinned toolchain (`~/development/zig/zig-0.16.0-macos-aarch64/zig` (Zig 0.16.0)).
Measured numbers only; no `Claude-Session:` trailers (public repo); no home
paths or device identifiers in tracked files.

## Rule added 2026-09-30 (S1-T6)
Run this repository's suites with `SEARCH_SIMPLI_LIBRARY_PATH` **unset**. `simpli-helper/tools/env.sh` exports it (pointing at the app's pinned copy in the pub cache), and it outranks the package's own `native/` libraries, so a shell that sourced that file tests an older library and reports failures that are not in this repository. Source it for the Dart/Flutter PATH if needed, then `unset SEARCH_SIMPLI_LIBRARY_PATH`.

## Rules added 2026-10-08 (series S2)
- **No single wall-clock threshold as a test.** A regression test for speed asserts a growth ratio across sizes (interleaved runs, best of N each), never an absolute time, and the builder shows it passing under CPU load (busy loops on every core, a concurrent build) and failing with the old code restored. S2-T2's first test failed on correct code the moment another session built on the same Mac. (Copied from `simpli-helper/docs/process/ROLES.md`, where it was learned first.)
- **The orchestrator rules on a builder's deviations before verification**, in a `## Rulings on the Report` section of the task file, so the tester judges against the rulings and not the criteria alone, and a rejection never turns on a reading the builder could not have known.
- **A tester may correct a document inside the merge** (a wrong sentence, a missing condition) when no code changes; it says so in the Verdict. It never changes code or tests: that is a rejection.
- **Every verifier reproduces the defect in a real process when the claim is about the operating system** (a failing `fsync`, a `SIGKILL`, a hang), not only in the shim the builder wrote: S2-T5 was rejected on a bug the shim test could not see.
- **Testers add the dated `PROJECT-STATE.md` entry at the merge; nobody edits `IMPROVEMENT-BOARD.md` for another orchestrator.** Docs-only pushes to `main` do not force a tester to re-run suites; anything under `zig/`, `contracts/`, `bindings/`, `scripts/` or `tests/` does.
- Prebuilt libraries and `native/SOURCE-SHA256` are never resolved by picking a side in a merge: rebuild from the merged source with `tool/build_native.sh`, last.

- **Plants in a scratch copy need fresh Zig caches.** `zig test` in a scratch copy can return a binary built from another copy's sources through the global cache (S1-T16 tester, 10 Oct: it got the builder's leftover plant). Pass `--global-cache-dir` and `--cache-dir` pointing at empty folders for every plant run outside a worktree.
