# `scan`: every line that holds a string or matches a pattern

`scan` reads the text of the files in scope line by line and returns every line that holds an exact string or
matches a pattern. It is for what `find`'s words cannot ask: a code (`TS-0142`), an amount (`142.50`), part of a
word, punctuation, a line of a given shape. It is slower than `find`, because it reads the text instead of
looking words up, so it pages and has a time budget.

The design, the measurements and the rulings are in
[decision 0006](decisions/0006-pattern-search.md); the requirement is
[CAP-25](requirements/cap-25-pattern-search.md). The schemas are
[`contracts/tools/scan.request.schema.json`](../contracts/tools/scan.request.schema.json) and
[`scan.result.schema.json`](../contracts/tools/scan.result.schema.json).

## Where it runs

| Surface | Call | Source |
| --- | --- | --- |
| Command line | `searchd scan <dir> "<pattern>" [flags]` | an index (its retained source bytes) |
| Command line | `searchd scan --folder <folder> "<pattern>" [flags]` | a folder, with nothing prepared and nothing written |
| `searchd serve` (JSON-RPC) | method `scan` | the index |
| `searchd mcp` | tool `scan` (read-only; not in `--baseline`) | the index |
| C ABI | `ss_scan(handle, request_json)` (contract 2.10.0) | the open handle's index |
| Dart | `engine.scan(pattern, {...})` (package 0.12.0) | the open index |
| Python reference | `src/search_platform/scan.py`: `scan(index, request)`, `scan_folder(root, request)` | a `core` index, a folder |

A folder scan is on the command line and in the Python reference only; there is no `ss_scan_folder` yet.

## The request

