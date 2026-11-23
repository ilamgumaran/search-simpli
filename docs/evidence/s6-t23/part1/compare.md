# Judged set before and after (S6-T23 Part 1 prototype)

Before: `main 87bfd35, ReleaseSmall`, read 246 of 270 files. After: `main 8ffc41c under text-sniff-v1 (s6t23 rename prototype)`, read 270 of 270.
Direct = index, before: {'both/typed': {'identical': 181, 'of': 181}, 'both/query': {'identical': 181, 'of': 181}, 'content/typed': {'identical': 181, 'of': 181}, 'content/query': {'identical': 181, 'of': 181}}.
Direct = index, after: {'both/typed': {'identical': 181, 'of': 181}, 'both/query': {'identical': 181, 'of': 181}, 'content/typed': {'identical': 181, 'of': 181}, 'content/query': {'identical': 181, 'of': 181}}.

Cells are typed / query, before → after (bold when they differ). Counts are questions.

## `--search-field both`

Finding:

| Total | file@1 | file@3 | file@10 | passage@1 | passage@10 | complete | not_read |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| total (169) | 94 → **97** / 116 → **130** | 117 → **123** / 132 → **147** | 132 → **138** / 135 → **155** | 85 → **90** / 104 → **118** | 120 → **129** / 123 → **144** | 100 → **109** / 109 → **127** | 31 → **0** / 31 → **0** |
| readable now (146) | 94 → **90** / 115 | 117 → **116** / 130 | 131 → **129** / 133 | 85 → **83** / 103 | 119 → **120** / 121 → **122** | 100 → **102** / 109 → **108** | 8 → **0** / 8 → **0** |
| without single-source (116) | 62 → **60** / 80 → **87** | 79 / 89 → **98** | 90 → **91** / 92 → **103** | 55 / 70 → **76** | 78 → **82** / 82 → **93** | 68 → **72** / 75 → **85** | 19 → **0** / 19 → **0** |

Tightness and ranking:

| Total | complete_within | evidence_bytes_median | judged_share_mean | first_passage | stale_first |
| --- | ---: | ---: | ---: | ---: | ---: |
| total (169) | 9 → **10** / 36 | 11,814 → **12,042** / 9,475 → **10,553** | 0.065 → **0.070** / 0.148 → **0.152** | 100 → **109** / 109 → **127** | 10 / 5 |
| readable now (146) | 9 / 36 → **32** | 11,769 → **11,829** / 8,566 → **10,473** | 0.075 → **0.078** / 0.164 → **0.162** | 100 → **102** / 109 → **108** | 10 / 5 |
| without single-source (116) | 8 / 25 → **24** | 11,774 → **11,876** / 8,574 → **10,616** | 0.071 → **0.075** / 0.175 → **0.174** | 68 → **72** / 75 → **85** | 9 / 5 |

Per kind:

| Kind | n | file@1 | file@10 | complete | complete_within | not_read |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| word | 15 | 11 → **12** / 12 → **13** | 11 → **12** / 12 → **15** | 11 → **12** / 12 → **15** | 1 / 3 → **4** | 4 → **0** / 4 → **0** |
| word-form | 13 | 12 / 11 | 12 / 11 | 12 / 11 | 1 / 11 | 0 / 0 |
| misspelt | 12 | 10 / 11 | 12 / 11 | 8 → **9** / 9 | 3 / 6 → **5** | 1 → **0** / 1 → **0** |
| phrase | 12 | 11 → **12** / 11 → **12** | 11 → **12** / 11 → **12** | 11 → **12** / 11 → **12** | 1 → **2** / 1 → **2** | 1 → **0** / 1 → **0** |
| number | 12 | 9 → **11** / 8 → **10** | 10 → **12** / 10 → **12** | 10 → **12** / 10 → **12** | 0 / 4 | 4 → **0** / 4 → **0** |
| two-passages | 11 | 4 → **5** / 7 | 11 / 11 | 0 / 0 | 0 / 0 | 1 → **0** / 1 → **0** |
| two-files | 11 | 7 → **8** / 8 → **9** | 9 → **10** / 9 → **10** | 6 → **7** / 7 | 0 / 0 | 1 → **0** / 1 → **0** |
| filename | 12 | 7 / 10 → **11** | 10 / 11 → **12** | 10 / 11 → **12** | 1 / 4 | 1 → **0** / 1 → **0** |
| about | 11 | 8 → **4** / 10 | 10 / 11 | 4 / 8 → **7** | 0 / 2 → **1** | 3 → **0** / 3 → **0** |
| file-content | 11 | 3 → **2** / 7 → **10** | 8 → **7** / 8 → **11** | 8 → **7** / 8 → **11** | 0 / 2 → **1** | 3 → **0** / 3 → **0** |
| tamil-latin | 10 | 5 / 7 | 5 / 7 | 4 / 5 | 2 / 2 | 0 / 0 |
| synonym | 10 | 2 / 3 | 6 / 6 | 2 → **3** / 3 | 0 / 0 | 0 / 0 |
| table | 10 | 4 → **5** / 5 → **8** | 6 → **7** / 6 → **10** | 6 → **7** / 6 → **10** | 0 / 1 | 5 → **0** / 5 → **0** |
| current-copy | 9 | 0 / 4 | 8 / 8 | 5 → **6** / 5 | 0 / 0 | 0 / 0 |
| where-is-it | 10 | 1 → **2** / 2 → **4** | 3 → **4** / 3 → **8** | 3 → **4** / 3 → **8** | 0 / 0 → **1** | 7 → **0** / 7 → **0** |

