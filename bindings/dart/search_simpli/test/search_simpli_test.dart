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

const String _vectorInterchangeJson =
    '{"format_version":1,"generation":1,"analyzer_id":"ascii-alnum-v1",'
    '"embedding_model_id":"m","documents":['
    '{"id":"a","path":"a.md","start_line":1,"end_line":1,'
    '"text":"alpha search","vector":[1,0],"required_labels":[]},'
    '{"id":"b","path":"b.md","start_line":1,"end_line":1,'
    '"text":"beta search","vector":[0,1],"required_labels":[]}'
    ']}';

void main() {
  group('a valid query vector (S2-T13)', () {
    late Directory dir;
    late SearchSimpli engine;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('ss-dart-vec-');
      importSnapshotJson(dir.path, _vectorInterchangeJson);
      engine = SearchSimpli.open(dir.path);
    });

    tearDown(() {
      engine.close();
      dir.deleteSync(recursive: true);
    });

    test('a vector with an overflowing norm or a non-finite component is rejected', () {
      for (final bad in <List<double>>[
        [2e19, 0],
        [1e30, 1],
        [double.nan, 0],
        [double.infinity, 0],
        [1e300, 0], // too large for a 32-bit float
      ]) {
        for (final mode in [RetrievalMode.vector, RetrievalMode.hybrid]) {
          expect(
            () => engine.query('search', queryVector: bad, topK: 2, mode: mode),
            throwsA(isA<SearchSimpliException>()),
            reason: '$bad in $mode',
          );
        }
      }
    });

    test('lexical mode does not read the vector; a large valid one ranks', () {
      final lexical = engine.query('search',
          queryVector: [2e19, 0], topK: 2, mode: RetrievalMode.lexical);
      expect(lexical.results, hasLength(2));
      final vector = engine.query('search',
          queryVector: [1.8e19, 0], topK: 2, mode: RetrievalMode.vector);
      expect(vector.results.first.citation.path, 'a.md');
    });
  });

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

  group('SearchSimpli.indexFolder caps on a non-update run (S1-T5 criterion 1)', () {
    test('maxFileBytes caps a file on a full rebuild', () {
      // Own plant: a folder containing only one oversized file, not shared
      // with any other test's fixture.
      final folder = Directory.systemTemp.createTempSync('ss-dart-cap-file-');
      final out = Directory.systemTemp.createTempSync('ss-dart-cap-file-out-');
      out.deleteSync(); // ss_index_folder must create it.
      addTearDown(() => folder.deleteSync(recursive: true));
      addTearDown(() {
        if (out.existsSync()) out.deleteSync(recursive: true);
      });
      File('${folder.path}/oversized.md').writeAsStringSync(
        '123456789\n123456789\n123456789\n123456789\na', // 41 bytes
      );

      final report = SearchSimpli.indexFolder(
        out.path,
        folder.path,
        options: const IndexFolderOptions(update: false, maxFileBytes: 10),
      );

      expect(report.added, 0);
      expect(report.tooLarge, 1);
      expect(report.tooLargePaths, ['oversized.md']);
      expect(report.documents, 0);

      final engine = SearchSimpli.open(out.path);
      try {
        final result = engine.query('123456789', topK: 5, mode: RetrievalMode.lexical);
        expect(result.results, isEmpty);
      } finally {
        engine.close();
      }
    });

    test('maxTotalBytes caps files on a full rebuild', () {
      // Own plant: three ~41-byte files and a 50-byte budget, so only the
      // first (sorted by path) is read and the other two are left over.
      final folder = Directory.systemTemp.createTempSync('ss-dart-cap-total-');
      final out = Directory.systemTemp.createTempSync('ss-dart-cap-total-out-');
      out.deleteSync();
      addTearDown(() => folder.deleteSync(recursive: true));
      addTearDown(() {
        if (out.existsSync()) out.deleteSync(recursive: true);
      });
      for (final name in ['a.md', 'b.md', 'c.md']) {
        File('${folder.path}/$name').writeAsStringSync(
          '123456789\n123456789\n123456789\n123456789\na', // 41 bytes each
        );
      }

      final report = SearchSimpli.indexFolder(
        out.path,
        folder.path,
        options: const IndexFolderOptions(update: false, maxTotalBytes: 50),
      );

      expect(report.added, 1);
      expect(report.budgetExhausted, 2);
      expect(report.tooLarge, 0);
      expect(report.documents, greaterThanOrEqualTo(1));
    });
  });
}
