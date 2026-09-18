/// Typed Dart mirrors of the JSON shapes `search_simpli.h`'s `ss_status`,
/// `ss_query`, and `ss_evidence` return.
///
/// These are a contracts mirror in the same sense as
/// `simpli-helper/packages/vizhi_core/lib/src/search/contracts/
/// search_knowledge_result.dart`: field names and JSON keys line up field
/// for field with `contracts/search-tool.schema.json` (snake_case on the
/// wire, camelCase in Dart), because `ss_query`'s JSON is byte-for-byte the
/// same `search_knowledge` `result` object the JSON-RPC service returns
/// (`zig/include/search_simpli.h`'s "JSON shapes" section). A future app
/// consumer (simpli-helper M12-T0) can convert one of these to the other
/// with a field-for-field copy; this package does not depend on
/// `vizhi_core` itself.
library;

/// `ss_status()`'s JSON object.
class SnapshotStatus {
  final bool ready;
  final int generation;
  final String analyzerId;
  final String embeddingModelId;
  final int vectorDimensions;
  final int documents;
  final int terms;
  final int postings;

  const SnapshotStatus({
    required this.ready,
    required this.generation,
    required this.analyzerId,
    required this.embeddingModelId,
    required this.vectorDimensions,
    required this.documents,
    required this.terms,
    required this.postings,
  });

  factory SnapshotStatus.fromJson(Map<String, Object?> json) => SnapshotStatus(
        ready: json['ready']! as bool,
        generation: json['generation']! as int,
        analyzerId: json['analyzer_id']! as String,
        embeddingModelId: json['embedding_model_id']! as String,
        vectorDimensions: json['vector_dimensions']! as int,
        documents: json['documents']! as int,
        terms: json['terms']! as int,
        postings: json['postings']! as int,
      );

  Map<String, Object?> toJson() => {
        'ready': ready,
        'generation': generation,
        'analyzer_id': analyzerId,
        'embedding_model_id': embeddingModelId,
        'vector_dimensions': vectorDimensions,
        'documents': documents,
        'terms': terms,
        'postings': postings,
      };

  @override
  String toString() =>
      'SnapshotStatus(generation: $generation, documents: $documents)';
}

/// How `ss_query` retrieved its `results`.
enum RetrievalMode {
  lexical,
  vector,
  hybrid;

  String toJson() => name;

  static RetrievalMode fromJson(String value) => RetrievalMode.values.byName(value);
}

/// `search_knowledge`'s `authorization` object.
class SearchAuthorization {
  final String semantics;
  final int principalLabelCount;

  const SearchAuthorization({
    required this.semantics,
    required this.principalLabelCount,
  });

  factory SearchAuthorization.fromJson(Map<String, Object?> json) =>
      SearchAuthorization(
        semantics: json['semantics']! as String,
        principalLabelCount: json['principal_label_count']! as int,
      );

  Map<String, Object?> toJson() => {
        'semantics': semantics,
        'principal_label_count': principalLabelCount,
      };
}

/// `search_knowledge`'s `index` object.
class SearchIndexInfo {
  final int version;
  final int generation;
  final String analyzerId;
  final String embeddingModelId;

  const SearchIndexInfo({
    required this.version,
    required this.generation,
    required this.analyzerId,
    required this.embeddingModelId,
  });

  factory SearchIndexInfo.fromJson(Map<String, Object?> json) => SearchIndexInfo(
        version: json['version']! as int,
        generation: json['generation']! as int,
        analyzerId: json['analyzer_id']! as String,
        embeddingModelId: json['embedding_model_id']! as String,
      );

  Map<String, Object?> toJson() => {
        'version': version,
        'generation': generation,
        'analyzer_id': analyzerId,
        'embedding_model_id': embeddingModelId,
      };
}

/// `search_knowledge`'s `retrieval` object.
class SearchRetrieval {
  final RetrievalMode mode;
  final int vectorDimensions;
  final SearchAuthorization authorization;

  const SearchRetrieval({
    required this.mode,
    required this.vectorDimensions,
    required this.authorization,
  });

  factory SearchRetrieval.fromJson(Map<String, Object?> json) => SearchRetrieval(
        mode: RetrievalMode.fromJson(json['mode']! as String),
        vectorDimensions: json['vector_dimensions']! as int,
        authorization: SearchAuthorization.fromJson(
          json['authorization']! as Map<String, Object?>,
        ),
      );

  Map<String, Object?> toJson() => {
        'mode': mode.toJson(),
        'vector_dimensions': vectorDimensions,
        'authorization': authorization.toJson(),
      };
}

/// `search_knowledge`/`read_chunk`'s `citation` object.
class SearchCitation {
  final String path;
  final int startLine;
  final int endLine;

  const SearchCitation({
    required this.path,
    required this.startLine,
    required this.endLine,
  });

  factory SearchCitation.fromJson(Map<String, Object?> json) => SearchCitation(
        path: json['path']! as String,
        startLine: json['start_line']! as int,
        endLine: json['end_line']! as int,
      );