No-answer (12), returned anything: 11 / 8

## `--search-field content`

Finding:

| Total | file@1 | file@3 | file@10 | passage@1 | passage@10 | complete | not_read |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| total (169) | 94 → **97** / 116 → **130** | 117 → **123** / 132 → **147** | 130 → **138** / 134 → **154** | 85 → **90** / 104 → **118** | 123 → **132** / 125 → **145** | 110 → **120** / 118 → **137** | 31 → **0** / 31 → **0** |
| readable now (146) | 94 → **90** / 115 | 117 → **116** / 130 | 129 / 132 | 85 → **83** / 103 | 122 → **123** / 123 | 110 → **113** / 118 | 8 → **0** / 8 → **0** |
| without single-source (116) | 62 → **60** / 80 → **87** | 79 / 89 → **98** | 89 → **91** / 91 → **102** | 55 / 70 → **76** | 82 → **85** / 82 → **93** | 76 → **79** / 78 → **89** | 19 → **0** / 19 → **0** |

Tightness and ranking:

| Total | complete_within | evidence_bytes_median | judged_share_mean | first_passage | stale_first |
| --- | ---: | ---: | ---: | ---: | ---: |
| total (169) | 91 → **94** / 100 → **102** | 3,482 → **3,582** / 2,809 → **2,944** | 0.069 → **0.070** / 0.145 → **0.148** | 99 → **109** / 108 → **126** | 9 → **10** / 5 |
| readable now (146) | 91 → **90** / 100 → **91** | 3,404 → **3,478** / 2,719 → **2,914** | 0.080 → **0.078** / 0.161 → **0.158** | 99 → **102** / 108 → **107** | 9 → **10** / 5 |
| without single-source (116) | 65 / 67 → **68** | 3,404 → **3,496** / 2,695 → **2,774** | 0.076 → **0.075** / 0.165 → **0.166** | 68 → **72** / 74 → **84** | 8 → **9** / 5 |

Per kind:

