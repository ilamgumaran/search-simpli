/// Typed Dart mirror of `contracts/snapshot-interchange.schema.json`
/// (`SearchSnapshotInterchangeV1`): the JSON [importSnapshotJson]
/// (`ss_import_json`) publishes. Build one, `jsonEncode(x.toJson())`, and
/// pass the string to `importSnapshotJson`.
library;

/// The schema's `analyzer_id` enum (contract 1.1.0): how `ss_import_json`
/// tokenizes the documents, recorded in the snapshot so queries use the same
/// analyzer.
enum InterchangeAnalyzer {
  /// `"ascii-alnum-v1"`: ASCII letters and digits only, case-insensitive.
  /// Text in any other script yields no terms (Tamil is unsearchable), and
  /// `café` is indexed as `caf`. The only value before contract 1.1.0.
  asciiAlnumV1('ascii-alnum-v1'),

  /// `"analyzer-v2"` (contract 1.1.0): Unicode NFC, simple case folding,
  /// Unicode letter and digit categories. The import builds the same index
  /// `searchd index` / [SearchSimpli.indexFolder] build from the same
  /// chunks. Use this for any text that is not plain ASCII.
  analyzerV2('analyzer-v2');

  const InterchangeAnalyzer(this.id);

  /// The wire value of `analyzer_id`.
  final String id;

  /// The value whose [id] is [id]; throws [ArgumentError] for anything the
  /// schema does not accept (the native import would reject it too).
  static InterchangeAnalyzer fromId(String id) {
    for (final value in values) {
      if (value.id == id) return value;
    }
    throw ArgumentError.value(
      id,
      'analyzer_id',
      'must be one of ${values.map((v) => '"${v.id}"').join(', ')}',
    );
  }
}

/// `contracts/snapshot-interchange.schema.json`, `format_version: 1`.
class SnapshotInterchangeV1 {
  /// Always `1`: the schema's `format_version` const.
  int get formatVersion => 1;

  final int generation;

  /// Which analyzer the native import tokenizes with. Required: there is no
  /// silent default, because the ASCII one cannot search non-ASCII text.
  final InterchangeAnalyzer analyzer;

  /// The wire value of [analyzer].
  String get analyzerId => analyzer.id;

  /// `"none"` when no document carries a vector.
  final String embeddingModelId;

  final List<SnapshotInterchangeDocument> documents;

  /// Optional publication option (S2-T5), not snapshot content: after a
  /// successful import, delete the section files of generations older than
  /// the newest N. `null` (the default) deletes nothing. Must be >= 1.
  final int? keepGenerations;

  SnapshotInterchangeV1({
    required this.generation,
    required this.analyzer,
    required this.embeddingModelId,
    List<SnapshotInterchangeDocument>? documents,
    this.keepGenerations,
  }) : documents = List.unmodifiable(
          documents ?? const <SnapshotInterchangeDocument>[],
        ) {
    if (generation < 1) {
      throw ArgumentError.value(generation, 'generation', 'must be >= 1');
    }
    if (keepGenerations != null && keepGenerations! < 1) {
      throw ArgumentError.value(
        keepGenerations,
        'keepGenerations',
        'must be >= 1',
      );
    }
    if (embeddingModelId.isEmpty) {
      throw ArgumentError.value(
        embeddingModelId,
        'embeddingModelId',
        'must not be empty',
      );
    }
  }

  factory SnapshotInterchangeV1.fromJson(Map<String, Object?> json) {
    final formatVersion = json['format_version'];
    if (formatVersion != 1) {
      throw ArgumentError.value(formatVersion, 'format_version', 'must be 1');
    }
    return SnapshotInterchangeV1(
      generation: json['generation']! as int,
      analyzer: InterchangeAnalyzer.fromId(json['analyzer_id']! as String),
      embeddingModelId: json['embedding_model_id']! as String,
      documents: (json['documents']! as List<Object?>)
          .map((e) =>
              SnapshotInterchangeDocument.fromJson(e! as Map<String, Object?>))
          .toList(growable: false),
      keepGenerations: json['keep_generations'] as int?,
    );
  }

  Map<String, Object?> toJson() => {
        'format_version': formatVersion,
        'generation': generation,
        'analyzer_id': analyzerId,
        'embedding_model_id': embeddingModelId,
        if (keepGenerations != null) 'keep_generations': keepGenerations,
        'documents': documents.map((d) => d.toJson()).toList(growable: false),
      };

  @override
  String toString() => 'SnapshotInterchangeV1(generation: $generation, '
      'analyzer: $analyzerId, ${documents.length} documents)';
}

/// One `documents[]` entry: a chunk with its citation, stored vector and
/// access labels.
class SnapshotInterchangeDocument {
  final String id;
  final String path;
  final int startLine;
  final int endLine;
  final String text;
  final List<double> vector;
  final List<String> requiredLabels;

  SnapshotInterchangeDocument({
    required this.id,
    required this.path,
    required this.startLine,
    required this.endLine,
    required this.text,
    List<double>? vector,
    List<String>? requiredLabels,
  })  : vector = List.unmodifiable(vector ?? const <double>[]),
        requiredLabels = List.unmodifiable(requiredLabels ?? const <String>[]) {
    if (id.isEmpty) throw ArgumentError.value(id, 'id', 'must not be empty');
    if (path.isEmpty) {
      throw ArgumentError.value(path, 'path', 'must not be empty');
    }
    if (startLine < 1) {
      throw ArgumentError.value(startLine, 'startLine', 'must be >= 1');
    }
    if (endLine < 1) {
      throw ArgumentError.value(endLine, 'endLine', 'must be >= 1');
    }
    if (this.requiredLabels.any((label) => label.isEmpty) ||
        this.requiredLabels.toSet().length != this.requiredLabels.length) {
      throw ArgumentError.value(
        this.requiredLabels,
        'requiredLabels',
        'entries must be non-empty and unique',
      );
    }
  }

  factory SnapshotInterchangeDocument.fromJson(Map<String, Object?> json) =>
      SnapshotInterchangeDocument(
        id: json['id']! as String,
        path: json['path']! as String,
        startLine: json['start_line']! as int,
        endLine: json['end_line']! as int,
        text: json['text']! as String,
        vector: (json['vector']! as List<Object?>)
            .map((v) => (v! as num).toDouble())
            .toList(growable: false),
        requiredLabels: (json['required_labels']! as List<Object?>)
            .cast<String>()
            .toList(growable: false),
      );

  Map<String, Object?> toJson() => {
        'id': id,
        'path': path,
        'start_line': startLine,
        'end_line': endLine,
        'text': text,
        'vector': vector,
        'required_labels': requiredLabels,
      };
}
