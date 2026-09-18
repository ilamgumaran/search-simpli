// search_simpli example app (docs/tasks/S1-T2.md criterion 3): the Android
// instrumentation smoke test loads libsearch_simpli.so through this app and
// answers one query.
//
// The app bundles a tiny, already-published three-document demo snapshot
// (`assets/demo_snapshot/`, exactly what `searchd init-demo` writes — no
// family or real data, invented content only) as Flutter assets, copies its
// three files as plain bytes into its own app-support directory at
// startup, and calls `SearchSimpli.open`/`query`/`close` on the copy —
// proving the FFI path end to end (library load, ss_open, ss_query,
// ss_close) on a real published snapshot.
//
// This deliberately does NOT call `ss_import_json` on-device. It was tried
// first and failed on this API-34 (Android 14) emulator with
// `ss_import_json: AccessDenied`: Zig 0.16's `Dir.createFileAtomic` (used by the engine's
// atomic-publication path, `zig/src/publication.zig`) opens an `O_TMPFILE`
// descriptor on Linux targets before renaming it into place, and this
// device's SELinux policy denies `O_TMPFILE` inside an app's private
// `files/` directory (confirmed by reading
// `lib/std/Io/Threaded.zig`'s `dirCreateFileAtomic`: an `EACCES` from that
// `openat` call is returned as `error.AccessDenied` directly, with no
// fallback to a non-`O_TMPFILE` path). That is an engine/std-library
// question for `docs/tasks/S1-T0.md`'s ABI (`ss_import_json`), not
// something this binding can or should work around — this smoke test only
// needs to prove `ss_open`/`ss_query` load and answer correctly, which
// never writes, so it sidesteps the issue by shipping an
// already-published snapshot instead of publishing one on-device.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:search_simpli/search_simpli.dart';

const List<String> _demoSnapshotFiles = [
  'MANIFEST',
  'documents-1.hybseg',
  'lexical-1.hyblex',
];

void main() {
  runApp(const SearchSimpliExampleApp());
}

class SearchSimpliExampleApp extends StatelessWidget {
  const SearchSimpliExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'search_simpli example',
      home: const QueryScreen(),
    );
  }
}

class QueryScreen extends StatefulWidget {
  const QueryScreen({super.key});

  @override
  State<QueryScreen> createState() => _QueryScreenState();
}

class _QueryScreenState extends State<QueryScreen> {
  String _status = 'running query…';

  @override
  void initState() {
    super.initState();
    _runOneQuery();
  }

  Future<void> _runOneQuery() async {
    try {
      final supportDir = await getApplicationSupportDirectory();
      if (!supportDir.existsSync()) {
        supportDir.createSync(recursive: true);
      }
      final snapshotDir = Directory(p.join(supportDir.path, 'search_simpli_demo_snapshot'));
      if (snapshotDir.existsSync()) {
        snapshotDir.deleteSync(recursive: true);
      }
      snapshotDir.createSync(recursive: true);

      for (final name in _demoSnapshotFiles) {
        final bytes = await rootBundle.load('assets/demo_snapshot/$name');
        await File(p.join(snapshotDir.path, name))
            .writeAsBytes(bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes));
      }

      final engine = SearchSimpli.open(snapshotDir.path);
      try {
        final result = engine.query(
          'hybrid ranking',
          queryVector: [1.0, 0.0],
          topK: 1,
          mode: RetrievalMode.hybrid,
        );
        if (result.results.isEmpty) {
          setState(() => _status = 'FAIL: no results');
          return;
        }
        final hit = result.results.first;
        setState(() {
          _status = 'contracts_version=${SearchSimpli.contractsVersion} '
              'chunk_id=${hit.chunkId} path=${hit.citation.path} '
              'content="${hit.content}"';
        });
      } finally {
        engine.close();
      }
    } catch (e) {
      setState(() => _status = 'FAIL: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('search_simpli example')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text(_status, key: const Key('result-text')),
        ),
      ),
    );
  }
}