| Kind | n | file@1 | file@10 | complete | complete_within | not_read |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| word | 15 | 11 → **12** / 12 → **13** | 11 → **12** / 12 → **15** | 11 → **12** / 12 → **15** | 7 → **8** / 8 → **9** | 4 → **0** / 4 → **0** |
| word-form | 13 | 12 / 11 | 12 / 11 | 12 / 11 | 12 / 11 | 0 / 0 |
| misspelt | 12 | 10 / 11 | 12 / 11 | 11 / 9 | 10 → **9** / 9 | 1 → **0** / 1 → **0** |
| phrase | 12 | 11 → **12** / 11 → **12** | 11 → **12** / 11 → **12** | 11 → **12** / 11 → **12** | 10 → **11** / 10 → **11** | 1 → **0** / 1 → **0** |
| number | 12 | 9 → **11** / 8 → **10** | 10 → **12** / 10 → **12** | 10 → **12** / 10 → **12** | 7 → **8** / 7 | 4 → **0** / 4 → **0** |
| two-passages | 11 | 4 → **5** / 7 | 11 / 11 | 6 → **7** / 9 | 4 → **3** / 7 → **6** | 1 → **0** / 1 → **0** |
| two-files | 11 | 7 → **8** / 8 → **9** | 9 → **10** / 9 → **10** | 6 → **7** / 7 | 5 → **6** / 6 → **5** | 1 → **0** / 1 → **0** |
| filename | 12 | 7 / 10 → **11** | 10 / 11 → **12** | 10 / 11 → **12** | 9 → **8** / 10 | 1 → **0** / 1 → **0** |
| about | 11 | 8 → **4** / 10 | 10 / 11 | 5 / 8 | 5 / 8 → **7** | 3 → **0** / 3 → **0** |
| file-content | 11 | 3 → **2** / 7 → **10** | 7 / 8 → **11** | 7 / 8 → **11** | 5 / 7 → **6** | 3 → **0** / 3 → **0** |
| tamil-latin | 10 | 5 / 7 | 5 / 7 | 4 / 5 | 4 / 4 | 0 / 0 |
| synonym | 10 | 2 / 3 | 6 / 5 | 2 → **3** / 2 | 2 → **1** / 1 | 0 / 0 |
| table | 10 | 4 → **5** / 5 → **8** | 6 → **7** / 6 → **10** | 6 → **7** / 6 → **10** | 4 → **6** / 5 → **7** | 5 → **0** / 5 → **0** |
| current-copy | 9 | 0 / 4 | 7 → **8** / 8 | 6 → **7** / 6 | 6 → **7** / 6 | 0 / 0 |
| where-is-it | 10 | 1 → **2** / 2 → **4** | 3 → **4** / 3 → **8** | 3 → **4** / 3 → **8** | 1 / 1 → **3** | 7 → **0** / 7 → **0** |

No-answer (12), returned anything: 11 / 8

## Questions that got worse

Per question, every configuration (surface/field/form) in which it got worse and how. Judged-share drops alone are counted at the end, not listed.

- **spell-10** (misspelt):
  - `direct/both/typed`: within budget lost (3145 → 5980 bytes); first paths after ['toolshare/data/inventory.yaml', 'toolshare/data/loans-2026.csv']
  - `direct/both/query`: within budget lost (3145 → 5980 bytes); first paths after ['toolshare/data/inventory.yaml', 'toolshare/data/loans-2026.csv']
  - `index/both/typed`: within budget lost (3145 → 5980 bytes); first paths after ['toolshare/data/inventory.yaml', 'toolshare/data/loans-2026.csv']
  - `index/both/query`: within budget lost (3145 → 5980 bytes); first paths after ['toolshare/data/inventory.yaml', 'toolshare/data/loans-2026.csv']
- **name-06** (filename):
  - `direct/both/typed`: file rank 5 → 9; passage rank 5 → 9; first paths after ['toolshare/site/app.js', 'toolshare/docs/issues.md']
  - `direct/content/typed`: file rank 5 → 9; passage rank 5 → 9; first paths after ['toolshare/site/app.js', 'toolshare/docs/issues.md']
  - `index/both/typed`: file rank 5 → 9; passage rank 5 → 9; first paths after ['toolshare/site/app.js', 'toolshare/docs/issues.md']
  - `index/content/typed`: file rank 5 → 9; passage rank 5 → 9; first paths after ['toolshare/site/app.js', 'toolshare/docs/issues.md']
- **name-09** (filename):
  - `direct/both/typed`: complete lost; file rank 8 → None; passage rank 8 → None; first paths after ['home/house/house-notes.md', 'home/notes/baking-log.txt']
  - `direct/content/typed`: complete lost; within budget lost (3318 → 3387 bytes); file rank 8 → None; passage rank 8 → None; first paths after ['home/house/house-notes.md', 'home/notes/baking-log.txt']
  - `index/both/typed`: complete lost; file rank 8 → None; passage rank 8 → None; first paths after ['home/house/house-notes.md', 'home/notes/baking-log.txt']
  - `index/content/typed`: complete lost; within budget lost (3318 → 3387 bytes); file rank 8 → None; passage rank 8 → None; first paths after ['home/house/house-notes.md', 'home/notes/baking-log.txt']
