/// `SearchSimpli`: the Dart-facing wrapper over the generated FFI bindings
/// (`bindings_generated.dart`) in `lib/src/bindings_generated.dart`.
/// docs/tasks/S1-T2.md criterion 1.
library;

import 'dart:convert';
import 'dart:ffi';

import 'package:ffi/ffi.dart';

import 'bindings_generated.dart';
import 'contracts.dart';
import 'contracts_version.dart';
import 'library_loader.dart';

/// Thrown when an `ss_*` call fails. [message] is `ss_last_error()` at the
/// time of failure (see `zig/include/search_simpli.h`'s error convention).
class SearchSimpliException implements Exception {
  final String message;
  const SearchSimpliException(this.message);

  @override
  String toString() => 'SearchSimpliException: $message';
}

/// Thrown by [SearchSimpli.open] when the native library's
/// `ss_version()` does not match [expectedContractsVersion] — the binding
/// and the engine it was generated from have drifted apart.
class ContractsVersionMismatchException implements Exception {
  final String expected;
  final String actual;
  const ContractsVersionMismatchException(this.expected, this.actual);

  @override
  String toString() => 'ContractsVersionMismatchException: '
      'this search_simpli package expects contracts version "$expected" '
      'but the native library reports "$actual" — rebuild the library '
      '(tool/build_native.sh) or update this package.';
}

/// A handle on one published Search Simpli snapshot directory
/// (`ss_open`/`ss_close`), and the query/evidence/status operations over it
/// (`ss_query`/`ss_evidence`/`ss_status`).
///
/// Not thread-safe to close concurrently with any other call on the same
/// instance (matches `search_simpli.h`'s `ss_close` contract); concurrent
/// reads (`query`/`evidence`/`status`) from multiple isolates are fine as
/// long as each isolate has its own `SearchSimpli` instance opened on its
/// own `DynamicLibrary` (FFI handles cannot cross an isolate boundary).
class SearchSimpli {
  final SearchSimpliBindings _bindings;
  final Pointer<ss_handle> _handle;
  bool _closed = false;

  SearchSimpli._(this._bindings, this._handle);

  /// The `contracts/CONTRACTS_VERSION` this package was generated against.
  static const String contractsVersion = expectedContractsVersion;

  /// Opens the published snapshot directory at [snapshotDir] (as written by
  /// `searchd index`/`searchd import-json`/`ss_import_json`).
  ///
  /// Loads the native library via [library] if given, otherwise via
  /// [openSearchSimpliLibrary] (see that function's doc comment for the
  /// resolution order on each platform). Asserts the opened library's
  /// `ss_version()` equals [contractsVersion] (docs/tasks/S1-T2.md
  /// criterion 4) before doing anything else — throws
  /// [ContractsVersionMismatchException] on a mismatch, without touching
  /// [snapshotDir] at all.
  ///
  /// Throws [SearchSimpliException] if `ss_open` fails (missing/corrupt
  /// snapshot, I/O error, out of memory — see `ss_last_error()`).
  factory SearchSimpli.open(String snapshotDir, {DynamicLibrary? library}) {
    final dylib = library ?? openSearchSimpliLibrary();
    final bindings = SearchSimpliBindings(dylib);

    final actualVersion = bindings.ss_version().cast<Utf8>().toDartString();
    if (actualVersion != expectedContractsVersion) {
      throw ContractsVersionMismatchException(expectedContractsVersion, actualVersion);
    }

    final pathPtr = snapshotDir.toNativeUtf8();
    try {
      final handle = bindings.ss_open(pathPtr.cast());
      if (handle == nullptr) {
        throw SearchSimpliException(_lastError(bindings));
      }
      return SearchSimpli._(bindings, handle);
    } finally {
      malloc.free(pathPtr);
    }
  }

  static String _lastError(SearchSimpliBindings bindings) =>
      bindings.ss_last_error().cast<Utf8>().toDartString();

  void _checkOpen() {
    if (_closed) {
      throw StateError('search_simpli: this SearchSimpli was already closed');
    }
  }

