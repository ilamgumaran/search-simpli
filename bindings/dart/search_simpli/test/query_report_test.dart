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
    '"text":"hybrid Zebra","vector":[],"required_labels":[]}'
    ']}';

/// Contract 2.4.0 (S5-T3): fuzzy-v1 runs on analyzer-v2 indexes only.
const String _interchangeV2 =
    '{"format_version":1,"generation":1,"analyzer_id":"analyzer-v2",'
    '"embedding_model_id":"none","documents":['
    '{"id":"a","path":"public/a.md","start_line":1,"end_line":1,'
    '"text":"the dinosaur museum","vector":[],"required_labels":[]},'
    '{"id":"b","path":"public/b.md","start_line":1,"end_line":1,'
    '"text":"dinosaurs and a tournament","vector":[],"required_labels":[]}'
    ']}';

/// Contract 2.6.0 (S5-T5): fold-groups-v2's verb forms.
const String _interchangeVerbs =
    '{"format_version":1,"generation":1,"analyzer_id":"analyzer-v2",'
    '"embedding_model_id":"none","documents":['
    '{"id":"a","path":"public/a.md","start_line":1,"end_line":1,'
    '"text":"we went dancing on friday","vector":[],"required_labels":[]},'
    '{"id":"b","path":"public/b.md","start_line":1,"end_line":1,'
    '"text":"the painted gate","vector":[],"required_labels":[]},'
    '{"id":"c","path":"public/c.md","start_line":1,"end_line":1,'
    '"text":"painting the fence","vector":[],"required_labels":[]},'
    '{"id":"d","path":"private/d.md","start_line":1,"end_line":1,'
    '"text":"secret dancers","vector":[],"required_labels":["tenant:x"]}'
    ']}';

