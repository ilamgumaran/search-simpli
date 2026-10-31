# Family-folder fixture and judgment pack (S3-T7)

Invented content only: made-up people, a made-up school (Larkfield Primary),
made-up places. It stands in for the three folders of UC-007: a school folder, a
home folder and a laptop folder. **Frozen**: `judgments.json` is the acceptance
oracle for S3-T1..T6. A later task that needs a judgment changed says so in its
Report, and the change is a reviewed commit, not a silent edit.

Do not edit the files by hand. `python3 fixtures/family-folder/generate.py`
rewrites every file and `judgments.json` (and this README) deterministically from
`content.py` and `generate.py`; `tests/test_family_folder_fixture.py` regenerates
into a temporary folder and compares byte for byte. Every line range, section
path and sha256 below is computed from the files, never typed. The generator imports
the repository's analyzer (`tokenize`) and chunker (`_line_chunks`): a later change to
either moves the phrase and prefix sets or the chant placement and fails the
determinism test, which is intended for a frozen pack.

## Roots and special files

| Root | Files | Notes |
| --- | --- | --- |
| `school/` | 16 | 13 Markdown, 3 text |
| `home/` | 16 | 13 Markdown, 3 text |
| `laptop/` | 10 | 8 Markdown, 2 text |

Special files the S3 chunker, reader and tests rely on:

| File | Why |
| --- | --- |
| `laptop/big-log.txt` | 1133158 bytes, more than 1 MB, deterministic (fixed LCG, no randomness), committed; lines 4711 and 12003 are planted |
| `home/house-rules.md`, `laptop/archive/house-rules-old.md` | identical content under different names and in different roots |
| `home/crlf-shopping.md` | CRLF line endings |
| `home/no-final-newline.txt` | last line has no terminator |
| `home/bom-checklist.md` | UTF-8 byte order mark |
| `home/tamil-notes.md` | Tamil text |
| `home/repeated-tokens.md` | "the the", "to to", "is is" |
| `home/empty.txt` | zero bytes |
| `laptop/maths-script.md` | the long fenced block (1949 codepoints, more than the 1,600 `max_chars`) with `#` lines that are not headings |
| `laptop/meeting-notes.md` | the second, short fenced block |
| `school/clapping-chant.txt` | one word per line; holds the known chunk-local phrase miss |
| `school/science-notes.md`, `school/spelling-lists.md` | Setext headings (and ATX in the first) |

Front matter is the YAML subset `key: value` (strings only). Headings nest to depth 3.

## Conventions

- Lines are 1-based. A line ends at `\n` or `\r\n`; a final line without a terminator counts; an empty file has 0 lines; a BOM is not part of any line.
- A returned hit matches an expected entry when `root_id` and `path` are equal and the line ranges overlap.
- Phrase and prefix expected sets are complete across all pages. Tokens come from the repository analyzer (`tokenize`), so case is folded and punctuation separates words.
- `read_span`: the sha256 of the original bytes from the start of `start_line` to the start of the line after `end_line` (CAP-19 FR-22, section 4), so every terminator in the range is kept, the last line's own included, and CRLF stays CRLF; a final line without a terminator has none (case s4). Cases avoid line 1 of the BOM file because a BOM is not a line.
- Outline `end_line` is the line before the next heading of the same or higher level, else the last line. `#` lines inside a fence are not headings. Setext headings report the text line.

## Gates (UC-007)

Phrase recall 1.00, prefix recall 1.00, outline exactness 1.00, `read_span` byte-exact,
words recall@5 at least 0.9. `python3 scripts/relevance_smoke.py --pack family-folder`
runs what the Python reference can answer today (words cases and the empty newt
question) and prints a skipped count for the rest until S3-T1/T2 land.

## The 13 UC-007 scenarios

| # | Question | Kind | Expected |
| --- | --- | --- | --- |
| 1 | Find tide table. | words | `home/trips/seaside-weekend.md` 11-11<br>`laptop/meeting-notes.md` 10-10<br>`school/geography-coast.md` 10-10<br>`school/geography-coast.md` 13-13 |
| 2 | Find the exact phrase count me in. | phrase | see `phrase:p1` below |
| 3 | Which notes mention anything starting with photosyn? | prefix | see `prefix:x1` below |
| 4 | Show me the outline of science-notes.md. | outline | see `outline:o1` below |
| 5 | Open lines 40 to 60 of that file. | read_span | see `read_span:s1` below |
| 6 | What did the teacher say about the spelling test next week? | answer | `school/notes.md` 27-29 (section path in `judgments.json`) |
| 7 | When is the band concert? | answer | `school/notes.md` 33-33<br>`school/newsletter-oct.md` 10-10 (section path in `judgments.json`) |
| 8 | Is there anything in my folders about newts? | empty | empty result |
| 9 | Summarise the project-ideas note. | summary | outline of `laptop/project-ideas.md` plus the first span of 7 sections |
| 10 | What does the recipe say to do after the dough rests? | phrase_neighbour | phrase `p2`; then the next step at `home/recipes/bread.md` 20-20 |
| 11 | A new file lands in the iCloud folder on another device; a file not yet downloaded shows as pending. | lifecycle | 6 steps (apply_changes report and find results; S3-T3/T4) |
| 12 | A note is renamed; old citations stop and the new name works. | lifecycle | 3 steps (apply_changes report and find results; S3-T3/T4) |
| 13 | A folder is removed from the app; nothing from it is returned again. | lifecycle | 4 steps (apply_changes report and find results; S3-T3/T4) |

