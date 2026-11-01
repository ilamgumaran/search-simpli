# Recovery hardening and CAP-16/S3 integration

State: implementation in verification; owner-authorized 2026-11-01.
Claim: [issue #20](https://github.com/ilamgumaran/search-simpli/issues/20).
Branch: `improve/recovery-and-filename`, based on main `e9d97b0` and CAP-16
source at `daddbee`. Supersedes the pre-S3 integration base of draft PR #18.

## Acceptance

- Preserve S3 phrase/prefix/words, headings, exact source reads, roots, labels,
  pending files, MCP and existing default content results.
- Bind filename sections under HYBMAN03/version 3; keep v1/v2 readers and
  reject the old incompatible filename draft-v2. Require a separate directory
  for changing filename enablement or analyzer identity; updates retain it.
- Validate filename sizes, checksums, counts, safe filenames and anchors;
  publish source/body/filename sections before the manifest commit point.
  Allocate around orphan filename names and prune them with their generation.
- Committed recovery state preserves own/inherited labels, hashes, sizes,
  mtimes, chunker and moves without mutable cache or original host bytes.
- Restricted writers cannot provision roots, change policy, touch hidden
  files/move targets or remove roots containing hidden files. File opens pin
  each directory with no-follow and read/hash the same bounded bytes.
- Real CLI/RPC/ABI tests, S3 and filename fixtures, schema checks, native and
  Dart tests pass. Rebuild authentic native packages/stamp, never edit a stamp
  to match unbuilt source. Publish a reviewable PR, not an automatic merge.

## Implementation

Contract 2.1.0 / Dart 0.3.0 integrates the prior filename field and match
sections into current S3 surfaces. Optional filename queries require explicit
lexical mode. Default content behavior and contract 2.0.0 function signatures
remain; strict-version consumers must repin to 2.1.0.

Main's HYBMAN02 remains 104 bytes; new HYBMAN03 is 152 bytes with the two
filename section descriptors and nine payload strings. See
[format v3](../manifest-format-v3.md). Source, positions, roots and section
paths remain intact. CAP-16's unmerged draft-v2 snapshots need a fresh output
directory; no length-based format guessing is added.

`meta.recovery_state` contains the exact state JSON bound by the manifest's
checksum and atomic replacement. It is authoritative for new generations;
INDEX-STATE is a compatibility cache. Old generations still reconstruct if
needed, conservatively keeping effective labels as own labels when their
provenance is unknowable (fail closed, possibly more restrictive). No state
is inferred from omitted retained bytes on a newly written generation.

Trusted C/CLI callers remain index administrators. RPC/MCP servers configured
with roots or labels restrict writes to that configured scope, refuse root
policy declarations and filesystem reads, and accept bytes only. Unscoped
`--allow-write` deliberately grants index administration; `--allow-file-reads`
additionally authorizes the host's declared canonical local paths. It is not
an authenticated remote access system. Restricted callers cannot mint those
grants in a model request.

## Verification report

Initial integration: 262/262 Zig tests and 22/22 C ABI checks passed before
the final schema/lifecycle amendments; Python filename semantics 16/16,
folder semantics 8/8, directory race tests 2/2, and combined v3/S3 integration
3/3 passed. Requirements/path checks pass. Final integrated suites and native
packaging outcomes are appended after verification.

A broad intermediate Python run executed 233 tests with two failures: the
pre-S3 filename test expected an obsolete RPC unavailable code (updated to
S3's capacity code), and packaged-native freshness (genuine rebuild required).
Neither failure was hidden by weakening freshness or writing a source stamp.
The local environment cannot execute Xcode; a read-only macOS CI packaging
job builds all native targets and runs Dart against its outputs. Final output
artifacts must cite the exact source commit and be verified before adoption.

## Limits

The public fixture is authored evidence, not real-folder relevance. No
physical phone execution is claimed. Independent maintainer review and
consumer pin/device validation remain separate from this source integration.
