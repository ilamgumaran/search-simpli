/// Locates and opens the prebuilt `libsearch_simpli` native library
/// (docs/tasks/S1-T2.md criterion 1: "prebuilt libsearch_simpli for macOS
/// arm64 and Android arm64 under native/").
library;

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:path/path.dart' as path;

/// The `native/<subdir>/<filename>` layout for the current desktop platform
/// (macOS or Linux; Android uses the OS's own jniLibs convention instead —
/// see [openSearchSimpliLibrary]'s doc comment), or `null` on any other
/// platform.
({String subdir, String filename})? _desktopNativeLayout() {
  if (Platform.isMacOS) return (subdir: 'macos-arm64', filename: 'libsearch_simpli.dylib');
  if (Platform.isLinux) return (subdir: 'linux-x64', filename: 'libsearch_simpli.so');
  return null;
}

/// Finds this package's own root directory by locating and parsing the
/// nearest `.dart_tool/package_config.json` (searched upward from both
/// [Directory.current] and the running script's directory) and reading the
/// `search_simpli` package's `rootUri` out of it — the same file
/// `dart:isolate`'s `Isolate.resolvePackageUri` resolves against, read
/// directly and synchronously here because [openSearchSimpliLibrary] must
/// stay synchronous (`resolvePackageUri` is `Future`-returning, and making
/// `SearchSimpli.open` asynchronous would be a breaking change to this
/// package's public API). This is what makes library loading work for a
/// consumer that depends on this package via a `path:` entry in their own
/// `pubspec.yaml` (docs/tasks/S1-T4.md criterion 2): a `pub`-generated
/// `package_config.json` always has an accurate `rootUri` for every
/// dependency, path or otherwise, regardless of the consumer's own working
/// directory or script location.
String? _resolvePackageRootViaPackageConfig(String packageName) {
  for (final start in <String>[
    Directory.current.path,
    path.dirname(Platform.script.toFilePath()),
  ]) {
    var dir = Directory(start);
    while (true) {
      final candidate = File(path.join(dir.path, '.dart_tool', 'package_config.json'));
      if (candidate.existsSync()) {
        final root = _rootUriFromPackageConfig(candidate, packageName);
        if (root != null) return root;
        break;
      }
      final parent = dir.parent;
      if (parent.path == dir.path) break;
      dir = parent;
    }
  }
  return null;
}

String? _rootUriFromPackageConfig(File configFile, String packageName) {
  final Object? decoded;
  try {
    decoded = jsonDecode(configFile.readAsStringSync());
  } on FormatException {
    return null;
  }
  if (decoded is! Map<String, Object?>) return null;
  final packages = decoded['packages'];
  if (packages is! List<Object?>) return null;
  for (final entry in packages) {
    if (entry is! Map<String, Object?>) continue;
    if (entry['name'] != packageName) continue;
    final rootUriText = entry['rootUri'];
    if (rootUriText is! String) return null;
    final rootUri = Uri.parse(rootUriText);
    final configDirUri = Uri.directory(path.dirname(configFile.path));
    final resolved = rootUri.isAbsolute ? rootUri : configDirUri.resolveUri(rootUri);
    return resolved.toFilePath();
  }
  return null;
}

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
/// 3. **macOS/Linux:** `native/<subdir>/<filename>` under this package's own
///    root, resolved package-relatively (docs/tasks/S1-T4.md criterion 2) so
///    a plain `path:` dependency works with no environment variable at all:
///    first via `_resolvePackageRootViaPackageConfig` (accurate for any
///    consumer, any working directory), then — only if that fails, e.g. no
///    `package_config.json` has been generated yet — the two paths this
///    package's own documented dev workflow already covered: the current
///    working directory (`dart test`/`dart run` invoked from inside
///    `bindings/dart/search_simpli/`) and the running script's directory.
DynamicLibrary openSearchSimpliLibrary() {
  final override = Platform.environment['SEARCH_SIMPLI_LIBRARY_PATH'];
  if (override != null && override.isNotEmpty) {
    return DynamicLibrary.open(override);
  }

  if (Platform.isAndroid) {
    return DynamicLibrary.open('libsearch_simpli.so');
  }

  final layout = _desktopNativeLayout();
  if (layout != null) {
    final relative = ['native', layout.subdir, layout.filename];
    final candidates = <String>[];

    final packageRoot = _resolvePackageRootViaPackageConfig('search_simpli');
    if (packageRoot != null) {
      candidates.add(path.joinAll([packageRoot, ...relative]));
    }
    candidates.addAll([
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
    ]);
    for (final candidate in candidates) {
      if (File(candidate).existsSync()) {
        return DynamicLibrary.open(candidate);
      }
    }
    throw StateError(
      'search_simpli: could not find ${layout.filename}. Tried:\n'
      '${candidates.join('\n')}\n'
      'Depend on search_simpli as a path: dependency and run `pub get`/'
      '`flutter pub get` first, run from inside bindings/dart/search_simpli/, '
      'or set SEARCH_SIMPLI_LIBRARY_PATH to an explicit path.',
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
