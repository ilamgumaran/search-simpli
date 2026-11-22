# Text-search score: the right file and the right passage

Status: built by S6-T22 ([plan step H1](plans/2026-11-16-objective-plan.md#h-text-search-done-well-the-priority-of-22-nov-2026)).
The baseline below is `main`'s engine at `b8852d8`, measured on 22 Nov 2026; its
files are in [`docs/evidence/s6-t22/`](evidence/s6-t22/).

The maintainer's priority is text search done very well: find the files relevant to
a question and answer from the relevant parts of them. The other judged sets
([J2](../fixtures/j2/README.md), [the family folder](../fixtures/family-folder/README.md))
score ranking. This set asks, end to end through `searchd`, whether the right file
came back and whether the passage that answers came back with it. Steps H2 to H6 are
judged by how they move it.

## What the set is

| Piece | File | What it does |
| --- | --- | --- |
| The folder | [`scripts/gen_text_search_corpus.py`](../scripts/gen_text_search_corpus.py) | writes 264 invented files (140,622 bytes) from seed 2211, deterministically |
| The questions | [`scripts/text_search_questions.py`](../scripts/text_search_questions.py) | holds the 129 questions, written by hand, and writes the judgments with line numbers computed from the folder |
| The judgments | [`fixtures/text-search/judgments.json`](../fixtures/text-search/judgments.json) | `text-search-judgments-v1`: per question the words typed, the query sent, the kind, the files and the line ranges, the checks |
| The scorer | [`scripts/text_search_score.py`](../scripts/text_search_score.py) | runs `searchd` both ways and writes a JSON file and a Markdown table |
| The tests | [`tests/test_text_search_score.py`](../tests/test_text_search_score.py) | 16 tests: the folder, the judgments against the folder, the scorer's arithmetic, one run through `searchd` |

**The folder** is what a household and a small project keep: the Pellow family's
notes, lists, recipes, schedules, receipts and trip plans, their grandmother's notes
in Tamil, a year's garden diary (1,462 lines), a journal, and the files of the
Harrowdean Tool Share (a volunteer lending library): its documents, meeting notes,
inventory in YAML, configuration, Python and JavaScript source, HTML pages and server
logs. Shapes: 156 Markdown, 72 plain text, 12 `.log`, 4 CSV, 2 TSV, 2 JSON, 2 YAML,
2 HTML, 3 Python, one each of TOML, JavaScript, CSS, shell and XML, and 4 files with
no extension; one-line files, a CRLF file, a Tamil file name, an exact duplicate and
three near duplicates, and files whose name says more than their text. All names,
places, firms and numbers are invented (phone numbers in the 01632 960xxx drama
range).

**The questions**, 129 in eleven kinds:

| Kind | n | What it asks |
| --- | ---: | --- |
| `word` | 12 | a word the file holds |
| `word-form` | 13 | a different form of a word the file holds (plural, tense, irregular plural, Tamil inflection) |
| `misspelt` | 12 | a misspelt word (11 Latin, 1 Tamil); the file holds the right spelling |
| `phrase` | 12 | an exact phrase whose words also occur apart in other files |
| `number` | 12 | a number, date or code |
| `two-passages` | 11 | an answer in two passages of one file |
| `two-files` | 11 | an answer that needs two files |
| `filename` | 12 | a question about the file's name, not its text |
| `about` | 11 | "which files are about X" |
| `file-content` | 11 | "what is in this file" |
| `no-answer` | 12 | nothing answers; the right result is nothing |

Each answer is a list of *parts*, one per thing a complete answer cites (two for a
two-passage or two-file question, one per file for `about`); a part lists the line
ranges that satisfy it (the exact copy of the sourdough recipe is an alternative
within a part). Eleven questions are asked in Tamil. Questions whose answer lies in a file
the engine does not read today (CSV, TSV, `.log`, no extension) stay in the set and
score zero (the task's ruling 3).

**How the judgments are kept honest.** Line numbers are never typed: each range is
an anchor text found on exactly one line, and the generator computes the numbers. The
test reads every committed range back from a freshly generated folder with its own
line splitter and requires the range's key words in it (167 ranges). Misspelt and
no-answer questions name words that must occur in no file; word-form and file-name
questions name words that must occur in none of the answer's files; the test checks
both as tokens of the repository analyzer. Planting a shifted range, a present
"absent" word or a stale judgments file fails the tests (shown:
[`plants.txt`](evidence/s6-t22/plants.txt)).

## How it is scored

Every question is asked four ways, with `--top-k 10`: `searchd search <folder>
"<query>" --evidence` (direct search, no index) and `searchd evidence <index>
"<query>"` over `searchd index <folder> --out <index> --filename-index`, each with
`--search-field both` and `--search-field content`. The query is the question's
`query` (the words a caller would send), else the question as typed.

- **file@k**: an answer file is among the first k distinct files of the results;
- **passage@k**: one of the first k returned passages holds an answer range whole
  (same path, the passage starts at or before the range and ends at or after it);
- **complete**: every part has a range held by some returned passage;
- **not read**: an answer file is not in `searchd list-files` for the index;
- **returned anything** (no-answer only): any result came back;
- **evidence bytes**: the envelope's size on stdout; **passage bytes**: the UTF-8
  size of the returned passages.

Shares are of the kind's questions; *total* is the 117 questions with an answer.

## How to run it

```sh
cd zig && zig build -Doptimize=ReleaseSmall --prefix <scratch>/prefix && cd ..
python3 scripts/text_search_score.py --searchd <scratch>/prefix/bin/searchd \
    --scratch <scratch>/run --out-json run.json --out-md run.md
```

`<scratch>/run` must be new or empty; the folder and the index are left there. The
whole run (520 `searchd` calls) took 3.8 s and 4.4 s in two timed runs on the Mac that measured the baseline.
Two runs give byte-identical JSON and Markdown (shown:
[`determinism.txt`](evidence/s6-t22/determinism.txt)); the output holds no time and
no absolute path. To change a question, edit `scripts/text_search_questions.py` and
run `python3 scripts/text_search_questions.py --write fixtures/text-search/judgments.json`;
as for J2, a changed judgment is a reviewed commit named in its task's Report.

## The baseline (`main` at `b8852d8`)

Direct search and the index gave byte-identical evidence for all 129 questions with
each field (shown: `direct_equals_index` in
[`baseline.json`](evidence/s6-t22/baseline.json)), so one table per field stands for
both surfaces. Full tables, with file@3 and passage@3:
[`baseline.md`](evidence/s6-t22/baseline.md).

`--search-field both` (the file-name channel on):

| Kind | n | file@1 | file@10 | passage@1 | passage@10 | complete | not read | returned anything | evidence bytes |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| word | 12 | 9 | 9 | 8 | 8 | 8 | 3 | | 5,610 |
| word-form | 13 | 11 | 11 | 11 | 11 | 11 | 0 | | 1,855 |
| misspelt | 12 | 11 | 11 | 11 | 11 | 9 | 0 | | 3,180 |
| phrase | 12 | 11 | 11 | 11 | 11 | 11 | 1 | | 10,673 |
| number | 12 | 8 | 10 | 8 | 10 | 10 | 2 | | 8,857 |
| two-passages | 11 | 10 | 11 | 9 | 10 | **0** | 0 | | 9,238 |
| two-files | 11 | 10 | 10 | 9 | 10 | 7 | 0 | | 10,174 |
| filename | 12 | 10 | 11 | 10 | 11 | 11 | 1 | | 7,549 |
| about | 11 | 10 | 11 | 10 | 11 | 8 | 1 | | 7,863 |
| file-content | 11 | 7 | 8 | 7 | 8 | 8 | 3 | | 7,366 |
| no-answer | 12 | | | | | | | 8 | 4,883 |
| **total** | 117 | **97 (0.83)** | **103 (0.88)** | **94 (0.80)** | **101 (0.86)** | **83 (0.71)** | 11 | | 7,142 |

`--search-field content`:

| Kind | n | file@1 | file@10 | passage@1 | passage@10 | complete | not read | returned anything | evidence bytes |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| word | 12 | 9 | 9 | 8 | 9 | 9 | 3 | | 2,485 |
| word-form | 13 | 11 | 11 | 11 | 11 | 11 | 0 | | 474 |
| misspelt | 12 | 11 | 11 | 11 | 11 | 9 | 0 | | 1,036 |
| phrase | 12 | 11 | 11 | 11 | 11 | 11 | 1 | | 3,299 |
| number | 12 | 8 | 10 | 8 | 10 | 10 | 2 | | 3,039 |
| two-passages | 11 | 10 | 11 | 9 | 11 | 10 | 0 | | 3,758 |
| two-files | 11 | 10 | 10 | 9 | 10 | 8 | 0 | | 3,216 |
| filename | 12 | 10 | 11 | 10 | 11 | 11 | 1 | | 2,299 |
| about | 11 | 10 | 11 | 10 | 11 | 8 | 1 | | 2,521 |
| file-content | 11 | 7 | 8 | 7 | 8 | 8 | 3 | | 3,026 |
| no-answer | 12 | | | | | | | 8 | 2,903 |
| **total** | 117 | **97 (0.83)** | **103 (0.88)** | **94 (0.80)** | **103 (0.88)** | **95 (0.81)** | 11 | | 2,477 |

Counts are questions; evidence bytes are the mean per question.

## What the engine cannot do today, kind by kind

Stated from the numbers above and the per-question rows in `baseline.json`
(`configs.<surface>/<field>.questions`); each names the plan step that addresses it.

- **Across the kinds: 24 of 264 files are never read** (the 12 `.log`, 4 CSV, 2 TSV,
  the shell script, the XML sitemap and the 4 files with no extension; shown:
  `corpus.files_not_read`). 11 of the 117 answerable questions have an answer file
  among them, and each of those misses that part (shown: `not_read_questions`). Plan
  step **H2**.
- **`word`** (8 of 12 complete with `both`): three misses are unread files (the
  plumber's charge in a CSV, word-07; the failed backup in a `.log`, word-08; the loft
  hatch in a file with no extension, word-12). The fourth, word-06 (Tamil), finds the
  right file first but `both` returns its title section, not line 15 that answers;
  `content` returns that line (shown: word-06 rows). H2; H5 for word-06.
- **`word-form`** (11 of 13): the two misses are irregular plurals: `geese` (the file
  says goose, form-08) and `mice` (mouse, form-09) return nothing at all. Regular
  forms (repainting/repainted, batteries/battery, pruned/prune, descaling/descale)
  and both Tamil locatives are found first. **H6** (query rewording, semantic matches).
- **`misspelt`** (11 of 12 found, 9 complete): every Latin misspelling finds the right
  file and a passage at rank 1; the Tamil one (பொங்கள் for பொங்கல், ள் for ல், spell-11)
  returns nothing. Two questions sent only the misspelt word and ask for a second
  passage of the file (the baking temperature, spell-04; half term, spell-09); the
  engine returns the passage the word matches and not the one that answers, with
  either field. **H6** for spell-11; **H5** for the other two.
- **`phrase`** (11 of 12 at rank 1): the one miss is the unread TSV (phrase-10). On
  this set the ranked search put the file holding the adjacent words first every time
  it read the file, although the near duplicates hold the same words apart; adjacency
  itself is not checked by `search` (argued: it is a bag-of-words BM25). **H2**; H3
  for an exact-phrase check.
- **`number`** (10 of 12 at 10, 8 at 1): two misses are unread (`.log`, CSV). A date
  or code split into common tokens ranks below files that share a token: "17 March"
  comes third, behind two journal files named `2026-04-17.md` and `2026-10-17.md`
  (number-04); "2026-11-30" comes eighth, behind seven journal files (number-12).
  **H3** (an exact-string scan); H2 for the unread two.
- **`two-passages`** (0 of 11 complete with `both`, 10 of 11 with `content`): with the
  file-name channel on, every result is a different file, so the second passage of
  the same file is never handed over (shown: span-01, three passages of
  `otto-week.md` with `content`, one with `both`). With `content`, span-03 misses the
  members line. **H5** (the passage that answers and its neighbours).
- **`two-files`** (7 of 11 with `both`, 8 with `content`): pair-02 ("What's for dinner
  on Wednesday and what do I need for it?") finds neither file, since the meal plan
  names the dish and only its link names the recipe; pair-01 finds the boiler file but
  not the receipt, which says Wenlow Heating and not boiler; pair-08 (Tamil) gets the
  Pongal file's title and tip sections but not its ingredients, with either field.
  With `both`, pair-06 also loses a part to the one-passage-per-file rule. **H5**, and **H6** for
  following a reference.
- **`filename`** (11 of 12): the file-name and title channels find a file whose text
  lacks the words, with either field (shown: 10 at rank 1 under both); name-01 comes
  second, behind `house-notes.md`, and name-10 is an unread CSV. **H2** for name-10;
  H4 for the ranking of a name against text.
- **`about`** (11 of 11 at 10, 8 of 11 complete): one file per topic is easy; all of
  them is not. `kootu.md` never says recipe (about-04); the Tool Share's code files
  never say website or code, and only one of four comes back, at rank 9 (about-09);
  the bills are a CSV (unread), an insurance quote and one file named bill (about-11).
  **H4** (a profile per file).
- **`file-content`** (8 of 11): three are unread (`NOTES`, a CSV, a TSV). The others
  return the passage the name matches, which is the head of the file here; for
  `server.yaml` the source file that names it comes first (content-06). Nothing says
  what kind of data a file holds. **H4**; H2 for the three.
- **`no-answer`** (8 of 12 returned something, with either field): a question that
  shares one word with the folder gets results: "piano tuner" returns the piano exam
  (none-03), "solar panel quote" the insurance quote (none-08), "TS-999" the
  inventory (none-09). Only the four whose every word is absent (snorkel, the Tamil
  for cricket, orthodontist, flu jab) return nothing. No envelope field says the
  match is weak (argued from the envelope). **H3** (an exact check that the words are
  absent) and **H6** (re-ranking).
- **Evidence size**: with `both` the envelope averages 7,142 bytes per answerable
  question against 2,477 with `content`, while the passages in it are smaller (1,086
  against 1,325 bytes): the `both` envelope repeats each passage's text under
  `match_sections` and adds ranking fields (argued from one envelope; the sizes are
  measured). **H5**.

## Limits of the set

- One invented folder of 264 files; a real folder is larger and messier. Its
  statistics (most text from fixed sentence pools) are not a real household's.
- The queries are the words a caller would send, chosen by hand; a person typing the
  whole question into a search box is not scored.
- `complete` asks for every part, so an answer that would satisfy a person with one
  of two near-equivalent passages can score incomplete; the alternatives within a
  part cover only the exact copy and TS-017's two entries.
- The questions were written by the same builder who wrote the folder, before the
  scorer first ran. After the first run one query was narrowed (form-10 sends only
  `wrapping`, since the file name already says presents; it scored complete before and
  after) and one absent-word check corrected (none-08: a journal says fence panel);
  no question was dropped. Later tasks may add questions held out from whoever tunes
  against these.
