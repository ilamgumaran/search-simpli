// Android instrumentation smoke test (docs/tasks/S1-T2.md criterion 3):
// runs on a real device/emulator, loads libsearch_simpli.so through the
// example app, and checks it answered the one query with the expected
// document rather than merely "did not crash".
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:search_simpli/search_simpli.dart';
import 'package:search_simpli_example/main.dart' as app;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('loads libsearch_simpli.so and answers one query', (tester) async {
    app.main();
    await tester.pumpAndSettle(const Duration(seconds: 5));

    final textFinder = find.byKey(const Key('result-text'));
    expect(textFinder, findsOneWidget);

    final text = tester.widget<Text>(textFinder).data ?? '';
    expect(text, isNot(startsWith('FAIL')));
    expect(text, contains('contracts_version=1.0.0'));
    // Top hybrid result over the full 3-document demo snapshot (no
    // path_prefix filter, default candidate_k) — measured directly from a
    // real run on the emulator (docs/tasks/S1-T2.md's Report has the exact
    // command and output).
    expect(text, contains('chunk_id=lexical-guide'));
    expect(text, contains('path=guides/lexical.md'));
  });

  // docs/tasks/S1-T4.md criterion 1: SearchSimpli.indexFolder, exercised
  // end to end against the app's own private storage (not raw FFI, as the
  // S1-T3 tester's on-device probe was — this is the Dart binding itself).
  testWidgets('SearchSimpli.indexFolder indexes and publishes into private storage', (tester) async {
    final supportDir = await getApplicationSupportDirectory();

    final folderDir = Directory(p.join(supportDir.path, 'index_folder_test_source'));
    if (folderDir.existsSync()) folderDir.deleteSync(recursive: true);
    folderDir.createSync(recursive: true);
    File(p.join(folderDir.path, 'note.md')).writeAsStringSync(
      'hybrid ranking combines lexical and semantic evidence',
    );

    final outDir = Directory(p.join(supportDir.path, 'index_folder_test_out'));
    if (outDir.existsSync()) outDir.deleteSync(recursive: true);

    // First publish, with update:true so <dir>/INDEX-STATE.json is written
    // (a plain, non-update rebuild never writes it — docs/incremental-indexing.md):
    // publishes generation 1 into the app's own private files/ directory
    // (the same directory ss_import_json previously failed to write to with
    // AccessDenied before S1-T3's portable atomic publish fix —
    // docs/publication-recovery.md).
    final report = SearchSimpli.indexFolder(
      outDir.path,
      folderDir.path,
      options: const IndexFolderOptions(update: true),
    );
    expect(report.generation, 1);
    expect(report.added, 1);
    expect(report.documents, 1);
    expect(File(p.join(outDir.path, 'MANIFEST')).existsSync(), isTrue);

    final engine = SearchSimpli.open(outDir.path);
    try {
      final result = engine.query('hybrid', topK: 5, mode: RetrievalMode.lexical);
      expect(result.results, isNotEmpty);
      expect(result.results.first.citation.path, 'note.md');
    } finally {
      engine.close();
    }

    // A second, incremental publish into the same private directory --
    // generation 2, nothing re-chunked (docs/incremental-indexing.md).
    final updateReport = SearchSimpli.indexFolder(
      outDir.path,
      folderDir.path,
      options: const IndexFolderOptions(update: true),
    );
    expect(updateReport.generation, 2);
    expect(updateReport.unchanged, 1);
  });
}
