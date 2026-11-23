# Text-search score

`searchd` sha256 `5ad3de31652ab4db88302678132c86ac5e45de25b6f3ce0630b28cf33f6bd8c1` (main 87bfd35, ReleaseSmall).
Judgments `fixtures/text-search/judgments.json` sha256 `e8f407728a3178c0b0ca01d296c9fd36b1709f2865fb3a1963b3567ff0cc5a55`, 181 questions.
Corpus 270 files, 141,870 bytes, sha256 `b7cf14314ee097b82cb75d9568a7fae22e728f7e7aa4af17abc159d21eef8dec`; the engine read 246 and left 24 unread.
Top 10 results per question. Every cell is typed / query: the question sent as typed, then the query words.

## `--search-field both`, direct search

Finding: how many questions (typed / query).

| Kind | n | single-source | not read | file@1 | file@3 | file@10 | passage@1 | passage@3 | passage@10 | complete | answer in its file's first passage (ranking) | stale copy ranked first | returned anything |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| word | 15 | 7 | 4 | 11 / 12 | 11 / 12 | 11 / 12 | 10 / 11 | 11 / 12 | 11 / 12 | 11 / 12 | 11 / 12 | 0 / 0 | – / – |
| word-form | 13 | 2 | 0 | 12 / 11 | 12 / 11 | 12 / 11 | 12 / 11 | 12 / 11 | 12 / 11 | 12 / 11 | 12 / 11 | – / – | – / – |
| misspelt | 12 | 0 | 1 | 10 / 11 | 12 / 11 | 12 / 11 | 7 / 9 | 8 / 9 | 8 / 9 | 8 / 9 | 8 / 9 | 0 / 0 | – / – |
| phrase | 12 | 6 | 1 | 11 / 11 | 11 / 11 | 11 / 11 | 11 / 11 | 11 / 11 | 11 / 11 | 11 / 11 | 11 / 11 | 0 / 0 | – / – |
| number | 12 | 6 | 4 | 9 / 8 | 9 / 9 | 10 / 10 | 9 / 8 | 9 / 9 | 10 / 10 | 10 / 10 | 10 / 10 | – / – | – / – |
| two-passages | 11 | 7 | 1 | 4 / 7 | 9 / 11 | 11 / 11 | 4 / 6 | 9 / 9 | 11 / 9 | 0 / 0 | 0 / 0 | 1 / 1 | – / – |
| two-files | 11 | 8 | 1 | 7 / 8 | 8 / 9 | 9 / 9 | 6 / 7 | 8 / 9 | 9 / 9 | 6 / 7 | 6 / 7 | 1 / 1 | – / – |
| filename | 12 | 5 | 1 | 7 / 10 | 8 / 11 | 10 / 11 | 7 / 10 | 7 / 11 | 10 / 11 | 10 / 11 | 10 / 11 | 1 / 0 | – / – |
| about | 11 | 1 | 3 | 8 / 10 | 9 / 11 | 10 / 11 | 7 / 10 | 8 / 11 | 10 / 11 | 4 / 8 | 4 / 8 | – / – | – / – |
| file-content | 11 | 3 | 3 | 3 / 7 | 5 / 8 | 8 / 8 | 3 / 7 | 5 / 8 | 8 / 8 | 8 / 8 | 8 / 8 | – / – | – / – |
| no-answer | 12 | – | – | – / – | – / – | – / – | – / – | – / – | – / – | – / – | – / – | – / – | 11 / 8 |
| tamil-latin | 10 | 0 | 0 | 5 / 7 | 5 / 7 | 5 / 7 | 4 / 5 | 4 / 5 | 4 / 5 | 4 / 5 | 4 / 5 | – / – | – / – |
| synonym | 10 | 0 | 0 | 2 / 3 | 4 / 4 | 6 / 6 | 0 / 0 | 2 / 1 | 2 / 3 | 2 / 3 | 2 / 3 | 0 / 0 | – / – |
| table | 10 | 4 | 5 | 4 / 5 | 5 / 6 | 6 / 6 | 4 / 5 | 5 / 6 | 6 / 6 | 6 / 6 | 6 / 6 | – / – | – / – |
| current-copy | 9 | 0 | 0 | 0 / 4 | 6 / 8 | 8 / 8 | 0 / 2 | 4 / 5 | 5 / 5 | 5 / 5 | 5 / 5 | 7 / 3 | – / – |
| where-is-it | 10 | 4 | 7 | 1 / 2 | 3 / 3 | 3 / 3 | 1 / 2 | 3 / 3 | 3 / 3 | 3 / 3 | 3 / 3 | – / – | – / – |
| **total** (with an answer) | 169 | 53 | 31 | 94 / 116 | 117 / 132 | 132 / 135 | 85 / 104 | 106 / 120 | 120 / 123 | 100 / 109 | 100 / 109 | 10 / 5 | – / – |
| **total readable now** | 146 | 43 | 8 | 94 / 115 | 117 / 130 | 131 / 133 | 85 / 103 | 106 / 118 | 119 / 121 | 100 / 109 | 100 / 109 | 10 / 5 | – / – |
| **total without single-source** | 116 | 0 | 19 | 62 / 80 | 79 / 89 | 90 / 92 | 55 / 70 | 69 / 79 | 78 / 82 | 68 / 75 | 68 / 75 | 9 / 5 | – / – |

