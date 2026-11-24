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
| a program over 8,192 steps (`(a{255}){255}`), or a compile that would do over 8,192 steps of work, emitting or not (`(?:a{255}){32}`) | `the pattern is too large (over 8,192 steps)` |

In both modes a pattern that is empty or over 1,024 bytes, not UTF-8, or holds a line break is refused. A real tab
in a literal is accepted.

A repeat of something that can only match the empty string (`(?:)`, `^$`, `\b\b`, and groups of them) is kept
at most once: `(?:^$){255}` is `(?:^$)`, `(?:\b\b)*` is `(?:\b\b)?`. It matches the same lines and the same
offsets, and nested repeats of it cost nothing to compile.

The matcher runs in time proportional to the pattern's size times the line's length, whatever the pattern: there
is no catastrophic backtracking. Deciding whether a line is a hit is one pass. In `regex` mode at most **16
matches a line** are listed: when a 17th non-empty match starts within `text`, `text` is cut where it starts,
with `text_truncated: true` and **`matches_truncated: true`**, so every match listed is whole, nothing the hit
says is unchecked, and a caller can tell this cut from the 512-byte one (which sets `text_truncated` alone).
Empty matches are not listed and do not count: `x*` over a line of 17 or more code points gives the whole line
(up to 512 bytes) with no offsets and nothing cut. Listing a line's matches is so at most 17 passes plus one per
code point of `text` where an empty match starts (at most 512), all of it metered. In `literal` mode every match
is listed (the search is one linear pass: Knuth-Morris-Pratt) and `matches_truncated` is always false.

