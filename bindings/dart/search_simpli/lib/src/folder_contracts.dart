/// Typed Dart mirrors of the contract 2.0.0 folder-knowledge results
/// (`zig/include/search_simpli.h`: `ss_find`, `ss_outline`, `ss_read_span`,
/// `ss_list_files`, `ss_roots`, `ss_apply_changes`;
/// `docs/folder-knowledge-implementation.md` section 8).
///
/// snake_case on the wire, camelCase in Dart. Every result also keeps the
/// decoded JSON object it was read from as [json], unchanged: the same bytes
/// `searchd serve` returns as `result` and `searchd <command> --json`
/// prints, so a caller (or the parity test) can compare or forward it
/// without a lossy round trip.
library;

/// `mode` of a `find` request.
enum FindMode {
  words('words'),
  phrase('phrase'),
  prefix('prefix');

  const FindMode(this.wire);
  final String wire;

  static FindMode parse(String value) =>
      FindMode.values.firstWhere((m) => m.wire == value, orElse: () => throw FormatException('unknown find mode "$value"'));
}

/// `status` of a listed file.
enum FileStatus {
  indexed('indexed'),
  pending('pending');

  const FileStatus(this.wire);
  final String wire;

  static FileStatus parse(String value) =>
      FileStatus.values.firstWhere((s) => s.wire == value, orElse: () => throw FormatException('unknown file status "$value"'));
}

List<String> _strings(Object? value) => (value! as List<Object?>).map((e) => e! as String).toList(growable: false);

/// The envelope's `scope`: the roots the request could see.
class ResultScope {
  final List<String> roots;
  final bool labelsApplied;

  const ResultScope({required this.roots, required this.labelsApplied});

  factory ResultScope.fromJson(Map<String, Object?> json) =>
      ResultScope(roots: _strings(json['roots']), labelsApplied: json['labels_applied']! as bool);
}

/// One entry of the envelope's `warnings` (`end_line_clamped`, …).
class ResultWarning {
  final String code;
  final String message;

  const ResultWarning({required this.code, required this.message});

  factory ResultWarning.fromJson(Map<String, Object?> json) =>
      ResultWarning(code: json['code']! as String, message: json['message']! as String);
}

/// What every 2.0.0 read result starts with.
abstract class FolderResult {
  /// The decoded result object, exactly as the engine wrote it.
  final Map<String, Object?> json;
  FolderResult(this.json);

  /// The request echoed back with defaults filled in.
  Map<String, Object?> get request => json['request']! as Map<String, Object?>;
  int get generation => json['generation']! as int;
  ResultScope get scope => ResultScope.fromJson(json['scope']! as Map<String, Object?>);
  List<ResultWarning> get warnings => (json['warnings']! as List<Object?>)
      .map((e) => ResultWarning.fromJson(e! as Map<String, Object?>))
      .toList(growable: false);
}

/// A half-open `[start, end)` range of codepoints.
class CodepointRange {
  final int start;
  final int end;
  const CodepointRange(this.start, this.end);

  factory CodepointRange.fromJson(Object? value) {
    final pair = value! as List<Object?>;
    return CodepointRange(pair[0]! as int, pair[1]! as int);
  }

  @override
  bool operator ==(Object other) => other is CodepointRange && other.start == start && other.end == end;
  @override
  int get hashCode => Object.hash(start, end);
  @override
  String toString() => '[$start, $end)';
}

/// One `find` hit.
class FindHit {
  final String chunkId;
  final String rootId;
  final String path;
  final List<String> sectionPath;
  final int startLine;
  final int endLine;
  final double score;
  final String snippet;
  final int snippetStart;
  final List<CodepointRange> snippetOffsets;
  final List<CodepointRange> matchOffsets;

  const FindHit({
    required this.chunkId,
    required this.rootId,
    required this.path,
    required this.sectionPath,
    required this.startLine,
    required this.endLine,
    required this.score,
    required this.snippet,
    required this.snippetStart,
    required this.snippetOffsets,
    required this.matchOffsets,
  });

