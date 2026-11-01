/// S2-T1 (contract 1.1.0): `SnapshotInterchangeV1.analyzer` takes both
/// values of the schema's `analyzer_id` enum, and `analyzer-v2` reaches the
/// native import: a Tamil passage published through `importSnapshotJson` is
/// found, where `ascii-alnum-v1` indexes no terms for it.
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:search_simpli/search_simpli.dart';
import 'package:test/test.dart';

final String _repoRoot = p.normalize(
  p.join(Directory.current.path, '..', '..', '..'),
);

SnapshotInterchangeV1 _tamilSnapshot(InterchangeAnalyzer analyzer) {
  final passages =
      Directory(p.join(_repoRoot, 'fixtures', 'tamil', 'passages'))
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.md'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
  return SnapshotInterchangeV1(
    generation: 1,
    analyzer: analyzer,
    embeddingModelId: 'none',
    documents: [
      for (final file in passages)
        SnapshotInterchangeDocument(
          id: p.basenameWithoutExtension(file.path),
          path: p.basename(file.path),
          startLine: 1,
          endLine: file.readAsLinesSync().length,
          text: file.readAsStringSync(),
        ),
    ],
  );
}

void main() {
  test('InterchangeAnalyzer ids are exactly the schema enum', () {
    final schema = jsonDecode(
      File(p.join(_repoRoot, 'contracts', 'snapshot-interchange.schema.json'))
          .readAsStringSync(),
    ) as Map<String, Object?>;
    final analyzerId =
        (schema['properties']! as Map<String, Object?>)['analyzer_id']!
            as Map<String, Object?>;
    expect(
      analyzerId['enum'],
      InterchangeAnalyzer.values.map((v) => v.id).toList(),
    );
  });

  test(
    'toJson/fromJson round-trip both analyzer values; others are rejected',
    () {
      for (final analyzer in InterchangeAnalyzer.values) {
        final snapshot = SnapshotInterchangeV1(
          generation: 3,
          analyzer: analyzer,
          embeddingModelId: 'none',
          documents: [
            SnapshotInterchangeDocument(
              id: 'a',
              path: 'a.md',
              startLine: 1,
              endLine: 2,
              text: 'café',
            ),
          ],
        );
        final json =
            jsonDecode(jsonEncode(snapshot.toJson())) as Map<String, Object?>;
        expect(json['analyzer_id'], analyzer.id);
        final back = SnapshotInterchangeV1.fromJson(json);
        expect(back.analyzer, analyzer);
        expect(back.documents.single.text, 'café');
        expect(jsonEncode(back.toJson()), jsonEncode(snapshot.toJson()));
      }
      expect(
        InterchangeAnalyzer.fromId('ascii-alnum-v1'),
        InterchangeAnalyzer.asciiAlnumV1,
      );
      expect(
        InterchangeAnalyzer.fromId('analyzer-v2'),
        InterchangeAnalyzer.analyzerV2,
      );
      for (final bad in ['v2', 'analyzer-v1', 'other', '']) {
        expect(() => InterchangeAnalyzer.fromId(bad), throwsArgumentError);
      }
    },
  );

  test('keepGenerations is optional, validated, and round-trips beside the analyzer', () {
    final schema = jsonDecode(
      File(p.join(_repoRoot, 'contracts', 'snapshot-interchange.schema.json'))
          .readAsStringSync(),
    ) as Map<String, Object?>;
    expect(
      (schema['properties']! as Map<String, Object?>).containsKey(
        'keep_generations',
      ),
      isTrue,
    );
    const v2 = InterchangeAnalyzer.analyzerV2;
    expect(
      _tamilSnapshot(v2).toJson().containsKey('keep_generations'),
      isFalse,
    );
    final snapshot = SnapshotInterchangeV1(
      generation: 1,
      analyzer: v2,
      embeddingModelId: 'none',
      keepGenerations: 2,
    );
    final json = snapshot.toJson();
    expect(json['analyzer_id'], 'analyzer-v2');
    expect(json['keep_generations'], 2);
    expect(SnapshotInterchangeV1.fromJson(json).keepGenerations, 2);
    expect(
      () => SnapshotInterchangeV1(
        generation: 1,
        analyzer: v2,
        embeddingModelId: 'none',
        keepGenerations: 0,
      ),
      throwsArgumentError,
    );
  });

  test('V1 keeps its exact wire shape and V2 round-trips the frozen filename policy', () {
    final v1 = SnapshotInterchangeV1(
      generation: 1,
      analyzer: InterchangeAnalyzer.analyzerV2,
      embeddingModelId: 'none',
    );
    expect(v1.toJson().keys, [
      'format_version',
      'generation',
      'analyzer_id',
      'embedding_model_id',
      'documents',
    ]);
    expect(v1.toJson()['format_version'], 1);

    final v2 = SnapshotInterchangeV2(
      generation: 4,
      analyzer: InterchangeAnalyzer.analyzerV2,
      embeddingModelId: 'none',
      keepGenerations: 2,
      documents: [
        SnapshotInterchangeDocument(
          id: 'anchor',
          path: 'src/readme.md',
          startLine: 1,
          endLine: 2,
          text: 'filename navigation',
          requiredLabels: ['team'],
        ),
      ],
    );
    final json = jsonDecode(jsonEncode(v2.toJson())) as Map<String, Object?>;
    expect(json['format_version'], 2);
    expect(json['filename_policy_id'], 'filename-field-v1');
    final back = SnapshotInterchangeV2.fromJson(json);
    expect(back.toJson(), v2.toJson());
    expect(
      () => SnapshotInterchangeV2.fromJson({
        ...json,
        'filename_policy_id': 'other',
      }),
      throwsArgumentError,
    );
  });

  test(
    'filename option and status field keep their legacy defaults compact',
    () {
      expect(
        const IndexFolderOptions().toJson().containsKey('filename_index'),
        isFalse,
      );
      expect(
        const IndexFolderOptions(filenameIndex: true)
            .toJson()['filename_index'],
        isTrue,
      );
      final legacyStatus = SnapshotStatus.fromJson({
        'ready': true,
        'generation': 1,
        'analyzer_id': 'analyzer-v2',
        'embedding_model_id': 'none',
        'vector_dimensions': 0,
        'documents': 1,
        'terms': 2,
        'postings': 2,
      });
      expect(legacyStatus.filenamePolicyId, isNull);
      expect(legacyStatus.toJson().containsKey('filename_policy_id'), isFalse);
      final status = SnapshotStatus.fromJson({
        ...legacyStatus.toJson(),
        'filename_policy_id': 'filename-field-v1',
      });
      expect(status.filenamePolicyId, 'filename-field-v1');
      expect(status.toJson()['filename_policy_id'], 'filename-field-v1');
    },
  );

  group('importSnapshotJson with the Tamil fixture', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('ss-dart-s2t1-'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('analyzer-v2 indexes Tamil and records analyzer-v2', () {
      final json = jsonEncode(
        _tamilSnapshot(InterchangeAnalyzer.analyzerV2).toJson(),
      );
      expect(importSnapshotJson(dir.path, json), 1);
      final engine = SearchSimpli.open(dir.path);
      addTearDown(engine.close);
      final status = engine.status();
      expect(status.analyzerId, 'analyzer-v2');
      expect(status.terms, greaterThan(0));
      final result = engine.query('யானை', topK: 3, mode: RetrievalMode.lexical);
      expect(result.results, isNotEmpty);
      expect(result.results.first.citation.path, 'passage-04-animals.md');
    });

    test('ascii-alnum-v1 still imports, with no Tamil terms (unchanged)', () {
      final json = jsonEncode(
        _tamilSnapshot(InterchangeAnalyzer.asciiAlnumV1).toJson(),
      );
      expect(importSnapshotJson(dir.path, json), 1);
      final engine = SearchSimpli.open(dir.path);
      addTearDown(engine.close);
      expect(engine.status().analyzerId, 'ascii-alnum-v1');
      expect(engine.status().terms, 0);
      expect(
        engine.query('யானை', topK: 3, mode: RetrievalMode.lexical).results,
        isEmpty,
      );
    });
  });
}