- **about-01** (about):
  - `direct/both/typed`: file rank 1 → 2; passage rank 1 → 2; first paths after ['toolshare/README', 'school/bee-project.md']
  - `direct/content/typed`: file rank 1 → 2; passage rank 1 → 2; first paths after ['toolshare/README', 'school/bee-project.md']
  - `index/both/typed`: file rank 1 → 2; passage rank 1 → 2; first paths after ['toolshare/README', 'school/bee-project.md']
  - `index/content/typed`: file rank 1 → 2; passage rank 1 → 2; first paths after ['toolshare/README', 'school/bee-project.md']
- **about-05** (about):
  - `direct/both/typed`: file rank 1 → 2; passage rank 1 → 2; first paths after ['toolshare/README', 'toolshare/docs/repairs.md']
  - `direct/content/typed`: file rank 1 → 2; passage rank 1 → 2; first paths after ['toolshare/README', 'toolshare/docs/repairs.md']
  - `direct/content/query`: within budget lost (3917 → 5613 bytes); first paths after ['toolshare/docs/repairs.md', 'toolshare/docs/treasurer.md']
  - `index/both/typed`: file rank 1 → 2; passage rank 1 → 2; first paths after ['toolshare/README', 'toolshare/docs/repairs.md']
  - `index/content/typed`: file rank 1 → 2; passage rank 1 → 2; first paths after ['toolshare/README', 'toolshare/docs/repairs.md']
  - `index/content/query`: within budget lost (3917 → 5613 bytes); first paths after ['toolshare/docs/repairs.md', 'toolshare/docs/treasurer.md']
- **about-07** (about):
  - `direct/both/typed`: file rank 2 → 4; passage rank 2 → 4; first paths after ['toolshare/README', 'journal/2026-09-01.md']
  - `direct/content/typed`: file rank 2 → 4; passage rank 2 → 4; first paths after ['toolshare/README', 'journal/2026-09-01.md']
  - `index/both/typed`: file rank 2 → 4; passage rank 2 → 4; first paths after ['toolshare/README', 'journal/2026-09-01.md']
  - `index/content/typed`: file rank 2 → 4; passage rank 2 → 4; first paths after ['toolshare/README', 'journal/2026-09-01.md']
- **about-08** (about):
  - `direct/both/typed`: file rank 1 → 2; passage rank 4 → 6; first paths after ['toolshare/README', 'home/house/damp-bedroom.md']
  - `direct/both/query`: complete lost; within budget lost (4047 → 5043 bytes); passage rank 1 → 3; first paths after ['home/house/damp-bedroom.md', 'inbox/NOTES']
  - `direct/content/typed`: file rank 1 → 2; passage rank 2 → 3; first paths after ['toolshare/README', 'home/house/damp-bedroom.md']
  - `direct/content/query`: passage rank 1 → 2; first paths after ['home/house/damp-bedroom.md', 'home/house/damp-bedroom.md']
  - `index/both/typed`: file rank 1 → 2; passage rank 4 → 6; first paths after ['toolshare/README', 'home/house/damp-bedroom.md']
  - `index/both/query`: complete lost; within budget lost (4047 → 5043 bytes); passage rank 1 → 3; first paths after ['home/house/damp-bedroom.md', 'inbox/NOTES']
  - `index/content/typed`: file rank 1 → 2; passage rank 2 → 3; first paths after ['toolshare/README', 'home/house/damp-bedroom.md']
  - `index/content/query`: passage rank 1 → 2; first paths after ['home/house/damp-bedroom.md', 'home/house/damp-bedroom.md']
- **about-09** (about):
  - `direct/both/typed`: file rank 5 → 6; passage rank 5 → 6; first paths after ['toolshare/README', 'toolshare/meetings/2026-02-committee.md']
  - `direct/both/query`: file rank 3 → 4; passage rank 3 → 4; first paths after ['toolshare/README', 'toolshare/meetings/2026-02-committee.md']
  - `direct/content/typed`: file rank 5 → 6; passage rank 5 → 6; first paths after ['toolshare/README', 'toolshare/meetings/2026-02-committee.md']
  - `direct/content/query`: file rank 3 → 4; passage rank 3 → 4; first paths after ['toolshare/README', 'toolshare/meetings/2026-02-committee.md']
  - `index/both/typed`: file rank 5 → 6; passage rank 5 → 6; first paths after ['toolshare/README', 'toolshare/meetings/2026-02-committee.md']
  - `index/both/query`: file rank 3 → 4; passage rank 3 → 4; first paths after ['toolshare/README', 'toolshare/meetings/2026-02-committee.md']
  - `index/content/typed`: file rank 5 → 6; passage rank 5 → 6; first paths after ['toolshare/README', 'toolshare/meetings/2026-02-committee.md']
  - `index/content/query`: file rank 3 → 4; passage rank 3 → 4; first paths after ['toolshare/README', 'toolshare/meetings/2026-02-committee.md']