  /// `ss_status()`: metadata about the opened snapshot.
  SnapshotStatus status() {
    _checkOpen();
    final resultPtr = _bindings.ss_status(_handle);
    if (resultPtr == nullptr) {
      throw SearchSimpliException(_lastError(_bindings));
    }
    try {
      final json = jsonDecode(resultPtr.cast<Utf8>().toDartString());
      return SnapshotStatus.fromJson(json as Map<String, Object?>);
    } finally {
      _bindings.ss_free(resultPtr);
    }
  }

  /// `ss_query()`: runs one query against the opened snapshot and returns
  /// the typed `search_knowledge` result envelope.
  ///
  ///   [queryText]        Must not be empty.
  ///   [queryVector]       Ignored for `RetrievalMode.lexical` and for
  ///                       snapshots with zero vector dimensions; otherwise
  ///                       its length must equal the snapshot's vector
  ///                       dimensions (see [status]).
  ///   [topK]              Final result count, 1-100.
  ///   [mode]              Default `RetrievalMode.hybrid`.
  ///   [candidateK]        Default 100 on the native side; must be >= topK
  ///                       and <= 10000 when given.
  ///   [pathPrefix]        Restricts results to chunks whose path starts
  ///                       with this prefix.
  ///   [principalLabels]   A chunk is only returned if the caller holds
  ///                       every one of its required labels.
  SearchKnowledgeResult query(
    String queryText, {
    List<double>? queryVector,
    int topK = 10,
    RetrievalMode? mode,
    int? candidateK,
    String? pathPrefix,
    List<String>? principalLabels,
  }) {
    _checkOpen();

    final options = <String, Object?>{
      if (mode != null) 'retrieval_mode': mode.toJson(),
      if (candidateK != null) 'candidate_k': candidateK,
      if (pathPrefix != null) 'path_prefix': pathPrefix,
      if (principalLabels != null) 'principal_labels': principalLabels,
    };
    final optionsJson = options.isEmpty ? null : jsonEncode(options);

    final queryTextPtr = queryText.toNativeUtf8();
    final optionsPtr = optionsJson?.toNativeUtf8();
    Pointer<Float> vectorPtr = nullptr;
    if (queryVector != null && queryVector.isNotEmpty) {
      vectorPtr = malloc<Float>(queryVector.length);
      for (var i = 0; i < queryVector.length; i++) {
        vectorPtr[i] = queryVector[i];
      }
    }

    try {
      final resultPtr = _bindings.ss_query(
        _handle,
        queryTextPtr.cast(),
        vectorPtr,
        queryVector?.length ?? 0,
        topK,
        optionsPtr?.cast() ?? nullptr,
      );
      if (resultPtr == nullptr) {
        throw SearchSimpliException(_lastError(_bindings));
      }
      try {
        final json = jsonDecode(resultPtr.cast<Utf8>().toDartString());
        return SearchKnowledgeResult.fromJson(json as Map<String, Object?>);
      } finally {
        _bindings.ss_free(resultPtr);
      }
    } finally {
      malloc.free(queryTextPtr);
      if (optionsPtr != null) malloc.free(optionsPtr);
      if (vectorPtr != nullptr) malloc.free(vectorPtr);
    }
  }

  /// `ss_evidence()`: looks up stored chunks by id, in the same order as
  /// [ids]. An unknown or unauthorized id comes back with `found: false`
  /// rather than failing the whole call.
  List<EvidenceChunk> evidence(
    List<String> ids, {
    String? pathPrefix,
    List<String>? principalLabels,
  }) {
    _checkOpen();

    final idsJson = jsonEncode({
      'ids': ids,
      if (pathPrefix != null) 'path_prefix': pathPrefix,
      if (principalLabels != null) 'principal_labels': principalLabels,
    });

    final idsPtr = idsJson.toNativeUtf8();
    try {
      final resultPtr = _bindings.ss_evidence(_handle, idsPtr.cast());
      if (resultPtr == nullptr) {
        throw SearchSimpliException(_lastError(_bindings));
      }
      try {
        final json = jsonDecode(resultPtr.cast<Utf8>().toDartString());
        return (json as List<Object?>)
            .map((e) => EvidenceChunk.fromJson(e! as Map<String, Object?>))
            .toList(growable: false);
      } finally {
        _bindings.ss_free(resultPtr);
      }
    } finally {
      malloc.free(idsPtr);
    }
  }

