# Text-search score

`searchd` sha256 `5ad3de31652ab4db88302678132c86ac5e45de25b6f3ce0630b28cf33f6bd8c1` (main 87bfd35, ReleaseSmall).
Judgments `fixtures/text-search/judgments.json` sha256 `5aa111d0446d8389b9b8e68e3d42ae3f939b8eeef1240a1eb2ff88ab6a55b01f`, 181 questions.
Corpus 270 files, 141,726 bytes, sha256 `35a08d3237d32952ad77abfc5ea19c61098dce23e486a6bc136b2eaa3d5519d9`; the engine read 246 and left 24 unread.
Top 10 results per question. Every cell is typed / query: the question sent as typed, then the query words.

## `--search-field both`, direct search

Finding: how many questions (typed / query).

| Kind | n | single-source | not read | file@1 | file@3 | file@10 | passage@1 | passage@3 | passage@10 | complete | returned anything |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| word | 15 | 7 | 4 | 10 / 11 | 11 / 12 | 11 / 12 | 9 / 10 | 11 / 12 | 11 / 12 | 11 / 12 | – / – |
| word-form | 13 | 2 | 0 | 12 / 11 | 12 / 11 | 12 / 11 | 12 / 11 | 12 / 11 | 12 / 11 | 12 / 11 | – / – |
| misspelt | 12 | 0 | 1 | 10 / 11 | 12 / 11 | 12 / 11 | 7 / 9 | 8 / 9 | 8 / 9 | 8 / 9 | – / – |
| phrase | 12 | 6 | 1 | 11 / 11 | 11 / 11 | 11 / 11 | 11 / 11 | 11 / 11 | 11 / 11 | 11 / 11 | – / – |
| number | 12 | 6 | 4 | 9 / 8 | 9 / 9 | 10 / 10 | 9 / 8 | 9 / 9 | 10 / 10 | 10 / 10 | – / – |
| two-passages | 11 | 7 | 1 | 4 / 7 | 9 / 11 | 11 / 11 | 4 / 6 | 9 / 9 | 11 / 9 | 0 / 0 | – / – |
| two-files | 11 | 8 | 1 | 7 / 8 | 8 / 9 | 9 / 9 | 6 / 7 | 8 / 9 | 9 / 9 | 6 / 7 | – / – |
| filename | 12 | 5 | 1 | 7 / 10 | 8 / 11 | 10 / 11 | 7 / 10 | 7 / 11 | 10 / 11 | 10 / 11 | – / – |
| about | 11 | 1 | 3 | 8 / 10 | 9 / 11 | 10 / 11 | 7 / 10 | 8 / 11 | 10 / 11 | 4 / 8 | – / – |
| file-content | 11 | 3 | 3 | 3 / 7 | 5 / 8 | 8 / 8 | 3 / 7 | 5 / 8 | 8 / 8 | 8 / 8 | – / – |
| no-answer | 12 | – | – | – / – | – / – | – / – | – / – | – / – | – / – | – / – | 11 / 8 |
| tamil-latin | 10 | 0 | 0 | 5 / 7 | 5 / 7 | 5 / 7 | 4 / 5 | 4 / 5 | 4 / 5 | 4 / 5 | – / – |
| synonym | 10 | 0 | 0 | 2 / 3 | 4 / 4 | 5 / 6 | 0 / 0 | 2 / 1 | 2 / 3 | 2 / 3 | – / – |
| table | 10 | 4 | 5 | 4 / 5 | 5 / 6 | 6 / 6 | 4 / 5 | 5 / 6 | 6 / 6 | 6 / 6 | – / – |
| current-copy | 9 | 0 | 0 | 0 / 4 | 6 / 8 | 8 / 8 | 0 / 2 | 4 / 5 | 5 / 5 | 5 / 5 | – / – |
| where-is-it | 10 | 4 | 7 | 1 / 2 | 3 / 3 | 3 / 3 | 1 / 2 | 3 / 3 | 3 / 3 | 3 / 3 | – / – |
| **total** (with an answer) | 169 | 53 | 31 | 93 / 115 | 117 / 132 | 131 / 135 | 84 / 103 | 106 / 120 | 120 / 123 | 100 / 109 | – / – |
| **total without single-source** | 116 | 0 | 19 | 61 / 79 | 79 / 89 | 89 / 92 | 54 / 69 | 69 / 79 | 78 / 82 | 68 / 75 | – / – |

Tightness (typed / query).

