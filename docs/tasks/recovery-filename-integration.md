# Recovery hardening and CAP-16/S3 integration

State: implemented and verified; owner-authorized 2026-11-01; PR #21.
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

Final Linux source verification at `5822041`: Zig 263/263; C ABI 22/22;
Python 238 tests with four platform skips and only the expected stale-native
failure before package adoption. Requirements, home-path and whitespace checks
pass. Family-folder gates pass: words recall@5 1.000, outline 7/7,
read-span 9/9, lifecycle 3/3, phrase-neighbour 1/1, phrase/prefix precision
and recall 1.00 across their full paged sets. The dependency-free relevance
mechanics invariant also passes all four metrics at 1.0. These are authored
fixture checks, not evidence of real-folder relevance.

The macOS run at `5822041` built and checked all three native targets and
passed Dart analysis, then exposed missing Zig on PATH in subprocess-based
Dart conformance suites (73 tests passed; four setup/teardown failures).
The workflow now exposes the pinned Zig executable to subprocesses. The
missing-symbol compatibility assertion now derives its version from the pin;
the host-fed Dart regression also covers filename enablement, retained S3
source/phrase operations, pending files and recovery after cache removal.

### Authentic native build

[macOS workflow run 41309041051](https://github.com/ilamgumaran/search-simpli/actions/runs/41309041051)
at source `bf2c9b79032cf70475c7663fd9db95ac21ea15d9` passed all build,
platform and Dart steps: 20/20 build steps, clean Dart analysis, 82/82 Dart
tests (including CLI/RPC parity, ABI goldens and host-fed recovery). Pinned
Zig 0.16.0 and Android NDK 28.2.13676358 built macOS arm64 (773240 bytes),
Android arm64 (746568 bytes), and the iOS arm64 framework (1016352-byte
binary). Platform checks verify the iOS 17 deployment target, framework
metadata/install name and all four segments' 16 KiB alignment.

Adopted artifact `13084576932`, SHA-256
`8dc7dcf004dd90cad20f463833138c55cbee1cb73c80326fd3d7dc00c8455ddd`.
Verified the archive checksum, its exact source commit, expected paths and
file types before copying native packages plus the identical example JNI
library. The build-generated source stamp is
`4293d53ef3f1dcaa86dc6173f20481b7f6f5ee3388668709a6d727ebe0bf4b95`,
which matches the local source digest. No source stamp was fabricated.

After package adoption, the complete Python suite passes: 238 tests in
54.485 seconds, four platform-dependent skips, no failures. This includes
the three native-freshness tests and MCP/RPC canonical parity across 66
requests. Requirements, home-path and diff whitespace checks pass again.

## Limits

The public fixture is authored evidence, not real-folder relevance. No
physical phone execution is claimed. Independent maintainer review and
consumer pin/device validation remain separate from this source integration.
