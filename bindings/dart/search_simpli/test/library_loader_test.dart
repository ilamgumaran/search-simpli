/// Candidate order for [openSearchSimpliLibraryWith] (docs/tasks/S1-T10.md
/// criterion 4). The opener is a fake that records every attempt.
library;

import 'dart:ffi';

import 'package:search_simpli/src/library_loader.dart';
import 'package:test/test.dart';

DynamicLibrary _self() => DynamicLibrary.process();

void main() {
  List<String> attempts = [];
  DynamicLibrary Function(String) failing() => (String p) {
        attempts.add(p);
        throw ArgumentError('no such file: $p');
      };

  setUp(() => attempts = []);

  Object? run({
    bool mac = true,
    Map<String, String> env = const {},
    bool Function(String)? exists,
    DynamicLibrary Function(String)? opener,
  }) {
    try {
      return openSearchSimpliLibraryWith(
        environment: env,
        opener: opener ?? failing(),
        exists: exists ?? (_) => true,
        packageRootOverride: '/pkg',
        executablePath: '/App.app/Contents/MacOS/app',
        scriptDir: '/script',
        cwd: '/cwd',
        isMacOS: mac,
        isLinux: !mac,
        isAndroid: false,
      );
    } on StateError catch (e) {
      return e;
    }
  }

  test('macOS: bundle (bare name, Frameworks), then package root, then the rest', () {
    run();
    expect(attempts, [
      'libsearch_simpli.dylib',
      '/App.app/Contents/MacOS/../Frameworks/libsearch_simpli.dylib',
      '/pkg/native/macos-arm64/libsearch_simpli.dylib',
      '/cwd/native/macos-arm64/libsearch_simpli.dylib',
      '/script/../native/macos-arm64/libsearch_simpli.dylib',
      '/script/native/macos-arm64/libsearch_simpli.dylib',
    ]);
  });

  test('Linux: bare .so, then <exe dir>/lib, then the rest', () {
    run(mac: false);
    expect(attempts.take(3), [
      'libsearch_simpli.so',
      '/App.app/Contents/MacOS/lib/libsearch_simpli.so',
      '/pkg/native/linux-x64/libsearch_simpli.so',
    ]);
  });

  test('the override short-circuits everything', () {
    expect(() => run(env: {'SEARCH_SIMPLI_LIBRARY_PATH': '/forced/lib.dylib'}),
        throwsArgumentError);
    expect(attempts, ['/forced/lib.dylib']);
  });

  test('a failed earlier candidate does not mask a later one', () {
    final lib = _self();
    final result = run(opener: (p) {
      attempts.add(p);
      if (p.startsWith('/pkg/')) return lib;
      throw ArgumentError('no such file: $p');
    });
    expect(result, same(lib));
    expect(attempts.length, 3);
  });

  test('the error lists every candidate in order and keeps the advice', () {
    final e = run(exists: (_) => false) as StateError;
    final lines = e.message.split('\n');
    expect(lines[1], 'libsearch_simpli.dylib');
    expect(lines[2], '/App.app/Contents/MacOS/../Frameworks/libsearch_simpli.dylib');
    expect(lines[3], '/pkg/native/macos-arm64/libsearch_simpli.dylib');
    expect(e.message, contains('SEARCH_SIMPLI_LIBRARY_PATH'));
    // The bare name is always tried; missing files are not opened.
    expect(attempts, ['libsearch_simpli.dylib']);
  });
}
