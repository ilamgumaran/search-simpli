// A calling program's everyday use of the Dart binding, against the invented
// household folder: index it (with the file-name channel), search content,
// file names and both, find, read the cited span, update after a change.
//
// Run by run_scenarios.py, which copies this package to the scratch folder
// and points its path dependency at the binding.
// Usage: dart run bin/probe.dart <household-folder> <index-dir>
import 'dart:convert';
import 'dart:io';

import 'package:search_simpli/search_simpli.dart';

void line(String name, Object? value) => stdout.writeln(jsonEncode({'probe': name, 'value': value}));

void main(List<String> args) {
  final folder = args[0];
  final indexDir = args[1];
  final report = SearchSimpli.indexFolder(indexDir, folder, options: const IndexFolderOptions(filenameIndex: true));
  line('index', {'generation': report.generation, 'added': report.added, 'tooLarge': report.tooLarge, 'unreadable': report.unreadable});
  final engine = SearchSimpli.open(indexDir);
  try {
    final content = engine.query('leaky faucet', topK: 2, mode: RetrievalMode.lexical);
    line('content', content.results.map((r) => '${r.citation.path}:${r.citation.startLine}-${r.citation.endLine}').toList());
    final top = content.results.first;
    final span = engine.readSpan('r-legacy', top.citation.path, top.citation.startLine, top.citation.endLine);
    line('span_has_faucet', span.text.contains('faucet'));
    final file = File('$folder/${top.citation.path}').readAsLinesSync();
    final expected = file.sublist(top.citation.startLine - 1, top.citation.endLine).join('\n');
    line('span_equals_file_lines', span.text.trimRight() == expected.trimRight());
    final byName = engine.query('plumber', topK: 2, mode: RetrievalMode.lexical, searchField: SearchField.filename);
    line('filename', byName.results.map((r) => r.citation.path).toList());
    final both = engine.query('lentil', topK: 2, mode: RetrievalMode.lexical, searchField: SearchField.both);
    line('both', both.results.map((r) => [r.citation.path, r.matchedIn]).toList());
    final tamil = engine.query('தோசை', topK: 1, mode: RetrievalMode.lexical);
    line('tamil', tamil.results.map((r) => r.citation.path).toList());
    final found = engine.find('"compost bin"');
    line('find_phrase', found.hits.map((h) => '${h.path}:${h.startLine}-${h.endLine}').toList());
    final none = engine.query('zzqqxx', topK: 3, mode: RetrievalMode.lexical);
    line('no_answer', none.results.length);
    try {
      engine.query('faucet', mode: RetrievalMode.lexical, searchField: SearchField.filename, profile: true);
      line('filename_profile', 'accepted');
    } on ArgumentError catch (error) {
      line('filename_profile', 'ArgumentError: ${error.message}');
    }
    try {
      engine.readSpan('r-legacy', 'no-such-file.txt', 1, 1);
      line('missing_span', 'accepted');
    } on SearchSimpliException catch (error) {
      line('missing_span', error.message);
    }
  } finally {
    engine.close();
  }
  File('$folder/notes/added-by-dart.txt').writeAsStringSync('The marmalade jar lid is stuck.\n');
  final update = SearchSimpli.indexFolder(indexDir, folder, options: const IndexFolderOptions(update: true));
  line('update', {'generation': update.generation, 'added': update.added, 'changed': update.changed});
  final reopened = SearchSimpli.open(indexDir);
  try {
    line('after_update', reopened.query('marmalade', mode: RetrievalMode.lexical).results.map((r) => r.citation.path).toList());
  } finally {
    reopened.close();
  }
}
