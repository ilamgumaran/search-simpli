# Judged set before and after (S6-T23 Part 1 prototype)

Before: `main 8ffc41c under text-sniff-v1 (s6t23 rename prototype)`, read 270 of 270 files. After: `S6-T23 Part 2 head, ReleaseSmall searchd`, read 270 of 270.
Direct = index, before: {'both/typed': {'identical': 181, 'of': 181}, 'both/query': {'identical': 181, 'of': 181}, 'content/typed': {'identical': 181, 'of': 181}, 'content/query': {'identical': 181, 'of': 181}}.
Direct = index, after: {'both/typed': {'identical': 181, 'of': 181}, 'both/query': {'identical': 181, 'of': 181}, 'content/typed': {'identical': 181, 'of': 181}, 'content/query': {'identical': 181, 'of': 181}}.

Cells are typed / query, before → after (bold when they differ). Counts are questions.

## `--search-field both`

Finding:

| Total | file@1 | file@3 | file@10 | passage@1 | passage@10 | complete | not_read |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| total (169) | 97 / 130 | 123 / 147 | 138 / 155 | 90 / 118 | 129 / 144 | 109 / 127 | 0 / 0 |
| readable now (146) | 90 / 115 | 116 / 130 | 129 / 133 | 83 / 103 | 120 / 122 | 102 / 108 | 0 / 0 |
| without single-source (116) | 60 / 87 | 79 / 98 | 91 / 103 | 55 / 76 | 82 / 93 | 72 / 85 | 0 / 0 |

Tightness and ranking:

| Total | complete_within | evidence_bytes_median | judged_share_mean | first_passage | stale_first |
| --- | ---: | ---: | ---: | ---: | ---: |
| total (169) | 10 / 36 | 12,042 → **12,034** / 10,553 | 0.070 / 0.152 | 109 / 127 | 10 / 5 |
| readable now (146) | 9 / 32 | 11,829 / 10,473 | 0.078 / 0.162 | 102 / 108 | 10 / 5 |
| without single-source (116) | 8 / 24 | 11,876 / 10,616 | 0.075 / 0.174 | 72 / 85 | 9 / 5 |

Per kind:

| Kind | n | file@1 | file@10 | complete | complete_within | not_read |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| word | 15 | 12 / 13 | 12 / 15 | 12 / 15 | 1 / 4 | 0 / 0 |
| word-form | 13 | 12 / 11 | 12 / 11 | 12 / 11 | 1 / 11 | 0 / 0 |
| misspelt | 12 | 10 / 11 | 12 / 11 | 9 / 9 | 3 / 5 | 0 / 0 |
| phrase | 12 | 12 / 12 | 12 / 12 | 12 / 12 | 2 / 2 | 0 / 0 |
| number | 12 | 11 / 10 | 12 / 12 | 12 / 12 | 0 / 4 | 0 / 0 |
| two-passages | 11 | 5 / 7 | 11 / 11 | 0 / 0 | 0 / 0 | 0 / 0 |
| two-files | 11 | 8 / 9 | 10 / 10 | 7 / 7 | 0 / 0 | 0 / 0 |
| filename | 12 | 7 / 11 | 10 / 12 | 10 / 12 | 1 / 4 | 0 / 0 |
| about | 11 | 4 / 10 | 10 / 11 | 4 / 7 | 0 / 1 | 0 / 0 |
| file-content | 11 | 2 / 10 | 7 / 11 | 7 / 11 | 0 / 1 | 0 / 0 |
| tamil-latin | 10 | 5 / 7 | 5 / 7 | 4 / 5 | 2 / 2 | 0 / 0 |
| synonym | 10 | 2 / 3 | 6 / 6 | 3 / 3 | 0 / 0 | 0 / 0 |
| table | 10 | 5 / 8 | 7 / 10 | 7 / 10 | 0 / 1 | 0 / 0 |
| current-copy | 9 | 0 / 4 | 8 / 8 | 6 / 5 | 0 / 0 | 0 / 0 |
| where-is-it | 10 | 2 / 4 | 4 / 8 | 4 / 8 | 0 / 1 | 0 / 0 |

