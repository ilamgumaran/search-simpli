# search_simpli (Dart)

Dart FFI bindings for [Search Simpli](../../../README.md)'s C ABI
(`zig/include/search_simpli.h`, [ADR 0002](../../../docs/decisions/0002-standalone-portable-platform.md)):
open a published snapshot directory, run a hybrid/lexical/vector query, read
cited evidence by chunk id, and check status — all in-process, with no
daemon and no network call. This package is not published to pub.dev; use
it as a path dependency.

## What's in here

```
bindings/dart/search_simpli/
  lib/
    search_simpli.dart          # public API (import this)
    src/
      bindings_generated.dart   # ffigen output over search_simpli.h — do not edit by hand
      search_simpli_base.dart   # SearchSimpli: the class you actually use
      contracts.dart            # typed result classes (SearchKnowledgeResult, SnapshotStatus, ...)
      contracts_version.dart    # the CONTRACTS_VERSION this package expects
      library_loader.dart       # finds/opens the right native library for the platform
  native/
    macos-arm64/libsearch_simpli.dylib
    android-arm64/libsearch_simpli.so
  tool/build_native.sh          # rebuilds native/ from the pinned Zig toolchain
  ffigen.yaml                   # regenerate bindings_generated.dart from the header
  test/                         # dart test — conformance + unit tests
  example/                      # a minimal Flutter app (Android smoke test)
```

## Install

Not on pub.dev. Add it as a path dependency from another package in this
checkout, or vendor the whole `bindings/dart/search_simpli/` directory:

```yaml
dependencies:
  search_simpli:
    path: ../../search-simpli/bindings/dart/search_simpli
```

## Quick start

```dart
import 'package:search_simpli/search_simpli.dart';

void main() {
  final engine = SearchSimpli.open('/path/to/a/published/snapshot');
  try {
    final result = engine.query(
      'how does hybrid ranking work',
      topK: 3,
      mode: RetrievalMode.lexical, // or .hybrid / .vector, with queryVector
    );
    for (final hit in result.results) {
      print('${hit.citation.path}:${hit.citation.startLine} ${hit.content}');
    }

    final evidence = engine.evidence([result.results.first.chunkId]);
    print(evidence.first);

    print(engine.status());
  } finally {
    engine.close();
  }
}
```

A "published snapshot directory" is whatever `searchd index <folder> --out
<dir>`, `searchd import-json`, or this package's own `importSnapshotJson`
wrote — see the [root README](../../../README.md) and
[docs/zig-engine-api.md](../../../docs/zig-engine-api.md).

## `SearchSimpli` API

- `SearchSimpli.open(String snapshotDir, {DynamicLibrary? library})` — opens
  a snapshot. Asserts the native library's `ss_version()` equals this
  package's `CONTRACTS_VERSION` (`1.0.0`) before touching `snapshotDir` at
  all; throws `ContractsVersionMismatchException` on a mismatch and
  `SearchSimpliException` if `ss_open` itself fails (missing/corrupt
  snapshot, I/O error — see the thrown exception's `message`, which is
  `ss_last_error()`).
- `engine.status()` → `SnapshotStatus` (generation, analyzer, document/term/
  posting counts, vector dimensions).
