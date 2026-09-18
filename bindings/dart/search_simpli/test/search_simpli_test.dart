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
}
