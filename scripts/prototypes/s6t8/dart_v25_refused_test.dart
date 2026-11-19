// S6-T8 ruling 2 through Dart (rulings on the Report, item 3): main's Dart
// package and library (62324f9, 0.9.1) against a v2.5 index. Not part of
// this package's tests: copy it into the `test/` folder of an extract of
// main's package (`git archive 62324f9 bindings/dart/search_simpli`) as
// `test/v25_refused_test.dart` and run `dart test test/v25_refused_test.dart`
// there. INDEX: the index to
// copy (each call gets its own copy); FOLDER: any folder for indexFolder.
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
  final library = DynamicLibrary.open(p.absolute('native/macos-arm64/libsearch_simpli.dylib'));
  late Directory work;

  setUp(() => work = Directory.systemTemp.createTempSync('ss-v25-'));
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