| Kind | n | complete | complete within 4,096 bytes | evidence bytes, median | judged share of passage bytes, mean | answer in its file's first passage | stale copy ranked first |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| word | 15 | 11 / 12 | 1 / 3 | 12,354 / 5,820 | 0.07 / 0.14 | 11 / 12 | – / – |
| word-form | 13 | 12 / 11 | 1 / 11 | 10,941 / 1,812 | 0.07 / 0.46 | 12 / 11 | – / – |
| misspelt | 12 | 8 / 9 | 3 / 6 | 6,892 / 2,976 | 0.06 / 0.25 | 8 / 9 | – / – |
| phrase | 12 | 11 / 11 | 1 / 1 | 11,680 / 11,680 | 0.07 / 0.07 | 11 / 11 | – / – |
| number | 12 | 10 / 10 | 0 / 4 | 12,592 / 10,062 | 0.03 / 0.10 | 10 / 10 | – / – |
| two-passages | 11 | 0 / 0 | 0 / 0 | 12,148 / 10,389 | 0.07 / 0.06 | 0 / 0 | – / – |
| two-files | 11 | 6 / 7 | 0 / 0 | 12,085 / 11,095 | 0.06 / 0.08 | 6 / 7 | 0 / 0 |
| filename | 12 | 10 / 11 | 1 / 4 | 11,464 / 8,982 | 0.13 / 0.32 | 10 / 11 | – / – |
| about | 11 | 4 / 8 | 0 / 2 | 11,250 / 9,605 | 0.08 / 0.27 | 4 / 8 | – / – |
| file-content | 11 | 8 / 8 | 0 / 2 | 12,946 / 6,060 | 0.04 / 0.06 | 8 / 8 | – / – |
| no-answer | 12 | – / – | – / – | 11,550 / 3,662 | 0.00 / 0.00 | – / – | – / – |
| tamil-latin | 10 | 4 / 5 | 2 / 2 | 1,884 / 1,878 | 0.28 / 0.25 | 4 / 5 | – / – |
| synonym | 10 | 2 / 3 | 0 / 0 | 12,103 / 11,332 | 0.01 / 0.01 | 2 / 3 | 1 / 0 |
| table | 10 | 6 / 6 | 0 / 1 | 12,288 / 10,501 | 0.02 / 0.03 | 6 / 6 | – / – |
| current-copy | 9 | 5 / 5 | 0 / 0 | 11,547 / 11,104 | 0.03 / 0.05 | 5 / 5 | 7 / 3 |
| where-is-it | 10 | 3 / 3 | 0 / 0 | 12,644 / 11,936 | 0.01 / 0.03 | 3 / 3 | – / – |
| **total** (with an answer) | 169 | 100 / 109 | 9 / 36 | 11,814 / 9,403 | 0.06 / 0.15 | 100 / 109 | 8 / 3 |
| **total without single-source** | 116 | 68 / 75 | 8 / 25 | 11,770 / 8,561 | 0.07 / 0.17 | 68 / 75 | 8 / 3 |

The index surface (`index` then `evidence`) gave byte-identical evidence for every question in both forms, so its tables are the same.

## `--search-field content`, direct search

Finding: how many questions (typed / query).

| Kind | n | single-source | not read | file@1 | file@3 | file@10 | passage@1 | passage@3 | passage@10 | complete | returned anything |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| word | 15 | 7 | 4 | 10 / 11 | 11 / 12 | 11 / 12 | 9 / 10 | 11 / 12 | 11 / 12 | 11 / 12 | – / – |
| word-form | 13 | 2 | 0 | 12 / 11 | 12 / 11 | 12 / 11 | 12 / 11 | 12 / 11 | 12 / 11 | 12 / 11 | – / – |
| misspelt | 12 | 0 | 1 | 10 / 11 | 12 / 11 | 12 / 11 | 7 / 9 | 9 / 9 | 11 / 9 | 11 / 9 | – / – |
| phrase | 12 | 6 | 1 | 11 / 11 | 11 / 11 | 11 / 11 | 11 / 11 | 11 / 11 | 11 / 11 | 11 / 11 | – / – |
| number | 12 | 6 | 4 | 9 / 8 | 9 / 9 | 10 / 10 | 9 / 8 | 9 / 9 | 10 / 10 | 10 / 10 | – / – |
| two-passages | 11 | 7 | 1 | 4 / 7 | 9 / 11 | 11 / 11 | 4 / 6 | 9 / 10 | 11 / 11 | 6 / 9 | – / – |
| two-files | 11 | 8 | 1 | 7 / 8 | 8 / 9 | 9 / 9 | 6 / 7 | 8 / 9 | 9 / 9 | 6 / 7 | – / – |
| filename | 12 | 5 | 1 | 7 / 10 | 8 / 11 | 10 / 11 | 7 / 10 | 7 / 11 | 10 / 11 | 10 / 11 | – / – |
| about | 11 | 1 | 3 | 8 / 10 | 9 / 11 | 10 / 11 | 7 / 10 | 9 / 11 | 10 / 11 | 5 / 8 | – / – |
| file-content | 11 | 3 | 3 | 3 / 7 | 5 / 8 | 7 / 8 | 3 / 7 | 5 / 8 | 7 / 8 | 7 / 8 | – / – |
| no-answer | 12 | – | – | – / – | – / – | – / – | – / – | – / – | – / – | – / – | 11 / 8 |
| tamil-latin | 10 | 0 | 0 | 5 / 7 | 5 / 7 | 5 / 7 | 4 / 5 | 4 / 5 | 4 / 5 | 4 / 5 | – / – |
| synonym | 10 | 0 | 0 | 2 / 3 | 4 / 4 | 5 / 5 | 0 / 0 | 2 / 1 | 2 / 2 | 2 / 2 | – / – |
| table | 10 | 4 | 5 | 4 / 5 | 5 / 6 | 6 / 6 | 4 / 5 | 5 / 6 | 6 / 6 | 6 / 6 | – / – |
| current-copy | 9 | 0 | 0 | 0 / 4 | 6 / 8 | 7 / 8 | 0 / 2 | 4 / 5 | 6 / 6 | 6 / 6 | – / – |
| where-is-it | 10 | 4 | 7 | 1 / 2 | 3 / 3 | 3 / 3 | 1 / 2 | 3 / 3 | 3 / 3 | 3 / 3 | – / – |
| **total** (with an answer) | 169 | 53 | 31 | 93 / 115 | 117 / 132 | 129 / 134 | 84 / 103 | 108 / 121 | 123 / 125 | 110 / 118 | – / – |
| **total without single-source** | 116 | 0 | 19 | 61 / 79 | 79 / 89 | 88 / 91 | 54 / 69 | 71 / 79 | 82 / 82 | 76 / 78 | – / – |

