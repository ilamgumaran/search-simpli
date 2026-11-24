// S6-T24 verifier probe (Verdict 2): the Dart binding's `scan` on the requests `probe_interfaces.py` sends.
//
// Usage (from a package whose pubspec depends on bindings/dart/search_simpli by path, with
// SEARCH_SIMPLI_LIBRARY_PATH naming the dylib): dart run bin/scan_probe.dart INDEX REQUESTS.json
// Prints one JSON line per request: {"ok": <the result object as the engine wrote it>} or {"refused": message}.
// Every typed field is read too (ScanResult.fromJson does), so a field the binding cannot parse fails here.
import 'dart:convert';
import 'dart:io';

import 'package:search_simpli/search_simpli.dart';

void main(List<String> args) {
  final engine = SearchSimpli.open(args[0]);
  final requests = (jsonDecode(File(args[1]).readAsStringSync()) as List).cast<Map<String, Object?>>();
  for (final r in requests) {
    try {
      final result = engine.scan(
        r['pattern']! as String,
        mode: r['mode'] == null ? null : ScanMode.values.firstWhere((m) => m.wire == r['mode']),
        caseMode: r['case'] == null ? null : ScanCase.parse(r['case']! as String),
        wholeWord: r['whole_word'] as bool?,
        roots: (r['roots'] as List?)?.cast<String>(),
        pathPrefix: r['path_prefix'] as String?,
        nameGlob: r['name_glob'] as String?,
        contextLines: r['context_lines'] as int?,
        maxHitsPerFile: r['max_hits_per_file'] as int?,
        pageSize: r['page_size'] as int?,
        cursor: r['cursor'] as String?,
        timeBudgetMs: r['time_budget_ms'] as int?,
      );
      final typed = result.hits.map((h) => [h.text, h.textTruncated, h.matchOffsets.length]).toList();
      stdout.writeln(jsonEncode({'ok': result.json, 'typed_hits': typed.length, 'stopped': result.stopped.wire}));
    } on SearchSimpliException catch (e) {
      stdout.writeln(jsonEncode({'refused': e.message}));
    }
  }
  engine.close();
}
