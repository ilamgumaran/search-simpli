/// Conformance test (docs/tasks/S1-T2.md criterion 2): the Dart FFI binding
/// must produce the same top-k as (a) the Python reference and (b) the
/// `searchd` CLI, on every fixture that has judged queries, plus (c) the
/// exact S1-T0 ABI harness golden (`zig/tests/abi_test.c`) — the golden the
/// Dart binding must also reproduce byte for byte, since `ss_query` shares
/// its JSON-writing code with the JSON-RPC service (see
/// `zig/include/search_simpli.h`'s "JSON shapes" section).
///
/// (a) is checked against `fixtures/bm25-golden.json`, generated directly
/// from the real `search_platform.core.build_index`/`core.search`
/// (`scripts/gen_bm25_golden.py`) — the same golden `zig/src/
/// bm25_conformance_test.zig` uses for S1-T1's own Python-vs-Zig
/// conformance, so this test proves the *binding* reproduces what the
/// *engine* already proved matches Python, rather than re-deriving that
/// proof (running `python3 search.py` again here would only re-check S1-T1's
/// engine-level claim, not anything specific to the FFI layer).
///
/// (b) is checked by shelling out to the real `searchd` binary
/// (`zig build`) and parsing its `query --top-k 1 --json` output.
///
/// Requires the pinned Zig 0.16.0 toolchain on `PATH` (`zig build` in
/// `setUpAll` builds `searchd` and the ABI library fresh if not already
/// built/cached).
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:search_simpli/search_simpli.dart';
import 'package:test/test.dart';

/// Golden JSON literals copied verbatim from `zig/tests/abi_test.c`
/// (captured from a real `searchd init-demo` + `searchd serve` session —
/// see `docs/tasks/S1-T0.md`'s Report for the exact commands). Kept as
/// plain strings, not re-derived, so a change to either abi_test.c's golden
/// or this test independently shows up as a diff against the same source of
/// truth.
const String demoInterchangeJson =
    '{"format_version":1,"generation":1,"analyzer_id":"ascii-alnum-v1",'
    '"embedding_model_id":"manual-demo-vectors-v1","documents":['
    '{"id":"hybrid-guide","path":"guides/hybrid.md","start_line":1,"end_line":6,'
    '"text":"hybrid retrieval combines lexical and semantic ranks with reciprocal rank fusion",'
    '"vector":[0.9,0.1],"required_labels":[]},'
    '{"id":"lexical-guide","path":"guides/lexical.md","start_line":10,"end_line":12,'
    '"text":"BM25 is an exact lexical ranking function",'
    '"vector":[0.1,0.9],"required_labels":[]},'
    '{"id":"semantic-guide","path":"guides/semantic.md","start_line":20,"end_line":22,'
    '"text":"meaning based retrieval finds paraphrases",'
    '"vector":[1,0],"required_labels":[]}'
    ']}';

const String goldenStatusJson =
    '{"ready":true,"generation":1,"analyzer_id":"ascii-alnum-v1",'
    '"embedding_model_id":"manual-demo-vectors-v1","vector_dimensions":2,'
    '"documents":3,"terms":21,"postings":23}';

/// S5-T2 (contract 2.3.0): the title field adds a part to guides/hybrid.md,
/// whose stem is the query word "hybrid" (its lexical rank and score and the
/// fused score changed), and the result gains `retrieval.title_policy_id`
/// and `ranking.title`; every other byte is the S1-T0 capture
/// (`zig/tests/abi_test.c`'s golden).
const String goldenQueryResultJson =
    '{"tool":"search_knowledge","query":"hybrid ranking","index":{"version":2,'
    '"generation":1,"analyzer_id":"ascii-alnum-v1","embedding_model_id":"manual-demo-vectors-v1"},'
    '"retrieval":{"mode":"hybrid","vector_dimensions":2,"authorization":{'
    '"semantics":"all-required-labels-v1","principal_label_count":0},'
    '"title_policy_id":"title-field-v1"},'
    '"results":[{"chunk_id":"hybrid-guide","citation":{"path":"guides/hybrid.md",'
    '"start_line":1,"end_line":6},"content":"hybrid retrieval combines lexical and semantic '
    'ranks with reciprocal rank fusion","score":0.032522473484277725,"ranking":{"lexical":{'
    '"rank":1,"score":2.0587539672851562},"vector":{"rank":2,"score":0.9938837289810181},'
    '"title":{"score":1.2260364294052124}}}],'
    '"answer_policy":{"ground_in_results":true,"cite_path_and_lines":true,'
    '"say_when_evidence_is_insufficient":true}}';