## Phrase cases

Expected sets are every adjacent-words occurrence in the folders, after case folding.

| id | Query | Expected | Note |
| --- | --- | --- | --- |
| p1 | `count me in` | `home/birthday-plans.md` 12-12<br>`laptop/meeting-notes.md` 10-10<br>`school/notes.md` 33-34 | a phrase wrapped over two lines in one section, plus two plain occurrences |
| p2 | `the dough rests` | `home/recipes/bread.md` 19-19 | a phrase inside a numbered step |
| p3 | `round the old mill pond` | `school/clapping-chant.txt` 296-300 | the known chunk-local miss: five one-word lines straddle a 1,600-character window edge, so no single chunk holds the phrase **expected engine miss** |
| p4 | `the the` | `home/repeated-tokens.md` 7-7<br>`home/repeated-tokens.md` 9-9 | the repeated-tokens file: adjacent identical words are a legal phrase |
| p5 | `பள்ளி விடுமுறை` | `home/tamil-notes.md` 5-5<br>`home/tamil-notes.md` 16-16 | Tamil phrase in a Tamil file, two occurrences |

**Known expected miss (CAP-19 open decision 1).** Case `p3` is true text in the
folder, but its five words sit on five separate lines that straddle the end of a
1,600-character window of `line-window-v1`: the window holding the first words
stops one word short and the next window, which restarts three lines back, begins
one word late. A chunk-local positional index cannot return it. The judgment lists
it under `expected_engine_miss`; S3-T2's test asserts the miss and the recall gate
counts it as excluded, not as a failure. `generate.py` searches for the placement
and asserts that no single chunk holds the phrase. Every other phrase case is
found.

## Prefix cases

| id | Query | Expected lines | Note |
| --- | --- | --- | --- |
| x1 | `photosyn*` | `home/garden.md` 17-17<br>`laptop/photosynthesis-draft.md` 6-6<br>`laptop/photosynthesis-draft.md` 12-12<br>`laptop/photosynthesis-draft.md` 17-17<br>`school/science-notes.md` 15-15<br>`school/science-notes.md` 18-18 | words that begin the same way across three files **expected engine miss (front matter, not body):** `laptop/photosynthesis-draft.md` 2-2 |
| x2 | `spell*` | `laptop/reports/term-summary.md` 5-5<br>`laptop/todo.txt` 3-3<br>`school/homework-routine.txt` 4-4<br>`school/homework-routine.txt` 9-9<br>`school/notes.md` 25-25<br>`school/notes.md` 27-27<br>`school/spelling-lists.md` 1-1<br>`school/spelling-lists.md` 16-16<br>`school/timetable.md` 29-29 | one prefix covers the words spell and spelling (names, notes and lists) |
| x3 | `harbo*` | `home/trips/seaside-weekend.md` 11-11<br>`laptop/big-log.txt` 4711-4711<br>`laptop/big-log.txt` 12003-12003<br>`school/geography-coast.md` 11-11<br>`school/geography-coast.md` 18-18 | includes one hit deep inside the file larger than 1 MB |
| x4 | `lighthou*` | `laptop/big-log.txt` 4711-4711<br>`laptop/big-log.txt` 12003-12003<br>`laptop/reading-notes.md` 3-3<br>`laptop/reading-notes.md` 5-5<br>`school/notes.md` 15-15<br>`school/reading-log.md` 5-5 | a prefix that is also a whole word; a planted line in the large file |
| x5 | `கணி*` | `home/tamil-notes.md` 6-6 | Tamil prefix of a whole token |

## Outline cases

| id | File | Headings | Note |
| --- | --- | --- | --- |
| o1 | `school/science-notes.md` | 13 over 74 lines | Setext and ATX headings mixed, depth 3, front matter |
| o2 | `laptop/project-ideas.md` | 7 over 36 lines | ATX headings to depth 3 with front matter |
| o3 | `school/spelling-lists.md` | 4 over 32 lines | Setext only, no front matter |
| o4 | `laptop/maths-script.md` | 5 over 87 lines | hash-sign lines inside a fenced block are not headings |
| o5 | `home/crlf-shopping.md` | 4 over 22 lines | CRLF line endings: same line numbers as LF |

## read_span cases

| id | File | Lines | Bytes | Note |
| --- | --- | --- | --- | --- |
| s1 | `school/science-notes.md` | 40-60 | 575 | the UC-007 example: lines 40 to 60 with one line of context |
| s2 | `home/crlf-shopping.md` | 3-8 | 65 | CRLF: the returned bytes keep the inner \r\n |
| s3 | `home/bom-checklist.md` | 3-6 | 29 | a BOM file: line numbers ignore the BOM; the span starts after line 1 |
| s4 | `home/no-final-newline.txt` | 3-4 | 39 | ends at the last line, which has no terminator |
| s5 | `laptop/big-log.txt` | 9000-9010 | 819 | deep inside the file larger than 1 MB |
| s6 | `school/notes.md` | 1-5 | 58 | a front-matter range, from line 1 through the closing --- line |
| s7 | `school/notes.md` | 33-34 | 124 | an indented continuation line inside a list item |
| s8 | `home/tamil-notes.md` | 3-6 | 246 | Tamil text: multi-byte UTF-8, byte length differs from codepoint count |