| Field | Default | Range | Meaning |
| --- | --- | --- | --- |
| `pattern` | (required) | 1 to 1,024 bytes of UTF-8, no line break | the string or the pattern |
| `mode` | `literal` | `literal`, `regex` | `literal`: no character is special. `regex`: the subset below |
| `case` | `smart` | `sensitive`, `insensitive`, `smart` | see [Case](#case) |
| `whole_word` | `false` | | a match needs a non-word code point, or the line's edge, on each side |
| `roots` | all visible | | the roots to search, as in `find` |
| `path_prefix` | none | | a root-relative path prefix |
| `name_glob` | none | at most 255 bytes | the file name (not its folders) against `*` and `?` |
| `context_lines` | 0 | 0 to 20 | lines before and after each hit |
| `max_hits_per_file` | 50 | 1 to 1,000 | after that many hit lines the rest of the file is skipped and counted in `files_capped` |
| `page_size` | 20 | 1 to 100 | hit lines per page |
| `cursor` | none | | the previous page's `next_cursor` |
| `time_budget_ms` | 2,000 | 1 to 30,000 | see [Time](#time) |

On the command line: `--regex`, `--case`, `--word`, `--roots a,b`, `--path-prefix`, `--glob`, `--context`,
`--max-per-file`, `--page-size`, `--cursor`, `--time-ms`, `--json`, and `--max-file-bytes` with `--folder` only
(default 10 MiB; a larger file is counted as `too_large`). Without `--json` the hits are printed as
`path:line:text` (`root/path` when the index has named roots), with context lines as `path-line-text` and `--`
between hits; the next cursor, a time stop and the files not searched are told on stderr. Exit 0 for an answer,
1 for a refused request, 2 for a usage error.

## The pattern language (`mode: "regex"`)

| Write | Means |
| --- | --- |
| `abc` | the characters, in order |
| `.` | any one code point |
| `^`, `$` | the start, the end of the line (a line holds no terminator) |
| `[abc]`, `[a-z]`, `[^0-9]` | a class; `]` first (or right after `^`) is itself |
| `\d`, `\D` | a decimal digit of any script (Unicode Nd), or not: `\d` matches `7`, `௩` and `٣`, not `²` or `Ⅻ` |
| `\w`, `\W` | a word code point, or not (below) |
| `\s`, `\S` | white space, or not |
| `\b`, `\B` | a word boundary, or not |
| `\t` | a tab |
| `\.`, `\(`, `\ `, … | a backslash before ASCII punctuation or a space is that character |
| `a|b` | either |
| `(...)`, `(?:...)` | a group (nothing is captured) |
| `*`, `+`, `?`, `{m}`, `{m,}`, `{m,n}` | repeats, greedy; m and n at most 255 |

**Word code points** are the analyser's: letters and digits by Unicode category, the combining marks Mn and Mc,
and the joiners ZWNJ and ZWJ. So a Tamil word with its vowel signs is one word. **`_` is not a word character**
(ruling O-1): in `tide_pool`, `\w+` matches `tide` and `pool` separately, `\bpool\b` and `pool` with
`whole_word` both match, and `e_p` with `whole_word` does not.

**Refused,** with `invalid_argument` and the message `pattern not supported at byte <n>: <reason>` (`<n>` counts
bytes from 0):

| Construct | Reason |
| --- | --- |
| `(?=`, `(?!`, `(?<=`, `(?<!`, `(?i)` | `look-around and inline flags are not supported` |
| `\1` to `\9` | `back-references are not supported` |
| `\n`, `\x41`, `\p{L}`, `\A`, any other letter escape | `an escape outside the subset` |
| `*?`, `+?`, `*+`, … | `lazy and possessive repeats are not supported` |
| `[[:alpha:]]` | `a [ inside a class must be escaped` |
| `[\b]` | `\b inside a class is not supported` |
| `*a`, `a**`, `^*` | `a repeat follows nothing it can repeat` |
| `a{`, `a{,3}`, `a{2,`, `a{256}`, `a{3,2}` | the repeat's own reason |
| `[z-a]`, `[abc`, `(a`, `a)`, a trailing `\` | the class's, the group's or the backslash's reason |
| a program over 8,192 steps (`(a{255}){255}`) | `the pattern is too large (over 8,192 steps)` |

In both modes a pattern that is empty or over 1,024 bytes, not UTF-8, or holds a line break is refused. A real tab
in a literal is accepted.

The matcher runs in time proportional to the pattern's size times the line's length, whatever the pattern: there
is no catastrophic backtracking.

## Case

- `sensitive`: code points as written.
- `insensitive`: the line and the pattern are folded one code point to one (the analyser's simple fold), so
  offsets do not move. `K` matches `k` and the Kelvin sign; `Σ`, `σ` and `ς` match each other. A letter whose
  fold is more than one code point does not change: `ẞ` and `ß` do not match each other, and neither matches `ss`.
- `smart` (the default): insensitive, unless the pattern writes a code point that changes under the fold (`Tide`
  is sensitive, `tide` and `142.50` are insensitive). The answer's `case_applied` says which.

## The answer

Hits come in order of `root_id` (bytes), then path (bytes), then line. **A hit is a line**: `root_id`, `path`,
`line` (1-based, `read_span`'s numbering: CRLF is one break, a leading BOM is not part of line 1), `text` (the
line without its break, at most 512 bytes, cut on a code point, with `text_truncated`), `match_offsets` (every
match starting within `text`, as `[start, end)` in code points, leftmost first, not overlapping), and `before` and
`after` (`{line, text, text_truncated}`). Neighbouring hits each carry their own context, so a line can repeat.

**A pattern that can match the empty string** (`x?`, `a|`, `^`) makes a line a hit even where it matches only
the empty string; such a match is left out of `match_offsets`, so a hit can have none. The answer then carries
the warning `pattern_matches_empty`.

The counts are over the files finished on this page, so their sums over all pages are the totals:
`files_scanned`, `bytes_scanned`, `files_matched`, `files_capped`. `pending_files` and `not_scanned`
(`too_large`, `unreadable`, `budget_exhausted`, `not_retained`) count the files in scope that were not searched;
`truncated` is true when any of them is not zero, so an empty answer with `truncated: true` is not "no line".
A folder scan also gives `not_read`: the files the walk did not read, by kind, as `searchd index` reports them.
A file hidden by its root or its labels is never searched and never counted.

## Paging

`next_cursor` present means more may remain; pass it back with the same request. A cursor belongs to its request:
another pattern, case, scope or set of labels refuses it (`cursor does not belong to this request`).

- **Over an index** a cursor names its generation. After a new generation is published it is refused with
  `stale cursor`, as `find`'s is; start again from the first page.
- **Over a folder** there is no generation. The cursor names the list of paths the walk found, so a file added,
  removed or renamed between pages makes it `stale cursor`. **An edit to a file that keeps its path is not
  detected** (ruling O-4): every hit is a true match of the file as it was read for its page, but lines can shift
  between pages, and a line edited between pages can be missed or listed twice.

## Time

`time_budget_ms` bounds one page. The clock is checked between files, every 256 lines, and inside the matcher
every 4,096 code points. When the budget runs out the page ends with `stopped: "time"` and always a
`next_cursor`; it may hold fewer hits than `page_size`, or none, but never a hit with missing offsets. Call again
with the cursor.

A single line that alone takes longer than the whole budget would make no progress, so the request is refused
with `capacity` (`SS_ERR_CAPACITY`) and the message `line <n> of <root>/<path> outlasts time_budget_ms (<b>): raise
it (at most 30000) or narrow the scope` (ruling O-7). This is distinct from an ordinary `stopped: "time"`.

There is no cancel yet; a scan holds the server for at most its budget.

## Known differences from the Python reference

The Python reference translates a pattern into Python's `re` with explicit classes. It and the engine agree on
every generated case in `tests/test_scan.py` but one, recorded there with its reason: an empty alternative first
inside a repeat, `(|a)*` over `aa`, gives `[[0,2]]` in the engine and `[[0,1],[1,2]]` in Python's `re`. The
lines that match are the same; only the offsets differ. The reference's cursors use SHA-256 where the engine's use
XXH3, so a cursor is only handed back to the implementation that made it; and the reference checks its budget
between lines only, never inside one.
