# Folder knowledge follow-up after S3-T1

Reviewed main at `73fc226339e21e81861edbf771512a1a9686684d` and the
filename-search branch at `daddbeeefb6a642ecd9dc386ba94fe511c24248c`.

S3-T1 landed during this review. Its implemented 104-byte manifest already
binds the source section length/checksum, superseding the original review's
missing-field finding. Preserve that work; no engine format is changed here.

## Changes

- Pack CLI honors explicit `--top-k`, keeps its existing default of 5 (the
  ordinary corpus workflow remains 10), validates positive values and rejects
  unsupported evaluation/index/model flags instead of silently ignoring them.
  Long-option abbreviations are disabled so the pack's allowed flags are
  unambiguous. Regression coverage exercises the real forwarding script,
  output JSON, gate failure/exit status and rejected options.
- Supplemental indexed-read tests pin BOM exclusion on line 1, CR-only line
  terminators and an unterminated final line. The frozen family-folder pack,
  its generator, 42 corpus files and eight span judgments remain unchanged.
  The leading BOM stays in the retained source hash but not returned lines,
  matching S3-T1's documented convention.
- Main's implemented HYBMAN02/version 2 owns the 104-byte source layout.
  CAP-16's unmerged 136-byte draft using the same identifier cannot merge as
  another v2 decoder. Integration must use a documented combined v3 and test
  v1/main-v2/v3 migration; rebuild old CAP-16 draft snapshots separately.
- S3-T3 must publish immutable state before MANIFEST, bind its filename,
  length and hash, and use that state after restart. Mutable INDEX-STATE is
  only a compatibility cache. Crash cases include pending/empty/moved/removed
  host files without replayable original payloads and failures after commit.
- Root provisioning, label policy and filesystem grants come from trusted
  host configuration. Add adversarial tests for forged roots, policy
  downgrades, cross-root operations and symlink replacement during reads.

## Evidence and limits

In an isolated workspace over the pinned main Python sources, ran:

| Check | Result |
|---|---|
| `test_source_boundaries.py` | 1 passed (three indexed byte-boundary cases) |
| `test_markdown_chunker.py` | 12 passed |
| `test_relevance_smoke.py` | 7 passed |
| `test_family_folder_fixture.py` | 15 passed |
| `test_requirements_validator.py` | 18 passed |

Requirements consistency, home-path check and the default family pack also
pass. With explicit top-1, the CLI now reports top-1 recall below 0.9 and
exits 1; unsupported flags exit 2 before indexing. Before the fix the same
CLI invocation silently ran top-5 and exited 0. The default pack now benefits
from S3-T1's outline/read-span execution; phrase/prefix/lifecycle skips remain
disclosed, not feature-acceptance evidence.

An initial local Markdown-suite run failed because the isolated source
snapshot lacked its fixture generator and had normalized an empty fixture
during copying. Restoring the pinned generator and exact generated fixture
bytes fixed the workspace; the rerun above passed without product changes.

No native runtime or Zig source changes, native artifact rebuilds, device
execution or merges are included. Format/state amendments are requirements
for subsequent implementation, not claims that v3 or atomic host state exists.
PR #18 remains a packaging/integration follow-up; PR #11's conflicting branch
needs its own rebase and verification, outside these S3 corrections.

## Integration update (2026-11-01)

While publication was in progress, main advanced to 292cb56826a4aa1bc824c79c50af600667cd72f3
through S3-T8. Merge that main without reverting any S3 work. S3-T3 already
implements state reconstruction; the current amendment therefore requires an
extended exact-state recovery oracle and names immutable manifest-bound state
as a fallback only if that oracle cannot pass. Existing task Reports/Verdicts
are preserved, and format coordination remains a future CAP-16 integration.

The execution environment became unavailable before an integrated rerun.
The 53 passing tests above were run over 73fc226, not this newer base. The CLI
fix is reapplied to the newer runner with its phrase/prefix/lifecycle logic
unchanged; hosted CI and a fresh native-equipped check must validate the merge.