  factory FindHit.fromJson(Map<String, Object?> json) => FindHit(
        chunkId: json['chunk_id']! as String,
        rootId: json['root_id']! as String,
        path: json['path']! as String,
        sectionPath: _strings(json['section_path']),
        startLine: json['start_line']! as int,
        endLine: json['end_line']! as int,
        score: (json['score']! as num).toDouble(),
        snippet: json['snippet']! as String,
        snippetStart: json['snippet_start']! as int,
        snippetOffsets: (json['snippet_offsets']! as List<Object?>).map(CodepointRange.fromJson).toList(growable: false),
        matchOffsets: (json['match_offsets']! as List<Object?>).map(CodepointRange.fromJson).toList(growable: false),
      );
}

/// Hits per file over every page of a `find`.
class FileHitCount {
  final String rootId;
  final String path;
  final int hits;
  const FileHitCount({required this.rootId, required this.path, required this.hits});

  factory FileHitCount.fromJson(Map<String, Object?> json) =>
      FileHitCount(rootId: json['root_id']! as String, path: json['path']! as String, hits: json['hits']! as int);
}

/// `ss_find()`'s result.
class FindResult extends FolderResult {
  final List<FindHit> hits;
  final List<FileHitCount> files;

  /// Phrase mode: whether a phrase hit exists; null in the other modes.
  final bool? exactMatch;
  final bool empty;
  final int coverageFiles;
  final int coverageSections;

  /// A file in scope was given but not indexed in full.
  final bool truncated;
  final String? nextCursor;

  /// Files in scope announced but not indexed yet.
  final int pendingFiles;

  FindResult._(super.json)
      : hits = (json['hits']! as List<Object?>).map((e) => FindHit.fromJson(e! as Map<String, Object?>)).toList(growable: false),
        files = (json['files']! as List<Object?>).map((e) => FileHitCount.fromJson(e! as Map<String, Object?>)).toList(growable: false),
        exactMatch = json['exact_match'] as bool?,
        empty = json['empty']! as bool,
        coverageFiles = (json['coverage']! as Map<String, Object?>)['files']! as int,
        coverageSections = (json['coverage']! as Map<String, Object?>)['sections']! as int,
        truncated = json['truncated']! as bool,
        nextCursor = json['next_cursor'] as String?,
        pendingFiles = json['pending_files']! as int;

  factory FindResult.fromJson(Map<String, Object?> json) => FindResult._(json);
}

/// A Markdown file's front matter block.
class FrontMatter {
  final int startLine;
  final int endLine;
  final Map<String, String> fields;

  /// The inner lines, when they are not all `key: value`.
  final String? raw;

  const FrontMatter({required this.startLine, required this.endLine, required this.fields, this.raw});

  factory FrontMatter.fromJson(Map<String, Object?> json) => FrontMatter(
        startLine: json['start_line']! as int,
        endLine: json['end_line']! as int,
        fields: (json['fields']! as Map<String, Object?>).map((k, v) => MapEntry(k, v! as String)),
        raw: json['raw'] as String?,
      );
}

/// One heading of an outline.
class OutlineHeading {
  final int level;
  final String text;
  final int line;
  final int endLine;
  const OutlineHeading({required this.level, required this.text, required this.line, required this.endLine});

  factory OutlineHeading.fromJson(Map<String, Object?> json) => OutlineHeading(
      level: json['level']! as int, text: json['text']! as String, line: json['line']! as int, endLine: json['end_line']! as int);
}

/// `ss_outline()`'s result.
class OutlineResult extends FolderResult {
  final FrontMatter? frontMatter;
  final List<OutlineHeading> headings;
  final int lines;
  final String chunker;

  OutlineResult._(super.json)
      : frontMatter = json['front_matter'] == null ? null : FrontMatter.fromJson(json['front_matter']! as Map<String, Object?>),
        headings = (json['headings']! as List<Object?>).map((e) => OutlineHeading.fromJson(e! as Map<String, Object?>)).toList(growable: false),
        lines = json['lines']! as int,
        chunker = json['chunker']! as String;

