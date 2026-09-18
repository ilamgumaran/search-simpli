/// Locates and opens the prebuilt `libsearch_simpli` native library
/// (docs/tasks/S1-T2.md criterion 1: "prebuilt libsearch_simpli for macOS
/// arm64 and Android arm64 under native/").
library;

import 'dart:ffi';
import 'dart:io';

import 'package:path/path.dart' as path;

/// Opens the platform's prebuilt `search_simpli` shared library.
///
/// Resolution order:
/// 1. `SEARCH_SIMPLI_LIBRARY_PATH` environment variable, if set (an
///    absolute path to the `.dylib`/`.so` file) — always wins, on every
///    platform; useful for pointing at a freshly rebuilt library from
///    `tool/build_native.sh` without reinstalling the package.
/// 2. **Android:** `DynamicLibrary.open('libsearch_simpli.so')` — the
///    standard Android convention. The app embedding this package is
///    responsible for packaging `native/android-arm64/libsearch_simpli.so`
///    as a jniLib for `arm64-v8a` (see this package's README and
///    `example/android/app/build.gradle.kts` for a worked Flutter example);
///    once packaged, the OS's own dynamic linker finds it by soname.
/// 3. **macOS:** `native/macos-arm64/libsearch_simpli.dylib`, resolved
///    relative to this package's own root. Two roots are tried, in order,
///    covering both supported ways of running Dart against this package:
///    the current working directory (`dart test`/`dart run` invoked from
///    inside `bindings/dart/search_simpli/`, this package's own documented
///    dev workflow) and the directory of the running script (covers a
///    script located elsewhere that still points at a checkout of this
///    package via a relative path, e.g. a copy under `example/`).
DynamicLibrary openSearchSimpliLibrary() {
  final override = Platform.environment['SEARCH_SIMPLI_LIBRARY_PATH'];
  if (override != null && override.isNotEmpty) {
    return DynamicLibrary.open(override);
  }

  if (Platform.isAndroid) {
    return DynamicLibrary.open('libsearch_simpli.so');
  }

  if (Platform.isMacOS) {
    const relative = ['native', 'macos-arm64', 'libsearch_simpli.dylib'];
    final candidates = <String>[
      path.joinAll([Directory.current.path, ...relative]),
      path.joinAll([
        path.dirname(Platform.script.toFilePath()),
        '..',
        ...relative,
      ]),
      path.joinAll([
        path.dirname(Platform.script.toFilePath()),
        ...relative,
      ]),
    ];
    for (final candidate in candidates) {
      if (File(candidate).existsSync()) {
        return DynamicLibrary.open(candidate);
      }
    }
    throw StateError(
      'search_simpli: could not find libsearch_simpli.dylib. Tried:\n'
      '${candidates.join('\n')}\n'
      'Run from inside bindings/dart/search_simpli/, or set '
      'SEARCH_SIMPLI_LIBRARY_PATH to an explicit path.',
    );
  }

  throw UnsupportedError(
    'search_simpli: no prebuilt libsearch_simpli for platform '
    '${Platform.operatingSystem} (only macOS arm64 and Android arm64 are '
    'built by tool/build_native.sh — see docs/decisions/'
    '0002-standalone-portable-platform.md). Set SEARCH_SIMPLI_LIBRARY_PATH '
    'to use a library you built yourself for another target.',
  );
}