Tightness (typed / query).

| Kind | n | complete | complete within 4,096 bytes | evidence bytes, median | judged share of passage bytes, mean | answer in its file's first passage | stale copy ranked first |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| word | 15 | 11 / 12 | 7 / 8 | 3,515 / 2,553 | 0.08 / 0.14 | 11 / 12 | – / – |
| word-form | 13 | 12 / 11 | 12 / 11 | 3,093 / 461 | 0.07 / 0.42 | 12 / 11 | – / – |
| misspelt | 12 | 11 / 9 | 10 / 9 | 2,816 / 900 | 0.10 / 0.25 | 8 / 9 | – / – |
| phrase | 12 | 11 / 11 | 10 / 10 | 3,394 / 3,394 | 0.07 / 0.07 | 11 / 11 | – / – |
| number | 12 | 10 / 10 | 7 / 7 | 3,824 / 3,272 | 0.03 / 0.10 | 10 / 10 | – / – |
| two-passages | 11 | 6 / 9 | 4 / 7 | 3,861 / 2,800 | 0.09 / 0.13 | 0 / 0 | – / – |
| two-files | 11 | 6 / 7 | 5 / 6 | 3,478 / 3,205 | 0.06 / 0.07 | 6 / 7 | 0 / 0 |
| filename | 12 | 10 / 11 | 9 / 10 | 3,259 / 2,740 | 0.13 / 0.32 | 10 / 11 | – / – |
| about | 11 | 5 / 8 | 5 / 8 | 3,394 / 2,658 | 0.08 / 0.22 | 4 / 8 | – / – |
| file-content | 11 | 7 / 8 | 5 / 7 | 3,898 / 1,849 | 0.04 / 0.06 | 7 / 8 | – / – |
| no-answer | 12 | – / – | – / – | 3,282 / 1,834 | 0.00 / 0.00 | – / – | – / – |
| tamil-latin | 10 | 4 / 5 | 4 / 4 | 466 / 459 | 0.28 / 0.25 | 4 / 5 | – / – |
| synonym | 10 | 2 / 2 | 2 / 1 | 3,638 / 3,513 | 0.01 / 0.01 | 2 / 2 | 1 / 0 |
| table | 10 | 6 / 6 | 4 / 5 | 3,648 / 3,116 | 0.02 / 0.03 | 6 / 6 | – / – |
| current-copy | 9 | 6 / 6 | 6 / 6 | 3,145 / 2,882 | 0.05 / 0.05 | 5 / 5 | 6 / 3 |
| where-is-it | 10 | 3 / 3 | 1 / 1 | 3,994 / 3,809 | 0.01 / 0.01 | 3 / 3 | – / – |
| **total** (with an answer) | 169 | 110 / 118 | 91 / 100 | 3,479 / 2,785 | 0.07 / 0.15 | 99 / 108 | 7 / 3 |
| **total without single-source** | 116 | 76 / 78 | 65 / 67 | 3,404 / 2,688 | 0.08 / 0.17 | 68 / 74 | 7 / 3 |

The index surface (`index` then `evidence`) gave byte-identical evidence for every question in both forms, so its tables are the same.