  factory OutlineResult.fromJson(Map<String, Object?> json) => OutlineResult._(json);
}

/// `ss_read_span()`'s result: the lines byte for byte (terminators kept).
class SpanResult extends FolderResult {
  final int startLine;

  /// The last line returned (an `end_line` past the file's end is clamped,
  /// with an `end_line_clamped` warning).
  final int endLine;
  final String text;
  final String contextBefore;
  final String contextAfter;
  final bool byteExact;

  /// Lowercase hex sha256 of [text]'s UTF-8 bytes.
  final String sha256;

  SpanResult._(super.json)
      : startLine = json['start_line']! as int,
        endLine = json['end_line']! as int,
        text = json['text']! as String,
        contextBefore = json['context_before']! as String,
        contextAfter = json['context_after']! as String,
        byteExact = json['byte_exact']! as bool,
        sha256 = json['sha256']! as String;

  factory SpanResult.fromJson(Map<String, Object?> json) => SpanResult._(json);
}

/// One listed file.
class ListedFile {
  final String rootId;
  final String path;

  /// Retained bytes, or a pending file's announced size; null when unknown.
  final int? size;

  /// Always null in contract 2.0.0 (a generation does not record it).
  final int? mtimeMs;
  final FileStatus status;
  final int chunks;
  final String? chunker;

  const ListedFile({
    required this.rootId,
    required this.path,
    required this.size,
    required this.mtimeMs,
    required this.status,
    required this.chunks,
    required this.chunker,
  });

  factory ListedFile.fromJson(Map<String, Object?> json) => ListedFile(
        rootId: json['root_id']! as String,
        path: json['path']! as String,
        size: json['size'] as int?,
        mtimeMs: json['mtime_ms'] as int?,
        status: FileStatus.parse(json['status']! as String),
        chunks: json['chunks']! as int,
        chunker: json['chunker'] as String?,
      );
}

/// `ss_list_files()`'s result.
class FileListResult extends FolderResult {
  final List<ListedFile> files;

  /// Files matching the request over every page.
  final int total;
  final String? nextCursor;

  FileListResult._(super.json)
      : files = (json['files']! as List<Object?>).map((e) => ListedFile.fromJson(e! as Map<String, Object?>)).toList(growable: false),
        total = json['total']! as int,
        nextCursor = json['next_cursor'] as String?;

  factory FileListResult.fromJson(Map<String, Object?> json) => FileListResult._(json);
}

/// A visible root with its counts (`ss_roots`, and `ss_status`'s `roots`).
class RootInfo {
  final String rootId;
  final String label;
  final String kind;
  final int files;
  final int documents;
  final int pending;

  const RootInfo({
    required this.rootId,
    required this.label,
    required this.kind,
    required this.files,
    required this.documents,
    required this.pending,
  });

  factory RootInfo.fromJson(Map<String, Object?> json) => RootInfo(
        rootId: json['root_id']! as String,
        label: json['label']! as String,
        kind: json['kind']! as String,
        files: json['files']! as int,
        documents: json['documents']! as int,
        pending: json['pending']! as int,
      );

  Map<String, Object?> toJson() =>
      {'root_id': rootId, 'label': label, 'kind': kind, 'files': files, 'documents': documents, 'pending': pending};
}

/// `ss_roots()`'s result.
class RootsResult extends FolderResult {
  final List<RootInfo> roots;

  RootsResult._(super.json)
      : roots = (json['roots']! as List<Object?>).map((e) => RootInfo.fromJson(e! as Map<String, Object?>)).toList(growable: false);

  factory RootsResult.fromJson(Map<String, Object?> json) => RootsResult._(json);
}

/// A file named in an apply report (`too_large_paths`, …).
class FileRef {
  final String rootId;
  final String path;
  const FileRef({required this.rootId, required this.path});

