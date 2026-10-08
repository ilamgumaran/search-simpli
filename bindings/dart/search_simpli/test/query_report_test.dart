/// S2-T4 (contract 1.2.0): `warnings`, `request` and the opt-in `profile`
/// reach Dart typed, and `query(profile: ...)` sends the option.
library;

import 'dart:io';

import 'package:search_simpli/search_simpli.dart';
import 'package:test/test.dart';

const String _interchange =
    '{"format_version":1,"generation":1,"analyzer_id":"ascii-alnum-v1",'
    '"embedding_model_id":"none","documents":['
    '{"id":"a","path":"public/a.md","start_line":1,"end_line":1,'
    '"text":"hybrid retrieval ranks chunks","vector":[],"required_labels":[]},'
    '{"id":"b","path":"public/b.md","start_line":1,"end_line":1,'
    '"text":"hybrid search ranks","vector":[],"required_labels":[]},'
    '{"id":"c","path":"other/c.md","start_line":1,"end_line":1,'
    '"text":"hybrid zebra","vector":[],"required_labels":[]}'
    ']}';

void main() {
  late Directory dir;
  late SearchSimpli engine;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('ss-dart-report-');
    importSnapshotJson(dir.path, _interchange);
    engine = SearchSimpli.open(dir.path);
  });

  tearDown(() {
    engine.close();
    dir.deleteSync(recursive: true);
  });

  test('an unmatched word is a typed warning with its term', () {
    final result = engine.query('hybrid dinosaurus', topK: 5, mode: RetrievalMode.lexical);
    final warnings = result.warnings!;
    expect(warnings, hasLength(1));
    expect(warnings.single.code, SearchWarningCode.queryTermUnmatched);
    expect(warnings.single.term, 'dinosaurus');
    expect(result.profile, isNull);
  });

  test('a punctuation-only query is empty after analysis', () {
    final result = engine.query('?!', topK: 5, mode: RetrievalMode.lexical);
    expect(result.results, isEmpty);
    expect(result.warnings!.map((w) => w.code), [SearchWarningCode.queryEmptyAfterAnalysis]);
  });

  test('a vector passed in lexical mode is reported as ignored', () {
    final result = engine.query('hybrid', queryVector: [1.0, 0.0], topK: 5, mode: RetrievalMode.lexical);
    expect(result.warnings!.map((w) => w.code), [SearchWarningCode.vectorIgnored]);
  });

  test('a shallow candidate_k reports the cut', () {
    final result = engine.query('hybrid', topK: 1, candidateK: 2, mode: RetrievalMode.lexical);
    expect(result.warnings!.map((w) => w.code), [SearchWarningCode.candidateDepthCut]);
  });

  test('request echoes the defaults and the options used', () {
    final result = engine.query('hybrid', topK: 3, mode: RetrievalMode.lexical, pathPrefix: 'public/');
    final request = result.request!;
    expect(request.analyzerId, 'ascii-alnum-v1');
    expect(request.retrievalMode, RetrievalMode.lexical);
    expect(request.topK, 3);
    expect(request.candidateK, 100);
    expect(request.pathPrefix, 'public/');
    expect(engine.query('hybrid', topK: 3, mode: RetrievalMode.lexical).request!.pathPrefix, isNull);
  });

  test('profile appears only for profile: true', () {
    final off = engine.query('hybrid', topK: 3, mode: RetrievalMode.lexical);
    expect(off.profile, isNull);
    final on = engine.query('hybrid', topK: 3, mode: RetrievalMode.lexical, profile: true);
    expect(on.profile, isNotNull);
    expect(on.profile!.matchedChunks, 3);
    expect(on.profile!.tokenizeUs, greaterThanOrEqualTo(0));
    expect(on.profile!.serializeUs, greaterThanOrEqualTo(0));
    // The same results, with or without the profile.
    expect(on.results.map((r) => r.chunkId), off.results.map((r) => r.chunkId));
  });

  test('toJson round-trips the new fields', () {
    final result = engine.query('hybrid dinosaurus', topK: 3, mode: RetrievalMode.lexical, profile: true);
    final again = SearchKnowledgeResult.fromJson(result.toJson());
    expect(again.toJson(), result.toJson());
  });

  test('a result without the new keys (JSON-RPC shape) still parses', () {
    final result = engine.query('hybrid', topK: 3, mode: RetrievalMode.lexical);
    final json = {...result.toJson()}
      ..remove('warnings')
      ..remove('request');
    final old = SearchKnowledgeResult.fromJson(json);
    expect(old.warnings, isNull);
    expect(old.request, isNull);
    expect(old.profile, isNull);
  });
}