  /// Frees the native handle (`ss_close`). Safe to call at most once; a
  /// second call throws [StateError] rather than double-freeing.
  void close() {
    _checkOpen();
    _bindings.ss_close(_handle);
    _closed = true;
  }

  /// `ss_index_folder()`: indexes the folder at [folderPath] and atomically
  /// publishes (or re-publishes/updates) a lexical-only snapshot into
  /// [dirPath] (created, including parent directories, if missing) —
  /// exactly what `searchd index` does. Returns the typed
  /// [IndexFolderReport] (docs/tasks/S1-T4.md criterion 1).
  ///
  /// A static method rather than an instance method, deliberately: it takes
  /// a directory path, not an open [SearchSimpli] handle, the same shape as
  /// [importSnapshotJson] and `ss_index_folder` itself — an already-open
  /// handle is a read-only view of one immutable generation and has nothing
  /// to contribute to publishing a new one (see the S1-T3 tester's verdict,
  /// `docs/tasks/S1-T3.md` criterion 1, and `ss_index_folder`'s doc comment
  /// in `zig/include/search_simpli.h`).
  ///
  /// [options.update] (default `false`) selects a full rebuild (always
  /// publishing the next free generation) or an incremental update
  /// (content-hash reuse, tombstoned deletions) — see
  /// docs/incremental-indexing.md. Throws [SearchSimpliException] if
  /// `ss_index_folder` fails (missing/unreadable [folderPath], an
  /// unrecognized `options.analyzer`, or — with `options.update: true` —
  /// [dirPath] already holding a snapshot published with a different
  /// analyzer — see `ss_last_error()`).
  static IndexFolderReport indexFolder(
    String dirPath,
    String folderPath, {
    IndexFolderOptions options = const IndexFolderOptions(),
    DynamicLibrary? library,
  }) {
    final dylib = library ?? openSearchSimpliLibrary();
    final bindings = SearchSimpliBindings(dylib);

    final dirPtr = dirPath.toNativeUtf8();
    final folderPtr = folderPath.toNativeUtf8();
    final optsPtr = jsonEncode(options.toJson()).toNativeUtf8();
    try {
      final resultPtr = bindings.ss_index_folder(dirPtr.cast(), folderPtr.cast(), optsPtr.cast());
      if (resultPtr == nullptr) {
        throw SearchSimpliException(_lastError(bindings));
      }
      try {
        final json = jsonDecode(resultPtr.cast<Utf8>().toDartString());
        return IndexFolderReport.fromJson(json as Map<String, Object?>);
      } finally {
        bindings.ss_free(resultPtr);
      }
    } finally {
      malloc.free(dirPtr);
      malloc.free(folderPtr);
      malloc.free(optsPtr);
    }
  }
}

/// Publishes [bytesJson] (neutral interchange JSON,
/// `contracts/snapshot-interchange.schema.json`) as a new generation under
/// [dirPath] — `ss_import_json`, exactly what `searchd import-json` does.
/// Returns the published generation number (>= 1).
///
/// A free function, not a [SearchSimpli] method, because it takes a
/// directory path rather than an open handle (mirrors
/// `search_simpli.h`'s own free-standing `ss_import_json`).
int importSnapshotJson(
  String dirPath,
  String bytesJson, {
  DynamicLibrary? library,
}) {
  final dylib = library ?? openSearchSimpliLibrary();
  final bindings = SearchSimpliBindings(dylib);

  final dirPtr = dirPath.toNativeUtf8();
  final bytesUnit8 = utf8.encode(bytesJson);
  final bytesPtr = malloc<Uint8>(bytesUnit8.length);
  bytesPtr.asTypedList(bytesUnit8.length).setAll(0, bytesUnit8);

  try {
    final generation = bindings.ss_import_json(
      dirPtr.cast(),
      bytesPtr.cast(),
      bytesUnit8.length,
    );
    if (generation < 0) {
      throw SearchSimpliException(bindings.ss_last_error().cast<Utf8>().toDartString());
    }
    return generation;
  } finally {
    malloc.free(dirPtr);
    malloc.free(bytesPtr);
  }
}
