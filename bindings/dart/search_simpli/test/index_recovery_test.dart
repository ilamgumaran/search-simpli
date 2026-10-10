/// S2-T12 criterion 3: `keepGenerations`, `recovered`, `prunedFiles` and
/// `pruneFailures` on the Dart index types. Reports below are captured
/// `searchd index --update` / `ss_index_folder` JSON.
library;

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:search_simpli/search_simpli.dart';
import 'package:test/test.dart';

const String _base =
    '"generation":3,"analyzer_id":"analyzer-v2","added":3,"changed":0,"removed":0,'
    '"unchanged":0,"budget_exhausted":0,"too_large":0,"unreadable":0,'
    '"too_large_paths":[],"unreadable_paths":[],"documents":3,"terms":9,"postings":12';

IndexFolderReport _parse(String extra) =>
    IndexFolderReport.fromJson(jsonDecode('{$_base$extra}') as Map<String, Object?>);

class _CountingAllocator implements Allocator {
  int allocations = 0;
  int live = 0;

  @override
  Pointer<T> allocate<T extends NativeType>(int byteCount, {int? alignment}) {
    allocations++;
    live++;
    return malloc.allocate<T>(byteCount, alignment: alignment);
  }

  @override
  void free(Pointer pointer) {
    live--;
    malloc.free(pointer);
  }
}

void main() {
  group('IndexFolderOptions.keepGenerations', () {
    test('serialises as keep_generations and is absent by default', () {
      expect(const IndexFolderOptions(keepGenerations: 2).toJson()['keep_generations'], 2);
      expect(const IndexFolderOptions().toJson().containsKey('keep_generations'), isFalse);
    });

    test('an invalid value allocates no native memory (S2-T14)', () {
      final counting = _CountingAllocator();
      expect(
        () => SearchSimpli.indexFolder('/nonexistent/out', '/nonexistent/in',
            options: const IndexFolderOptions(keepGenerations: 0),
            library: DynamicLibrary.process(),
            allocator: counting),
        throwsArgumentError,
      );
      expect(counting.allocations, 0);
      expect(counting.live, 0);
    });

    test('0 and negatives throw ArgumentError, before the native call', () {
      expect(() => const IndexFolderOptions(keepGenerations: 0).toJson(), throwsArgumentError);
      expect(
        () => SearchSimpli.indexFolder('/nonexistent/out', '/nonexistent/in',
            options: const IndexFolderOptions(keepGenerations: 0)),
        throwsArgumentError,
      );
      expect(() => const IndexFolderOptions(keepGenerations: -1).toJson(), throwsArgumentError);
    });
  });

  group('IndexFolderReport recovery and pruning fields (captured reports)', () {
    test('missing_manifest', () {
      final r = _parse(',"recovered":"missing_manifest"');
      expect(r.recovered, IndexRecovery.missingManifest);
      expect(r.recoveredRaw, 'missing_manifest');
      expect(r.prunedFiles, isNull);
      expect(r.pruneFailures, isNull);
    });

    test('missing_section with pruning counters', () {
      final r = _parse(',"recovered":"missing_section","pruned_files":6,"prune_failures":1');
      expect(r.recovered, IndexRecovery.missingSection);
      expect(r.prunedFiles, 6);
      expect(r.pruneFailures, 1);
    });

    test('an unknown recovered value falls back and keeps the raw string', () {
      final r = _parse(',"recovered":"something_new"');
      expect(r.recovered, IndexRecovery.unknown);
      expect(r.recoveredRaw, 'something_new');
      expect(r.toJson()['recovered'], 'something_new');
    });

    test('without any of the fields all three are null; pruning alone leaves recovered null', () {
      final plain = _parse('');
      expect(plain.recovered, isNull);
      expect(plain.recoveredRaw, isNull);
      expect(plain.prunedFiles, isNull);
      expect(plain.pruneFailures, isNull);
      expect(plain.toJson().containsKey('recovered'), isFalse);

      final pruned = _parse(',"pruned_files":0,"prune_failures":0');
      expect(pruned.recovered, isNull);
      expect(pruned.prunedFiles, 0);
      expect(pruned.pruneFailures, 0);
    });

    test('toJson/fromJson round-trips', () {
      final r = _parse(',"recovered":"missing_manifest","pruned_files":2,"prune_failures":0');
      final again = IndexFolderReport.fromJson(r.toJson());
      expect(again.toJson(), r.toJson());
    });
  });

  group('through the native library', () {
    late Directory folder;
    late Directory out;

    setUp(() {
      folder = Directory.systemTemp.createTempSync('ss-dart-recov-in-');
      out = Directory.systemTemp.createTempSync('ss-dart-recov-out-');
      for (final name in ['a', 'b', 'c']) {
        File('${folder.path}/$name.md').writeAsStringSync('$name evidence about recovery\n');
      }
    });
    tearDown(() {
      folder.deleteSync(recursive: true);
      out.deleteSync(recursive: true);
    });

    List<String> sections() => out
        .listSync()
        .map((e) => e.uri.pathSegments.where((s) => s.isNotEmpty).last)
        .where((n) => n.endsWith('.hybseg') || n.endsWith('.hyblex'))
        .toList()
      ..sort();

    test('keepGenerations reaches ss_index_folder and prunes', () {
      SearchSimpli.indexFolder(out.path, folder.path);
      SearchSimpli.indexFolder(out.path, folder.path);
      expect(sections().length, 4);
      final r = SearchSimpli.indexFolder(out.path, folder.path,
          options: const IndexFolderOptions(keepGenerations: 1));
      expect(r.generation, 3);
      expect(r.prunedFiles, 4);
      expect(r.pruneFailures, 0);
      expect(sections(), ['documents-3.hybseg', 'lexical-3.hyblex']);
      expect(SearchSimpli.indexFolder(out.path, folder.path).prunedFiles, isNull);
    });

    test('a deleted MANIFEST yields a full generation and recovered == missingManifest', () {
      const upd = IndexFolderOptions(update: true);
      SearchSimpli.indexFolder(out.path, folder.path, options: upd);
      File('${out.path}/MANIFEST').deleteSync();
      final r = SearchSimpli.indexFolder(out.path, folder.path,
          options: const IndexFolderOptions(update: true, keepGenerations: 1));
      expect(r.recovered, IndexRecovery.missingManifest);
      expect(r.documents, 3);
      expect(r.added, 3);
      expect(r.prunedFiles, isNotNull);
      final next = SearchSimpli.indexFolder(out.path, folder.path, options: upd);
      expect(next.recovered, isNull);
      expect(next.unchanged, 3);
    });
  });
}
