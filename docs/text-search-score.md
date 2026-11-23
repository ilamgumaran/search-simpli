# Text-search score: the right file and the right passage

Status: built by S6-T22 ([plan step H1](plans/2026-11-16-objective-plan.md#h-text-search-done-well-the-priority-of-22-nov-2026)),
reworked after its Verdict (rework 1) and its second Verdict (rework 2), both 22 Nov 2026. The baseline below is
`main`'s engine at `87bfd35` (ReleaseSmall), measured on 22 Nov 2026 on the rework-2 set. Its files are in
[`docs/evidence/s6-t22/`](evidence/s6-t22/). The earlier baselines are kept:
[`baseline-v1.md`](evidence/s6-t22/baseline-v1.md) (129 questions, `b8852d8`) and
[`baseline-rework-1.md`](evidence/s6-t22/baseline-rework-1.md).

The maintainer's priority is text search done very well: find the files relevant to a question, and answer
from the relevant parts of them. The other judged sets ([J2](../fixtures/j2/README.md),
[the family folder](../fixtures/family-folder/README.md)) score ranking. This set runs end to end through
`searchd` and asks two things: did the right file come back, and did the passage that answers come back with it.
It also asks how much other text came with that passage. Steps H2 to H6 are judged by how they move it.

## What the set is

| Piece | File | What it does |
| --- | --- | --- |
| The folder | [`scripts/gen_text_search_corpus.py`](../scripts/gen_text_search_corpus.py) | writes 270 invented files (141,870 bytes) from seed 2211, the same every time |
| The questions | [`scripts/text_search_questions.py`](../scripts/text_search_questions.py) | holds the 181 hand-written questions; writes the judgments, computing line numbers and `single_source` from the folder |
| The judgments | [`fixtures/text-search/judgments.json`](../fixtures/text-search/judgments.json) | `text-search-judgments-v2`, set version 3: per question, the question as typed, the query words, the kind, the files, the line ranges, the stale copies, the checks, `single_source` and `readable_now` |
| The freeze | [`fixtures/text-search/question-digests.json`](../fixtures/text-search/question-digests.json) | one sha256 per question over its id, kind, question, query, files, parts (ranges, keys and alternatives), stale copies and checks (rework 2) |
| The scorer | [`scripts/text_search_score.py`](../scripts/text_search_score.py) | runs `searchd` in both forms, on both surfaces, with both fields; writes a JSON file and Markdown tables |
| The tests | [`tests/test_text_search_score.py`](../tests/test_text_search_score.py) | 36 tests: the folder, the judgments against the folder, the freeze, the contradiction search, the scorer's arithmetic, one run through `searchd` |

**The folder** holds what a household and a small project keep:

- the Pellow family's notes, lists, recipes, schedules, receipts and trip plans;
- their grandmother's notes in Tamil;
- a year's garden diary (1,462 lines) and a journal;
- the files of the Harrowdean Tool Share, a volunteer lending library: documents, meeting notes, a YAML
  inventory, configuration, Python and JavaScript source, HTML pages and server logs.

Shapes:

- by type: 162 Markdown, 72 plain text, 12 `.log`, 4 CSV, 2 TSV, 2 JSON, 2 YAML, 2 HTML, 3 Python, one each of
  TOML, JavaScript, CSS, shell and XML, and 4 files with no extension;
- one-line files, a CRLF file and a Tamil file name;
- an exact duplicate and three near duplicates;
- files whose name says more than their text;
- five older or draft copies that disagree with the current file (added in rework 1), and two archive copies of
  version 1 that do too. Each of the seven says so in its own text (rework 2): a last line `Status: superseded.`
  (`Status: draft, superseded.` in the Cornwall draft, whose title also says "(draft)", as the draft calendar's
  does). The line holds no word of its topic, so it does not pull the old copy up for a topic query;
- a Markdown table of school clubs (added in rework 1).

Rework 1 only added files. Rework 2 changed three files of version 1 on purpose (`CHANGED_IN_REWORK_2` in the
generator): `archive/committee-2025.md` and `archive/house-notes-2024.md` gained the status line, and
`inbox/note-08.txt`, a line from the sentence pool, now says Wilf does the Saturday *repairs* on the 21st, not the
*desk*, which contradicted the rota that table-09 judges. The other 261 keep their bytes (shown by
`test_the_files_of_version_1_keep_their_bytes`, which also pins the three new digests). Every name, firm and number is invented. Phone numbers are in
the 01632 960xxx drama range and web addresses end in `.invalid`. The one real place is the county of Cornwall,
where a trip goes.

**The questions**: 181, in sixteen kinds. The last five came from the Verdict's gap list.

| Kind | n | What it asks |
| --- | ---: | --- |
| `word` | 15 | a word the file holds |
| `word-form` | 13 | another form of a word the file holds: plural, tense, irregular plural, Tamil inflection |
| `misspelt` | 12 | a misspelt word (11 Latin, 1 Tamil); the file holds the right spelling |
| `phrase` | 12 | an exact phrase whose words also occur apart in other files |
| `number` | 12 | a number, date or code |
| `two-passages` | 11 | an answer in two passages of one file |
| `two-files` | 11 | an answer that needs two files |
| `filename` | 12 | a question about the file's name, not its text |
| `about` | 11 | "which files are about X" |
| `file-content` | 11 | "what is in this file" |
| `no-answer` | 12 | nothing answers; the right result is nothing |
| `tamil-latin` | 10 | Tamil asked in Latin letters (`pongal`, `rasam`); the file is in Tamil script |
| `synonym` | 10 | another word or a paraphrase, not a word form (orthodontist for the brace review, rubbish for bin) |
| `table` | 10 | a row found by one column's value; the answer is another column of that row |
| `current-copy` | 9 | two files disagree; the answer is the current one, and the older or draft copy is judged `stale`; the copy's own text says it is a draft or superseded |
| `where-is-it` | 10 | a file asked for by its type or role ("the spreadsheet with the loans") |

The Verdict also asked for the whole question typed with no key words picked. That is not a separate kind. Every
question is sent that way as well (the *typed* form, below).

Kind notes: word-13 is a `word` question with two parts (a date and what to bring). The `two-files` kind is not
comparable with version 1: rework 1 moved v1's pair-04, pair-06 and pair-07, which one file answered, to
word-13/14/15 and wrote new two-file questions under those ids, so compare `two-files` only from rework 1 on.
where-05 ("python loan record") reaches `models.py` through "records" and "loans" in its docstring, a word-form
match more than a match by role. about-09 counts `site/sitemap.xml` as site code, because the folder's README
says the website code is `src/` and `site/`.

Each answer is a list of *parts*, one for each thing a complete answer cites: two for a two-passage or two-file
question, one per file for `about`. A part lists the line ranges that satisfy it. Any one of them is enough: an
exact copy, or another file that says the same. For example, the useful-numbers list and `contacts.tsv` both
give the chimney sweep's number.

**Stale copies, one rule for all 181** (rework 2). An older or draft copy that *contradicts* the judged answer is
marked `stale` on that question; returning it is not an answer, and ranking it first is counted. A copy that
*agrees* and answers is an alternative instead (syn-02 and syn-03 with the 2024 house notes, syn-08 with the 2025
committee list, about-02 and about-03 with the Cornwall draft and the 2024 Pickle note). 22 questions carry a
stale mark: the nine current-copy questions and word-05, spell-06, phrase-01, phrase-02, span-03, span-06, span-07,
span-08, span-10, pair-01, pair-06, name-01 and syn-07.

Eleven questions are asked in Tamil script and ten in Latin letters over Tamil text. Some answers lie in files
the engine does not read today (CSV, TSV, `.log`, shell, XML, no extension). Those questions stay in the set and
miss that part (ruling 3). Rework 1 judged the answers those files hold, so the set will not change when H2 makes
them readable.

**How the judgments are kept honest.**

- Line numbers are never typed. Each range is an anchor text found on exactly one line, and the generator
  computes the numbers.
- The test reads every committed range back from a freshly generated folder, using its own line splitter, and
  requires the range's key words in it.
- Misspelt and no-answer questions name words that must occur in no file. Word-form, file-name, synonym and
  where-is-it questions name words that must not occur in the file of each part's first range. The test checks
  both as tokens of the repository analyzer. That analyzer does not stem, so the check proves a word is absent
  from the text; it does not prove the engine finds nothing (none-10 below).
- Rework 1 adds these tests:
  - the 129 questions of version 1 keep their wording (a digest of their texts);
  - each answer judged in rework 1 beside an earlier one stays judged, so removing one of two fails;
  - no query uses a word that appears only in its answer and not in the question;
  - `single_source` is recomputed independently;
  - stale copies hold their keys and are never answer files.
- Rework 2 adds these tests:
  - every one of the 181 questions matches its frozen digest, so a change to wording, query, kind, files, a
    range, an alternative, a stale copy or a check fails until it is frozen on purpose (below);
  - every stale copy disagrees with the answer (one of its keys is not in the answer files, or one of the
    answer's keys is not in the copy), says "draft" or "superseded" in its text, and the answer files say
    neither;
  - `readable_now` is recomputed;
  - no other file states a different value for a judged key fact. `contradictions()` in the questions script
    takes each judged key that is a value (a digit, or a name), the words around it on its line (for a table
    row, its other cells and the column heading), and looks in every other file for a line sharing those words
    that holds another value of the same shape. What it returns must equal a reviewed list of five lines, each
    read as not a contradiction (another recipe, another trip, another invoice). It finds the old note-08 and a
    planted sentence, and, with the stale marks removed, the stale copies of 12 of the 22 marked questions; the
    other 10 differ in shape or in words and were marked by reading
    ([`contradictions-rework-2.txt`](evidence/s6-t22/contradictions-rework-2.txt)). It is a net, not a proof.
- Planted faults fail the tests (shown: [`plants.txt`](evidence/s6-t22/plants.txt),
  [`plants-rework-1.txt`](evidence/s6-t22/plants-rework-1.txt), which also puts back each of the five
  borrowed-word queries of version 1, and [`plants-rework-2.txt`](evidence/s6-t22/plants-rework-2.txt)).

## How it is scored

Every question is sent in two forms:

- **typed**: the question as a person typed it;
- **query**: the words a caller would pick (the same text when none were picked).

Each form is sent with `--top-k 10` on two surfaces:

- `searchd search <folder> "<text>" --evidence`: direct search, no index;
- `searchd evidence <index> "<text>"`, over `searchd index <folder> --out <index> --filename-index`.

Each surface runs once with `--search-field both` and once with `--search-field content`. That makes 1,448
`searchd` calls, about 11 s.

Every table cell is *typed / query*.

**Finding**

- **file@k**: an answer file is among the first k distinct files of the results.
- **passage@k**: one of the first k returned passages holds an answer range whole: same path, and the passage
  starts at or before the range and ends at or after it.
- **complete**: every part has a range held by some returned passage.
- **not read**: an answer file is not in `searchd list-files` for the index.
- **answer in its file's first passage (ranking)**: every part is held by the first passage returned from one
  of its ranges' files. A two-passage answer can meet this only through an alternative. It says where the answer
  sits, not how much text came with it: with `both` it equals *complete* (one passage per file), and the
  Verdict's whole-file plant raised it. So it is a ranking measure, reported here and not under tightness.
- **stale copy ranked first** (questions with `stale` ranges): a stale file ranks before every answer file, or is
  returned when no answer file is.
- **returned anything** (no-answer only): any result came back.

**Tightness** (rework 1). Handing over more text must not look like progress.

- **evidence bytes, median**: the size of the envelope on stdout, which is what a caller receives.
- **complete within 4,096 bytes**: complete, with an envelope of at most 4,096 bytes. N = 4,096 (4 KiB) was
  picked from the baselines. It is just above the median envelope with `content` (version 1 mean 2,477;
  rework-1 median 3,479 typed, 2,785 query). It is 35% and 44% of the median with `both` (11,814 / 9,403).
  So it separates the tight answer from the same answer buried in more text.
- **judged share of passage bytes, mean**: the share of the returned passages' bytes that lie inside a judged
  range. Each content line counts with its newline, and line i of a passage is taken as its file's line
  `start_line + i`, after aligning the content's first line to the file (rework 2: 3 of 5,364 passages start
  on a blank line the content skips; the alignment changes no score today, shown:
  [`line-alignment-rework-2.txt`](evidence/s6-t22/line-alignment-rework-2.txt)). 1.0 means nothing but the
  answer came back. With `both` this is the column that catches widening; *complete within 4,096 bytes* barely
  moves there, because most `both` envelopes are over budget already.

**Single-source.** A question is `single_source` when the rarest query word that any readable file holds is
held by exactly one such file. "Readable" means one of the 19 extensions the engine read before H2 (S6-T23), with exact
copies counted once, using the repository analyzer and no stemming. For such a question, file@k mostly measures
whether the file was read, not ranking under competition (the Verdict's finding 8). 53 of the 169 answerable
questions are single-source. `single_source` is computed from the query form only; the typed totals "without
single-source" leave out the same 53. Every table has a total without them.

**Readable now** (rework 2). A question is `readable_now` when every part has a range in a file of one of the 19
extensions the engine read before H2. The list is fixed in the questions script, so H2 does not move the set. 146
of the 169 are readable now; every table has a total over them beside the full total, so H2's gain on the rest
reads as "now readable", not as better ranking. Eight readable-now questions still name an unread file, as an
alternative.

Shares are of the kind's questions. *total* is the 169 questions with an answer.

## How to run it

```sh
cd zig && zig build -Doptimize=ReleaseSmall --prefix <scratch>/prefix && cd ..
python3 scripts/text_search_score.py --searchd <scratch>/prefix/bin/searchd \
    --scratch <scratch>/run --out-json run.json --out-md run.md
```

- `<scratch>/run` must be new or empty; the folder and the index are left there.
- Two runs give byte-identical JSON and Markdown (shown:
  [`build-rework-1.txt`](evidence/s6-t22/build-rework-1.txt)).
- The output holds no time and no absolute path.
- To change a question, edit `scripts/text_search_questions.py`, then run
  `python3 scripts/text_search_questions.py --write fixtures/text-search/judgments.json`. The tests then fail on
  that question's digest. If the change is meant, record it with
  `python3 scripts/text_search_questions.py --freeze fixtures/text-search/question-digests.json`, and list the
  question, with its score before and after, in the task's Report.
- A changed judgment is a reviewed commit named in its task's Report, with its score before and after (the ruling
  after the Verdict).

## The baseline (`main` at `87bfd35`)

Direct search and the index gave byte-identical evidence for all 181 questions, in both forms and with both
fields (shown: `direct_equals_index` in [`baseline-rework-2.json`](evidence/s6-t22/baseline-rework-2.json)). One
set of tables per field therefore stands for both surfaces.

The engines of `b8852d8` and `87bfd35` gave identical rows for all 1,448 calls (shown: `build-rework-1.txt`). The
full tables, with file@3, passage@3 and every tightness column, are in
[`baseline-rework-2.md`](evidence/s6-t22/baseline-rework-2.md). Every question whose judgment or score changed
from rework 1 is listed, before and after, in
[`changed-questions-rework-2.txt`](evidence/s6-t22/changed-questions-rework-2.txt).

Complete, and file@1, per kind (typed / query):

| Kind | n | single-source | not read | `both` file@1 | `both` complete | `content` file@1 | `content` complete |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| word | 15 | 7 | 4 | 11 / 12 | 11 / 12 | 11 / 12 | 11 / 12 |
| word-form | 13 | 2 | 0 | 12 / 11 | 12 / 11 | 12 / 11 | 12 / 11 |
| misspelt | 12 | 0 | 1 | 10 / 11 | 8 / 9 | 10 / 11 | 11 / 9 |
| phrase | 12 | 6 | 1 | 11 / 11 | 11 / 11 | 11 / 11 | 11 / 11 |
| number | 12 | 6 | 4 | 9 / 8 | 10 / 10 | 9 / 8 | 10 / 10 |
| two-passages | 11 | 7 | 1 | 4 / 7 | **0 / 0** | 4 / 7 | 6 / 9 |
| two-files | 11 | 8 | 1 | 7 / 8 | 6 / 7 | 7 / 8 | 6 / 7 |
| filename | 12 | 5 | 1 | 7 / 10 | 10 / 11 | 7 / 10 | 10 / 11 |
| about | 11 | 1 | 3 | 8 / 10 | 4 / 8 | 8 / 10 | 5 / 8 |
| file-content | 11 | 3 | 3 | 3 / 7 | 8 / 8 | 3 / 7 | 7 / 8 |
| tamil-latin | 10 | 0 | 0 | 5 / 7 | 4 / 5 | 5 / 7 | 4 / 5 |
| synonym | 10 | 0 | 0 | 2 / 3 | 2 / 3 | 2 / 3 | 2 / 2 |
| table | 10 | 4 | 5 | 4 / 5 | 6 / 6 | 4 / 5 | 6 / 6 |
| current-copy | 9 | 0 | 0 | **0** / 4 | 5 / 5 | **0** / 4 | 6 / 6 |
| where-is-it | 10 | 4 | 7 | 1 / 2 | 3 / 3 | 1 / 2 | 3 / 3 |
| **total** | 169 | 53 | 31 | **94 / 116** | **100 / 109** | **94 / 116** | **110 / 118** |
| **total readable now** | 146 | 43 | 8 | 94 / 115 | 100 / 109 | 94 / 115 | 110 / 118 |
| **total without single-source** | 116 | 0 | 19 | 62 / 80 | 68 / 75 | 62 / 80 | 76 / 78 |

No-answer (12): 11 / 8 returned something, with either field.

Tightness, totals (typed / query):

| Field | complete | complete within 4,096 bytes | evidence bytes, median | judged share, mean |
| --- | ---: | ---: | ---: | ---: |
| `both` | 100 / 109 | **9 / 36** | 11,814 / 9,475 | 0.07 / 0.15 |
| `content` | 110 / 118 | **91 / 100** | 3,482 / 2,809 | 0.07 / 0.15 |

Over the 146 readable now, the same complete and within-budget counts hold (no complete question needs an unread
file). Ranking measures, totals (typed / query):

| Field | answer in its file's first passage | stale copy ranked first (of 22) |
| --- | ---: | ---: |
| `both` | 100 / 109 | **10 / 5** |
| `content` | 99 / 108 | **9 / 5** |

Counts are questions. "Stale copy first" is out of the 22 questions that name a stale copy. Typed with `both`, the
10 are span-07, pair-01, name-01 and cur-01, 02, 03, 04, 05, 08 and 09; with `content` the same less cur-04. With
the query words, the 5 are span-07, pair-01, cur-01, cur-03 and cur-04, with either field. Rework 1 published
8 / 3 of 12; the change is the rule applied to all questions, syn-02's mark dropped, and the status lines.

## The baseline after H2 (S6-T23 Part 2, contract 2.9.0)

The first baseline above stays as it was: it is what `main` at `87bfd35` (and `8ffc41c`) scores. This is the
second, beside it: the same scorer, questions, judgments, digests and `readable_now` list, run on the engine
that reads every file whose bytes are text (`text-sniff-v1`, [decision 0005](decisions/0005-which-files-are-text.md)).
All 270 files are read (before: 246); no question names an unread file (before: 31). Direct search and the
index again gave byte-identical evidence for all 181 questions in every configuration (shown: `direct_equals_index`
in [`after-h2.json`](evidence/s6-t23/part2/after-h2.json)); the full tables are in
[`after-h2.md`](evidence/s6-t23/part2/after-h2.md), and every cell before → after with every question that got
worse in [`compare.md`](evidence/s6-t23/part2/compare.md). The counts equal Part 1's prototype's in every cell
([`build.txt`](evidence/s6-t23/part2/build.txt)).

Totals, before → after (typed / query):

| | n | `both` file@1 | `both` file@10 | `both` complete | `content` file@1 | `content` file@10 | `content` complete |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| **total** | 169 | 94 → 97 / 116 → 130 | 132 → 138 / 135 → 155 | **100 → 109 / 109 → 127** | 94 → 97 / 116 → 130 | 130 → 138 / 134 → 154 | **110 → 120 / 118 → 137** |
| **readable now** | 146 | 94 → 90 / 115 | 131 → 129 / 133 | 100 → 102 / 109 → 108 | 94 → 90 / 115 | 129 / 132 | 110 → 113 / 118 |
| **without single-source** | 116 | 62 → 60 / 80 → 87 | 90 → 91 / 92 → 103 | 68 → 72 / 75 → 85 | 62 → 60 / 80 → 87 | 89 → 91 / 91 → 102 | 76 → 79 / 78 → 89 |

Tightness and ranking, totals (typed / query):

| Field | complete within 4,096 bytes | evidence bytes, median | judged share, mean | stale copy first (of 22) |
| --- | ---: | ---: | ---: | ---: |
| `both` | 9 → 10 / 36 | 11,814 → 12,034 / 9,475 → 10,553 | 0.065 → 0.070 / 0.148 → 0.152 | 10 / 5 |
| `content` | 91 → 94 / 100 → 102 | 3,482 → 3,582 / 2,809 → 2,944 | 0.069 → 0.070 / 0.145 → 0.148 | 9 → 10 / 5 |
| `both`, readable now | 9 / 36 → 32 | 11,769 → 11,829 / 8,566 → 10,473 | 0.075 → 0.078 / 0.164 → 0.162 | 10 / 5 |
| `content`, readable now | 91 → 90 / 100 → 91 | 3,404 → 3,478 / 2,719 → 2,914 | 0.080 → 0.078 / 0.161 → 0.158 | 9 → 10 / 5 |

No-answer (12): 11 / 8 returned something, unchanged.

**What H2 did not do.** Thirty questions got worse in some configuration (29 readable now, and `about-09`). None
is lost by the walk: the files read before have the same chunks. They come from ranking and the ten-result cut. A
newly read file (most often the four-line `toolshare/README`) takes a place above the answer. Or the added text
shifts BM25's statistics and reorders the files read before. Or newly read passages fill the ten results and the
envelope grows past 4,096 bytes. Each question, its cause and the plan step that owns it (H5 for passages and the
envelope, H6 for ranking) are listed in [S6-T23's Report](tasks/S6-T23.md#report-part-2), from
[`causes.tsv`](evidence/s6-t23/part2/causes.tsv). Ranking was not tuned in H2.

## What the engine cannot do today, kind by kind

Stated from the first baseline and the per-question rows in `baseline-rework-2.json` (since H2 every file of the
folder is read; the after-H2 tables are above)
(`configs.<surface>/<field>/<form>.questions`). Each item names the plan step that addresses it. Ranks are for
the query form unless "typed" is said.

- **Across the kinds: 24 of 270 files are never read.** They are the 12 `.log`, 4 CSV, 2 TSV, the shell script,
  the XML sitemap and the 4 files with no extension (shown: `corpus.files_not_read`). 31 of the 169 answerable
  questions name one among their answers (`not_read_questions`). Some of these still score through an
  alternative that is read; 23 have no readable answer for some part, which is why *total readable now* is 146.
  Plan step **H2**.
- **The typed question loses to the picked words** on file@1 (94 against 116), but it is not uniformly worse:
  - `word-form` is 12 against 11 and `misspelt` content-complete is 11 against 9. The extra words of a typed
    question sometimes bring the answer's second part (spell-04, spell-09 with `content`).
  - Typed questions return something for 11 of 12 no-answer questions, against 8 for the picked words, since a
    whole sentence always shares a word with the folder.
  - **H6** (query handling) and **H3** (telling a weak match from none).
- **`two-passages`** (0 of 11 complete with `both`; 9 with `content`, query). With the file-name channel on,
  every result is a different file, so the second passage of the same file is never handed over. **H5**.
- **`current-copy`** (complete 5 / 5 with `both`; file@1 0 typed, 4 query). Typed, the older or draft copy
  ranks above the current file, or comes back without it, for 7 of 9 questions (all but cur-06 and cur-07):
  - cur-01: `archive/lending-rules-2024.md` (14 days) comes before `lending-rules.md` (7 days);
  - cur-09: the 2024 house notes' key safe comes before the blue pot.
  - The current answer is often in the list too, so complete does not show this; "stale copy ranked first"
    does. Nothing in the envelope says which copy is newer. **H4** (a profile per file, with its date) and
    **H6**.
- **`synonym`** (2 / 3 of 10 complete with `both`):
  - syn-01: "orthodontist" returns nothing, though the dentist note's brace review answers.
  - syn-06: "ear check" never reaches the hearing test.
  - syn-02: "rubbish collected" finds a draft trip file and Otto's week; typed, the 2024 house notes (an
    alternative) come back at rank 10, but not the passage with the black bin.
  - The three found share another word with the answer: back door for the ants (syn-05), Tool Share for the
    membership (syn-09), and, at rank 10 with `both` only, the mains for the stopcock (syn-03, by "off").
  - **H6**.
- **`tamil-latin`** (5 of 10 complete). Four are found through Latin file names: `rasam.md`, `kootu.md`,
  `mira-kaditham.md` and `naatkaatti-2027.md` (by "2027"). The fifth, `chedigal.md` for "paatti thottam", is
  found with the query words only; the folder is named `paati/`, and why it ranks first was not traced. tam-01 `pongal` finds `pongal-samayal.md` and returns its title, not the date line. thulasi,
  deepavali, murukku and pacharisi, whose files are not named in Latin, return nothing. **H6**
  (transliteration), with H4 for names.
- **`table`** (6 of 10). The Markdown tables (orders, clubs) and the YAML inventory are found: table-05 at
  rank 2, behind the repairs note that also names the hedge trimmer. All four misses are in CSV or TSV, which
  are not read. A row is never cited apart from its table, so a whole table comes back. **H2**, then **H5**.
- **`where-is-it`** (3 of 10). The three found are a JSON file named for its role (`smart-plugs.json`),
  `models.py`, and the numbers list, which ranks first with the query words but third typed. Seven of ten
  answers are in unread files: the loans spreadsheet, the backup script, the June log, the sitemap, the budget
  spreadsheet, `TODO` and `contacts.tsv`. where-04 ("the website's stylesheet") misses the readable
  `styles.css`: nothing says "stylesheet". **H2** and **H4**.
- **`word`** (12 of 15). The misses are unread files: the plumber's charge in a CSV (word-07), the failed backup
  in a `.log` (word-08), the loft hatch in a file with no extension (word-12). word-05 ranked the 2024 lending
  rules first in rework 1; with the copy's status line it now ranks them second, a sign of how close those two
  scores are. **H2**.
- **`word-form`** (11 of 13). The irregular plurals `geese` (form-08) and `mice` (form-09) return nothing.
  **H6**.
- **`misspelt`** (9 of 12, query, `both`):
  - every misspelling sends only the misspelt word (all twelve);
  - the Tamil one (பொங்கள் for பொங்கல், spell-11) returns nothing;
  - spell-04 (`sourdogh` for the baking temperature) and spell-09 (`calender` for half term) find the right file
    but not the line that answers. Rework 1 dropped the part that judged the title or intro line;
  - with `content` and the typed question, both are complete.
  - **H6** for spell-11; **H5** for the other two.
- **`phrase`** (11 of 12). The miss is the unread TSV (phrase-10). Adjacency is not checked by `search` (argued:
  it is a bag-of-words BM25). **H2**; H3 for an exact-phrase check.
- **`number`** (10 of 12). The two misses are unread. "17 March" and "2026-11-30" rank below journal files that
  share a token. **H3** (an exact-string scan).
- **`two-files`** (7 of 11):
  - pair-02: the meal plan names the dish and only a link names the recipe;
  - pair-06 (new): the chair's number is only in `contacts.tsv`;
  - pair-08 (Tamil): with `both` it gets the Pongal file's title section and not its ingredients; with
    `content` it gets the title and tip sections;
  - pair-01: the 2025 boiler copy ranks first, in all four configurations.
  - **H5**, and **H6** for following a reference.
- **`filename`** (11 of 12). The file-name and title channels find files whose text lacks the words. name-10 is
  an unread CSV. **H2**; H4 for the ranking of a name against text.
- **`about`** (8 of 11):
  - about-09 needs eight files (the README says the site code is `src/` and `site/`), and three come back;
  - `kootu.md` never says recipe (about-04);
  - the bills are partly a CSV (about-11).
  - **H4**.
- **`file-content`** (8 of 11). Three are unread: `NOTES`, a CSV and a TSV. Typed, file@1 is 3 of 11, because
  "What is in X?" ranks other files above X. **H4**; H2 for the three.
- **`no-answer`** (8 of 12 returned something with the query words):
  - A question that shares one word with the folder gets results.
  - Five queries have every word absent from the text: snorkel, the Tamil for cricket, hammock, wedding
    anniversary, flu jab. Four of them return nothing. The fifth, none-10 (`wedding anniversary`), returns
    garden-diary passages (1 with `both`, 10 with `content`): the engine's stemmer makes `wedding` match the day
    abbreviation "Wed".
  - No envelope field says a match is weak (argued from the envelope).
  - **H3** and **H6**.
- **Tightness.** With `both`, 9 typed and 36 query questions are complete within 4,096 bytes, against 100 and 109
  complete. The `both` envelope repeats each passage's text under `match_sections` and adds ranking fields
  (argued from one envelope; the sizes are measured). Even with `content`, a mean of 0.15 of the returned
  passage bytes lie inside a judged range. **H5**.

## Limits: what the score still cannot see

- **One invented folder of 270 files.** A real folder is larger and messier, and most text here comes from fixed
  sentence pools. About ten questions per kind means one question moves a kind's share by about ten points.
- **Whether the text handed over is right but loose.**
  - The judged share counts bytes inside judged ranges. Text next to the answer that a reader would want (a
    heading, the line above) counts as outside.
  - A passage that holds the range plus a 50-line remainder is complete. Only the share and the byte budget show
    the cost.
  - An engine could raise *complete* by returning whole files. *complete within 4,096 bytes* and the judged
    share are the columns that catch that; *complete* alone does not.
- **Order within an answer, and wrong text.**
  - The score does not see whether the passage that answers comes first in the envelope, beyond passage@k.
  - It does not see whether wrong text is also handed over, except as a stale copy ranked first.
  - A stale copy returned after the current one is not counted against the answer.
- **Partial answers.** *complete* asks for every part, and alternatives are judged only where found by reading.
  A good answer the builder did not foresee can still score incomplete. The Verdict found five such cases, and
  rework 1 judged them.
- **Words absent from the text.** `absent_from_corpus` uses the Python analyzer, which does not stem. A word
  absent from the text can still match through the engine's stemmer (none-10).
- **Kinds not covered.** Recency, negation, relative dates, sums over a table, mixed-script queries and
  "everything about Mira" (the Verdict's other gaps) have no kind yet. Neither do the MCP and C ABI surfaces,
  `find`, or `--search-field filename`.
- **Who wrote it.** The questions were written by the same builder who wrote the folder. Rework 1 corrected
  judgments and replaced five queries after seeing scores, under the ruling after the Verdict (fix the
  yardstick, never reword to pass); rework 2 applied the stale rule to all questions and changed three files.
  Every change is listed with its scores in [`changed-questions.txt`](evidence/s6-t22/changed-questions.txt) and
  [`changed-questions-rework-2.txt`](evidence/s6-t22/changed-questions-rework-2.txt). Later tasks may add
  questions held out from whoever tunes against these.
- **Contradictions not found by the script.** The contradiction search catches a different value of the same
  shape near the same words. A contradiction in words ("key safe" against "blue pot") is caught only by reading.