/// Contract 1.2.0 appends `warnings` and `request` to `ss_query`'s report.
/// The demo query's vector channel offers 3 candidates against `candidate_k` 2.
const String goldenQueryTail =
    ',"warnings":[{"code":"candidate_depth_cut","message":'
    '"candidate_k 2 kept 2 of 3 vector candidates"}],'
    '"request":{"analyzer_id":"ascii-alnum-v1","retrieval_mode":"hybrid",'
    '"top_k":1,"candidate_k":2,"path_prefix":"guides/"}}';

const String goldenEvidenceFoundJson =
    '[{"chunk_id":"hybrid-guide","citation":{"path":"guides/hybrid.md",'
    '"start_line":1,"end_line":6},"content":"hybrid retrieval combines lexical and semantic '
    'ranks with reciprocal rank fusion"}]';

const String goldenEvidenceMissingJson = '[{"chunk_id":"missing-id","found":false}]';

/// Contract 2.0.0 tails, copied from `zig/tests/abi_test.c`.
const String goldenStatusTail =
    ',"files":3,"pending":0,"truncated":false,"roots":[{"root_id":"r-legacy",'
    '"label":"folder","kind":"local","files":3,"documents":3,"pending":0}],'
    '"pending_paths":[],"has_source":false,"has_positions":false,"chunkers":["line-window-v1"],"source":"absent"}';
const String goldenEvidenceTail = ',"root_id":"r-legacy","section_path":[],"neighbours":{"prev":null,"next":null}}]';