  Map<String, Object?> toJson() => {
        'path': path,
        'start_line': startLine,
        'end_line': endLine,
      };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is SearchCitation &&
          other.path == path &&
          other.startLine == startLine &&
          other.endLine == endLine);

  @override
  int get hashCode => Object.hash(path, startLine, endLine);

  @override
  String toString() => 'SearchCitation($path:$startLine-$endLine)';
}

/// One ranked result in `ss_query`'s `results` array.
class SearchResultItem {
  final String chunkId;
  final SearchCitation citation;
  final String content;
  final double score;

  /// Component ranking details (lexical/vector rank+score); an open object,
  /// kept as-is, same as `vizhi_core`'s `SearchResultItem.ranking`.
  final Map<String, Object?> ranking;

  const SearchResultItem({
    required this.chunkId,
    required this.citation,
    required this.content,
    required this.score,
    required this.ranking,
  });

  factory SearchResultItem.fromJson(Map<String, Object?> json) => SearchResultItem(
        chunkId: json['chunk_id']! as String,
        citation: SearchCitation.fromJson(json['citation']! as Map<String, Object?>),
        content: json['content']! as String,
        score: (json['score']! as num).toDouble(),
        ranking: json['ranking']! as Map<String, Object?>,
      );

  Map<String, Object?> toJson() => {
        'chunk_id': chunkId,
        'citation': citation.toJson(),
        'content': content,
        'score': score,
        'ranking': ranking,
      };

  @override
  String toString() => 'SearchResultItem($chunkId, ${citation.path})';
}

/// `search_knowledge`'s fixed `answer_policy` object.
class AnswerPolicy {
  final bool groundInResults;
  final bool citePathAndLines;
  final bool sayWhenEvidenceIsInsufficient;

  const AnswerPolicy({
    this.groundInResults = true,
    this.citePathAndLines = true,
    this.sayWhenEvidenceIsInsufficient = true,
  });

  factory AnswerPolicy.fromJson(Map<String, Object?> json) => AnswerPolicy(
        groundInResults: json['ground_in_results']! as bool,
        citePathAndLines: json['cite_path_and_lines']! as bool,
        sayWhenEvidenceIsInsufficient: json['say_when_evidence_is_insufficient']! as bool,
      );

  Map<String, Object?> toJson() => {
        'ground_in_results': groundInResults,
        'cite_path_and_lines': citePathAndLines,
        'say_when_evidence_is_insufficient': sayWhenEvidenceIsInsufficient,
      };
}

/// `ss_query()`'s JSON object — exactly a `search_knowledge` JSON-RPC
/// response's `result` value (`zig/include/search_simpli.h`).
class SearchKnowledgeResult {
  final String tool;
  final String query;
  final SearchIndexInfo index;
  final SearchRetrieval retrieval;
  final List<SearchResultItem> results;
  final AnswerPolicy answerPolicy;

  const SearchKnowledgeResult({
    required this.tool,
    required this.query,
    required this.index,
    required this.retrieval,
    required this.results,
    required this.answerPolicy,
  });

  factory SearchKnowledgeResult.fromJson(Map<String, Object?> json) =>
      SearchKnowledgeResult(
        tool: json['tool']! as String,
        query: json['query']! as String,
        index: SearchIndexInfo.fromJson(json['index']! as Map<String, Object?>),
        retrieval: SearchRetrieval.fromJson(json['retrieval']! as Map<String, Object?>),
        results: (json['results']! as List<Object?>)
            .map((e) => SearchResultItem.fromJson(e! as Map<String, Object?>))
            .toList(growable: false),
        answerPolicy:
            AnswerPolicy.fromJson(json['answer_policy']! as Map<String, Object?>),
      );

  Map<String, Object?> toJson() => {
        'tool': tool,
        'query': query,
        'index': index.toJson(),
        'retrieval': retrieval.toJson(),
        'results': results.map((r) => r.toJson()).toList(growable: false),
        'answer_policy': answerPolicy.toJson(),
      };

  @override
  String toString() => 'SearchKnowledgeResult($query, ${results.length} results)';
}

/// One entry in `ss_evidence()`'s JSON array: a found chunk, or
/// `{"chunk_id": ..., "found": false}`.
class EvidenceChunk {
  final String chunkId;
  final bool found;
  final SearchCitation? citation;
  final String? content;

  const EvidenceChunk({
    required this.chunkId,
    required this.found,
    this.citation,
    this.content,
  });

  factory EvidenceChunk.fromJson(Map<String, Object?> json) {
    final found = json['found'] as bool?;
    if (found == false) {
      return EvidenceChunk(chunkId: json['chunk_id']! as String, found: false);
    }
    return EvidenceChunk(
      chunkId: json['chunk_id']! as String,
      found: true,
      citation: SearchCitation.fromJson(json['citation']! as Map<String, Object?>),
      content: json['content']! as String,
    );
  }

  Map<String, Object?> toJson() => found
      ? {
          'chunk_id': chunkId,
          'citation': citation!.toJson(),
          'content': content,
        }
      : {'chunk_id': chunkId, 'found': false};

  @override
  String toString() => 'EvidenceChunk($chunkId, found: $found)';
}