A class costs a bounded amount to test whatever it says: when a pattern is compiled, a class's ranges are sorted
and merged and each of `\w`, `\d` and `\s` is kept once (`[^\w\w…\w]` is `[^\w]`), so testing a code point is at
most five binary searches (the ranges, the two tables of `\w`, the table of `\d`, the folds). Compiling is
bounded too: every pattern of the fuzz, up to 1,024 bytes, class-heavy ones and the crafted ones at the caps
included, compiles in at most 500,000 counted steps (`pattern.zig`, "compiling any pattern of up to 1,024 bytes
is bounded work"); timed outside the tests (`scripts/prototypes/s6t24/rework2/meter_bench.zig`, ReleaseSmall),
the slowest took at most 0.45 ms.

## Case

- `sensitive`: code points as written.
- `insensitive`: the line and the pattern are folded one code point to one (the analyser's fold table), so
  offsets do not move. `K` matches `k` and the Kelvin sign; `Σ`, `σ` and `ς` match each other. The table is
  Unicode simple case folding (Unicode 13.0.0) except for the 28 code points whose full folding is more than one
  code point: they are left as they are. So `ẞ` (U+1E9E, full fold `ss`) and `ß` do not match each other, and
  neither matches `ss`; and the 27 Greek capitals with prosgegrammeni (`ᾈ` to `ᾏ`, `ᾘ` to `ᾟ`, `ᾨ` to `ᾯ`, `ᾼ`,
  `ῌ`, `ῼ`) do not match their lowercase forms (`ᾀ` and the rest).
- `smart` (the default): insensitive, unless the pattern writes a code point that changes under the fold (`Tide`
  is sensitive, `tide` and `142.50` are insensitive). The answer's `case_applied` says which.

## The answer

Hits come in order of `root_id` (bytes), then path (bytes), then line. **A hit is a line**: `root_id`, `path`,
`line` (1-based, `read_span`'s numbering: CRLF is one break, a leading BOM is not part of line 1), `text` (the
line without its break, at most 512 bytes, cut on a code point, with `text_truncated`; in `regex` mode cut sooner
where a 17th non-empty match starts, with `matches_truncated`, above), `match_offsets` (every non-empty match
starting within `text`, as `[start, end)` in code points, leftmost first, not overlapping), and `before` and
`after` (`{line, text, text_truncated}`). Neighbouring hits each carry their own context, so a line can repeat.

**What ends a line** (`read_span`'s breaks): LF, CR, CRLF (one break), VT (U+000B), FF (U+000C), the separators
FS, GS and RS (U+001C to U+001E), NEL (U+0085), LS (U+2028) and PS (U+2029). `grep` ends a line at LF only, so
its line numbers and its lines differ from `scan`'s in a file holding any of the others.

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
- **The file in a cursor** is an ordinal among all the files the caller may see, in scan order, before
  `path_prefix` and `name_glob`: those are tested on each file's path as the scan reaches it, inside the budget,
  so a page can stop with `stopped: "time"` while it is still passing over names that do not match, and the
  next page carries on from there.
- **Over a folder** there is no generation. The cursor names the list of paths the walk found, so a file added,
  removed or renamed between pages makes it `stale cursor`. **An edit to a file that keeps its path is not
  detected** (ruling O-4): every hit is a true match of the file as it was read for its page, but lines can shift
  between pages, and a line edited between pages can be missed or listed twice.

## Time

`time_budget_ms` bounds one page. **A scan holds its caller for at most `time_budget_ms` plus 50 ms**, on every
path, with these outside the budget, each stated here:

- **The walk of a folder.** A folder scan lists every file under the folder first (`searchd index`'s walk) and
  only then starts the clock; a folder of many files takes that long whatever the budget.
- **Over an index, the list of files the caller may see**, built from the index before the clock starts, as
  `find` builds its candidates; with it the counts of the scope's pending and skipped files (`pending_files`,
  `not_scanned`), which are the same on every page, so every such file's path is tested against `path_prefix`
  and `name_glob` there: the files the index recorded as pending or skipped, and the files of roots that keep no
  source. That test is one step per byte of the path (3.1 ns a byte measured, ReleaseSmall: 16 ms for 20,000
  names of 255 bytes); the files the scan reads are tested inside the budget instead.
- **The read of the one file in hand** (at most `--max-file-bytes`, 10 MiB by default; finding a cursor's line
  in it is part of the read).

Everything else is inside it. The clock starts before the pattern is parsed. Work is metered, not sampled: the
matcher, the literal search, the line reader and the scope filter charge what they do and read the clock once
65,536 units have built up, and between files. **A unit is a bounded amount of work** (rework 2): a byte read
or searched, a byte of a path tested against `path_prefix` and `name_glob`, a thread of the matcher followed or
stepped, a position (one unit more when it folds, two when it tests a word boundary), and a step on a class over
a code point outside ASCII one unit per binary search it may do (at most six). The tests count the work behind
each unit (at most 12 elementary steps a unit; measured at most 5.24) and the units between two reads of the
clock (at most 65,536 plus one position's, 139,268 in all), on the heaviest units and on every fuzz pattern;
`pattern.zig` and `scan_test.zig`, the tests named for rework 2.

The 50 ms is the first line's grace (10 ms, below), one meter interval (at most 139,268 units: 0.60 ms at the
slowest unit measured, 4.3 ns; the widest gap measured, 0.25 ms), the compile (at most 500,000 counted steps;
0.45 ms measured at most) and the work of a hit outside the meter (its text and context, at most 41 lines of 512
bytes). The times are of this repository's ReleaseSmall build on the development Mac
(`scripts/prototypes/s6t24/rework2/meter_bench.zig`); a slower machine scales them, and the counts hold on any.
Timed end to end, through the command line and `searchd serve`, by
`scripts/prototypes/s6t24/rework2/bound_probe.py` and the verifier's probes; no default test asserts a time
(NFR-19).

When the budget runs out the page ends with `stopped: "time"` and always a `next_cursor`; it may hold fewer hits
than `page_size`, or none, but never a hit with missing offsets. Call again with the cursor.

**The first line of a page gets 10 ms** even when the budget is spent (a tiny budget, or a long read), so a page
always makes progress where a line can be searched in 10 ms. A single line that cannot be searched within the
budget and that grace would make no progress, so the request is refused with `capacity` (`SS_ERR_CAPACITY`)
(ruling O-7). The message names the cause:

- `line <n> of <root>/<path> outlasts time_budget_ms (<b>): raise it (at most 30000) or narrow the scope` when
  the line itself took the budget;
- `time_budget_ms (<b>) ran out reading <root>/<path>, and line <n> did not finish in the 10 ms after: raise it
  (at most 30000) or narrow the scope` when the budget had gone on reading the file (or compiling) before the
  line started.

This is distinct from an ordinary `stopped: "time"`. There is no cancel yet.

## Memory

A page holds **one file's bytes at a time**, plus what is bounded by the request: the page's hits (at most
`page_size` lines of 512 bytes, each with its context) and a ring of `2 × context_lines + 1` line positions. No
table grows with the number of lines in a file. Over an index the stored text is read straight into that one
buffer when the file is kept whole, or rebuilt into it from its chunks. Measured
(`scan_service_test.zig`, ruling 4, and the verifier's `probe_memory.py`), a 10 MiB file of 67-byte lines and a
10 MiB file of nothing but line breaks (10,485,759 lines) give the same page: at most 2.25 times the file in live
allocator bytes (the arena growing by half again twice) plus under 1 MiB, over the folder and the index alike;
the process's peak memory footprint (ReleaseFast) 11.8 MB for both over the folder, 30.0 MB and 23.4 MB over the
index, whose own open (the index's tables, not the page) makes the difference.

## Known differences from the Python reference

The Python reference translates a pattern into Python's `re` with explicit classes. It and the engine agree on
the lines that match and on every count for every pattern. They **may differ on `match_offsets`**, and so on
where a `text` cut after 16 matches ends, for one class of pattern: **a regex holding a repeat with no upper
bound, or one above 1, whose body can match the empty string** (`(|a)*`, `(a?)+`, `(?:x|y?){3,}`; the
reference's `offsets_may_differ`). Python's `re` retries such a repeat after an empty iteration; the engine's
Pike VM ends the repeat there. For example `(|a)*` over `aa` gives `[[0,2]]` in the engine and `[[0,1],[1,2]]`
in Python's `re`. `tests/test_scan.py` compares exactly that much on those patterns (lines and counts, not text
or offsets) and everything on the others. The reference's cursors use SHA-256 where the engine's use XXH3, so a
cursor is only handed back to the implementation that made it; and the reference checks its budget between lines
only, never inside one.
