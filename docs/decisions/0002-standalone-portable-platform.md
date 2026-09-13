# ADR 0002 · Search Simpli as a standalone, portable platform

**Status:** accepted (owner's decision, 2026-09-13) · **Supersedes:** nothing · **Relates to:** 0001 (engine boundary), simpli-helper ADR-005

## Context
The Zig engine (segments, manifest, publication, hybrid ranking, JSON-RPC
service) works, but only as a Mac-side daemon fed by the Python reference.
The family app (`simpli-helper`) uses Search Simpli's **contracts** and
**chunker** (`line-window-v1`) through a Dart port of the lexical ranking
and runs the Zig daemon only as a test oracle. Two rankers drift; the phone
never runs the real engine; no other program can use it without Python.

## Decision
Make Search Simpli a standalone product and a portable library, in this order:
1. **A C ABI over the engine** (`ss_*` functions, one header, no hidden
   allocator, no I/O of its own beyond the snapshot directory it is given),
   built as a static and a shared library for macOS arm64, Android arm64,
   Linux x86_64 now; iOS, Windows, Linux arm64 when the app needs them.
2. **Native indexing in Zig**: the `line-window-v1` chunker and a
   Unicode-aware analyzer (`analyzer-v2`; the current analyzer is ASCII-only)
   ported with golden conformance to the Python reference; Tamil is the
   first non-Latin test corpus.
3. **A standalone CLI** (`searchd index <folder>`, `query`, `evidence`,
   `serve`) as one static binary per platform, JSON in and out.
4. **Bindings**: a Dart FFI package under `bindings/dart/` (Android arm64,
   macOS arm64 prebuilt), Python via the existing gateway; the same
   conformance fixtures for every binding.
5. **Incremental folder indexing in the core** (content hashes,
   tombstones, rescan on demand), so an app can index a folder in place.
6. **Contracts as the only shared dependency**: `contracts/` gets a
   `CONTRACTS_VERSION`; every binding and the app pin it.

## Consequences
- The app replaces its Dart lexical engine with the FFI core (simpli-helper
  M12-T0), gaining hybrid ranking and one implementation everywhere. Its
  APK grows by the library size; the app's 60 MiB ceiling still applies.
- Search Simpli gains a user-facing surface (CLI, daemon) and can be used by
  project-ennam, the school-helper documents, and a home server.
- Zig cross-compilation: static libraries need no sysroot; the Android shared
  library links against the NDK's libc (the NDK already lives under the app's
  `tools/android/`).
- Process: tasks under `docs/tasks/` follow simpli-helper's builder/verifier
  loop (`docs/process/ROLES.md` here points to it).