- **about-10** (about):
  - `direct/both/typed`: file rank 1 → 2; passage rank 1 → 2; first paths after ['toolshare/README', 'archive/sourdough-copy.md']
  - `direct/content/typed`: file rank 1 → 2; passage rank 1 → 2; first paths after ['toolshare/README', 'archive/sourdough-copy.md']
  - `index/both/typed`: file rank 1 → 2; passage rank 1 → 2; first paths after ['toolshare/README', 'archive/sourdough-copy.md']
  - `index/content/typed`: file rank 1 → 2; passage rank 1 → 2; first paths after ['toolshare/README', 'archive/sourdough-copy.md']
- **content-01** (file-content):
  - `direct/both/typed`: complete lost; file rank 10 → None; passage rank 10 → None; first paths after ['toolshare/src/app.py', 'toolshare/docs/treasurer.md']
  - `index/both/typed`: complete lost; file rank 10 → None; passage rank 10 → None; first paths after ['toolshare/src/app.py', 'toolshare/docs/treasurer.md']
- **content-05** (file-content):
  - `direct/both/typed`: file rank 4 → 9; passage rank 4 → 9; first paths after ['toolshare/Makefile', 'toolshare/docs/issues.md']
  - `direct/content/typed`: file rank 4 → 9; passage rank 4 → 9; first paths after ['toolshare/Makefile', 'toolshare/docs/issues.md']
  - `direct/content/query`: within budget lost (1851 → 12888 bytes); first paths after ['toolshare/src/reminders.py', 'toolshare/Makefile']
  - `index/both/typed`: file rank 4 → 9; passage rank 4 → 9; first paths after ['toolshare/Makefile', 'toolshare/docs/issues.md']
  - `index/content/typed`: file rank 4 → 9; passage rank 4 → 9; first paths after ['toolshare/Makefile', 'toolshare/docs/issues.md']
  - `index/content/query`: within budget lost (1851 → 12888 bytes); first paths after ['toolshare/src/reminders.py', 'toolshare/Makefile']
- **content-08** (file-content):
  - `direct/both/typed`: file rank 1 → 2; passage rank 1 → 2; first paths after ['toolshare/site/join.html', 'toolshare/site/index.html']
  - `direct/both/query`: within budget lost (3536 → 30577 bytes); first paths after ['toolshare/site/index.html', 'toolshare/site/join.html']
  - `direct/content/typed`: file rank 1 → 2; passage rank 1 → 2; first paths after ['toolshare/site/join.html', 'toolshare/site/index.html']
  - `direct/content/query`: within budget lost (1094 → 13613 bytes); first paths after ['toolshare/site/index.html', 'toolshare/site/join.html']
  - `index/both/typed`: file rank 1 → 2; passage rank 1 → 2; first paths after ['toolshare/site/join.html', 'toolshare/site/index.html']
  - `index/both/query`: within budget lost (3536 → 30577 bytes); first paths after ['toolshare/site/index.html', 'toolshare/site/join.html']
  - `index/content/typed`: file rank 1 → 2; passage rank 1 → 2; first paths after ['toolshare/site/join.html', 'toolshare/site/index.html']
  - `index/content/query`: within budget lost (1094 → 13613 bytes); first paths after ['toolshare/site/index.html', 'toolshare/site/join.html']
- **content-09** (file-content):
  - `direct/both/typed`: file rank 2 → 3; passage rank 2 → 3; first paths after ['toolshare/README', 'home/house/house-notes.md']
  - `direct/content/typed`: file rank 2 → 3; passage rank 2 → 3; first paths after ['toolshare/README', 'home/house/house-notes.md']
  - `index/both/typed`: file rank 2 → 3; passage rank 2 → 3; first paths after ['toolshare/README', 'home/house/house-notes.md']
  - `index/content/typed`: file rank 2 → 3; passage rank 2 → 3; first paths after ['toolshare/README', 'home/house/house-notes.md']
