/// Locates and opens the prebuilt `libsearch_simpli` native library
/// (docs/tasks/S1-T2.md criterion 1: "prebuilt libsearch_simpli for macOS
/// arm64 and Android arm64 under native/").
library;

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:path/path.dart' as path;

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
/// 3. **macOS/Linux, a built app bundle (docs/tasks/S1-T10.md, order fixed
///    by docs/tasks/S1-T11.md):** first the app's own copy,
///    `<executable dir>/../Frameworks/libsearch_simpli.dylib` (macOS) or
///    `<executable dir>/lib/libsearch_simpli.so` (Linux), from
///    [Platform.resolvedExecutable], as an exact path so a stray copy in the
///    cwd or `/usr/local/lib` can never win; then the bare file name through
///    the loader's search path (`@rpath` resolves it to `Contents/Frameworks`
///    in a macOS app, after the cwd and the engine's other rpaths).
/// 4. **macOS/Linux, a development checkout:** `native/<subdir>/<filename>`
///    under this package's own root, resolved package-relatively
///    (docs/tasks/S1-T4.md criterion 2) so a plain `path:` dependency works
///    with no environment variable at all: first via
///    `_resolvePackageRootViaPackageConfig`, then the current working
///    directory and the running script's directory.
///
/// A candidate that fails to open never stops the search; the final
/// [StateError] lists every candidate tried, in order.
DynamicLibrary openSearchSimpliLibrary() => openSearchSimpliLibraryWith(
      environment: Platform.environment,
      opener: DynamicLibrary.open,
    );

/// [openSearchSimpliLibrary] with its inputs injected so tests can record the
/// order of attempts. Not exported from `package:search_simpli/search_simpli.dart`.
DynamicLibrary openSearchSimpliLibraryWith({
  required Map<String, String> environment,
  required DynamicLibrary Function(String) opener,
  bool Function(String)? exists,
  String? packageRootOverride,
  String? executablePath,
  String? scriptDir,
  String? cwd,
  bool? isMacOS,
  bool? isLinux,
  bool? isAndroid,
}) {
  final override = environment['SEARCH_SIMPLI_LIBRARY_PATH'];
  if (override != null && override.isNotEmpty) {
    return opener(override);
  }

  if (isAndroid ?? Platform.isAndroid) {
    return opener('libsearch_simpli.so');
  }

  final mac = isMacOS ?? Platform.isMacOS;
  final linux = isLinux ?? Platform.isLinux;
  if (mac || linux) {
    final subdir = mac ? 'macos-arm64' : 'linux-x64';
    final filename = mac ? 'libsearch_simpli.dylib' : 'libsearch_simpli.so';
    final relative = ['native', subdir, filename];
    final fileExists = exists ?? (String p) => File(p).existsSync();
    final exeDir = path.dirname(executablePath ?? Platform.resolvedExecutable);
    final script = scriptDir ?? path.dirname(Platform.script.toFilePath());
    final workDir = cwd ?? Directory.current.path;

    // (path, needsFileCheck): the app's own copy comes first, as an exact
    // path, so a stray copy on dyld's search path (cwd, /usr/local/lib) can
    // never beat it; the bare name goes straight to the loader.
    final candidates = <({String name, bool check})>[
      (
        name: mac
            ? path.join(exeDir, '..', 'Frameworks', filename)
            : path.join(exeDir, 'lib', filename),
        check: true,
      ),
      (name: filename, check: false),
    ];
    final packageRoot = packageRootOverride ??
        _resolvePackageRootViaPackageConfig('search_simpli');
    if (packageRoot != null) {
      candidates.add((name: path.joinAll([packageRoot, ...relative]), check: true));
    }
    candidates.addAll([
      (name: path.joinAll([workDir, ...relative]), check: true),
      (name: path.joinAll([script, '..', ...relative]), check: true),
      (name: path.joinAll([script, ...relative]), check: true),
    ]);

    final failures = <String>[];
    for (final candidate in candidates) {
      if (candidate.check && !fileExists(candidate.name)) continue;
      try {
        return opener(candidate.name);
      } on ArgumentError catch (e) {
        failures.add('${candidate.name} ($e)');
      }
    }
    throw StateError(
      'search_simpli: could not find $filename. Tried:\n'
      '${candidates.map((c) => c.name).join('\n')}\n'
      '${failures.isEmpty ? '' : 'Candidates that existed or were tried by name but failed to open:\n${failures.join('\n')}\n'}'
      'Depend on search_simpli as a path: dependency and run `pub get`/'
      '`flutter pub get` first, run from inside bindings/dart/search_simpli/, '
      'bundle the library in the app (Contents/Frameworks on macOS), '
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
