/// Contract 2.0.0 parity (docs/tasks/S3-T4.md ruling 5): for every
/// family-folder judgment (phrase, prefix, outline, read_span) plus a
/// `list_files` and a `roots` call, the CLI's `--json` output, the RPC
/// server's `result` and the Dart binding's result are the same canonical
/// JSON (keys sorted). All three run over one index the binding publishes
/// with `applyChanges`; the CLI and the server are the real `searchd`
/// (`zig build`, Zig 0.16.0 on PATH, as the conformance test needs).
/// S3-T6 adds one request per method with no optional field.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:search_simpli/search_simpli.dart';
import 'package:test/test.dart';

import 'support/family_folder.dart';

/// One `searchd serve` process answering one request per line.
class RpcServer {
  final Process process;
  final List<Completer<Map<String, Object?>>> _waiting = [];
  int _id = 0;

  RpcServer._(this.process) {
    process.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
      _waiting.removeAt(0).complete(jsonDecode(line) as Map<String, Object?>);
    });
  }

  static Future<RpcServer> start(String binary, String index) async =>
      RpcServer._(await Process.start(binary, ['serve', index]));

  Future<Map<String, Object?>> result(String method, Map<String, Object?> params) async {
    final completer = Completer<Map<String, Object?>>();
    _waiting.add(completer);
    process.stdin.writeln(jsonEncode({'jsonrpc': '2.0', 'id': ++_id, 'method': method, 'params': params}));
    final response = await completer.future;
    if (!response.containsKey('result')) throw StateError('$method failed: $response');
    return response['result']! as Map<String, Object?>;
  }

  Future<void> stop() async {
    await process.stdin.close();
    await process.exitCode;
  }
}

void main() {
  final zigDir = p.join(repoRoot, 'zig');
  final searchd = p.join(zigDir, 'zig-out', 'bin', 'searchd');
  final judgments = loadJudgments();
  late Directory dir;
  late SearchSimpli engine;
  late RpcServer rpc;

  setUpAll(() async {
    final built = await Process.run('zig', ['build'], workingDirectory: zigDir);
    if (built.exitCode != 0) fail('zig build failed (is the pinned Zig 0.16.0 on PATH?):\n${built.stderr}');
    dir = publishFixture('ss-dart-parity-');
    engine = SearchSimpli.open(dir.path);
    rpc = await RpcServer.start(searchd, dir.path);
  });

  tearDownAll(() async {
    await rpc.stop();
    engine.close();
    dir.deleteSync(recursive: true);
  });

  Future<Map<String, Object?>> cli(List<String> args) async {
    final run = await Process.run(searchd, [...args, '--json']);
    expect(run.exitCode, 0, reason: '${run.stderr}');
    return jsonDecode(run.stdout as String) as Map<String, Object?>;
  }

  Future<void> same(String label, Map<String, Object?> fromCli, Map<String, Object?> fromRpc, Map<String, Object?> fromDart) async {
    expect(canonical(fromRpc), canonical(fromCli), reason: '$label: RPC vs CLI');
    expect(canonical(fromDart), canonical(fromCli), reason: '$label: Dart vs CLI');
  }

  test('CLI --json, RPC and Dart return the same canonical JSON for the fixture judgments', () async {
    var compared = 0;
    for (final raw in [...judgments['phrase']! as List<Object?>, ...judgments['prefix']! as List<Object?>]) {
      final j = raw! as Map<String, Object?>;
      final query = j['query']! as String;
      final mode = j['mode']! as String;
      await same(
        '${j['id']}',
        await cli(['find', dir.path, query, '--mode', mode, '--page-size', '100']),
        await rpc.result('find', {'query': query, 'mode': mode, 'page_size': 100}),
        engine.find(query, mode: FindMode.parse(mode), pageSize: 100).json,
      );
      compared++;
    }
    for (final raw in judgments['outline']! as List<Object?>) {
      final j = raw! as Map<String, Object?>;
      final rootId = j['root_id']! as String;
      final path = j['path']! as String;
      await same('${j['id']}', await cli(['outline', dir.path, rootId, path]),
          await rpc.result('outline', {'root_id': rootId, 'path': path}), engine.outline(rootId, path).json);
      compared++;
    }
    for (final raw in judgments['read_span']! as List<Object?>) {
      final j = raw! as Map<String, Object?>;
      final args = [j['root_id']! as String, j['path']! as String, j['start_line']! as int, j['end_line']! as int, j['context_lines']! as int];
      await same(
        '${j['id']}',
        await cli(['read-span', dir.path, '${args[0]}', '${args[1]}', '${args[2]}', '${args[3]}', '--context', '${args[4]}']),
        await rpc.result('read_span', {'root_id': args[0], 'path': args[1], 'start_line': args[2], 'end_line': args[3], 'context_lines': args[4]}),
        engine.readSpan(args[0] as String, args[1] as String, args[2] as int, args[3] as int, contextLines: args[4] as int).json,
      );
      compared++;
    }
    await same('list_files', await cli(['list-files', dir.path, '--page-size', '1000']),
        await rpc.result('list_files', {'page_size': 1000}), engine.listFiles(pageSize: 1000).json);
    await same('roots', await cli(['roots', dir.path]), await rpc.result('roots', {}), engine.roots().json);
    compared += 2;
    expect(compared, 25);
    // ignore: avoid_print
    print('S3-T4 parity: $compared requests, CLI --json = RPC = Dart (canonical JSON)');
  });

  // S3-T4 Verdict finding 1 (closed in S3-T6): one request per method that
  // states no optional field, so a surface that injects a different default
  // (a page size, a mode, a context) is caught.
  test('CLI --json, RPC and Dart agree with no optional fields', () async {
    final rootId = 'school';
    final path = 'science-notes.md';
    await same('find (defaults)', await cli(['find', dir.path, 'tide table']), await rpc.result('find', {'query': 'tide table'}),
        engine.find('tide table').json);
    await same('outline', await cli(['outline', dir.path, rootId, path]), await rpc.result('outline', {'root_id': rootId, 'path': path}),
        engine.outline(rootId, path).json);
    await same('read_span (defaults)', await cli(['read-span', dir.path, rootId, path, '40', '42']),
        await rpc.result('read_span', {'root_id': rootId, 'path': path, 'start_line': 40, 'end_line': 42}),
        engine.readSpan(rootId, path, 40, 42).json);
    await same('list_files (defaults)', await cli(['list-files', dir.path]), await rpc.result('list_files', {}), engine.listFiles().json);
    await same('roots (defaults)', await cli(['roots', dir.path]), await rpc.result('roots', {}), engine.roots().json);
  });
}