- **syn-02** (synonym):
  - `direct/both/typed`: file rank 10 → None; first paths after ['home/trips/cornwall-2026-draft.md', 'toolshare/meetings/2026-06-committee.md']
  - `direct/content/typed`: file rank 10 → None; first paths after ['home/trips/cornwall-2026-draft.md', 'toolshare/meetings/2026-06-committee.md']
  - `index/both/typed`: file rank 10 → None; first paths after ['home/trips/cornwall-2026-draft.md', 'toolshare/meetings/2026-06-committee.md']
  - `index/content/typed`: file rank 10 → None; first paths after ['home/trips/cornwall-2026-draft.md', 'toolshare/meetings/2026-06-committee.md']
- **syn-09** (synonym):
  - `direct/both/typed`: file rank 3 → 4; passage rank 3 → 4; first paths after ['toolshare/README', 'toolshare/docs/lending-rules.md']
  - `direct/both/query`: file rank 8 → 9; passage rank 8 → 9; first paths after ['toolshare/site/index.html', 'toolshare/config/server.yaml']
  - `direct/content/typed`: within budget lost (3825 → 4325 bytes); file rank 3 → 4; passage rank 3 → 4; first paths after ['toolshare/README', 'toolshare/docs/lending-rules.md']
  - `direct/content/query`: file rank 8 → 9; passage rank 8 → 9; first paths after ['toolshare/site/index.html', 'toolshare/config/server.yaml']
  - `index/both/typed`: file rank 3 → 4; passage rank 3 → 4; first paths after ['toolshare/README', 'toolshare/docs/lending-rules.md']
  - `index/both/query`: file rank 8 → 9; passage rank 8 → 9; first paths after ['toolshare/site/index.html', 'toolshare/config/server.yaml']
  - `index/content/typed`: within budget lost (3825 → 4325 bytes); file rank 3 → 4; passage rank 3 → 4; first paths after ['toolshare/README', 'toolshare/docs/lending-rules.md']
  - `index/content/query`: file rank 8 → 9; passage rank 8 → 9; first paths after ['toolshare/site/index.html', 'toolshare/config/server.yaml']
- **cur-04** (current-copy):
  - `direct/both/typed`: file rank 10 → None; first paths after ['home/contacts.tsv', 'toolshare/site/index.html']
  - `direct/content/typed`: stale copy now first; first paths after ['home/contacts.tsv', 'toolshare/site/index.html']
  - `index/both/typed`: file rank 10 → None; first paths after ['home/contacts.tsv', 'toolshare/site/index.html']
  - `index/content/typed`: stale copy now first; first paths after ['home/contacts.tsv', 'toolshare/site/index.html']
- **cur-09** (current-copy):
  - `direct/both/typed`: file rank 7 → 8; passage rank 7 → 8; first paths after ['toolshare/meetings/2026-11-committee.md', 'toolshare/meetings/2026-06-committee.md']
  - `direct/content/typed`: file rank 7 → 8; passage rank 7 → 8; first paths after ['toolshare/meetings/2026-11-committee.md', 'toolshare/meetings/2026-06-committee.md']
  - `index/both/typed`: file rank 7 → 8; passage rank 7 → 8; first paths after ['toolshare/meetings/2026-11-committee.md', 'toolshare/meetings/2026-06-committee.md']
  - `index/content/typed`: file rank 7 → 8; passage rank 7 → 8; first paths after ['toolshare/meetings/2026-11-committee.md', 'toolshare/meetings/2026-06-committee.md']
- **where-05** (where-is-it):
  - `direct/both/typed`: file rank 2 → 3; passage rank 2 → 3; first paths after ['toolshare/README', 'toolshare/pyproject.toml']
  - `direct/content/typed`: file rank 2 → 3; passage rank 2 → 3; first paths after ['toolshare/README', 'toolshare/pyproject.toml']
  - `index/both/typed`: file rank 2 → 3; passage rank 2 → 3; first paths after ['toolshare/README', 'toolshare/pyproject.toml']
  - `index/content/typed`: file rank 2 → 3; passage rank 2 → 3; first paths after ['toolshare/README', 'toolshare/pyproject.toml']
