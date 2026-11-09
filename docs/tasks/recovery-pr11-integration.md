# Recovery PR #11: integration handoff after iPhone support

Date: 2026-10-19 · Status: re-landed on current `main` by [S1-T23](S1-T23.md) (2026-11-09) without a native rebuild; verified and merged 2026-11-09, which closes PR #11 as merged

[PR #11](https://github.com/ilamgumaran/search-simpli/pull/11) at `bf71ab5` contains
the tested occupied-symlink generation fix. [PR #12](https://github.com/ilamgumaran/search-simpli/pull/12)
is merged as `89fadce` and contains the quality plan only. This handoff records a
read-only parent/Sol integration audit; it does not modify the recovery branch
or invalidate its historical test results against its own base.

Main now ships an iOS framework and uses S1-T21 for that verified iPhone task.
The recovery branch independently used S1-T21 for its fix. A merge-tree check
found three conflicts: `docs/tasks/S1-T21.md` (add/add),
`docs/journey/03-next.md`, and the packaged `native/SOURCE-SHA256`.
No additional concrete defect was found in the recovery runtime diff.

Before merge, the integration owner must:

1. Claim integration against current main, retaining main's iOS task/build/loader/tests.
2. Rename the recovery task to a distinct, centrally agreed ID/file; update its board, experiment and queue links. Do not overwrite the verified iPhone S1-T21 record.
3. Retain the recovery source fix and its Zig/ABI/CLI regressions, and reconcile the queue/status chronologically.
4. Rebuild macOS, Android and iOS libraries from the **integrated source** on a Mac with Xcode and the pinned NDK. Sync the Android example copy and regenerate the native source stamp using `tool/build_native.sh` in the Dart package.
5. Run `tool/check_native.sh`, native source freshness checks, and affected Zig/ABI/Python/Dart suites, preserving the established predecessor-failure and link/data-preservation evidence. State which device behaviors were actually exercised.
6. Push the integrated branch, obtain an independent review and green CI for its new head, then merge if no unresolved findings remain. Update the handoff with that actual outcome.

Neither the recovery branch's `0b00cc7f…` stamp nor main's `cd2c198e…` stamp is
the digest of the integrated source. Taking one side of that conflict or editing
the stamp alone cannot make a library current. The recovery branch rebuilt
macOS/Android only; main's iOS binary predates its source change.

This cloud host is Linux without `xcrun`. Main's build script requires the iOS
output before writing the final source stamp, and the native checker uses Mac
tools. The required integrated iOS rebuild/verification is therefore outstanding.
Do not merge PR #11 with a stale iOS binary or call it complete based on old CI.
Independent SQ-01 documentation work can be reviewed while this native task is
pending; runtime work requiring either task must respect its own gates.

## Closing (2026-11-09, S1-T23)

The six steps against what [S1-T23](S1-T23.md) did on `main` at `07e842a`:

1. **Claimed** as S1-T23 on current `main`; `main`'s iOS task, build, loader and tests are untouched (nothing under `bindings/` changes).
2. **Renamed.** The recovery work is S1-T23. The branch's `docs/tasks/S1-T21.md` text is kept unchanged in S1-T23's closing section; `main`'s iPhone S1-T21 is not overwritten. The board, experiment and queue entries point to S1-T23.
3. **Retained.** The source fix (the no-follow probe) has been on `main` since PR #21 (S4-T2/S4-T3). The regressions are re-landed and widened to the six names the allocator now probes; the queue gets a dated entry, and the earlier dated lines that say the pull request is open stay as records of their dates.
4. **Not needed.** No digest-covered file changes (`source_digest.py` prints `81f9c76b…` before and after), so the natives and the stamp stay as they are; the fix has been in them since S4-T3. Neither the branch's `0b00cc7f…` stamp nor its 19 Oct binaries are taken (the branch's ancestry is recorded by a `-s ours` merge).
5. **Checked** on the Xcode Mac: Zig in Debug and `ReleaseSmall`, the C ABI harness, the Python suite, native freshness, tracked home paths and whitespace; the predecessor (probe returned to following links) fails the new regressions. Counts are in S1-T23's Report. No device behaviour was exercised; no Dart file changed, so the Dart suite was not rerun.
6. **Pushed** as `task/S1-T23` for an independent verifier, who merges with `Fixes #10`; the outcome is recorded in S1-T23's Verdict.
