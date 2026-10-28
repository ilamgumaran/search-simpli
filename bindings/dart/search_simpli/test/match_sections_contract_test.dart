import 'package:search_simpli/search_simpli.dart';
import 'package:test/test.dart';

void main() {
  test(
    'match sections preserve full text, actual terms and field citations',
    () {
      final json = <String, Object?>{
        'chunk_id': 'chunk-1',
        'citation': {'path': 'docs/README.md', 'start_line': 8, 'end_line': 10},
        'content': 'The result passage returned by retrieval.',
        'score': 0.75,
        'ranking': {'lexical_rank': 2},
        'matched_in': ['content'],
        'basename': 'README.md',
        'match_sections': {
          'filename': {
            'label': 'File name',
            'matched': false,
            'matched_terms': <String>[],
            'text': 'README.md',
            'citation': {'path': 'docs/README.md', 'field': 'filename'},
          },
          'content': {
            'label': 'Content',
            'matched': true,
            'matched_terms': ['retrieval', 'result'],
            'text': 'The complete matching passage with retrieval and result.',
            'citation': {
              'path': 'docs/README.md',
              'field': 'content',
              'start_line': 8,
              'end_line': 9,
            },
          },
        },
      };

      final result = SearchResultItem.fromJson(json);
      final sections = result.matchSections!;
      expect(sections.filename.label, 'File name');
      expect(sections.filename.matched, isFalse);
      expect(sections.filename.matchedTerms, isEmpty);
      expect(sections.filename.text, 'README.md');
      expect(sections.filename.citation.toJson(), {
        'path': 'docs/README.md',
        'field': 'filename',
      });
      expect(sections.content.label, 'Content');
      expect(sections.content.matched, isTrue);
      expect(sections.content.matchedTerms, ['retrieval', 'result']);
      expect(
        sections.content.text,
        'The complete matching passage with retrieval and result.',
      );
      expect(sections.content.citation.toJson(), {
        'path': 'docs/README.md',
        'field': 'content',
        'start_line': 8,
        'end_line': 9,
      });
      expect(result.toJson(), json);
    },
  );

  test('legacy result JSON keeps its original keys and no sections', () {
    final json = <String, Object?>{
      'chunk_id': 'chunk-2',
      'citation': {'path': 'docs/guide.md', 'start_line': 3, 'end_line': 4},
      'content': 'Legacy passage.',
      'score': 0.5,
      'ranking': <String, Object?>{},
    };

    final result = SearchResultItem.fromJson(json);
    expect(result.matchSections, isNull);
    expect(result.toJson(), json);
    expect(result.toJson().containsKey('match_sections'), isFalse);
  });
}