- **number-12** (number):
  - `direct/both/query`: file rank 8 → 9; passage rank 8 → 9; first paths after ['toolshare/logs/server-2026-11.log', 'journal/2026-09-30.md']
  - `direct/content/query`: file rank 8 → 9; passage rank 8 → 9; first paths after ['toolshare/logs/server-2026-11.log', 'journal/2026-09-30.md']
  - `index/both/query`: file rank 8 → 9; passage rank 8 → 9; first paths after ['toolshare/logs/server-2026-11.log', 'journal/2026-09-30.md']
  - `index/content/query`: file rank 8 → 9; passage rank 8 → 9; first paths after ['toolshare/logs/server-2026-11.log', 'journal/2026-09-30.md']
- **span-11** (two-passages):
  - `direct/both/query`: file rank 2 → 3; passage rank 2 → 3; first paths after ['toolshare/docs/repairs.md', 'toolshare/data/loans-2026.csv']
  - `direct/content/query`: within budget lost (3392 → 4594 bytes); file rank 2 → 3; passage rank 2 → 3; first paths after ['toolshare/docs/repairs.md', 'toolshare/data/loans-2026.csv']
  - `index/both/query`: file rank 2 → 3; passage rank 2 → 3; first paths after ['toolshare/docs/repairs.md', 'toolshare/data/loans-2026.csv']
  - `index/content/query`: within budget lost (3392 → 4594 bytes); file rank 2 → 3; passage rank 2 → 3; first paths after ['toolshare/docs/repairs.md', 'toolshare/data/loans-2026.csv']
- **content-06** (file-content):
  - `direct/both/query`: within budget lost (3313 → 35568 bytes); first paths after ['toolshare/src/app.py', 'toolshare/config/server.yaml']
  - `direct/content/query`: within budget lost (979 → 15365 bytes); first paths after ['toolshare/src/app.py', 'toolshare/config/server.yaml']
  - `index/both/query`: within budget lost (3313 → 35568 bytes); first paths after ['toolshare/src/app.py', 'toolshare/config/server.yaml']
  - `index/content/query`: within budget lost (979 → 15365 bytes); first paths after ['toolshare/src/app.py', 'toolshare/config/server.yaml']
- **spell-01** (misspelt):
  - `direct/content/typed`: within budget lost (2972 → 4589 bytes); first paths after ['home/house/damp-bedroom.md', 'toolshare/config/server.yaml']
  - `index/content/typed`: within budget lost (2972 → 4589 bytes); first paths after ['home/house/damp-bedroom.md', 'toolshare/config/server.yaml']
- **number-03** (number):
  - `direct/content/typed`: within budget lost (3779 → 4472 bytes); first paths after ['toolshare/docs/treasurer.md', 'toolshare/docs/treasurer.md']
  - `index/content/typed`: within budget lost (3779 → 4472 bytes); first paths after ['toolshare/docs/treasurer.md', 'toolshare/docs/treasurer.md']
- **span-06** (two-passages):
  - `direct/content/typed`: within budget lost (4074 → 4742 bytes); first paths after ['home/trips/cornwall-2026.md', 'home/trips/directions-to-gull-cottage.txt']
  - `index/content/typed`: within budget lost (4074 → 4742 bytes); first paths after ['home/trips/cornwall-2026.md', 'home/trips/directions-to-gull-cottage.txt']
- **name-01** (filename):
  - `direct/content/typed`: passage rank 6 → 7; first paths after ['home/house/house-notes.md', 'archive/boiler-2025.md']
  - `index/content/typed`: passage rank 6 → 7; first paths after ['home/house/house-notes.md', 'archive/boiler-2025.md']
- **word-01** (word):
  - `direct/content/query`: within budget lost (2973 → 4590 bytes); first paths after ['home/house/damp-bedroom.md', 'toolshare/config/server.yaml']
  - `index/content/query`: within budget lost (2973 → 4590 bytes); first paths after ['home/house/damp-bedroom.md', 'toolshare/config/server.yaml']