void main() {
  final packageRoot = Directory.current.path;
  final repoRoot = p.normalize(p.join(packageRoot, '..', '..', '..'));
  final zigDir = p.join(repoRoot, 'zig');
  final searchdBin = p.join(zigDir, 'zig-out', 'bin', 'searchd');

  setUpAll(() async {
    final result = await Process.run('zig', ['build'], workingDirectory: zigDir);
    if (result.exitCode != 0) {
      fail('zig build failed (is the pinned Zig 0.16.0 on PATH?):\n'
          '${result.stdout}\n${result.stderr}');
    }
    if (!File(searchdBin).existsSync()) {
      fail('searchd binary not found at $searchdBin after zig build');
    }
  });

  group('S1-T0 ABI harness golden (zig/tests/abi_test.c)', () {
    test('ss_import_json + ss_open + ss_status/ss_query/ss_evidence match abi_test.c byte for byte', () {
      final dir = Directory.systemTemp.createTempSync('ss-dart-abi-golden-');
      addTearDown(() => dir.deleteSync(recursive: true));

      final generation = importSnapshotJson(dir.path, demoInterchangeJson);
      expect(generation, 1);

      final engine = SearchSimpli.open(dir.path);
      addTearDown(engine.close);

      // Contract 2.0.0 appends the section 8 status fields after the v1
      // ones (the same tail zig/tests/abi_test.c checks).
      expect(jsonEncode(engine.status().toJson()),
          goldenStatusJson.substring(0, goldenStatusJson.length - 1) + goldenStatusTail);

      final result = engine.query(
        'hybrid ranking',
        queryVector: [1.0, 0.0],
        topK: 1,
        mode: RetrievalMode.hybrid,
        candidateK: 2,
        pathPrefix: 'guides/',
      );
      final shared = goldenQueryResultJson.substring(0, goldenQueryResultJson.length - 1);
      expect(jsonEncode(result.toJson()), shared + goldenQueryTail);
      // The shared fields alone are the S1-T0 golden, unchanged.
      expect(jsonEncode(SearchKnowledgeResult.fromJson(
        {...result.toJson()}..remove('warnings')..remove('request'),
      ).toJson()), goldenQueryResultJson);

      final found = engine.evidence(['hybrid-guide']);
      expect(jsonEncode(found.map((e) => e.toJson()).toList()),
          goldenEvidenceFoundJson.substring(0, goldenEvidenceFoundJson.length - 2) + goldenEvidenceTail);

      final missing = engine.evidence(['missing-id']);
      expect(jsonEncode(missing.map((e) => e.toJson()).toList()), goldenEvidenceMissingJson);
    });
  });

  group('BM25 conformance vs Python reference (fixtures/bm25-golden.json) and the searchd CLI', () {
    final goldenFile = File(p.join(repoRoot, 'fixtures', 'bm25-golden.json'));
    final golden = jsonDecode(goldenFile.readAsStringSync()) as Map<String, Object?>;

    final corpora = <String, ({String root, String analyzer})>{
      'app_text': (root: p.join(repoRoot, 'fixtures', 'app-text'), analyzer: 'v2'),
      'tamil': (root: p.join(repoRoot, 'fixtures', 'tamil', 'passages'), analyzer: 'v2'),
    };

    for (final corpusName in corpora.keys) {
      final spec = corpora[corpusName]!;
      final queries = (golden[corpusName]! as List<Object?>).cast<Map<String, Object?>>();

      test('$corpusName (analyzer-${spec.analyzer}): ${queries.length} queries, top-1 identical to Python and to the CLI', () async {
        final snapshotDir = Directory.systemTemp.createTempSync('ss-dart-bm25-$corpusName-');
        addTearDown(() => snapshotDir.deleteSync(recursive: true));

        final indexResult = await Process.run(searchdBin, [
          'index',
          spec.root,
          '--out',
          snapshotDir.path,
          '--analyzer',
          spec.analyzer,
        ]);
        expect(indexResult.exitCode, 0, reason: 'searchd index failed: ${indexResult.stderr}');

        final engine = SearchSimpli.open(snapshotDir.path);
        addTearDown(engine.close);

        var compared = 0;
        var titled = 0;
        for (final entry in queries) {
          final queryText = entry['query']! as String;
          final ranking = (entry['ranking']! as List<Object?>).cast<Map<String, Object?>>();
          if (ranking.isEmpty) continue;
          final expectedTop = ranking.first;
          final expectedPath = expectedTop['path']! as String;

          // (a) Python reference, via the pre-generated golden fixture.
          final ffiResult = engine.query(queryText, topK: 1, mode: RetrievalMode.lexical);
          expect(
            ffiResult.results, isNotEmpty,
            reason: 'no FFI results for "$queryText" in $corpusName',
          );
          // S3-T1: md-section-v1 makes exact BM25 ties (files whose first
          // section is the same title line). The engines break ties
          // differently on purpose (Zig by document index, Python by chunk
          // id), so the FFI top-1 may be any path the reference scored equal
          // to its top (same rule as zig/src/bm25_conformance_test.zig).
          // S5-T2: the golden is plain BM25 (generated at title weight 0).
          // When the FFI top-1 carries no title part its score is its plain
          // body score and every other score only grew, so it is the plain
          // top-1 too; when it carries one, the title field may have moved
          // it, and only the CLI agreement below applies.
          if (ffiResult.results.first.titleScore != null) {
            titled++;
          } else {
            final expectedScore = (expectedTop['lexical_score']! as num).toDouble();
            final tiedTopPaths = ranking
                .takeWhile((item) => ((item['lexical_score']! as num).toDouble() - expectedScore).abs() < 1e-4)
                .map((item) => item['path']! as String)
                .toSet();
            expect(
              tiedTopPaths,
              contains(ffiResult.results.first.citation.path),
              reason: 'FFI top-1 path mismatch vs Python reference for "$queryText" in $corpusName (expected $expectedPath)',
            );
          }

          // (b) The searchd CLI, over the same published snapshot.
          final cliResult = await Process.run(searchdBin, [
            'query',
            snapshotDir.path,
            queryText,
            '--top-k',
            '1',
            '--json',
          ]);
          expect(cliResult.exitCode, 0, reason: 'searchd query failed: ${cliResult.stderr}');
          final cliJson = jsonDecode(cliResult.stdout as String) as Map<String, Object?>;
          final cliResults = (cliJson['results']! as List<Object?>).cast<Map<String, Object?>>();
          expect(cliResults, isNotEmpty, reason: 'no CLI results for "$queryText" in $corpusName');
          final cliTop = cliResults.first;

          expect(
            ffiResult.results.first.chunkId,
            cliTop['chunk_id'],
            reason: 'FFI/CLI chunk_id mismatch for "$queryText" in $corpusName',
          );
          expect(
            ffiResult.results.first.citation.path,
            cliTop['path'],
            reason: 'FFI/CLI path mismatch for "$queryText" in $corpusName',
          );
          expect(
            ffiResult.results.first.score,
            closeTo((cliTop['score']! as num).toDouble(), 1e-9),
            reason: 'FFI/CLI score mismatch for "$queryText" in $corpusName',
          );

          compared++;
        }

        expect(compared, queries.length);
        // Printed so the task Report can paste a real "N queries compared,
        // N identical" line, same convention as
        // `zig/src/bm25_conformance_test.zig`'s own summary line.
        // ignore: avoid_print
        print('$corpusName conformance: $compared queries compared, ${compared - titled} identical to the plain-BM25 Python top-1 '
            '($titled with a title part at top-1, compared with the CLI only), $compared identical to the CLI top-1');
      });
    }
  });
}
