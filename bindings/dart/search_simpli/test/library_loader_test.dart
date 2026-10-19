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
    String exe = '/checkout/bin/dart',
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
        executablePath: exe,
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

  const appExe = '/App.app/Contents/MacOS/app';
  const frameworks = '/App.app/Contents/MacOS/../Frameworks/libsearch_simpli.dylib';

  test('isInsideMacApp is a pure function of the executable path', () {
    expect(isInsideMacApp('/App.app/Contents/MacOS/app'), isTrue);
    expect(isInsideMacApp('/Applications/My App.app/Contents/MacOS/x'), isTrue);
    expect(isInsideMacApp('/opt/flutter/bin/cache/dart-sdk/bin/dart'), isFalse);
    expect(isInsideMacApp('/App.app/Contents/Frameworks/x'), isFalse);
    expect(isInsideMacApp('/.app/Contents/MacOS/x'), isFalse);
    expect(isInsideMacApp('/tmp/MacOS/app'), isFalse);
  });

  test('an executable under Contents/MacOS with no .app ancestor is outside an app', () {
    expect(isInsideMacApp('/Foo/Contents/MacOS/x'), isFalse);
    expect(isInsideMacApp('/Foo.app/Sub/Contents/MacOS/x'), isFalse);
    expect(isInsideMacApp('/opt/App.app/Resources/Contents/MacOS/x'), isFalse);
  });

  test('isInsideMacApp compares .app case-insensitively, Contents/MacOS exactly', () {
    for (final ext in ['.APP', '.App', '.app']) {
      expect(isInsideMacApp('/Upper$ext/Contents/MacOS/x'), isTrue, reason: ext);
    }
    expect(isInsideMacApp('/Upper.APP/contents/MacOS/x'), isFalse);
    expect(isInsideMacApp('/Upper.APP/Contents/macos/x'), isFalse);
  });

  test('in an app, the library present: only the Frameworks path is tried', () {
    final lib = _self();
    final result = run(exe: appExe, opener: (p) {
      attempts.add(p);
      return lib;
    });
    expect(result, same(lib));
    expect(attempts, [frameworks]);
  });

  test('in an app, the library missing: error names the path, bare name NOT attempted', () {
    final e = run(exe: appExe, exists: (_) => false) as StateError;
    expect(attempts, isEmpty);
    expect(e.message, contains('did not ship'));
    expect(e.message, isNot(contains('could not be opened')));
    expect(e.message, contains(frameworks));
    expect(e.message, isNot(contains('/pkg/native')));
    expect(attempts, isNot(contains('libsearch_simpli.dylib')));
  });

  test('in an app, an existing copy that cannot be opened is "found but could not be opened"', () {
    final e = run(exe: appExe, opener: (p) {
      attempts.add(p);
      throw ArgumentError('wrong architecture: $p');
    }) as StateError;
    expect(attempts, [frameworks]);
    expect(e.message, contains('found but could not be opened'));
    expect(e.message, contains('wrong architecture'));
    expect(e.message, isNot(contains('did not ship')));
  });

  test('in an app, a Frameworks copy that fails to open never falls back to the bare name', () {
    final e = run(exe: appExe);
    expect(e, isA<StateError>());
    expect(attempts, [frameworks]);
  });

  test('macOS checkout: package root, cwd, script, then the bare name last', () {
    run();
    expect(attempts, [
      '/pkg/native/macos-arm64/libsearch_simpli.dylib',
      '/cwd/native/macos-arm64/libsearch_simpli.dylib',
      '/script/../native/macos-arm64/libsearch_simpli.dylib',
      '/script/native/macos-arm64/libsearch_simpli.dylib',
      'libsearch_simpli.dylib',
    ]);
  });

  test('Linux checkout: the bare .so is last', () {
    run(mac: false);
    expect(attempts.first, '/checkout/bin/lib/libsearch_simpli.so');
    expect(attempts.last, 'libsearch_simpli.so');
    expect(attempts.indexOf('/pkg/native/linux-x64/libsearch_simpli.so'),
        lessThan(attempts.indexOf('libsearch_simpli.so')));
  });

  test('the override short-circuits everything, in both modes', () {
    for (final exe in [appExe, '/usr/bin/dart']) {
      attempts = [];
      expect(
          () => run(exe: exe, env: {'SEARCH_SIMPLI_LIBRARY_PATH': '/forced/lib.dylib'}),
          throwsArgumentError);
      expect(attempts, ['/forced/lib.dylib']);
    }
  });

  test('a failed earlier candidate does not mask a later one (first candidates all fail)', () {
    final lib = _self();
    final result = run(opener: (p) {
      attempts.add(p);
      if (p == 'libsearch_simpli.dylib') return lib;
      throw ArgumentError('no such file: $p');
    });
    expect(result, same(lib));
    expect(attempts.length, greaterThan(1));
    expect(attempts.last, 'libsearch_simpli.dylib');
    expect(attempts.take(attempts.length - 1), everyElement(contains('/native/')));
  });

  test('a failed earlier candidate does not mask a later one', () {
    final lib = _self();
    final result = run(opener: (p) {
      attempts.add(p);
      if (p.startsWith('/pkg/')) return lib;
      throw ArgumentError('no such file: $p');
    });
    expect(result, same(lib));
    expect(attempts.length, 1);
  });

  test('the checkout error lists every candidate in order and keeps the advice', () {
    final e = run(exists: (_) => false) as StateError;
    final lines = e.message.split('\n');
    expect(lines[1], '/pkg/native/macos-arm64/libsearch_simpli.dylib');
    expect(lines.indexOf('libsearch_simpli.dylib'), greaterThan(1));
    expect(e.message, contains('SEARCH_SIMPLI_LIBRARY_PATH'));
    // Missing files are not opened; the bare name is the only blind attempt.
    expect(attempts, ['libsearch_simpli.dylib']);
  });

  // docs/tasks/S1-T21.md ruling 3. The iOS library itself cannot be loaded on
  // the Mac; these tests only check what the loader hands to the opener.
  group('iOS', () {
    DynamicLibrary open({
      Map<String, String> env = const {},
      DynamicLibrary Function(String)? opener,
    }) =>
        openSearchSimpliLibraryWith(
          environment: env,
          opener: opener ?? failing(),
          exists: (_) => true,
          packageRootOverride: '/pkg',
          executablePath: '/Runner.app/Runner',
          scriptDir: '/script',
          cwd: '/cwd',
          isMacOS: false,
          isLinux: false,
          isAndroid: false,
          isIOS: true,
        );

    test('opens the framework binary by its relative path, and nothing else', () {
      final lib = _self();
      final result = open(opener: (p) {
        attempts.add(p);
        return lib;
      });
      expect(result, same(lib));
      expect(attempts, ['search_simpli.framework/search_simpli']);
    });

    test('a failed open propagates; no checkout or bare-name fallback is tried', () {
      expect(() => open(), throwsArgumentError);
      expect(attempts, ['search_simpli.framework/search_simpli']);
    });

    test('SEARCH_SIMPLI_LIBRARY_PATH still wins over the framework', () {
      final lib = _self();
      open(env: {'SEARCH_SIMPLI_LIBRARY_PATH': '/forced/lib'}, opener: (p) {
        attempts.add(p);
        return lib;
      });
      expect(attempts, ['/forced/lib']);
    });

    test('the unsupported-platform message lists iOS among the built platforms', () {
      Object? error;
      try {
        openSearchSimpliLibraryWith(
          environment: const {},
          opener: failing(),
          isMacOS: false,
          isLinux: false,
          isAndroid: false,
          isIOS: false,
        );
      } on UnsupportedError catch (e) {
        error = e;
      }
      expect(error, isA<UnsupportedError>());
      final message = (error as UnsupportedError).message!;
      expect(message, contains('iOS arm64'));
      expect(message, contains('macOS arm64'));
      expect(message, contains('Android arm64'));
      expect(attempts, isEmpty);
    });
  });
}