No-answer (12), returned anything: 11 / 8

## `--search-field content`

Finding:

| Total | file@1 | file@3 | file@10 | passage@1 | passage@10 | complete | not_read |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| total (169) | 97 / 130 | 123 / 147 | 138 / 154 | 90 / 118 | 132 / 145 | 120 / 137 | 0 / 0 |
| readable now (146) | 90 / 115 | 116 / 130 | 129 / 132 | 83 / 103 | 123 / 123 | 113 / 118 | 0 / 0 |
| without single-source (116) | 60 / 87 | 79 / 98 | 91 / 102 | 55 / 76 | 85 / 93 | 79 / 89 | 0 / 0 |

Tightness and ranking:

| Total | complete_within | evidence_bytes_median | judged_share_mean | first_passage | stale_first |
| --- | ---: | ---: | ---: | ---: | ---: |
| total (169) | 94 / 102 | 3,582 / 2,944 | 0.070 / 0.148 | 109 / 126 | 10 / 5 |
| readable now (146) | 90 / 91 | 3,478 / 2,914 | 0.078 / 0.158 | 102 / 107 | 10 / 5 |
| without single-source (116) | 65 / 68 | 3,496 / 2,774 | 0.075 / 0.166 | 72 / 84 | 9 / 5 |

Per kind:

| Kind | n | file@1 | file@10 | complete | complete_within | not_read |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| word | 15 | 12 / 13 | 12 / 15 | 12 / 15 | 8 / 9 | 0 / 0 |
| word-form | 13 | 12 / 11 | 12 / 11 | 12 / 11 | 12 / 11 | 0 / 0 |
| misspelt | 12 | 10 / 11 | 12 / 11 | 11 / 9 | 9 / 9 | 0 / 0 |
| phrase | 12 | 12 / 12 | 12 / 12 | 12 / 12 | 11 / 11 | 0 / 0 |
| number | 12 | 11 / 10 | 12 / 12 | 12 / 12 | 8 / 7 | 0 / 0 |
| two-passages | 11 | 5 / 7 | 11 / 11 | 7 / 9 | 3 / 6 | 0 / 0 |
| two-files | 11 | 8 / 9 | 10 / 10 | 7 / 7 | 6 / 5 | 0 / 0 |
| filename | 12 | 7 / 11 | 10 / 12 | 10 / 12 | 8 / 10 | 0 / 0 |
| about | 11 | 4 / 10 | 10 / 11 | 5 / 8 | 5 / 7 | 0 / 0 |
| file-content | 11 | 2 / 10 | 7 / 11 | 7 / 11 | 5 / 6 | 0 / 0 |
| tamil-latin | 10 | 5 / 7 | 5 / 7 | 4 / 5 | 4 / 4 | 0 / 0 |
| synonym | 10 | 2 / 3 | 6 / 5 | 3 / 2 | 1 / 1 | 0 / 0 |
| table | 10 | 5 / 8 | 7 / 10 | 7 / 10 | 6 / 7 | 0 / 0 |
| current-copy | 9 | 0 / 4 | 8 / 8 | 7 / 6 | 7 / 6 | 0 / 0 |
| where-is-it | 10 | 2 / 4 | 4 / 8 | 4 / 8 | 1 / 3 | 0 / 0 |

No-answer (12), returned anything: 11 / 8

## Questions that got worse

Per question, every configuration (surface/field/form) in which it got worse and how. Judged-share drops alone are counted at the end, not listed.

None, in any of the eight configurations.

Judged share lower by more than 0.005 and nothing else worse: .

## Questions that got better (direct surface)

- `direct/both/typed`, 0: 
- `direct/both/query`, 0: 
- `direct/content/typed`, 0: 
- `direct/content/query`, 0: 
