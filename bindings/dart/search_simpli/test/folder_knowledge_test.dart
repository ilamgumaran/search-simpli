/// Contract 2.0.0 (docs/tasks/S3-T4.md ruling 2): `find`, `outline`,
/// `readSpan`, `listFiles`, `roots` and the static `applyChanges`, through
/// the native library on the family-folder fixture; typed results and the
/// refusals' codes.
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:search_simpli/search_simpli.dart';
import 'package:test/test.dart';

import 'support/family_folder.dart';

bool _overlaps(FindHit hit, Map<String, Object?> expected) =>
    hit.rootId == expected['root_id'] &&
    hit.path == expected['path'] &&
    hit.startLine <= (expected['end_line']! as int) &&
    (expected['start_line']! as int) <= hit.endLine;

void main() {
  late Directory dir;
  late SearchSimpli engine;
  final judgments = loadJudgments();

  setUpAll(() {
    dir = publishFixture('ss-dart-folder-');
    engine = SearchSimpli.open(dir.path);
  });

  tearDownAll(() {
    engine.close();
    dir.deleteSync(recursive: true);
  });

  test('find pages every phrase and prefix judgment to its complete set', () {
    for (final raw in [...judgments['phrase']! as List<Object?>, ...judgments['prefix']! as List<Object?>]) {
      final judgment = raw! as Map<String, Object?>;
      final expected = (judgment['expected']! as List<Object?>).cast<Map<String, Object?>>();
      final misses = ((judgment['expected_engine_miss'] as List<Object?>?) ?? const []).cast<Map<String, Object?>>();
      final hits = <FindHit>[];
      String? cursor;
      late FindResult page;
      do {
        page = engine.find(judgment['query']! as String,
            mode: FindMode.parse(judgment['mode']! as String), pageSize: 2, cursor: cursor);
        expect(page.hits.length, lessThanOrEqualTo(2));
        expect(page.empty, page.hits.isEmpty);
        hits.addAll(page.hits);
        cursor = page.nextCursor;
      } while (cursor != null);
      final id = judgment['id'];
      expect(hits.length, page.files.fold<int>(0, (sum, f) => sum + f.hits), reason: '$id');
      for (final item in expected) {
        if (misses.any((m) => m['path'] == item['path'] && m['start_line'] == item['start_line'])) continue;
        expect(hits.any((h) => _overlaps(h, item)), isTrue, reason: '$id misses $item');
      }
      for (final hit in hits) {
        expect(expected.any((e) => _overlaps(hit, e)), isTrue, reason: '$id: unexpected ${hit.rootId}/${hit.path}:${hit.startLine}');
        expect(hit.matchOffsets, isNotEmpty);
        expect(hit.snippet.runes.length, lessThanOrEqualTo(240));
      }
      if (judgment['mode'] == 'phrase') expect(page.exactMatch, hits.isNotEmpty);
    }
  });

  test('find: typed hit, envelope, scope by roots, refusals with codes', () {
    final result = engine.find('"count me in"');
    expect(result.request['mode'], 'phrase');
    expect(result.generation, 1);
    expect(result.scope.roots, ['home', 'laptop', 'school']);
    expect(result.scope.labelsApplied, isTrue);
    expect(result.warnings, isEmpty);
    expect(result.exactMatch, isTrue);
    expect(result.coverageFiles, 3);
    final school = result.hits.singleWhere((h) => h.rootId == 'school');
    expect(school.sectionPath, ['Class notes', 'Week 7', 'Dates']);
    expect(school.matchOffsets.first.end, greaterThan(school.matchOffsets.first.start));
    final narrowed = engine.find('tide table', roots: ['school']);
    expect(narrowed.hits.map((h) => h.rootId).toSet(), {'school'});
    expect(narrowed.request['roots'], ['school']);
    expect(engine.find('tide table', roots: ['nowhere']).hits, isEmpty);
    final prefixed = engine.find('tide table', pathPrefix: 'trips/');
    expect(prefixed.hits.map((h) => h.path).toSet(), {'trips/seaside-weekend.md'});

    for (final call in <(String, void Function())>[
      ('empty query', () => engine.find('   ')),
      ('stray star', () => engine.find('ti*de table')),
      ('page size', () => engine.find('tide', pageSize: 101)),
      ('stale cursor', () => engine.find('tide', cursor: '99:0')),
    ]) {
      expect(call.$2, throwsA(isA<SearchSimpliException>().having((e) => e.code, 'code', 'SS_ERR_INVALID_ARGUMENT')), reason: call.$1);
    }
  });

  test('a generation without positions or source answers CAPACITY', () {
    final legacy = Directory.systemTemp.createTempSync('ss-dart-legacy-');
    addTearDown(() => legacy.deleteSync(recursive: true));
    importSnapshotJson(legacy.path,
        '{"format_version":1,"generation":1,"analyzer_id":"analyzer-v2","embedding_model_id":"none","documents":['
        '{"id":"a","path":"a.md","start_line":1,"end_line":1,"text":"exact lexical words","vector":[],"required_labels":[]}]}');
    final old = SearchSimpli.open(legacy.path);
    addTearDown(old.close);
    expect(old.find('lexical').hits.single.rootId, 'r-legacy');
    expect(() => old.find('"exact lexical"'),
        throwsA(isA<SearchSimpliException>().having((e) => e.code, 'code', 'SS_ERR_CAPACITY').having((e) => e.message, 'message', contains('positions absent'))));
    expect(() => old.readSpan('r-legacy', 'a.md', 1, 1),
        throwsA(isA<SearchSimpliException>().having((e) => e.code, 'code', 'SS_ERR_CAPACITY').having((e) => e.message, 'message', contains('source absent'))));
    expect(() => old.outline('r-legacy', 'a.md'), throwsA(isA<SearchSimpliException>().having((e) => e.code, 'code', 'SS_ERR_CAPACITY')));
  });

  test('a damaged source section surfaces at the first read, not at open (contract 2.1.0, S4-T1)', () {
    final damaged = publishFixture('ss-dart-damaged-');
    addTearDown(() => damaged.deleteSync(recursive: true));
    final section = damaged.listSync().whereType<File>().singleWhere((f) => p.basename(f.path).startsWith('source-'));
    final bytes = section.readAsBytesSync();
    bytes[bytes.length - 2] ^= 0x01; // a byte of the last file's text: only the checksum can see it
    section.writeAsBytesSync(bytes, flush: true);

    final opened = SearchSimpli.open(damaged.path); // the open does not read the section
    addTearDown(opened.close);
    expect(opened.status().source, 'unverified');
    expect(opened.find('tide table').hits, isNotEmpty);
    expect(() => opened.readSpan('home', 'garden.md', 1, 1),
        throwsA(isA<SearchSimpliException>()
            .having((e) => e.code, 'code', 'SS_ERR_CAPACITY')
            .having((e) => e.message, 'message', contains('source section unavailable'))));
    expect(opened.status().source, 'unavailable');
    expect(() => opened.outline('home', 'garden.md'), throwsA(isA<SearchSimpliException>().having((e) => e.code, 'code', 'SS_ERR_CAPACITY')));

    expect(engine.status().source, anyOf('unverified', 'verified'));
    engine.readSpan('home', 'garden.md', 1, 1);
    expect(engine.status().source, 'verified');
  });

  test('outline reproduces every outline judgment', () {
    for (final raw in judgments['outline']! as List<Object?>) {
      final judgment = raw! as Map<String, Object?>;
      final got = engine.outline(judgment['root_id']! as String, judgment['path']! as String);
      expect(jsonEncode(got.json['headings']), jsonEncode(judgment['headings']), reason: '${judgment['id']}');
      if (judgment.containsKey('front_matter')) {
        expect(jsonEncode(got.json['front_matter']), jsonEncode(judgment['front_matter']), reason: '${judgment['id']}');
      }
    }
    final science = engine.outline('school', 'science-notes.md');
    expect(science.frontMatter!.fields['title'], 'Science notes');
    expect(science.headings.first, isA<OutlineHeading>().having((h) => h.level, 'level', 1));
    expect(science.lines, 74);
    expect(science.chunker, 'md-section-v1');
    expect(() => engine.outline('school', 'nope.md'),
        throwsA(isA<SearchSimpliException>().having((e) => e.code, 'code', 'SS_ERR_NOT_FOUND')));
  });

  test('readSpan is byte exact for every read_span judgment; caps and clamping', () {
    for (final raw in judgments['read_span']! as List<Object?>) {
      final judgment = raw! as Map<String, Object?>;
      final span = engine.readSpan(judgment['root_id']! as String, judgment['path']! as String,
          judgment['start_line']! as int, judgment['end_line']! as int,
          contextLines: judgment['context_lines']! as int);
      expect(utf8.encode(span.text).length, judgment['byte_length'], reason: '${judgment['id']}');
      expect(span.sha256, judgment['sha256'], reason: '${judgment['id']}');
      expect(span.byteExact, isTrue);
    }
    final crlf = engine.readSpan('home', 'crlf-shopping.md', 3, 3, contextLines: 1);
    expect(crlf.text, endsWith('\r\n'));
    expect(crlf.contextBefore, endsWith('\r\n'));
    final clamped = engine.readSpan('school', 'science-notes.md', 73, 99);
    expect(clamped.endLine, 74);
    expect(clamped.warnings.single.code, 'end_line_clamped');
    expect(() => engine.readSpan('laptop', 'big-log.txt', 21, 381, contextLines: 20),
        throwsA(isA<SearchSimpliException>().having((e) => e.code, 'code', 'SS_ERR_CAPACITY').having((e) => e.message, 'message', contains('401 lines'))));
    expect(() => engine.readSpan('school', 'notes.md', 1, 1, contextLines: 21),
        throwsA(isA<SearchSimpliException>().having((e) => e.code, 'code', 'SS_ERR_INVALID_ARGUMENT')));
  });

  test('listFiles pages and filters; roots counts', () {
    final all = engine.listFiles(pageSize: 1000);
    expect(all.total, 42);
    expect(all.nextCursor, isNull);
    final collected = <ListedFile>[];
    String? cursor;
    do {
      final page = engine.listFiles(pageSize: 7, cursor: cursor);
      collected.addAll(page.files);
      cursor = page.nextCursor;
    } while (cursor != null);
    expect(collected.map((f) => '${f.rootId}/${f.path}').toList(), all.files.map((f) => '${f.rootId}/${f.path}').toList());
    final big = all.files.singleWhere((f) => f.path == 'big-log.txt');
    expect(big.size, File(p.join(packDir, 'laptop', 'big-log.txt')).lengthSync());
    expect(big.status, FileStatus.indexed);
    expect(big.mtimeMs, isNull);
    final empty = all.files.singleWhere((f) => f.path == 'empty.txt');
    expect(empty.chunks, 0);
    expect(empty.chunker, isNull);
    expect(engine.listFiles(rootId: 'home', pathPrefix: 'recipes/').files.every((f) => f.path.startsWith('recipes/')), isTrue);
    expect(engine.listFiles(status: FileStatus.pending).total, 0);
    expect(() => engine.listFiles(cursor: '5:0'), throwsA(isA<SearchSimpliException>().having((e) => e.message, 'message', contains('stale cursor'))));

    final roots = engine.roots();
    expect(roots.roots.map((r) => r.rootId), ['home', 'laptop', 'school']);
    expect(roots.roots.fold<int>(0, (sum, r) => sum + r.files), 42);
    expect(engine.roots(roots: ['school']).roots.single.label, 'School');

    final status = engine.status();
    expect(status.files, 42);
    expect(status.roots!.length, 3);
    expect(status.hasSource, isTrue);
    expect(status.hasPositions, isTrue);
    expect(status.chunkers, ['line-window-v1', 'md-section-v1']);
  });

  test('query and evidence take roots; evidence names section and neighbours', () {
    final school = engine.query('tide table', topK: 5, mode: RetrievalMode.lexical, roots: ['school']);
    expect(school.results, isNotEmpty);
    expect(school.results.every((r) => r.citation.path.startsWith('school/')), isTrue);
    final hit = engine.find('"count me in"', roots: ['school']).hits.single;
    final item = engine.evidence([hit.chunkId]).single;
    expect(item.rootId, 'school');
    expect(item.sectionPath, ['Class notes', 'Week 7', 'Dates']);
    expect(item.neighbours!.prev, isNotNull);
    expect(engine.evidence([hit.chunkId], roots: ['home']).single.found, isFalse);
  });

  test('host-fed filename index retains S3 and recovers without its state cache', () {
    final host = Directory.systemTemp.createTempSync('ss-dart-host-filename-');
    addTearDown(() => host.deleteSync(recursive: true));
    SearchSimpli.applyChanges(host.path, {
      'roots': [
        {'root_id': 'phone', 'kind': 'host'}
      ],
      'changes': [
        {'op': 'add', 'root_id': 'phone', 'path': 'Lighthouse.md',
          'content_base64': base64Encode(utf8.encode('exact coastal words\n'))},
        {'op': 'pending', 'root_id': 'phone', 'path': 'later.md', 'size': 9},
      ],
    }, options: const ApplyChangesOptions(filenameIndex: true));
    final first = SearchSimpli.open(host.path);
    try {
      expect(first.status().pending, 1);
      final hit = first.query('lighthouse', mode: RetrievalMode.lexical,
          searchField: SearchField.filename).results.single;
      expect(hit.citation.path, 'phone/Lighthouse.md');
      expect(first.find('"exact coastal"').hits, hasLength(1));
      expect(first.readSpan('phone', 'Lighthouse.md', 1, 1).text,
          'exact coastal words\n');
    } finally {
      first.close();
    }
    File(p.join(host.path, 'INDEX-STATE.json')).deleteSync();
    final report = SearchSimpli.applyChanges(host.path, {
      'expect_generation': 1,
      'changes': [
        {'op': 'change', 'root_id': 'phone', 'path': 'Lighthouse.md',
          'content_base64': base64Encode(utf8.encode('updated coastal words\n'))},
      ],
    });
    expect(report.generation, 2);
    final recovered = SearchSimpli.open(host.path);
    addTearDown(recovered.close);
    expect(recovered.status().pending, 1);
    expect(recovered.query('lighthouse', mode: RetrievalMode.lexical,
        searchField: SearchField.filename).results.single.citation.path,
        'phone/Lighthouse.md');
    expect(recovered.find('"updated coastal"').hits, hasLength(1));
  });

  test('applyChanges publishes, refuses a stale generation and file reads by default', () {
    final copy = Directory.systemTemp.createTempSync('ss-dart-apply-');
    addTearDown(() => copy.deleteSync(recursive: true));
    final first = SearchSimpli.applyChanges(copy.path, {
      'roots': [
        {'root_id': 'notes', 'kind': 'host'}
      ],
      'changes': [
        {'op': 'add', 'root_id': 'notes', 'path': 'a.md', 'content_base64': base64Encode(utf8.encode('# A\n\nalpha beta\n'))},
        {'op': 'pending', 'root_id': 'notes', 'path': 'b.md', 'size': 9},
      ],
    });
    expect((first.generation, first.added, first.pending), (1, 1, 1));
    expect(() => SearchSimpli.applyChanges(copy.path, {'expect_generation': 0, 'changes': []}),
        throwsA(isA<SearchSimpliException>().having((e) => e.code, 'code', 'SS_ERR_INVALID_ARGUMENT').having((e) => e.message, 'message', contains('stale: generation is 1'))));
    final file = File(p.join(copy.path, '..', 'ss-dart-apply-source.md'))..writeAsStringSync('gamma\n');
    addTearDown(() => file.deleteSync());
    final request = {
      'roots': [
        {'root_id': 'desk', 'kind': 'local', 'path': p.normalize(file.parent.absolute.path)}
      ],
      'changes': [
        {'op': 'add', 'root_id': 'desk', 'path': p.basename(file.path), 'file': p.normalize(file.absolute.path), 'sha256': '0' * 64}
      ],
    };
    expect(() => SearchSimpli.applyChanges(copy.path, request),
        throwsA(isA<SearchSimpliException>().having((e) => e.message, 'message', contains('file reads are not enabled'))));
    final second = SearchSimpli.applyChanges(copy.path, {'expect_generation': 1, 'changes': [
      {'op': 'remove', 'root_id': 'notes', 'path': 'a.md'}
    ]});
    expect((second.generation, second.removed), (2, 1));
    final reopened = SearchSimpli.open(copy.path);
    addTearDown(reopened.close);
    expect(reopened.listFiles().files.single.status, FileStatus.pending);
  });
}