- `engine.query(String queryText, {queryVector, topK, mode, candidateK,
  pathPrefix, principalLabels})` → `SearchKnowledgeResult` — exactly the
  `search_knowledge` JSON-RPC result shape (`tool`, `query`, `index`,
  `retrieval`, `results`, `answerPolicy`), because `ss_query` shares its
  JSON-writing code with the JSON-RPC service (see
  `zig/include/search_simpli.h`'s "JSON shapes" section) — a client already
  written against `search-tool.schema.json` needs no new parsing logic.
- `engine.evidence(List<String> ids, {pathPrefix, principalLabels})` →
  `List<EvidenceChunk>`, one entry per id, in order; an unknown or
  unauthorized id comes back as `EvidenceChunk(found: false)` rather than
  failing the whole call.
- `engine.close()` — frees the native handle. Safe to call once; a second
  call throws `StateError`. Not safe to race with any other call on the
  same `SearchSimpli` instance (matches `ss_close`'s contract).
- `importSnapshotJson(String dirPath, String bytesJson, {DynamicLibrary?
  library})` — a free function (it takes a directory, not an open handle),
  publishes neutral interchange JSON as a new generation, exactly what
  `searchd import-json` / `ss_import_json` do. Returns the published
  generation number.

Every `ss_*` failure surfaces as `SearchSimpliException` with the
human-readable `ss_last_error()` message.

## Native library packaging

This package ships prebuilt libraries for exactly two targets (ADR 0002):
**macOS arm64** (`native/macos-arm64/libsearch_simpli.dylib`) and **Android
arm64** (`native/android-arm64/libsearch_simpli.so`). `lib/src/
library_loader.dart` resolves which one to load:

1. `SEARCH_SIMPLI_LIBRARY_PATH` environment variable, if set — an absolute
   path to a `.dylib`/`.so`, on any platform. Always wins.
2. **Android:** `DynamicLibrary.open('libsearch_simpli.so')` — the app
   embedding this package must package `native/android-arm64/
   libsearch_simpli.so` as a jniLib for `arm64-v8a` (see
   `example/android/app/src/main/jniLibs/arm64-v8a/` and the `ndk {
   abiFilters += listOf("arm64-v8a") }` block in `example/android/app/
   build.gradle.kts` for a worked Flutter example). Once packaged, Android's
   own dynamic linker finds it by name.
3. **macOS:** resolves `native/macos-arm64/libsearch_simpli.dylib` relative
   to this package's own directory — works when `dart test`/`dart run` is
   invoked from inside `bindings/dart/search_simpli/` (this package's
   documented dev workflow).

Every other platform throws `UnsupportedError` from `SearchSimpli.open`
(pass your own library via `SEARCH_SIMPLI_LIBRARY_PATH` or the `library`
parameter if you've built one yourself for another target, e.g. following
ADR 0002's Linux x86_64 target).

### Rebuilding the native libraries

```sh
export SS_ANDROID_NDK=/path/to/android-sdk/ndk/28.2.13676358   # for the Android build
tool/build_native.sh
```

Requires the pinned Zig 0.16.0 toolchain on `PATH` (or `ZIG=/path/to/zig`).
This runs `zig build lib -Doptimize=ReleaseSmall` in `../../../zig/` and
copies the two artifacts into `native/`, plus (if `example/` exists) into
`example/android/app/src/main/jniLibs/arm64-v8a/` so the example app's
copy stays in sync. Without `SS_ANDROID_NDK` set, the macOS library still
rebuilds but the script exits 1 rather than silently leaving a stale
Android library in place.

## Regenerating the FFI bindings

`lib/src/bindings_generated.dart` is machine-generated from
`../../../zig/include/search_simpli.h` by [`ffigen`](https://pub.dev/packages/ffigen)
— never edit it by hand. Regenerate it whenever the header's shape changes:

```sh
dart pub get
dart run ffigen --config ffigen.yaml
```

`ffigen` needs `libclang`. On a Mac with only Xcode Command Line Tools (no
Homebrew LLVM), `ffigen.yaml`'s `llvm-path` already points at
`/Library/Developer/CommandLineTools/usr` — adjust it if your machine keeps
`libclang` elsewhere. If no `libclang` is available at all (a from-scratch
CI image, for instance), bindings would need to be written by hand from the
header instead; that has not been necessary on this project's dev machine.

## Testing

```sh
dart pub get
dart test
```

`test/conformance_test.dart` (docs/tasks/S1-T2.md criterion 2) needs the
pinned Zig 0.16.0 toolchain on `PATH` — it runs `zig build` in `../../../zig/`
itself (in `setUpAll`) to get a fresh `searchd` binary, then checks:

- The exact [S1-T0](../../../docs/tasks/S1-T0.md) ABI conformance harness
  golden (`zig/tests/abi_test.c`) — `ss_import_json`/`ss_open`/`ss_status`/
  `ss_query`/`ss_evidence` reproduce that golden JSON byte for byte through
  this Dart binding too, not only from C.
- Every query in `fixtures/bm25-golden.json` (generated directly from the
  Python reference, `scripts/gen_bm25_golden.py`) — the FFI binding's top-1
  result matches Python's top-1 path, **and** matches the `searchd query
  --json` CLI's top-1 result for the same published snapshot (chunk id,
  path, and score).

`test/contracts_version_pin_test.dart` fails if `lib/src/
contracts_version.dart`'s `expectedContractsVersion` drifts from the real
`../../../contracts/CONTRACTS_VERSION` file.

## Example app / Android instrumentation smoke test

`example/` is a minimal Flutter app (`docs/tasks/S1-T2.md` criterion 3): it
bundles a tiny, already-published three-document demo snapshot as an asset
(`example/assets/demo_snapshot/`, exactly what `searchd init-demo` writes —
invented content only), copies it into the app's own storage at startup,
opens it with `SearchSimpli.open`, and shows one query's top result on
screen.

```sh
cd example
flutter pub get
flutter test integration_test/app_test.dart -d <device-or-emulator-id>
```

One agent on the emulator at a time — see `~/workspace/simpli-helper/tools/
emulator-lock.sh` (`take S1-T2` / `release S1-T2`) if you're running this
inside that workspace's shared emulator lock convention.

**Why the example publishes nothing on-device.** An earlier version of this
example called `importSnapshotJson` (`ss_import_json`) directly on the
device and failed with `ss_import_json: AccessDenied` on a fresh API 34
(Android 14) emulator. The cause is in Zig 0.16's standard library, not this binding:
`Dir.createFileAtomic` (used by the engine's atomic-publication path,
`zig/src/publication.zig`) opens an `O_TMPFILE` descriptor before renaming
it into place on Linux targets, and this device's SELinux policy denies
`O_TMPFILE` inside an app's private `files/` directory — confirmed by
reading `lib/std/Io/Threaded.zig`'s `dirCreateFileAtomic`, which turns that
specific `EACCES` into `error.AccessDenied` with no fallback to a
non-`O_TMPFILE` path. `ss_open`/`ss_query` never write, so shipping an
already-published snapshot as an asset sidesteps the issue entirely; the
`ss_import_json`-on-Android gap itself is an engine/std-library question for
a future `docs/tasks/S1-T0.md`-style task, not something this package works
around silently — it's recorded here and in `example/lib/main.dart`'s
header comment.

## Known limitations

- Only macOS arm64 and Android arm64 have prebuilt libraries (ADR 0002's
  current target set). Other platforms need `SEARCH_SIMPLI_LIBRARY_PATH`
  pointed at a library you build yourself.
- `ss_import_json` (`importSnapshotJson`) is not proven to work from an
  Android app's private storage on every device/OS combination — see
  "Why the example publishes nothing on-device" above. It works fine from
  Dart on macOS (exercised by every test in `test/`).
- No incremental folder indexing yet (`ss_index_folder`, ADR 0002 step 5,
  is a separate task in flight); this package only opens snapshots that
  already exist.
