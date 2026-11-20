// S6-T9 ruling 2 through Dart: main's Dart package and library (a019f22)
// against a v2.6 index. S6-T8's dart_v25_refused_test.dart with its
// scratch folder named by WORK instead of the system's temporary folder.
// Not part of this package's tests: copy it into the `test/` folder of an
// extract of main's package (`git archive a019f22 bindings/dart/search_simpli`)
// as `test/v26_refused_test.dart` and run `dart test test/v26_refused_test.dart`
// there. INDEX: the index to copy (each call gets its own copy); FOLDER: any
// folder for indexFolder; WORK: an existing empty folder for the copies.
import 'dart:ffi';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:search_simpli/search_simpli.dart';
import 'package:test/test.dart';

Map<String, String> _bytes(Directory d) => {
      for (final f in d.listSync().whereType<File>()) p.basename(f.path): f.readAsBytesSync().join(',')
    };

void main() {
  final index = Platform.environment['INDEX']!;
  final folder = Platform.environment['FOLDER']!;
  final scratch = Platform.environment['WORK']!;
  final library = DynamicLibrary.open(p.absolute('native/macos-arm64/libsearch_simpli.dylib'));
  late Directory work;

  setUp(() => work = Directory(scratch).createTempSync('ss-v26-'));
  tearDown(() => work.deleteSync(recursive: true));

  Directory copy() {
    final target = Directory(p.join(work.path, 'idx'))..createSync();
    for (final f in Directory(index).listSync().whereType<File>()) {
      f.copySync(p.join(target.path, p.basename(f.path)));
    }
    return target;
  }

  void check(String label, void Function(String dir) call) {
    test(label, () {
      final dir = copy();
      final before = _bytes(dir);
      Object? caught;
      try {
        call(dir.path);
      } catch (e) {
        caught = e;
      }
      final after = _bytes(dir);
      final changed = after.keys.where((k) => before[k] != after[k]).toList();
      print('$label: ${caught.runtimeType}: $caught; files ${before.length} -> ${after.length}, changed $changed');
      expect(caught, isA<SearchSimpliException>());
      expect('$caught', contains('UnsupportedFlags'));
      expect(changed.every((k) => k == 'WRITER.LOCK' && after[k] == ''), isTrue);
    });
  }

  check('open', (d) => SearchSimpli.open(d, library: library));
  check('applyChanges', (d) => SearchSimpli.applyChanges(d, {'changes': []}, library: library));
  check('indexFolder', (d) => SearchSimpli.indexFolder(d, folder, library: library));
}
