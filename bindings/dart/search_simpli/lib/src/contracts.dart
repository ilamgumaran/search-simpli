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

  /// `index.root` in `contracts/search-tool.schema.json` — the indexed
  /// folder's root path. Schema-optional: the engine does not emit it
  /// today (docs/tasks/S1-T4.md criterion 4), so this is `null` for every
  /// snapshot `ss_query` currently produces; the field exists so a future
  /// engine that does emit it round-trips through `fromJson`/`toJson`
  /// without silently dropping it.
  final String? root;

  const SearchIndexInfo({
    required this.version,
    required this.generation,
    required this.analyzerId,
    required this.embeddingModelId,
    this.root,
  });

  factory SearchIndexInfo.fromJson(Map<String, Object?> json) => SearchIndexInfo(
        version: json['version']! as int,
        generation: json['generation']! as int,
        analyzerId: json['analyzer_id']! as String,
        embeddingModelId: json['embedding_model_id']! as String,
        root: json['root'] as String?,
      );

  Map<String, Object?> toJson() => {
        'version': version,
        'generation': generation,
        'analyzer_id': analyzerId,
        'embedding_model_id': embeddingModelId,
        if (root != null) 'root': root,
      };
}

/// `search_knowledge`'s `retrieval` object.
class SearchRetrieval {
  final RetrievalMode mode;
  final int vectorDimensions;
  final SearchAuthorization authorization;

  /// `retrieval.vector_mode` — the vector projection/model family in use
  /// (e.g. `"neural"`, `"cooccurrence"`). Schema-optional and not emitted by
  /// the engine today (docs/tasks/S1-T4.md criterion 4); see [SearchIndexInfo.root].
  final String? vectorMode;

  /// `retrieval.candidate_k` — the candidate pool size actually used for
  /// this query. Schema-optional and not emitted by the engine today.
  final int? candidateK;

  /// `retrieval.embedding` — an open object describing the query embedding
  /// (or explicit JSON `null`). Schema-optional and not emitted by the
  /// engine today; kept as a raw map, like [SearchResultItem.ranking].
  final Map<String, Object?>? embedding;

  const SearchRetrieval({
    required this.mode,
    required this.vectorDimensions,
    required this.authorization,
    this.vectorMode,
    this.candidateK,
    this.embedding,
  });

  factory SearchRetrieval.fromJson(Map<String, Object?> json) => SearchRetrieval(
        mode: RetrievalMode.fromJson(json['mode']! as String),
        vectorDimensions: json['vector_dimensions']! as int,
        authorization: SearchAuthorization.fromJson(
          json['authorization']! as Map<String, Object?>,
        ),
        vectorMode: json['vector_mode'] as String?,
        candidateK: json['candidate_k'] as int?,
        embedding: json['embedding'] as Map<String, Object?>?,
      );

