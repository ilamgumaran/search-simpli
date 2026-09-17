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
