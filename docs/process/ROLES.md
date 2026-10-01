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