Tightness (typed / query).

| Kind | n | complete | complete within 4,096 bytes | evidence bytes, median | judged share of passage bytes, mean |
| --- | ---: | ---: | ---: | ---: | ---: |
| word | 15 | 11 / 12 | 1 / 3 | 12,358 / 5,820 | 0.07 / 0.14 |
| word-form | 13 | 12 / 11 | 1 / 11 | 10,940 / 1,812 | 0.07 / 0.46 |
| misspelt | 12 | 8 / 9 | 3 / 6 | 6,890 / 3,008 | 0.06 / 0.25 |
| phrase | 12 | 11 / 11 | 1 / 1 | 11,704 / 11,704 | 0.07 / 0.07 |
| number | 12 | 10 / 10 | 0 / 4 | 12,585 / 10,060 | 0.03 / 0.10 |
| two-passages | 11 | 0 / 0 | 0 / 0 | 12,154 / 10,391 | 0.07 / 0.06 |
| two-files | 11 | 6 / 7 | 0 / 0 | 12,091 / 11,100 | 0.06 / 0.08 |
| filename | 12 | 10 / 11 | 1 / 4 | 11,462 / 8,982 | 0.13 / 0.32 |
| about | 11 | 4 / 8 | 0 / 2 | 11,271 / 9,627 | 0.08 / 0.27 |
| file-content | 11 | 8 / 8 | 0 / 2 | 12,942 / 6,062 | 0.04 / 0.06 |
| no-answer | 12 | – / – | – / – | 11,550 / 3,659 | 0.00 / 0.00 |
| tamil-latin | 10 | 4 / 5 | 2 / 2 | 1,884 / 1,878 | 0.28 / 0.25 |
| synonym | 10 | 2 / 3 | 0 / 0 | 12,100 / 11,326 | 0.01 / 0.01 |
| table | 10 | 6 / 6 | 0 / 1 | 12,389 / 10,503 | 0.02 / 0.03 |
| current-copy | 9 | 5 / 5 | 0 / 0 | 11,553 / 11,117 | 0.03 / 0.05 |
| where-is-it | 10 | 3 / 3 | 0 / 0 | 12,648 / 11,935 | 0.01 / 0.03 |
| **total** (with an answer) | 169 | 100 / 109 | 9 / 36 | 11,814 / 9,475 | 0.07 / 0.15 |
| **total readable now** | 146 | 100 / 109 | 9 / 36 | 11,769 / 8,566 | 0.08 / 0.16 |
| **total without single-source** | 116 | 68 / 75 | 8 / 25 | 11,774 / 8,574 | 0.07 / 0.17 |

The index surface (`index` then `evidence`) gave byte-identical evidence for every question in both forms, so its tables are the same.

## `--search-field content`, direct search

Finding: how many questions (typed / query).

