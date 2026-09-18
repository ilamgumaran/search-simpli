/// Dart FFI bindings for Search Simpli's C ABI (`ss_*`,
/// `zig/include/search_simpli.h`, ADR 0002 / docs/tasks/S1-T2.md).
///
/// ```dart
/// import 'package:search_simpli/search_simpli.dart';
///
/// final engine = SearchSimpli.open('/path/to/published-snapshot');
/// final result = engine.query('how does hybrid ranking work', topK: 3);
/// for (final hit in result.results) {
///   print('${hit.citation.path}:${hit.citation.startLine} ${hit.content}');
/// }
/// engine.close();
/// ```
///
/// See the package README for setup (native library packaging on macOS and
/// Android) and `example/` for a minimal Flutter app.
library;

export 'src/contracts.dart';
export 'src/contracts_version.dart' show expectedContractsVersion;
export 'src/library_loader.dart' show openSearchSimpliLibrary;
export 'src/search_simpli_base.dart'
    show
        SearchSimpli,
        SearchSimpliException,
        ContractsVersionMismatchException,
        importSnapshotJson;
