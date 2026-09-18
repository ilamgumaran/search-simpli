/// Unit tests for `SearchSimpli`'s Dart-level behavior (error handling,
/// lifecycle) that do not need a real published snapshot beyond the tiny
/// one `importSnapshotJson` publishes in `setUp`.
library;

import 'dart:io';

import 'package:search_simpli/search_simpli.dart';
import 'package:test/test.dart';

const String _tinyInterchangeJson =
    '{"format_version":1,"generation":1,"analyzer_id":"ascii-alnum-v1",'
    '"embedding_model_id":"none","documents":['
    '{"id":"only-doc","path":"only.md","start_line":1,"end_line":1,'
    '"text":"a single tiny document for unit tests","vector":[],"required_labels":[]}'
    ']}';

void main() {
  test('SearchSimpli.open on a missing directory throws SearchSimpliException', () {
    expect(
      () => SearchSimpli.open('/nonexistent/search-simpli-dart-test-dir'),
      throwsA(isA<SearchSimpliException>()),
    );
  });

  group('with a published snapshot', () {
    late Directory dir;
    late SearchSimpli engine;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('ss-dart-unit-');
      importSnapshotJson(dir.path, _tinyInterchangeJson);
      engine = SearchSimpli.open(dir.path);
    });

    tearDown(() {
      dir.deleteSync(recursive: true);
    });

    test('status reports one document', () {
      final status = engine.status();
      expect(status.ready, isTrue);
      expect(status.documents, 1);
    });

    test('query returns the only document for a matching term', () {
      final result = engine.query('tiny', topK: 5, mode: RetrievalMode.lexical);
      expect(result.results, isNotEmpty);
      expect(result.results.first.citation.path, 'only.md');
    });

    test('query rejects top_k=0', () {
      expect(
        () => engine.query('tiny', topK: 0),
        throwsA(isA<SearchSimpliException>()),
      );
    });

    test('evidence reports an unknown id as not found', () {
      final result = engine.evidence(['does-not-exist']);
      expect(result, hasLength(1));
      expect(result.single.found, isFalse);
      expect(result.single.chunkId, 'does-not-exist');
    });

    test('close is safe once, and a second close throws StateError', () {
      engine.close();
      expect(engine.close, throwsA(isA<StateError>()));
    });

    test('calling query after close throws StateError', () {
      engine.close();
      expect(() => engine.query('tiny'), throwsA(isA<StateError>()));
    });
  });

  group('SearchSimpli.indexFolder (docs/tasks/S1-T4.md criterion 1)', () {
    late Directory folderDir;
    late Directory outDir;

    setUp(() {
      folderDir = Directory.systemTemp.createTempSync('ss-dart-index-folder-');
      outDir = Directory.systemTemp.createTempSync('ss-dart-index-out-');
      outDir.deleteSync(); // ss_index_folder must create it.
      File('${folderDir.path}/one.md').writeAsStringSync(
        'hybrid ranking combines lexical and semantic evidence',
      );
    });

    tearDown(() {
      folderDir.deleteSync(recursive: true);
      if (outDir.existsSync()) outDir.deleteSync(recursive: true);
    });

    test('publishes a queryable generation and returns a typed report', () {
      final report = SearchSimpli.indexFolder(outDir.path, folderDir.path);

      expect(report.generation, 1);
      expect(report.added, 1);
      expect(report.changed, 0);
      expect(report.removed, 0);
      expect(report.unchanged, 0);
      expect(report.budgetExhausted, 0);
      expect(report.tooLarge, 0);
      expect(report.unreadable, 0);
      expect(report.tooLargePaths, isEmpty);
      expect(report.unreadablePaths, isEmpty);
      expect(report.documents, 1);

      final engine = SearchSimpli.open(outDir.path);
      try {
        final result = engine.query('hybrid', topK: 5, mode: RetrievalMode.lexical);
        expect(result.results, isNotEmpty);
        expect(result.results.first.citation.path, 'one.md');
      } finally {
        engine.close();
      }
    });

    test('an empty folder publishes an empty generation instead of throwing', () {
      final emptyDir = Directory.systemTemp.createTempSync('ss-dart-index-empty-');
      addTearDown(() => emptyDir.deleteSync(recursive: true));

      final report = SearchSimpli.indexFolder(outDir.path, emptyDir.path);
      expect(report.documents, 0);
      expect(report.terms, 0);
      expect(report.postings, 0);

      final engine = SearchSimpli.open(outDir.path);
      try {
        expect(engine.status().documents, 0);
      } finally {
        engine.close();
      }
    });

    test('an update run reports unreadable files by relative path', () {
      SearchSimpli.indexFolder(outDir.path, folderDir.path);
      File('${folderDir.path}/bad.md').writeAsBytesSync([0xff, 0xfe, 0x00]);

      final report = SearchSimpli.indexFolder(
        outDir.path,
        folderDir.path,
        options: const IndexFolderOptions(update: true),
      );
      expect(report.unreadable, 1);
      expect(report.unreadablePaths, ['bad.md']);
    });

    test('a folder that fails to index throws SearchSimpliException', () {
      expect(
        () => SearchSimpli.indexFolder(
          outDir.path,
          '/nonexistent/search-simpli-dart-test-folder',
        ),
        throwsA(isA<SearchSimpliException>()),
      );
    });
  });
}