  factory FileRef.fromJson(Map<String, Object?> json) => FileRef(rootId: json['root_id']! as String, path: json['path']! as String);

  Map<String, Object?> toJson() => {'root_id': rootId, 'path': path};
}

/// A change the engine refused (`hash_mismatch`, `size_mismatch`, …).
class RejectedChange {
  final String rootId;
  final String path;
  final String reason;
  const RejectedChange({required this.rootId, required this.path, required this.reason});

  factory RejectedChange.fromJson(Map<String, Object?> json) =>
      RejectedChange(rootId: json['root_id']! as String, path: json['path']! as String, reason: json['reason']! as String);
}

/// `ss_apply_changes()`'s report (implementation section 6).
class ApplyChangesReport {
  final Map<String, Object?> json;
  final int generation;
  final String analyzerId;
  final int added;
  final int changed;
  final int removed;
  final int moved;
  final int pending;
  final int unchanged;
  final int tooLarge;
  final int unreadable;
  final int budgetExhausted;
  final int rootsRemoved;
  final List<FileRef> tooLargePaths;
  final List<FileRef> unreadablePaths;
  final List<RejectedChange> rejected;
  final int documents;
  final int terms;
  final int postings;

  /// Set when the previous generation could not be read and the writer
  /// started from an empty table: the host must send its files again.
  final String? recovered;

  ApplyChangesReport._(this.json)
      : generation = json['generation']! as int,
        analyzerId = json['analyzer_id']! as String,
        added = json['added']! as int,
        changed = json['changed']! as int,
        removed = json['removed']! as int,
        moved = json['moved']! as int,
        pending = json['pending']! as int,
        unchanged = json['unchanged']! as int,
        tooLarge = json['too_large']! as int,
        unreadable = json['unreadable']! as int,
        budgetExhausted = json['budget_exhausted']! as int,
        rootsRemoved = json['roots_removed']! as int,
        tooLargePaths = (json['too_large_paths']! as List<Object?>).map((e) => FileRef.fromJson(e! as Map<String, Object?>)).toList(growable: false),
        unreadablePaths = (json['unreadable_paths']! as List<Object?>).map((e) => FileRef.fromJson(e! as Map<String, Object?>)).toList(growable: false),
        rejected = (json['rejected']! as List<Object?>).map((e) => RejectedChange.fromJson(e! as Map<String, Object?>)).toList(growable: false),
        documents = json['documents']! as int,
        terms = json['terms']! as int,
        postings = json['postings']! as int,
        recovered = json['recovered'] as String?;

  factory ApplyChangesReport.fromJson(Map<String, Object?> json) => ApplyChangesReport._(json);

  /// `conflicts` and `ambiguous_moves`, as the engine wrote them.
  List<Object?> get conflicts => json['conflicts']! as List<Object?>;
  List<Object?> get ambiguousMoves => json['ambiguous_moves']! as List<Object?>;

  @override
  String toString() => 'ApplyChangesReport(generation: $generation, added: $added, changed: $changed, removed: $removed)';
}

/// `opts_json` of `ss_apply_changes`.
class ApplyChangesOptions {
  /// A `file` change is refused unless this is true.
  final bool? filenameIndex;
  final bool allowFileReads;
  final int? maxFileBytes;
  final int? maxTotalBytes;
  final int? keepGenerations;

  const ApplyChangesOptions({this.filenameIndex, this.allowFileReads = false, this.maxFileBytes, this.maxTotalBytes, this.keepGenerations});

  Map<String, Object?> toJson() => {
        if (filenameIndex != null) 'filename_index': filenameIndex,
        if (allowFileReads) 'allow_file_reads': true,
        if (maxFileBytes != null) 'max_file_bytes': maxFileBytes,
        if (maxTotalBytes != null) 'max_total_bytes': maxTotalBytes,
        if (keepGenerations != null) 'keep_generations': keepGenerations,
      };
}
