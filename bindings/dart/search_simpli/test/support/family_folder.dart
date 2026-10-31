/// Shared by the contract 2.0.0 tests: the family-folder fixture
/// (`fixtures/family-folder/`) as three host roots, published through
/// `SearchSimpli.applyChanges` with `content_base64` changes, and its
/// judgments.
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:search_simpli/search_simpli.dart';

final String packageRoot = Directory.current.path;
final String repoRoot = p.normalize(p.join(packageRoot, '..', '..', '..'));
final String packDir = p.join(repoRoot, 'fixtures', 'family-folder');
const List<String> rootIds = ['home', 'laptop', 'school'];

Map<String, Object?> loadJudgments() =>
    jsonDecode(File(p.join(packDir, 'judgments.json')).readAsStringSync()) as Map<String, Object?>;

/// The batch that publishes the fixture's three roots.
Map<String, Object?> fixtureChanges() {
  final roots = <Map<String, Object?>>[];
  final changes = <Map<String, Object?>>[];
  for (final rootId in rootIds) {
    roots.add({'root_id': rootId, 'label': rootId[0].toUpperCase() + rootId.substring(1), 'kind': 'host'});
    final base = Directory(p.join(packDir, rootId));
    final files = base.listSync(recursive: true).whereType<File>().toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    for (final file in files) {
      changes.add({
        'op': 'add',
        'root_id': rootId,
        'path': p.relative(file.path, from: base.path).replaceAll(r'\', '/'),
        'content_base64': base64Encode(file.readAsBytesSync()),
      });
    }
  }
  return {'roots': roots, 'changes': changes};
}

/// A fresh index of the fixture in a temporary directory.
Directory publishFixture(String prefix) {
  final dir = Directory.systemTemp.createTempSync(prefix);
  final report = SearchSimpli.applyChanges(dir.path, fixtureChanges());
  if (report.added != 42) {
    throw StateError('expected 42 files added, got ${report.added}');
  }
  return dir;
}

/// JSON with every object's keys sorted, for comparing results across
/// surfaces independently of how a decoder orders keys.
String canonical(Object? value) => jsonEncode(_sorted(value));

Object? _sorted(Object? value) {
  if (value is Map) {
    final keys = value.keys.cast<String>().toList()..sort();
    return {for (final key in keys) key: _sorted(value[key])};
  }
  if (value is List) return value.map(_sorted).toList();
  return value;
}