| Kind | n | single-source | not read | file@1 | file@3 | file@10 | passage@1 | passage@3 | passage@10 | complete | answer in its file's first passage (ranking) | stale copy ranked first | returned anything |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| word | 15 | 7 | 4 | 11 / 12 | 11 / 12 | 11 / 12 | 10 / 11 | 11 / 12 | 11 / 12 | 11 / 12 | 11 / 12 | 0 / 0 | – / – |
| word-form | 13 | 2 | 0 | 12 / 11 | 12 / 11 | 12 / 11 | 12 / 11 | 12 / 11 | 12 / 11 | 12 / 11 | 12 / 11 | – / – | – / – |
| misspelt | 12 | 0 | 1 | 10 / 11 | 12 / 11 | 12 / 11 | 7 / 9 | 9 / 9 | 11 / 9 | 11 / 9 | 8 / 9 | 0 / 0 | – / – |
| phrase | 12 | 6 | 1 | 11 / 11 | 11 / 11 | 11 / 11 | 11 / 11 | 11 / 11 | 11 / 11 | 11 / 11 | 11 / 11 | 0 / 0 | – / – |
| number | 12 | 6 | 4 | 9 / 8 | 9 / 9 | 10 / 10 | 9 / 8 | 9 / 9 | 10 / 10 | 10 / 10 | 10 / 10 | – / – | – / – |
| two-passages | 11 | 7 | 1 | 4 / 7 | 9 / 11 | 11 / 11 | 4 / 6 | 9 / 10 | 11 / 11 | 6 / 9 | 0 / 0 | 1 / 1 | – / – |
| two-files | 11 | 8 | 1 | 7 / 8 | 8 / 9 | 9 / 9 | 6 / 7 | 8 / 9 | 9 / 9 | 6 / 7 | 6 / 7 | 1 / 1 | – / – |
| filename | 12 | 5 | 1 | 7 / 10 | 8 / 11 | 10 / 11 | 7 / 10 | 7 / 11 | 10 / 11 | 10 / 11 | 10 / 11 | 1 / 0 | – / – |
| about | 11 | 1 | 3 | 8 / 10 | 9 / 11 | 10 / 11 | 7 / 10 | 9 / 11 | 10 / 11 | 5 / 8 | 4 / 8 | – / – | – / – |
| file-content | 11 | 3 | 3 | 3 / 7 | 5 / 8 | 7 / 8 | 3 / 7 | 5 / 8 | 7 / 8 | 7 / 8 | 7 / 8 | – / – | – / – |
| no-answer | 12 | – | – | – / – | – / – | – / – | – / – | – / – | – / – | – / – | – / – | – / – | 11 / 8 |
| tamil-latin | 10 | 0 | 0 | 5 / 7 | 5 / 7 | 5 / 7 | 4 / 5 | 4 / 5 | 4 / 5 | 4 / 5 | 4 / 5 | – / – | – / – |
| synonym | 10 | 0 | 0 | 2 / 3 | 4 / 4 | 6 / 5 | 0 / 0 | 2 / 1 | 2 / 2 | 2 / 2 | 2 / 2 | 0 / 0 | – / – |
| table | 10 | 4 | 5 | 4 / 5 | 5 / 6 | 6 / 6 | 4 / 5 | 5 / 6 | 6 / 6 | 6 / 6 | 6 / 6 | – / – | – / – |
| current-copy | 9 | 0 | 0 | 0 / 4 | 6 / 8 | 7 / 8 | 0 / 2 | 4 / 5 | 6 / 6 | 6 / 6 | 5 / 5 | 6 / 3 | – / – |
| where-is-it | 10 | 4 | 7 | 1 / 2 | 3 / 3 | 3 / 3 | 1 / 2 | 3 / 3 | 3 / 3 | 3 / 3 | 3 / 3 | – / – | – / – |
| **total** (with an answer) | 169 | 53 | 31 | 94 / 116 | 117 / 132 | 130 / 134 | 85 / 104 | 108 / 121 | 123 / 125 | 110 / 118 | 99 / 108 | 9 / 5 | – / – |
| **total readable now** | 146 | 43 | 8 | 94 / 115 | 117 / 130 | 129 / 132 | 85 / 103 | 108 / 119 | 122 / 123 | 110 / 118 | 99 / 108 | 9 / 5 | – / – |
| **total without single-source** | 116 | 0 | 19 | 62 / 80 | 79 / 89 | 89 / 91 | 55 / 70 | 71 / 79 | 82 / 82 | 76 / 78 | 68 / 74 | 8 / 5 | – / – |

Tightness (typed / query).

| Kind | n | complete | complete within 4,096 bytes | evidence bytes, median | judged share of passage bytes, mean |
| --- | ---: | ---: | ---: | ---: | ---: |
| word | 15 | 11 / 12 | 7 / 8 | 3,545 / 2,555 | 0.08 / 0.14 |
| word-form | 13 | 12 / 11 | 12 / 11 | 3,096 / 461 | 0.07 / 0.42 |
| misspelt | 12 | 11 / 9 | 10 / 9 | 2,851 / 914 | 0.10 / 0.25 |
| phrase | 12 | 11 / 11 | 10 / 10 | 3,406 / 3,406 | 0.07 / 0.07 |
| number | 12 | 10 / 10 | 7 / 7 | 3,824 / 3,282 | 0.03 / 0.10 |
| two-passages | 11 | 6 / 9 | 4 / 7 | 3,861 / 2,827 | 0.08 / 0.13 |
| two-files | 11 | 6 / 7 | 5 / 6 | 3,480 / 3,203 | 0.06 / 0.07 |
| filename | 12 | 10 / 11 | 9 / 10 | 3,258 / 2,752 | 0.13 / 0.32 |
| about | 11 | 5 / 8 | 5 / 8 | 3,395 / 2,666 | 0.08 / 0.23 |
| file-content | 11 | 7 / 8 | 5 / 7 | 3,897 / 1,851 | 0.04 / 0.06 |
| no-answer | 12 | – / – | – / – | 3,282 / 1,833 | 0.00 / 0.00 |
| tamil-latin | 10 | 4 / 5 | 4 / 4 | 466 / 459 | 0.28 / 0.25 |
| synonym | 10 | 2 / 2 | 2 / 1 | 3,638 / 3,512 | 0.01 / 0.01 |
| table | 10 | 6 / 6 | 4 / 5 | 3,668 / 3,124 | 0.02 / 0.03 |
| current-copy | 9 | 6 / 6 | 6 / 6 | 3,153 / 2,905 | 0.04 / 0.05 |
| where-is-it | 10 | 3 / 3 | 1 / 1 | 3,994 / 3,810 | 0.01 / 0.01 |
| **total** (with an answer) | 169 | 110 / 118 | 91 / 100 | 3,482 / 2,809 | 0.07 / 0.15 |
| **total readable now** | 146 | 110 / 118 | 91 / 100 | 3,404 / 2,719 | 0.08 / 0.16 |
| **total without single-source** | 116 | 76 / 78 | 65 / 67 | 3,404 / 2,695 | 0.08 / 0.17 |

The index surface (`index` then `evidence`) gave byte-identical evidence for every question in both forms, so its tables are the same.

