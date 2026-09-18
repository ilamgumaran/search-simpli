// Android instrumentation smoke test (docs/tasks/S1-T2.md criterion 3):
// runs on a real device/emulator, loads libsearch_simpli.so through the
// example app, and checks it answered the one query with the expected
// document rather than merely "did not crash".
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
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
}
