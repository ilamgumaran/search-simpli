/// Contract 2.0.0 (docs/tasks/S3-T4.md ruling 2): a native library without
/// the new symbols is refused with [ContractsVersionMismatchException]
/// before anything else runs, by `SearchSimpli.open` and by the static
/// `SearchSimpli.applyChanges`. The two libraries here are stand-ins built
/// from a few lines of C with the pinned Zig: one that reports the previous
/// contract ("2.0.0", what every build before S4-T1 reports; it was "1.2.0"
/// before S3), and one that reports this package's contract but exports
/// none of the 2.0.0 functions.
library;

import 'dart:ffi';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:search_simpli/search_simpli.dart';
import 'package:test/test.dart';

Future<DynamicLibrary> _standIn(Directory dir, String name, String version) async {
  final source = File(p.join(dir.path, '$name.c'))
    ..writeAsStringSync('const char *ss_version(void) { return "$version"; }\n'
        'const char *ss_last_error(void) { return ""; }\n');
  final library = p.join(dir.path, Platform.isMacOS ? 'lib$name.dylib' : 'lib$name.so');
  final built = await Process.run('zig', ['build-lib', '-dynamic', '-OReleaseSmall', source.path, '-femit-bin=$library']);
  if (built.exitCode != 0) fail('zig build-lib failed (is the pinned Zig 0.16.0 on PATH?):\n${built.stderr}');
  return DynamicLibrary.open(library);
}

void main() {
  late Directory dir;
  late DynamicLibrary previous;
  late DynamicLibrary hollow;

  setUpAll(() async {
    dir = Directory.systemTemp.createTempSync('ss-dart-old-lib-');
    previous = await _standIn(dir, 'previous', '2.0.0');
    hollow = await _standIn(dir, 'hollow', expectedContractsVersion);
  });

  tearDownAll(() => dir.deleteSync(recursive: true));

  test('a library reporting the previous contract is refused at open and at applyChanges', () {
    final index = p.join(dir.path, 'never-created');
    expect(
      () => SearchSimpli.open(index, library: previous),
      throwsA(isA<ContractsVersionMismatchException>()
          .having((e) => e.expected, 'expected', expectedContractsVersion)
          .having((e) => e.actual, 'actual', '2.0.0')),
    );
    expect(() => SearchSimpli.applyChanges(index, {'changes': []}, library: previous),
        throwsA(isA<ContractsVersionMismatchException>()));
    expect(Directory(index).existsSync(), isFalse);
  });

  test('a library without the new symbols is refused, naming them', () {
    expect(
      () => SearchSimpli.open(dir.path, library: hollow),
      throwsA(isA<ContractsVersionMismatchException>().having(
          (e) => e.actual, 'actual', '$expectedContractsVersion without ss_find, ss_outline, ss_read_span, ss_list_files, ss_roots, ss_apply_changes')),
    );
    expect(() => SearchSimpli.applyChanges(dir.path, {'changes': []}, library: hollow),
        throwsA(isA<ContractsVersionMismatchException>()));
  });

  test('the packaged library has every new symbol', () {
    final library = openSearchSimpliLibrary();
    for (final name in ['ss_find', 'ss_outline', 'ss_read_span', 'ss_list_files', 'ss_roots', 'ss_apply_changes']) {
      expect(library.providesSymbol(name), isTrue, reason: name);
    }
  });
}