  Map<String, Object?> toJson() => {
        'mode': mode.toJson(),
        'vector_dimensions': vectorDimensions,
        'authorization': authorization.toJson(),
        if (vectorMode != null) 'vector_mode': vectorMode,
        if (candidateK != null) 'candidate_k': candidateK,
        if (embedding != null) 'embedding': embedding,
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

/// Options for [SearchSimpli.indexFolder] — mirrors
/// `zig/src/abi.zig`'s `IndexFolderOptions` and `ss_index_folder`'s
/// `opts_json` (`zig/include/search_simpli.h`), same field meanings as the
/// `searchd index` flags of the same names.
class IndexFolderOptions {
  /// `"analyzer-v1"`/`"v1"` (ASCII) or `"analyzer-v2"`/`"v2"` (Unicode,
  /// default).
  final String analyzer;
  final int? maxChars;
  final int? overlapLines;

  /// `false` (default): full rebuild, always publishing the next free
  /// generation. `true`: incremental update (content hashes, unchanged
  /// files skipped, deleted files tombstoned) — see
  /// docs/incremental-indexing.md.
  final bool update;

  /// Per-file size cap in bytes (native default 10 MiB). A file over this
  /// cap is never read, and is reported (and tombstoned) under `tooLarge`/
  /// `tooLargePaths`.
  final int? maxFileBytes;

  /// Total bytes read across all files in one call before the rest are left
  /// for a later run (native default 512 MiB); left-over files are reported
  /// under `budgetExhausted`.
  final int? maxTotalBytes;

  const IndexFolderOptions({
    this.analyzer = 'analyzer-v2',
    this.maxChars,
    this.overlapLines,
    this.update = false,
    this.maxFileBytes,
    this.maxTotalBytes,
  });

  Map<String, Object?> toJson() => {
        'analyzer': analyzer,
        if (maxChars != null) 'max_chars': maxChars,
        if (overlapLines != null) 'overlap_lines': overlapLines,
        'update': update,
        if (maxFileBytes != null) 'max_file_bytes': maxFileBytes,
        if (maxTotalBytes != null) 'max_total_bytes': maxTotalBytes,
      };
}

/// `ss_index_folder()`'s JSON report object — mirrors `zig/src/indexer.zig`'s
/// `IndexReport`/`IncrementalReport` as unified by `zig/src/abi.zig`
/// (docs/tasks/S1-T4.md criterion 1). A non-`update` run always reports
/// `changed`/`removed`/`unchanged`/`budgetExhausted`/`tooLarge` as 0 and
/// `tooLargePaths` as empty; an `update` run reports the full incremental
/// breakdown — see docs/incremental-indexing.md.
class IndexFolderReport {
  final int generation;
  final String analyzerId;
  final int added;
  final int changed;
  final int removed;

  /// Unchanged since the previous generation (content hash matched) —
  /// nothing to do. Distinct from [budgetExhausted]: docs/tasks/S1-T4.md
  /// criterion 3.
  final int unchanged;

  /// Left untouched this run because `maxTotalBytes` was exhausted first;
  /// eligible again on the next run.
  final int budgetExhausted;

  final int tooLarge;
  final int unreadable;

  /// Relative paths of every file counted under [tooLarge]. A file this
  /// large is tombstoned (its previous chunks, if any, are dropped), never
  /// silently kept.
  final List<String> tooLargePaths;

  /// Relative paths of every file counted under [unreadable]. Unlike
  /// [tooLargePaths], an unreadable file's previous chunks (if any) are
  /// carried forward.
  final List<String> unreadablePaths;

  final int documents;
  final int terms;
  final int postings;

  const IndexFolderReport({
    required this.generation,
    required this.analyzerId,
    required this.added,
    required this.changed,
    required this.removed,
    required this.unchanged,
    required this.budgetExhausted,
    required this.tooLarge,
    required this.unreadable,
    required this.tooLargePaths,
    required this.unreadablePaths,
    required this.documents,
    required this.terms,
    required this.postings,
  });

  factory IndexFolderReport.fromJson(Map<String, Object?> json) => IndexFolderReport(
        generation: json['generation']! as int,
        analyzerId: json['analyzer_id']! as String,
        added: json['added']! as int,
        changed: json['changed']! as int,
        removed: json['removed']! as int,
        unchanged: json['unchanged']! as int,
        budgetExhausted: json['budget_exhausted']! as int,
        tooLarge: json['too_large']! as int,
        unreadable: json['unreadable']! as int,
        tooLargePaths: (json['too_large_paths']! as List<Object?>)
            .map((e) => e! as String)
            .toList(growable: false),
        unreadablePaths: (json['unreadable_paths']! as List<Object?>)
            .map((e) => e! as String)
            .toList(growable: false),
        documents: json['documents']! as int,
        terms: json['terms']! as int,
        postings: json['postings']! as int,
      );

  Map<String, Object?> toJson() => {
        'generation': generation,
        'analyzer_id': analyzerId,
        'added': added,
        'changed': changed,
        'removed': removed,
        'unchanged': unchanged,
        'budget_exhausted': budgetExhausted,
        'too_large': tooLarge,
        'unreadable': unreadable,
        'too_large_paths': tooLargePaths,
        'unreadable_paths': unreadablePaths,
        'documents': documents,
        'terms': terms,
        'postings': postings,
      };

  @override
  String toString() =>
      'IndexFolderReport(generation: $generation, documents: $documents, '
      'added: $added, changed: $changed, removed: $removed)';
}
