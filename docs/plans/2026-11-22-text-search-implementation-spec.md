# Text search done well: implementation specification for review

**State:** draft for review, 22 Nov 2026. **Nothing below is built.** Work is
paused after [S6-T23](../tasks/S6-T23.md) so reviewers can object before code is
written. · **Plan:** [objective plan](2026-11-16-objective-plan.md), section
[H](2026-11-16-objective-plan.md#h-text-search-done-well-the-priority-of-22-nov-2026) ·
**Where things stand:** [review of 22 Nov 2026](../reviews/2026-11-22-state-and-next.md)

## How to review this

Each step has the same parts: what a caller gets, the interface and contract
change, where the code goes, how it is tested and what number it must move, what
is left out, and **questions for reviewers**. The questions are the places where
the author chose one of several defensible designs; an objection there is the
most useful kind. Comment on the pull request or open an issue naming the step
(`H3`, `H4`, ...) and the question number.

Facts about today's code are given with file and line, read on `main` at
`8ffc41c`. Where a number is quoted it was measured; where a design is proposed
it says "proposed".

### Rules every step keeps

1. **Note first.** Each task starts with a design note under `docs/decisions/`
   from reading the code, with a prototype measurement where the design depends
   on one, and stops for the orchestrator before any change under `zig/src/`.
2. **Capability document first** for a new or changed contract field, index
   format, ABI function or interface ([CONTRIBUTING](../../CONTRIBUTING.md),
   [capability process](../capability-process.md)).
3. **Layers.** New logic goes in `zig/src/core/`, its operation and JSON in
   `zig/src/ops/`, and each interface (`abi`, `cli`, `rpc`, `mcp`) only adapts
   ([layers](../layers.md), [core API](../core-api.md)). Bindings use the C ABI
   only. The Python reference takes the same behaviour, or the capability
   document says why not.
4. **Judged by the judged set.** Every step states the totals of
   [text-search-score](../text-search-score.md) before and after, question by
   question where a question gets worse. The 181 questions and their digests do
   not change; a step that needs new questions adds a second, separately frozen
   set and reports both.
5. **Timing rule of 2026-11-17** ([ROLES](../process/ROLES.md)) for any change
   to the natives, on an awake and quiet machine.
6. **A separate verifier** tries to disprove the builder's Report before a
   merge.

### What the judged set says today

181 invented questions over a generated folder of 270 files; 169 have an answer
in the folder, 12 have none. "Complete" means every file and passage a good
answer needs came back in the first ten results.

| Measure (of 169) | names and content, as typed | names and content, query words | content only, as typed | content only, query words |
| --- | --- | --- | --- | --- |
| Complete | 100 | 109 | 110 | 118 |
| Complete within 4,096 bytes | 9 | 36 | 91 | 100 |

Other baseline facts the steps below are aimed at:

- **Two passages of one file:** 0 of 11 with names and content, because that
  field returns one result per file (`zig/src/core/filename_field.zig:706`).
- **A stale copy ranked first:** 10 (typed) and 5 (query words) of 22. Nothing
  in a result says which copy is newer.
- **A question with no answer still returns something:** 11 and 8 of 12, and no
  field says the match is weak.
- **Files never read:** 24 of 270 (logs, CSV, TSV, a shell script, XML, no
  extension). S6-T23 addresses this; its measured effect is in the review.
- **As typed scores below query words** in every column: question words steer
  the ranking.

The 113 everyday scenarios run on 22 Nov
([report](../testing/scenarios-engine-2026-11-22.md)) found the same faults from
the outside, and some the judged set does not score: numbers such as `142.50`
are split in two, an accent in a file name is not folded, errors do not name the
path, and one README sentence is wrong.

---

## H2. All the text (in progress: S6-T23)

Not for design review here: the rule is decided in
[decision 0005](../decisions/0005-which-files-are-text.md) on the task's branch
and is being built. It is listed so the later steps can rely on it.

- A walked file is read when its bytes are text (the first 8,192 bytes are valid
  UTF-8 with no NUL and at most 1 % control bytes). Known non-text extensions
  are skipped without being opened.
- Files not read are counted by kind in a new report field `not_read`, without
  paths. Contract 2.9.0, additive.
- **Measured on the built branch** (complete answers of 169, typed / query
  words): names and content 100 / 109 to 109 / 127; content only 110 / 118 to
  120 / 137. **It is not a pure gain:** 30 questions get worse in some
  configuration, because repetitive logs and one short README now compete in
  the ranking and fill the ten results. Each is listed with its cause in the
  task's Report; H5 items 3 and 5 below and H6 own them.
- Two behaviours to weigh: a short file with one stray control byte is treated
  as binary, and a file with a known text extension that holds a NUL byte is no
  longer indexed.

**Questions for reviewers.** H2-Q1: logs and data files are read by default.
Should some kinds be excluded unless asked for, and if so by what rule that a
person could predict? H2-Q2: is "at most 1 % control bytes in the first 8,192"
right for short files and for logs that carry terminal colour codes?

---

## H3. Pattern search (`scan`)

### What a caller gets

A second way to search, beside the ranked search: give an exact string or a
pattern, get back **every line that matches, with its file and line number**, in
a fixed order. It is what `grep -n` gives, over the same files the engine reads,
with the same root and path scoping, on every interface.

It is for the question a ranked search answers badly: an exact phrase, a number
(`142.50`), a code or identifier, a line shape ("lines that start with a date").
It is also the oracle a ranked answer or a language model's quote can be checked
against: either the line is there or it is not.

### Today

- There is no pattern or regular-expression code in `zig/src/`.
- `find` has a phrase mode (adjacent tokens within one chunk,
  `zig/src/core/find.zig:8`, `:64`; a query in double quotes forces it,
  `:317`). It matches analysed tokens, so punctuation, case and number shape are
  lost: `"142.50"` is the tokens `142` `50`.
- `query`, `evidence` and `search` ignore quotes.

### Proposed behaviour

Request fields:

| Field | Meaning | Default |
| --- | --- | --- |
| `pattern` | The text or pattern. Required, 1 to 1,024 bytes. | |
| `mode` | `literal` or `regex`. | `literal` |
| `case` | `sensitive`, `insensitive` (simple case folding by code point), or `smart` (insensitive unless the pattern has an upper-case letter). | `smart` |
| `whole_word` | The match must start and end at a word boundary. | `false` |
| `roots`, `path_prefix` | Scope, as `find` has. | all |
| `name_glob` | Only files whose name matches (`*`, `?`; no path separators). | none |
| `context_lines` | Lines before and after each hit, 0 to 20. | 0 |
| `max_hits_per_file` | 1 to 1,000. | 50 |
| `page_size`, `cursor` | As `find`: 1 to 100 hits per page. | 20 |

Response fields:

| Field | Meaning |
| --- | --- |
| `hits[]` | `root_id`, `path`, `line` (1-based), `text` (the line, capped at 512 bytes at a code-point boundary, with `text_truncated`), `match_offsets` (code-point start and end pairs within `text`, as `find` reports them), `before[]`, `after[]`. |
| `files_matched`, `files_scanned`, `bytes_scanned` | Counts. |
| `truncated`, `next_cursor` | Paging. |
| `stopped` | `none`, `time`, or `cancelled`. A scan that stops early says so; it never returns a partial page as if complete. |
| `warnings` | For example a pattern that can match the empty string. |

Order is **path (byte order within a root, roots in their listed order), then
line**. It does not depend on any score, so two runs give the same pages.

**The pattern language (proposed):** a small regular-expression subset that can
be matched in time linear in the text, with no backtracking: literals, `.`,
character classes with ranges and negation, `\d \w \s` and their negations,
anchors `^ $`, word boundary `\b`, grouping, alternation, `? * +`, and bounded
repeats `{m,n}` with `n` at most 255. **No back-references and no look-around.**
A pattern outside the subset is refused with `SS_ERR_INVALID_ARGUMENT` and a
message naming the construct. Matching is per line; a pattern cannot span lines.

Unicode: the pattern and the text are UTF-8; `.` and classes work on code
points; `\w` is letters, marks and digits as the analyser defines them
(`zig/src/core/analyzer_v2.zig:1`), so Tamil words are words. Case-insensitive
matching uses simple one-to-one case folding only. Accent-insensitive matching
is **not** offered in the first version (see H3-Q3).

### Where it runs

Two sources, one matcher:

1. **Over an index.** The source section already holds each file's exact bytes
   (`source.Section.fileBytes`, `zig/src/core/source.zig:321`). The scan walks
   the file table in path order and matches line by line. No new index data.
2. **Over a folder with nothing prepared** (`searchd scan <folder>`, and the
   same through `ss_index_folder`'s direct path if the note finds that the
   right shape). It reuses the walk (`indexer.collectCandidatePaths`,
   `zig/src/core/indexer.zig:101`) and the H2 text rule. The read-and-caps
   logic is inline today in `apply.applyParsed`
   (`zig/src/core/apply.zig:1071`); the task extracts it into one function both
   paths call, with no behaviour change (shown by the existing tests).

Line numbering is `chunker.splitLines` (`zig/src/core/chunker.zig:95`), so a
`scan` line number, a `find` hit's lines and a `read_span` request agree.

**Cost control.** A time budget per call (proposed 2 s by default, a request
field up to 30 s) and the existing cancel mechanism. For `literal` mode the scan
searches bytes with a two-way or Boyer-Moore-Horspool search before decoding
lines. A later, separate optimisation may use the lexical postings to skip files
that cannot hold a literal's whole tokens; it is only taken if the measurement
below says the plain scan is too slow, because it must never drop a true match.

### Code

| Layer | File | What |
| --- | --- | --- |
| core | `core/pattern.zig` (new) | Parse the subset to a program; a Pike-style matcher over code points; literal fast path. No allocation per line after set-up. |
| core | `core/scan.zig` (new) | Iterate files (index or folder), split lines, call the matcher, build hits, paging cursor, budget. |
| core | `core/core.zig` | New `api.scan` names: request, result, the entry function. |
| ops | `ops/ops.zig` | The `scan` operation and its JSON. |
| interfaces | `cli.zig`, `abi.zig`, `rpc.zig`, `mcp.zig` | `searchd scan`, `ss_scan`, the `scan` tool (read-only). |
| contracts | `contracts/tools/scan.*.json` | Request and result schemas. |
| bindings | Dart `scan(...)` | Typed request and result. |
| Python | reference `scan` using the same subset (not Python's `re` directly: the reference compiles the subset to an `re` pattern and refuses the rest, so both agree on what is accepted). |

### Tests and acceptance

- **Matcher:** a table of pattern, text, expected spans, including empty
  matches, anchors, classes, Tamil, combining marks, very long lines, a line of
  1 MiB without a newline, invalid UTF-8 in the text (the H2 rule keeps such
  files out; the matcher must still not read out of bounds). A differential test
  against the Python reference on generated patterns and lines (seeded).
- **Linear time, shown:** patterns that make a backtracking matcher explode
  (`(a+)+b` on a long run of `a`) finish within a stated bound.
- **Agreement with the system tool:** for a set of literal and subset patterns,
  `scan` over the judged folder returns the same (file, line) set as `grep -n`
  run by the test script, case-sensitive mode.
- **Index and folder agree:** the same request over an index of a folder and
  over the folder directly returns identical hits.
- **Paging:** every hit appears exactly once across pages; a publish between
  pages is refused or restarts as `find` does (the note says which).
- **Judged set:** a new, separately frozen question set of exact-string kinds
  (numbers with punctuation, codes, quoted phrases, line shapes), each with the
  lines that must come back. Acceptance: every such line is returned, and no
  line that does not match. The existing 181 are unchanged; `scan` does not
  alter ranked answers (byte-identical, shown on the three 10k corpora).
- **Time:** scan time for a literal and for a regex over the three 10k corpora
  and the judged folder, reported; the proposed bar is a literal over 10,000
  files inside the 2 s default budget on the reference machine.

### Left out

Multi-line patterns, replacement (this is search, not `sed`), searching file
kinds the engine does not read, fuzzy patterns, and structured field queries
("column 3 greater than 100"; see H4 for table shape).

### Questions for reviewers

- **H3-Q1. Our own matcher, or none.** The proposal is a small matcher in
  `core/` (no dependency, about 600 to 900 lines with tests). The alternative is
  literal-only search with `whole_word` and case options, which covers numbers,
  codes and phrases and leaves line shapes out. Which is right for a first
  version?
- **H3-Q2. A new operation or a `find` mode.** `find` already pages and scopes,
  but its unit is the chunk and its match is on analysed tokens. A separate
  `scan` keeps `find`'s contract unchanged. Is a separate operation the right
  call?
- **H3-Q3. Accent folding.** `cafe` matching `café` is offered by the ranked
  search through fold groups. Should `scan` have an `insensitive` mode that
  folds marks too, or stay byte-honest so it can serve as an oracle?
- **H3-Q4. Version step.** The requirements say an optional field is a minor
  step and CAP-19 recorded a major step for new methods. A new read-only
  operation that changes no existing response: minor (2.10.0) or major?
- **H3-Q5. Default budget.** 2 s and `stopped: time` when exceeded, or no
  default budget and the caller always sets one?

---

## H4. A profile per file

### What a caller gets

For any file the engine has read, a short record of **what the file holds**,
derived by analysing it, and a summary of a folder built from those records. It
answers "what is in this folder", "which files are tables", "which files mention
dates in March", and gives a language model a one-line description of each file
beside the evidence.

### Today

The index stores, per file: path, chunk count, each chunk's lines, heading line
and section path, and the exact bytes
([documents and source format](../documents-v5-source-v2-format.md)). It stores
no kind, no script, no dates, and no modification time for a `searchd`-built
index (`walkBatch` sets no `mtime_ms`, `zig/src/core/indexer.zig:216`;
`list_files` writes `mtime_ms: null`, `zig/src/ops/ops.zig:503`). Headings are
re-parsed on request for Markdown only (`source.outline`,
`zig/src/core/source.zig:1289`). There is no language or script detection.

### Proposed record (`profile-v1`)

| Field | How it is derived | Notes |
| --- | --- | --- |
| `kind` | From content first, extension second: `prose`, `markdown`, `table` (delimited, consistent column count), `structured` (JSON, YAML, XML, property lists: by a shallow parse of the first 64 KiB), `log` (most lines start with a timestamp or level), `source` (by extension table and a keyword share), `list` (most lines are short items), `other-text`. | One value. The rule is a fixed, documented decision list with a test file per kind. |
| `bytes`, `lines` | Counted. | |
| `scripts` | Share of letters by Unicode script block, the top three with their share in percent. | A script, not a language: no language model is used. |
| `title` | First heading; else first non-empty line, capped at 120 code points. | |
| `headings` | First 12 headings (Markdown), or the header row's column names for a table, or top-level keys for structured text. | Capped. |
| `terms` | The 12 most distinctive analysed terms: highest term frequency times inverse document frequency against the index's own counts, ties by term. | Deterministic. Needs an index. |
| `dates` | Count, earliest and latest, of dates in a fixed list of unambiguous shapes (`2026-03-14`, `14 Mar 2026`, `March 14, 2026`). | Ambiguous shapes (`03/04/26`) are counted separately as `ambiguous_dates` and never interpreted. |
| `numbers` | Counts: plain numbers, amounts with a currency sign or code. | Counts only. |
| `table` | For `kind = table`: delimiter, column count, row count, whether the first row is a header. | |
| `modified_ms` | The file's modification time at the walk. | Requires the walk to record it; see below. |
| `content_hash`, `same_as` | The content hash the state section already keeps (`zig/src/core/incremental_state.zig:67`), and the count of other files with the same hash. | Exact copies only. Near copies are H5's subject. |

**Modification time** becomes real data: the walk records `mtime_ms`, the state
section already has the field. This is also what H5 needs for "which copy is
newer". The note states what happens on file systems with coarse or absent
times.

### Stored or computed at query time: decided by measurement

The maintainer's direction allows either. The note measures both on the three
10k corpora and the judged folder:

- **(a) Computed on request** from the source section: no format change; cost
  paid per call. Fine for one file; a folder summary reads every file.
- **(b) A stored section** written at publish, one record per file, carried
  unchanged for unchanged files by the incremental path: a format change (new
  optional section, older readers ignore it), index size grows.

**Proposed rule:** store (b) if a folder summary over 10,000 files computed on
request takes longer than 250 ms on the reference machine, or the stored section
costs less than 3 % of index bytes; else compute (a). The note reports both
numbers and the orchestrator rules.

### Interfaces

- `profile` operation: one file (`root_id`, `path`) gives the record.
- `list_files` gains an optional request flag `with_profile`; when set, each
  entry carries `kind`, `lines`, `scripts`, `title`, `modified_ms`, `same_as`.
- `folder_profile` operation: counts by kind, by script, by top-level folder;
  the date range; the 20 most distinctive terms of the scope; counts of exact
  copies. Scoped by roots and `path_prefix`.
- `evidence` and `search_knowledge` results gain an optional `file` object per
  result (`kind`, `title`, `modified_ms`, `same_as`) so a model sees what kind
  of file a passage came from.
- CLI `searchd profile`, `searchd list-files --with-profile`; ABI `ss_profile`,
  `ss_folder_profile`; MCP tools `profile`, `folder_profile`; Dart methods.

### Tests and acceptance

- One invented fixture file per kind and per edge (a CSV with quoted newlines, a
  log with stack traces, JSON lines, a Markdown file that is mostly a table,
  mixed Tamil and Latin, an empty file, one very long line). Expected record
  checked field by field. Python reference agrees byte for byte on the JSON.
- **Kind accuracy on the judged folder:** the generator already knows each
  file's kind; acceptance is at least 95 % agreement, every disagreement listed.
- **Questions:** a second frozen set of "which files" questions (kind, script,
  date range, has a column named X), answered from profiles alone. Acceptance:
  stated after the note measures a baseline; today the answer is zero because no
  such operation exists.
- Determinism: two builds of the same folder give byte-identical profiles.
- Incremental: an unchanged file's record is carried, a changed file's is
  recomputed, a removed file's is gone; shown through `apply`.
- Size and time against `main`, and the timing rule for the natives.

### Left out

Language identification beyond script; entity extraction (people, places);
summaries written by a model (the host can add one; the engine stores none);
near-copy detection; reading values out of tables.

### Questions for reviewers

- **H4-Q1. The field list.** Is anything here not worth its bytes, or missing
  for "know what kind of data is present in each file"?
- **H4-Q2. `kind` as one value.** A Markdown file that is mostly a table: one
  kind with a rule, or a small set of shares?
- **H4-Q3. Dates.** Counting only unambiguous shapes is safe and misses much.
  Is a locale hint from the caller acceptable, or should ambiguous dates stay
  uninterpreted?
- **H4-Q4. Privacy of terms.** `terms` puts a file's distinctive words in an
  operation that lists files. It adds nothing a caller with read access could
  not get from `read_span`, but it makes them cheap to enumerate. Is that
  acceptable under [authorization](../authorization.md)?
- **H4-Q5. Stored or computed.** Is the proposed threshold the right test?

---

## H5. The relevant parts

Seven changes, each measured on the judged set on its own, in this order. Each
is one task unless the note shows two belong together. Items 1 to 4 change what
comes back; 5 to 7 change what the caller is told.

### 1. More than one passage per file with names and content

**Fault:** with the `both` field a file contributes one result, its best chunk
(`zig/src/core/filename_field.zig:706`); a question whose answer is two passages
of one file scores 0 of 11.

**Proposed:** a request field `per_file` (1 to 5; default 1 keeps today's
answers byte-identical). When above 1, a file may contribute up to that many
chunks, in score order, each above a floor relative to the file's best chunk
(proposed: at least 50 % of its lexical score), and they are reported adjacent
to the file's first result with a `same_file_rank`.

**Acceptance:** two-passages complete rises from 0 of 11 to at least 8 with
`per_file = 3`; no other kind loses a complete answer at the same `top_k`
(listed question by question if one does).

### 2. Neighbours when the answer spans chunks

**Fault:** an answer that crosses a chunk boundary comes back as one half.
`ss_evidence` can return `neighbours {prev, next}`
(`zig/include/search_simpli.h:440`), but no search result carries them, and
overlapping windows are not merged (the 3-line overlap of `line-window-v1`
repeats lines).

**Proposed:** a request field `merge_adjacent` (default false). When set,
results that are adjacent or overlapping chunks of one file are merged into one
passage with one line range, the overlap removed, and the merged passage's score
is the best of its parts. A merged passage is capped at 3 chunks.

**Acceptance:** the judged kinds whose passages span a boundary (the scorer
lists them) gain complete answers; median evidence bytes do not rise by more
than 10 % at the same `top_k`.

### 3. Near-identical passages collapse

**Fault:** copies and near copies fill the first ten (scenario findings; H2's
logs make it worse). Only `find` removes overlapping duplicates
(`zig/src/core/find.zig:643`).

**Proposed:** a request field `collapse` (`none` default, `exact`, `near`).
`exact`: results whose passage text is byte-identical after whitespace
normalisation collapse into the best-ranked one, which gains
`also_in: [{root_id, path, start_line, end_line}]` (capped at 20, with
`also_in_more`). `near`: the same for passages whose normalised line sets
largely overlap (shared lines over lines in the union). **The threshold is not
proposed here; the note must derive it.** A consuming application that folds
copies itself found that a high threshold does not do what it sounds like: with
one differing line in a passage of *n* lines the share is (n − 1)/(n + 1), which
is 0.82 at ten lines and reaches 0.9 only at nineteen. It settled on 3/5, the
highest value that folded its copy cases and kept its template cases apart, and
recorded the limit of any line-set rule: two notes from one template that differ
in a single line of four or more look like copies. The note measures candidate
thresholds, and an alternative measure (overlap of word shingles), on the judged
set's copies and on a new template slice. The engine keeps fetching candidates until `top_k`
distinct passages are found or candidates run out, so collapsing never returns
fewer results than exist.

**Acceptance:** on the judged set after H2, the questions that lost the
4,096-byte budget to repeated logs regain it; the count of distinct files in the
first ten rises; no complete answer is lost.

### 4. The current copy

**Fault:** a stale copy ranks first in 10 (typed) and 5 (query words) of 22, and
nothing says which is newer.

**Proposed, in two parts.** (a) Every result carries `modified_ms` (from H4's
recorded time) so a caller can tell. (b) A request field `prefer_newer` (default
false): among results that step 3 would group as near copies, the newest file is
the representative; ranking between different passages is unchanged. Time never
outranks relevance between unrelated files.

**Acceptance:** stale-copy-first falls to at most 2 of 22 with `collapse = near`
and `prefer_newer`; no other measure changes without them.

### 5. Passages that fit a budget

**Fault:** with names and content only 9 (typed) and 36 (query words) of 169
answers are complete within 4,096 bytes; a chunk is up to 1,600 characters and
the whole chunk is returned. Nothing in the engine caps evidence bytes; 4,096 is
the scorer's yardstick.

**Proposed:** a request field `max_bytes` on `evidence` and `search_knowledge`.
When set, each passage is trimmed to the lines around its matched terms (a
window grown outward from the matched lines to whole lines, the heading line
kept), and results are filled in rank order until the budget is reached;
`truncated_by_budget` says results were left out. Each trimmed passage reports
its true line range, so `read_span` can widen it.

**Acceptance:** complete within 4,096 bytes with names and content rises from 9
and 36 to at least 60 and 80 (the note sets the final bar from a prototype), and
judged share (tightness) rises.

### 6. Say when the evidence is weak

**Fault:** 11 (typed) and 8 (query words) of 12 questions with no answer in the
folder return results, and no field says the match is weak. Warnings
(`query_term_unmatched`, `query_term_expanded`, ...;
`zig/src/ops/report.zig:46`) reach only `ss_query` and Dart, not `search_knowledge`,
MCP or the CLI, although the tool schema lists `warnings`.

**Proposed:** (a) warnings on every interface, as CAP-22 intended. (b) Per
result: `matched_terms` (which query words the passage holds, after grouping)
and `coverage` (their share of the query's content words). (c) Per response:
`match_quality`, one of `strong`, `partial`, `weak`, by a documented rule on
coverage and on whether matches are by name only or by a fuzzy expansion. No
score threshold is used, because BM25 scores are not comparable across folders
([CAP-14](../requirements/cap-14-trust-calibration.md) owns calibrated trust and
stays separate).

**Acceptance:** on the 12 no-answer questions, `match_quality` is `weak` for at
least 10; on the 169 answerable ones it is `weak` for at most 5 % of those
answered completely. Both numbers reported as typed and as query words.

### 7. Question words, short-word fuzziness, numbers

Three query-side faults, no index change:

- **Question words steer ranking** (as typed 100 against 109 as query words).
  Proposed: a small fixed list of question and function words per supported
  language (English first; Tamil after review by a reader of Tamil) that are
  dropped from ranking **only when at least one other word remains**, reported
  in a `query_term_ignored` warning. A quoted word is never dropped.
- **`where` becomes `were`.** fuzzy-v1 fires on an unmatched word of five or
  more letters ([fuzzy-v1](../fuzzy-v1.md)). Proposed: a word on the list above
  is never fuzzy-expanded; the floor itself (the 03-next row "fuzzy-v1 floor")
  is measured at 5 and 6 on the judged set and the better kept.
- **`142.50` is split** into `142` and `50` by the analyser
  (`zig/src/core/analyzer_v2.zig:1`). Changing the analyser changes the index
  format and every index. Proposed instead, query side: a number with internal
  punctuation is searched as its parts **required adjacent in that order**
  (positions already exist for `find`'s phrase mode), with the same for
  identifiers such as `AB-1234`. The exact form is always available through H3.

**Acceptance:** as-typed complete rises to within 3 of the query-words figure in
each column; the scenario cases for `where`/`were` and `142.50` pass; no
query-words figure falls.

### Defaults

Every new request field defaults to today's behaviour, so existing callers get
byte-identical answers (shown on the three 10k corpora). After all seven are
measured, one further task proposes **new defaults** (for example
`collapse = exact`, `per_file = 2`) as a contract change of its own, with the
judged-set table for each candidate. That decision is the maintainer's.

### Questions for reviewers

- **H5-Q1. Options or behaviour.** Seven opt-in fields keep every existing
  answer stable but put the burden on callers. Should some of these simply
  become the behaviour (collapse of exact copies, warnings everywhere)?
- **H5-Q2. Stop words.** Dropping question words is the oldest trick and the
  one most often regretted. Is "only when another word remains, never inside
  quotes, always reported" enough protection? Who can review the Tamil list?
- **H5-Q3. Near-copy measure.** Line-set overlap is simple and explainable, but
  its threshold is fitted to examples (see item 3), and it folds notes from one
  template that differ in one line. Is a different measure better (word
  shingles, an edit distance on the differing lines), or should near copies be
  grouped visibly and never hidden?
- **H5-Q4. `prefer_newer` and file times.** Modification times are unreliable
  after a copy or a sync. Is "only among near copies" narrow enough?
- **H5-Q5. `match_quality` without a threshold.** Is a three-value signal from
  term coverage honest enough to show a person, or does it need CAP-14 first?
- **H5-Q6. Numbers.** Query-side adjacency avoids a format change but leaves
  `142.50` and `142 50` indistinguishable. Acceptable, given H3 gives the exact
  form?

---

## H6. Refinement

Refinement comes after the base and is kept only where the judged set rises.
Two separate tracks.

### Semantic matches for a folder the engine indexed

Today vectors enter only through `import-json`; a `searchd`-built index has
none, and `apply` over a vector snapshot fails
([CAP-21](../requirements/cap-21-host-supplied-vectors.md), status Proposed, not
approved). CAP-21's design stands as written: the host embeds after a lexical
publish, the engine checks the model identity and stores a lazily loaded vector
section. **This step does not start until the maintainer has read and decided
CAP-21.** What this document adds is the gate:

- The judged set's `synonym` kind (2 or 3 complete, of its questions) and
  `about` kind are the ones a semantic signal should move. A semantic slice is
  added to the judged set first, frozen, with a lexical baseline.
- Acceptance for keeping it: complete answers on those kinds rise, no other kind
  falls by more than one question, and the index size and query time costs are
  stated per 10,000 files.

### The language-model loop

The engine does not call a model. It gives a model's host the tools for a loop:
ranked search with H5's signals, `scan` (H3), `profile` and `folder_profile`
(H4), `read_span`. The work here is:

1. The skill and tool descriptions ([tool protocol](../tool-protocol.md),
   [MCP server](../mcp-server.md)) rewritten for the loop: when to reword, when
   to `scan` for the exact string, when to read wider, when to say the folder
   does not hold the answer (`match_quality`).
2. An agent run with the MCP server as the only tool (an open follow-up in
   section G) over the judged set: complete answers, quotes verified by `scan`,
   and the number of tool calls, against the single-call baseline.
3. Each loop behaviour is kept in the skill only if the run's score rises.

### Questions for reviewers

- **H6-Q1.** Is CAP-21's two-phase design (lexical publish, then the host
  supplies vectors) still the right shape now that prepared metadata is allowed,
  or should the engine own an embedding step behind an interface?
- **H6-Q2.** Which model and budget should the agent run be judged with, so the
  numbers mean something to an outside reader?

---

## Smaller faults to fix alongside

One task each, small; none needs a capability document unless stated.

| # | Fault | Evidence | Proposed fix |
| --- | --- | --- | --- |
| S1 | CLI errors do not name the path (`error: FileNotFound`). | scenarios X01, X02; `zig/src/interfaces/main.zig:20` | Folder and file commands print the path and a one-line cause; exit codes unchanged. |
| S2 | README says `query` prints ranked passages; it prints `path:lines score`. | scenarios Q02; `README.md:33`; `zig/src/interfaces/cli.zig:955` | Correct the sentence; consider a `--show-text` flag in the same task. |
| S3 | An accent in a file name is not folded by the `filename` field (`cafe` misses `café notes.md`). | scenarios finding 5; [fold-groups-v1](../fold-groups-v1.md) | Fold marks in file-name matching, query side, reported as a grouped term. Changes answers for the `filename` field: capability note. |
| S4 | `ss_import_json` with a generation at or above 2^63 publishes and then reports failure. | [S6-T21](../tasks/S6-T21.md) merge section | Refuse before publishing; test. |
| S5 | Two C header comments name old paths. | `zig/include/search_simpli.h:5`, `:73` | Correct. Header text only; the maintainer was asked. |
| S6 | `search_knowledge` schema lists `warnings` but the RPC path sends none. | `zig/src/ops/report.zig:46`; [fuzzy-v1](../fuzzy-v1.md) | Folded into H5 item 6. |

---

## Proposed order and size

| Order | Task | Depends on | Natives change | Contract |
| --- | --- | --- | --- | --- |
| 1 | S6-T23 H2 all the text (in progress) | H1 | yes | 2.9.0 |
| 2 | S1, S2, S4, S5 small faults | none | S4 only | none |
| 3 | H5 item 6 (a): warnings on every interface | none | yes | additive |
| 4 | H3 `scan`, note then build | H2 | yes | new operation |
| 5 | H5 items 3 and 1 (collapse; passages per file) | H2 | yes | additive |
| 6 | H4 profile, note then build (records `mtime`) | H2 | yes | new operations, maybe a new section |
| 7 | H5 items 4, 2, 5 (current copy; neighbours; budget) | H4 for 4 | yes | additive |
| 8 | H5 items 6 (b, c) and 7 (weak evidence; question words; numbers) | 3 | yes | additive |
| 9 | H5 defaults task | 5, 7, 8 | yes | changes defaults |
| 10 | H6 loop: skill, MCP-only agent run | 4, 6, 8 | no | none |
| 11 | H6 semantic | CAP-21 decided | yes | CAP-21 |

Rows 2 and 3 can run beside row 4. Each row is a builder, a separate verifier,
and a merge; rows that change the natives each need a timing run.

## What this document does not decide

- New defaults for existing callers (row 9; the maintainer's).
- CAP-21, CAP-13's move to Validated, and review items R09 and R10 (the
  maintainer's; unchanged by this document).
- Other formats (PDF, images through text recognition, word-processor
  documents): after H1 to H5, and the host application's work today.