- **word-11** (word):
  - `direct/content/query`: within budget lost (1856 → 12974 bytes); first paths after ['toolshare/src/reminders.py', 'toolshare/docs/issues.md']
  - `index/content/query`: within budget lost (1856 → 12974 bytes); first paths after ['toolshare/src/reminders.py', 'toolshare/docs/issues.md']
- **number-02** (number):
  - `direct/content/query`: within budget lost (3368 → 4576 bytes); first paths after ['toolshare/docs/repairs.md', 'toolshare/data/loans-2026.csv']
  - `index/content/query`: within budget lost (3368 → 4576 bytes); first paths after ['toolshare/docs/repairs.md', 'toolshare/data/loans-2026.csv']
- **pair-05** (two-files):
  - `direct/content/query`: within budget lost (1811 → 11156 bytes); first paths after ['toolshare/config/server.yaml', 'toolshare/src/app.py']
  - `index/content/query`: within budget lost (1811 → 11156 bytes); first paths after ['toolshare/config/server.yaml', 'toolshare/src/app.py']
- **where-08** (where-is-it):
  - `direct/content/query`: within budget lost (3780 → 4210 bytes); first paths after ['home/lists/useful-numbers.txt', 'home/contacts.tsv']
  - `index/content/query`: within budget lost (3780 → 4210 bytes); first paths after ['home/lists/useful-numbers.txt', 'home/contacts.tsv']

Judged share lower by more than 0.005 and nothing else worse: `direct/both/typed` 22, `direct/both/query` 21, `direct/content/typed` 26, `direct/content/query` 10, `index/both/typed` 22, `index/both/query` 21, `index/content/typed` 26, `index/content/query` 10.

## Questions that got better (direct surface)

- `direct/both/typed`, 16: word-12 (complete, file found at 1); spell-04 (complete); phrase-10 (complete, file found at 1); number-05 (complete, file found at 1); number-08 (complete, file found at 1); span-03 (file rank 2 → 1); span-04 (file rank 5 → 2); span-11 (file rank 6 → 5); pair-03 (complete); pair-06 (file found at 1); name-10 (complete, file found at 4); syn-03 (complete, file found at 9); syn-04 (file rank 5 → 4); table-10 (complete, file found at 1); cur-05 (complete, file found at 10); where-02 (complete, file found at 1)
- `direct/both/query`, 21: word-07 (complete, file found at 4); word-08 (complete, file found at 2); word-12 (complete, file found at 1); phrase-10 (complete, file found at 1); number-05 (complete, file found at 1); number-08 (complete, file found at 1); span-04 (file rank 3 → 2); pair-06 (file found at 1); name-10 (complete, file found at 1); content-02 (complete, file found at 1); content-03 (complete, file found at 1); content-11 (complete, file found at 1); table-06 (complete, file found at 1); table-08 (complete, file found at 1); table-09 (complete, file found at 7); table-10 (complete, file found at 1); where-01 (complete, file found at 2); where-02 (complete, file found at 1); where-03 (complete, file found at 8); where-06 (complete, file found at 5); where-07 (complete, file found at 1)
- `direct/content/typed`, 15: word-12 (complete, file found at 1); phrase-10 (complete, file found at 1); number-05 (complete, file found at 1); number-08 (complete, file found at 1); span-03 (file rank 2 → 1); span-04 (complete, file rank 5 → 2); span-11 (file rank 6 → 5); pair-03 (complete); pair-06 (file found at 1); name-10 (complete, file found at 4); syn-03 (complete, file found at 9); syn-04 (file rank 5 → 4); table-10 (complete, file found at 1); cur-05 (complete, file found at 10); where-02 (complete, file found at 1)
- `direct/content/query`, 21: word-07 (complete, file found at 4); word-08 (complete, file found at 2); word-12 (complete, file found at 1); phrase-10 (complete, file found at 1); number-05 (complete, file found at 1); number-08 (complete, file found at 1); span-04 (file rank 3 → 2); pair-06 (file found at 1); name-10 (complete, file found at 1); content-02 (complete, file found at 1); content-03 (complete, file found at 1); content-11 (complete, file found at 1); table-06 (complete, file found at 1); table-08 (complete, file found at 1); table-09 (complete, file found at 7); table-10 (complete, file found at 1); where-01 (complete, file found at 2); where-02 (complete, file found at 1); where-03 (complete, file found at 8); where-06 (complete, file found at 5); where-07 (complete, file found at 1)