/// Contract 2.7.0 (S5-T8): fold-groups-v3 and fuzzy-v2.
const String _interchangeV3 =
    '{"format_version":1,"generation":1,"analyzer_id":"analyzer-v2",'
    '"embedding_model_id":"none","documents":['
    '{"id":"a","path":"public/a.md","start_line":1,"end_line":1,'
    '"text":"we hoped for sun","vector":[],"required_labels":[]},'
    '{"id":"b","path":"public/b.md","start_line":1,"end_line":1,'
    '"text":"the rabbit hopped away","vector":[],"required_labels":[]},'
    '{"id":"c","path":"public/c.md","start_line":1,"end_line":1,'
    '"text":"the heating system","vector":[],"required_labels":[]}'
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
    final result = engine.query(
      'hybrid dinosaurus',
      topK: 5,
      mode: RetrievalMode.lexical,
    );
    final warnings = result.warnings!;
    expect(warnings, hasLength(1));
    expect(warnings.single.code, SearchWarningCode.queryTermUnmatched);
    expect(warnings.single.term, 'dinosaurus');
    expect(result.profile, isNull);
  });

  test('a punctuation-only query is empty after analysis', () {
    final result = engine.query('?!', topK: 5, mode: RetrievalMode.lexical);
    expect(result.results, isEmpty);
    expect(result.warnings!.map((w) => w.code), [
      SearchWarningCode.queryEmptyAfterAnalysis,
    ]);
  });

  test('a vector passed in lexical mode is reported as ignored', () {
    final result = engine.query(
      'hybrid',
      queryVector: [1.0, 0.0],
      topK: 5,
      mode: RetrievalMode.lexical,
    );
    expect(result.warnings!.map((w) => w.code), [
      SearchWarningCode.vectorIgnored,
    ]);
  });

  test('a shallow candidate_k on one channel does not warn', () {
    // No vectors in this snapshot: hybrid is one channel, and the cut cannot
    // change the list (the two-channel case is the conformance golden).
    final hybrid = engine.query(
      'hybrid',
      topK: 1,
      candidateK: 2,
      mode: RetrievalMode.hybrid,
    );
    expect(hybrid.warnings, isEmpty);
    final lexical = engine.query(
      'hybrid',
      topK: 1,
      candidateK: 2,
      mode: RetrievalMode.lexical,
    );
    expect(lexical.warnings, isEmpty);
  });

  test('a word hidden by the path prefix is reported like an absent word', () {
    final result = engine.query(
      'Zebra zzmiss',
      topK: 5,
      mode: RetrievalMode.lexical,
      pathPrefix: 'public/',
      profile: true,
    );
    expect(result.warnings!.map((w) => (w.code, w.message, w.term)), [
      (
        SearchWarningCode.queryTermUnmatched,
        'the term was not found in the searched files',
        'zebra',
      ),
      (
        SearchWarningCode.queryTermUnmatched,
        'the term was not found in the searched files',
        'zzmiss',
      ),
    ]);
    expect(result.profile!.matchedChunks, 0);
  });

  test('request echoes the defaults and the options used', () {
    final result = engine.query(
      'hybrid',
      topK: 3,
      mode: RetrievalMode.lexical,
      pathPrefix: 'public/',
    );
    final request = result.request!;
    expect(request.analyzerId, 'ascii-alnum-v1');
    expect(request.retrievalMode, RetrievalMode.lexical);
    expect(request.topK, 3);
    expect(request.candidateK, 100);
    expect(request.pathPrefix, 'public/');
    expect(
      engine
          .query('hybrid', topK: 3, mode: RetrievalMode.lexical)
          .request!
          .pathPrefix,
      isNull,
    );
  });

  test('profile appears only for profile: true', () {
    final off = engine.query('hybrid', topK: 3, mode: RetrievalMode.lexical);
    expect(off.profile, isNull);
    final on = engine.query(
      'hybrid',
      topK: 3,
      mode: RetrievalMode.lexical,
      profile: true,
    );
    expect(on.profile, isNotNull);
    expect(on.profile!.matchedChunks, 3);
    expect(on.profile!.tokenizeUs, greaterThanOrEqualTo(0));
    expect(on.profile!.serializeUs, greaterThanOrEqualTo(0));
    // The same results, with or without the profile.
    expect(on.results.map((r) => r.chunkId), off.results.map((r) => r.chunkId));
  });

  test('toJson round-trips the new fields', () {
    final result = engine.query(
      'hybrid dinosaurus',
      topK: 3,
      mode: RetrievalMode.lexical,
      profile: true,
    );
    final again = SearchKnowledgeResult.fromJson(result.toJson());
    expect(again.toJson(), result.toJson());
  });

  test('contract 2.3.0: the title policy and the title part round-trip', () {
    // The folder name "public" is a title word of a.md and b.md: each takes
    // a part inside its lexical score; c.md (folder "other") takes none.
    final result = engine.query('hybrid public', topK: 3, mode: RetrievalMode.lexical);
    expect(result.retrieval.titlePolicyId, 'title-field-v1');
    expect(result.results.map((r) => r.citation.path).take(2).toSet(), {'public/a.md', 'public/b.md'});
    for (final item in result.results) {
      final lexical = (item.ranking['lexical']! as Map<String, Object?>)['score']! as num;
      if (item.citation.path.startsWith('public/')) {
        expect(item.titleScore, isNotNull);
        expect(lexical.toDouble(), greaterThan(item.titleScore!));
      } else {
        expect(item.titleScore, isNull);
        expect(item.ranking.containsKey('title'), isFalse);
      }
    }
    expect(
      SearchKnowledgeResult.fromJson(result.toJson()).toJson(),
      result.toJson(),
    );
    // A title-only match: no body word, cited at the file's first chunk.
    final titleOnly = engine.query('public', topK: 3, mode: RetrievalMode.lexical);
    expect(titleOnly.results.map((r) => r.citation.path).toSet(), {'public/a.md', 'public/b.md'});
    for (final item in titleOnly.results) {
      final lexical = (item.ranking['lexical']! as Map<String, Object?>)['score']! as num;
      expect(lexical.toDouble(), item.titleScore);
    }
  });

  test('filename query fields round-trip, while legacy JSON omits them', () {
    final legacy = engine.query('hybrid', topK: 2, mode: RetrievalMode.lexical);
    expect(legacy.retrieval.toJson().containsKey('search_field'), isFalse);
    expect(
      legacy.results.every((r) => r.matchedIn == null && r.basename == null),
      isTrue,
    );
    expect(
      legacy.answerPolicy.toJson().containsKey(
        'filename_matches_are_navigation',
      ),
      isFalse,
    );

    final result = SearchKnowledgeResult.fromJson({
      ...legacy.toJson(),
      'retrieval': {
        ...legacy.retrieval.toJson(),
        'search_field': 'both',
        'filename_policy_id': 'filename-field-v1',
      },
      'results': [
        {
          ...legacy.results.first.toJson(),
          'matched_in': ['filename'],
          'basename': 'README',
        },
      ],
      'answer_policy': {
        ...legacy.answerPolicy.toJson(),
        'filename_matches_are_navigation': true,
      },
    });
    expect(result.retrieval.searchField, SearchField.both);
    expect(result.retrieval.filenamePolicyId, 'filename-field-v1');
    expect(result.results.single.matchedIn, ['filename']);
    expect(result.results.single.basename, 'README');
    expect(result.answerPolicy.filenameMatchesAreNavigation, isTrue);
    expect(
      SearchKnowledgeResult.fromJson(result.toJson()).toJson(),
      result.toJson(),
    );
  });

  test(
    'filename search requires explicit lexical mode and forbids profile',
    () {
      expect(
        () => engine.query('hybrid', searchField: SearchField.filename),
        throwsArgumentError,
      );
      expect(
        () => engine.query(
          'hybrid',
          mode: RetrievalMode.hybrid,
          searchField: SearchField.both,
        ),
        throwsArgumentError,
      );
      expect(
        () => engine.query(
          'hybrid',
          mode: RetrievalMode.lexical,
          searchField: SearchField.filename,
          profile: true,
        ),
        throwsArgumentError,
      );
    },
  );

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
  test('contract 2.4.0: an ascii-alnum-v1 index is never expanded', () {
    final result = engine.query('hybrid', topK: 3, mode: RetrievalMode.lexical);
    expect(result.retrieval.fuzzyPolicyId, isNull);
    expect(result.retrieval.toJson().containsKey('fuzzy_policy_id'), isFalse);
  });

  group('contract 2.4.0 on an analyzer-v2 index', () {
    late Directory v2Dir;
    late SearchSimpli v2;

    setUp(() {
      v2Dir = Directory.systemTemp.createTempSync('ss-dart-fuzzy-');
      importSnapshotJson(v2Dir.path, _interchangeV2);
      v2 = SearchSimpli.open(v2Dir.path);
    });

    tearDown(() {
      v2.close();
      v2Dir.deleteSync(recursive: true);
    });

    test('a misspelt word is unmatched, then expanded, and finds the word', () {
      final result = v2.query(
        'tournamnet dinosuar',
        topK: 5,
        mode: RetrievalMode.lexical,
      );
      expect(result.retrieval.fuzzyPolicyId, 'fuzzy-v2');
      // A record compares a list by identity: the expansions are joined.
      expect(
        result.warnings!.map((w) => (w.code, w.term, w.expansions?.join(','))),
        [
          (SearchWarningCode.queryTermUnmatched, 'tournamnet', null),
          (SearchWarningCode.queryTermExpanded, 'tournamnet', 'tournament'),
          (SearchWarningCode.queryTermUnmatched, 'dinosuar', null),
          (
            SearchWarningCode.queryTermExpanded,
            'dinosuar',
            'dinosaur,dinosaurs',
          ),
        ],
      );
      expect(result.warnings![3].message, 'also searched: dinosaur, dinosaurs');
      expect(result.results.first.citation.path, 'public/b.md');
      expect(
        SearchKnowledgeResult.fromJson(result.toJson()).toJson(),
        result.toJson(),
      );
      expect(
        SearchWarning.fromJson(result.warnings![1].toJson()),
        result.warnings![1],
      );
    });

    test('a word held in scope is not expanded', () {
      final result = v2.query('dinosaur', topK: 5, mode: RetrievalMode.lexical);
      // Contract 2.5.0: no expansion; it is grouped with its plural instead.
      expect(
        result.warnings!.map((w) => w.code),
        [SearchWarningCode.queryTermGrouped],
      );
      expect(result.retrieval.fuzzyPolicyId, 'fuzzy-v2');
    });
  });

  test('contract 2.5.0: an ascii-alnum-v1 index is never grouped', () {
    final result = engine.query('hybrid', topK: 3, mode: RetrievalMode.lexical);
    expect(result.retrieval.foldPolicyId, isNull);
    expect(result.retrieval.toJson().containsKey('fold_policy_id'), isFalse);
  });

  group('contract 2.5.0 on an analyzer-v2 index', () {
    late Directory v2Dir;
    late SearchSimpli v2;

    setUp(() {
      v2Dir = Directory.systemTemp.createTempSync('ss-dart-fold-');
      importSnapshotJson(v2Dir.path, _interchangeV2);
      v2 = SearchSimpli.open(v2Dir.path);
    });

    tearDown(() {
      v2.close();
      v2Dir.deleteSync(recursive: true);
    });

    test('a plural no file holds is unmatched, then grouped with its singular', () {
      final result = v2.query(
        'tournaments museum dinosaur',
        topK: 5,
        mode: RetrievalMode.lexical,
      );
      expect(result.retrieval.foldPolicyId, 'fold-groups-v3');
      // A record compares a list by identity: the members are joined.
      expect(
        result.warnings!.map((w) => (w.code, w.term, w.members?.join(','))),
        [
          (SearchWarningCode.queryTermUnmatched, 'tournaments', null),
          (SearchWarningCode.queryTermGrouped, 'tournaments', 'tournament'),
          (SearchWarningCode.queryTermGrouped, 'dinosaur', 'dinosaurs'),
        ],
      );
      expect(result.warnings![1].message, 'also searched as: tournament');
      expect(result.warnings![1].expansions, isNull);
      // a holds dinosaur and museum; b the tournament and the dinosaurs.
      expect(result.results.map((r) => r.citation.path), [
        'public/a.md',
        'public/b.md',
      ]);
      expect(
        SearchKnowledgeResult.fromJson(result.toJson()).toJson(),
        result.toJson(),
      );
      expect(
        SearchWarning.fromJson(result.warnings![2].toJson()),
        result.warnings![2],
      );
    });

    test('a word with no other form keeps its old report', () {
      final result = v2.query('museum', topK: 5, mode: RetrievalMode.lexical);
      expect(result.warnings, isEmpty);
      expect(result.retrieval.foldPolicyId, 'fold-groups-v3');
    });
  });

  group('contract 2.6.0: verb forms on an analyzer-v2 index', () {
    late Directory verbsDir;
    late SearchSimpli verbs;

    setUp(() {
      verbsDir = Directory.systemTemp.createTempSync('ss-dart-verbs-');
      importSnapshotJson(verbsDir.path, _interchangeVerbs);
      verbs = SearchSimpli.open(verbsDir.path);
    });

    tearDown(() {
      verbs.close();
      verbsDir.deleteSync(recursive: true);
    });

    test('a verb form no file holds is unmatched, then grouped with the forms the files hold', () {
      final result = verbs.query('danced', topK: 5, mode: RetrievalMode.lexical);
      expect(result.retrieval.foldPolicyId, 'fold-groups-v3');
      expect(
        result.warnings!.map((w) => (w.code, w.term, w.members?.join(','))),
        [
          (SearchWarningCode.queryTermUnmatched, 'danced', null),
          (SearchWarningCode.queryTermGrouped, 'danced', 'dancing'),
        ],
      );
      expect(result.results.map((r) => r.citation.path), ['public/a.md']);
    });

    test('a held word is grouped with a form no more common than itself', () {
      final result = verbs.query('painting', topK: 5, mode: RetrievalMode.lexical);
      expect(
        result.warnings!.map((w) => (w.code, w.term, w.members?.join(','))),
        [(SearchWarningCode.queryTermGrouped, 'painting', 'painted')],
      );
      expect(result.results.map((r) => r.citation.path), ['public/c.md', 'public/b.md']);
    });
  });

  group('contract 2.7.0: fold-groups-v3 and fuzzy-v2 on an analyzer-v2 index', () {
    late Directory v3Dir;
    late SearchSimpli v3;

    setUp(() {
      v3Dir = Directory.systemTemp.createTempSync('ss-dart-v3-');
      importSnapshotJson(v3Dir.path, _interchangeV3);
      v3 = SearchSimpli.open(v3Dir.path);
    });

    tearDown(() {
      v3.close();
      v3Dir.deleteSync(recursive: true);
    });

    test('hopping is grouped with hopped, not with hope\'s hoped', () {
      final result = v3.query('hopping', topK: 5, mode: RetrievalMode.lexical);
      expect(result.retrieval.foldPolicyId, 'fold-groups-v3');
      expect(
        result.warnings!.map((w) => (w.code, w.term, w.members?.join(','))),
        [
          (SearchWarningCode.queryTermUnmatched, 'hopping', null),
          (SearchWarningCode.queryTermGrouped, 'hopping', 'hopped'),
        ],
      );
      expect(result.results.map((r) => r.citation.path), ['public/b.md']);
    });

    test('a short misspelling two edits away with another opening is not expanded', () {
      // sistems is 7 code points; system is two edits away and opens sy, not si.
      final result = v3.query('sistems', topK: 5, mode: RetrievalMode.lexical);
      expect(result.retrieval.fuzzyPolicyId, 'fuzzy-v2');
      expect(
        result.warnings!.map((w) => (w.code, w.term)),
        [(SearchWarningCode.queryTermUnmatched, 'sistems')],
      );
      expect(result.results, isEmpty);
    });
  });
}
