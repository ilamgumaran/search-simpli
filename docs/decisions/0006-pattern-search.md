# ADR 0006 · Pattern search: `scan`, a line-by-line search for exact strings and a small pattern language

**Status:** design note of [S6-T24](../tasks/S6-T24.md), Part 1, written from `main` at `43a308d` before any engine
code (23 Nov 2026). Plan step [H3](../plans/2026-11-22-text-search-implementation-spec.md#h3-pattern-search-scan).
Line numbers are `main`'s at `43a308d`. Each claim says how it is known: *read* (from the code), *shown* (a run, with
its evidence file in [`docs/evidence/s6-t24/part1/`](../evidence/s6-t24/part1/)), *measured* (a timed run) or
*argued*. No file under `zig/src/`, `contracts/`, `zig/include/`, `bindings/` or `src/` is changed. The prototype is
in [`scripts/prototypes/s6t24/`](../../scripts/prototypes/s6t24/) and is described in
[section 10](#10-the-prototype-what-it-does-and-what-it-cannot-show).

**The recommendation in one paragraph.** `scan` is a new read-only operation. It searches the lines of each file for
a literal string (the default) or for a pattern in a small regular-expression subset. Matching is per line, in time
linear in the line, by a Pike VM over code points. The VM is about 400 lines in a new `core/pattern.zig`. A literal
skips the VM: a byte search of the whole file runs first (Boyer-Moore-Horspool from the standard library), and an
ASCII case-insensitive byte search is exact when the needle holds no `s` and no `k`. Case folding is the analyser's
simple one-to-one fold. There is no accent or mark folding and no NFC. `\w` and `\b` use the analyser's word
code points, so Tamil words are words.

`scan` runs over two sources through one iterator:

- an index, through `source.Section.fileBytes`;
- a folder with nothing prepared, through the S6-T23 walk and a read-and-caps function extracted from
  `apply.applyParsed`.

Hits are ordered by root, then path, then line, and paged by a cursor bound to the generation. A cursor from
another generation is refused as `stale cursor`, as `find` does. A 2 s default time budget, which a request may
raise to 30 s, ends a page early with `stopped: "time"` and a cursor to resume from.

Measured with the prototype on this Mac, a literal over each 10,000-file corpus takes at most 27 ms from an index
and 127 ms from a folder. The two regular expressions take at most 418 ms and 528 ms (medians). It is a contract
change. The written rule requires a capability document and a `CONTRACTS_VERSION` step but does not say how large
a step. The repository's practice makes it a minor step, **2.10.0**. The specification's shape holds, with the
local corrections in [section 13](#13-where-the-rulings-and-the-specification-do-not-fit-the-code). The note
stops here for the orchestrator.

## 1. What exists today

| Question | Answer | How known |
| --- | --- | --- |
| Pattern code in `zig/src/` | None. `find` matches analysed tokens; quotes force phrase mode (`zig/src/core/find.zig` 317–331). | read |
| The bytes of an indexed file | `source.Section.fileBytes` (`zig/src/core/source.zig` 321–338). v1 (`HYBSRC01`) reads positionally and checks SHA-256 on every call. v2 (`HYBSRC02`, what `searchd index` writes today) rebuilds the file from its chunks and residual and checks SHA-256 on every call (`zig/src/core/source_v2.zig` 212–243). | read; the four scratch indexes are `HYBSRC02` (shown: their first 8 bytes) |
| Lines | `str.splitlines` lines: LF, CR, CRLF (one terminator), VT, FF, FS, GS, RS, NEL, LS, PS. A leading BOM is not part of line 1 (`source.zig` 1–28; `source.lineStarts` 427–444; `chunker.zig` 56–60). `chunker.splitLines` (95–126) keeps the BOM as a code point of line 1, but the numbering is the same. | read |
| Paging in `find` | Cursor `"<generation>:<offset>"` (`find.zig` 23, 267). Another generation gives `invalid_argument` `"stale cursor"` (64, 180–184, 309–315). Every page recomputes the whole ranked list (233–267). `page_size` 1..100, default 20 (59–60, 178–179). | read |
| What `truncated` means today | "True when the corpus may be incomplete" (`contracts/tools/find.result.schema.json` 151–153). It is not a paging flag: paging is `next_cursor` alone. | read |
| Order in `find` | Score, then `root_id`, path, `start_line` (`find.zig` 20–22). | read |
| Cancel | None anywhere. The MCP server "accepts and ignores" `notifications/cancelled`, because "every request is answered before the next line is read" (`zig/src/interfaces/mcp.zig` 16–17). The C ABI has no cancel function, and the Dart binding calls the library synchronously (`bindings/dart/search_simpli/lib/src/search_simpli_base.dart` 318–344). | read |
| Which files an index holds bytes for | Retained roots only. A host-declared `local` root defaults to no retention (`zig/src/core/apply.zig` 230–234). `searchd index` retains (`zig/src/core/indexer.zig` 420, 545). | read |
| The walk | `indexer.walkFolder` (267–296): sorted paths, dot components and ignored directories skipped, a bad name counted, the skip list, and the 8,192-byte sniff for names outside the 19 (`sniffFile` 301–308). `collectCandidatePaths` (311–313) returns the paths only. | read |
| Read and caps | Inline in `apply.applyParsed` (from 766), in the `.add, .change` branch (1070), lines 1082–1145: stat (unreadable when it fails), `max_file_bytes` (tombstone, `too_large`), byte budget (`budget_exhausted`), `readContent` (1472–1487), the re-sniff of a walked file outside the 19 names (1121–1131, `walk_binary`), the UTF-8 check (unreadable). Each outcome is bound to `work` bookkeeping (`work.skip`, `markCarried`, `tombstone`). Defaults: 10 MiB per file, 512 MiB per batch (49–50). | read |

## 2. The grammar: what is accepted and what is refused

### 2.1 `mode: "literal"` (the default)

The pattern is a string of 1 to 1,024 bytes of valid UTF-8, matched as written. No character is special.

### 2.2 `mode: "regex"`

```
pattern     = alternative ( "|" alternative )*
alternative = piece*                       (an empty alternative matches the empty string)
piece       = atom quantifier?
quantifier  = "*" | "+" | "?" | "{" m "}" | "{" m ",}" | "{" m "," n "}"     m, n decimal, m <= n <= 255
atom        = "(" pattern ")" | "(?:" pattern ")" | "[" class "]" | "." | "^" | "$"
            | "\d" | "\D" | "\w" | "\W" | "\s" | "\S" | "\b" | "\B"
            | "\" ascii-punctuation-or-space          (the character itself)
            | any other code point                    (itself)
class       = "^"? item+                    ("]" first, or right after "^", is a literal "]")
item        = c | c "-" c | "\d" | "\D" | "\w" | "\W" | "\s" | "\S"
c           = any code point but "\", "]" and "[" | "\" ascii-punctuation-or-space
```

- `^` and `$` are the start and end of the line; a line holds no terminator.
- `.` is any code point.
- Groups do not capture anything visible; `(...)` and `(?:...)` are the same.
- `ascii-punctuation-or-space` is U+0020–U+002F, U+003A–U+0040, U+005B–U+0060 and U+007B–U+007E.

**Refused.** Each refusal is `invalid_argument` (`SS_ERR_INVALID_ARGUMENT` over the C ABI). The message has the
form `pattern not supported at byte <n>: <reason>`, where `<n>` is the zero-based byte offset of the construct.
The reasons are the prototype's text (`scan_bench.zig` 185–278, exercised by its test block),
except four that the prototype does not have yet: `\b inside a class is not supported`,
`a [ inside a class must be escaped`, `a ) has no (` and `the pattern is too large (over 8,192 steps)`.

| Construct | Reason |
| --- | --- |
| `(?=` `(?!` `(?<=` `(?<!` `(?i)` and any other `(?` not followed by `:` | `look-around and inline flags are not supported` |
| `\1` … `\9` | `back-references are not supported` |
| `\` and a letter or digit outside `d D w W s S b B` (`\n`, `\t`, `\x41`, `\p{L}`, `\A`, `\Z`, …), or `\` and a non-ASCII code point | `an escape outside the subset` |
| `\b` or `\B` inside a class (in Python `[\b]` is a backspace) | `\b inside a class is not supported` |
| A `[` inside a class that is not escaped (`[[:alpha:]]`, set operations) | `a [ inside a class must be escaped` |
| `*?` `+?` `??` `{m,n}?` `*+` `++` `?+` | `lazy and possessive repeats are not supported` |
| A quantifier with nothing before it, or after `^`, `$`, `\b`, `\B` or another quantifier (`*a`, `a**`, `^*`) | `a repeat follows nothing it can repeat` |
| `{` with no number (`a{`, `a{,3}`) | `a repeat {m,n} needs a number` |
| `{m,n` with no closing brace | `a repeat {m,n} is not closed` |
| m or n above 255 | `a repeat bound is over 255` |
| n below m | `a repeat {m,n} has n below m` |
| `[` with no closing `]` | `a class [...] is not closed` |
| `[z-a]` | `a class range is reversed` |
| `(` with no `)` | `a group is not closed` |
| `)` with no `(` | `a ) has no (` |
| A trailing `\` | `the pattern ends with a backslash` |
| A program of more than 8,192 instructions (`(a{255}){255}` is 65,025) | `the pattern is too large (over 8,192 steps)` |

**Refused in both modes,** before parsing:

| Condition | Message |
| --- | --- |
| Empty, or over 1,024 bytes | `pattern must be 1..1024 bytes` |
| Not valid UTF-8, a lone surrogate included | `pattern is not valid UTF-8` |
| Holds a line terminator code point (U+000A–U+000D, U+001C–U+001E, U+0085, U+2028, U+2029) | `pattern holds a line break; matching is per line` |

A JSON request that writes `"\t"` sends a real tab, which is accepted as a literal. Only the regex escape `\t`
is refused. Whether to accept `\t` is open question O-8 in [section 14](#14-open-questions).

**Warnings, not refusals.** A pattern that can match the empty string (`x*`, `a|`, `^`) makes every line in scope a
hit. The answer carries the warning `{"code": "pattern_matches_empty", "message": "the pattern can match the empty
string, so every line matches"}`. The check is a flag computed at compile time (*argued*: the nullable set of a
regular expression is computed in one pass over the tree).

**Python's `re` agrees with the accepted part** (*argued*). Every accepted construct means in Python's `re` what it
means here, with three exceptions that the reference handles itself. `\w`, `\d` and `\s` are expanded into explicit
classes, because Python's `\w` has `_` and has no combining marks. Case is applied by folding (section 4.3), not by
`re.IGNORECASE`. `whole_word` is compiled as `(?<![…])(?:P)(?![…])`, using the same word class. The reference has its
own parser that refuses exactly the table above, with the same messages. It then emits a Python pattern, so both
sides accept the same patterns, as the specification asks (H3, "Code" table, last row).

## 3. The matcher and its worst-case bound

**Design** (prototyped in `scan_bench.zig` 304–529):

- **Parse and compile.** The pattern is parsed to a tree and compiled to a program of `char`, `any`, `class`,
  `assert` (`bol`, `eol`, `word`, `not_word`, `not_word_before`, `not_word_after`), `split`, `jmp` and `match`.
  Counted repeats are unrolled. The program is capped at 8,192 instructions (`max_program`, 113) and a repeat bound
  at 255 (`max_repeat`, 114).
- **Run.** A Pike VM makes one pass over the line's code points. It keeps two thread lists and a sparse set, so at
  most one thread per instruction per position. The epsilon closure is computed lazily at each position, so an
  assertion sees the code points before and after that position (421–468).
- **Memory.** All memory is set up once per call (`Vm.init` 395–406: five arrays of program length and two stacks of
  twice that). Nothing is allocated per line.
- **Semantics.** Leftmost-first: of the matches starting at the leftmost position, the earlier alternative and the
  greedier repeat win. This is the match a backtracking matcher, Python's `re` included, finds first (*argued*: the
  standard Pike VM result; *shown* by the prototype's agreement with `grep` in [section 9](#9-measurements)).

**Every match in a line.** A hit reports the offsets of its matches. The rule is Python 3.7's `finditer`:

- after a match `[s, e)`, the next search starts at `e`;
- after an empty match, an empty match at the same position is not allowed, but a non-empty one starting there is.

Empty matches are dropped from `match_offsets`, but they still make the line a hit (the warning above). The
"not empty here" condition depends only on the path a thread takes. It is therefore an assertion like the others,
and the leftmost-first priority still holds (*argued*). Python 3.9 gives `a*` over `baaac` the spans
`(0,0) (1,4) (4,4) (5,5)` and `a*|b` over `b` the spans `(0,0) (0,1) (1,1)` (*shown*, by a direct run). The
engine's offsets for those two are `[[1,4]]` and `[[0,1]]`.

**Bound.** For a program of `m` instructions and a line of `n` code points:

- **Whether a line is a hit:** one search, at most `m` thread steps per code point, so O(m·n) time and O(m) memory
  (*argued*; *measured* below).
- **Offsets:** they are reported only for matches that start within the hit's `text` (the first 512 bytes of the
  line; section 7). The iteration stops at the first match that starts beyond it. So a line costs at most
  2 × 513 + 1 searches, at most two per start position (one empty, one not). The bound is O(1027·m·n), linear in
  `n` (*argued*).
- **Without that cap,** listing every match is quadratic. This is a known property of leftmost-first iteration:
  `a*b|a` over n `a`s matches n times, and each search runs to the end of the line before the `a*b` thread dies
  (*measured*, below).
- **Wall-clock:** the time budget (section 8) is checked inside the VM every 4,096 code points, so no single line
  can hold a call past its budget by more than one interval (*argued*). *Superseded by section 17:* the work is
  metered (the clock read once 65,536 units of work have built up), and at most 16 matches are listed a line.

*Measured* (`docs/evidence/s6-t24/part1/linear.txt`; prototype ReleaseSmall, best of 3). `(a+)+b`, which takes a
backtracking matcher exponential time, compiles to a 12-instruction program. It was run over one line of n `a`s
with no `b`, up to a 1 MiB line without a newline:

| n | 16,384 | 32,768 | 65,536 | 131,072 | 262,144 | 524,288 | 1,048,576 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| ms | 0.732 | 1.365 | 2.617 | 4.959 | 8.839 | 16.556 | 33.082 |
| ratio to n/2 | — | 1.86 | 1.92 | 1.90 | 1.78 | 1.87 | 2.00 |

Every match of `a*b|a`, with no offset cap, so this is what the cap prevents:

| n | 1,024 | 2,048 | 4,096 | 8,192 | 16,384 |
| --- | --- | --- | --- | --- | --- |
| ms | 6.279 | 25.199 | 95.803 | 380.682 | 1,520.746 |
| ratio to n/2 | — | 4.01 | 3.80 | 3.97 | 3.99 |

## 4. Unicode: classes, `\w`, `\b`, case

### 4.1 Classes

| Escape | Code points | Source |
| --- | --- | --- |
| `\w` | The analyser's token code points: `letter_digit_ranges` (Unicode L\*, Nd, Nl, No) ∪ `mark_ranges` (M\*) ∪ {U+200C ZWNJ, U+200D ZWJ}. **No `_`.** | `zig/src/core/unicode_tables.zig` 18 and 729; `scripts/gen_unicode_tables.py` 17–21 and 73; `analyzer_v2.zig` 1–34 and 71 (read) |
| `\d` | Unicode Nd (decimal digits: ASCII, Tamil U+0BE6–U+0BEF, and so on), from a **new** generated table `digit_ranges`. `letter_digit_ranges` cannot serve: it merges letters with Nd, Nl and No. | `gen_unicode_tables.py` 73 (read); the prototype uses ASCII `0-9` only (`scan_bench.zig` 53–56) |
| `\s` | `chunker.isWhitespace`, the 29 code points of Python's `str.isspace`. Within a line, the terminators among them never occur. | `chunker.zig` 80 (read) |
| `.` | Any code point. | |
| `\W \D \S` | The complements. | |

The tables are those of Python 3.9 / Unicode 13, as the analyser's are. The Python reference builds the same
classes from `unicodedata` under Python 3.9, so both sides share one Unicode version (*argued*; Part 2 shows it
with a test over every code point, as `scripts/ci_unicode_goldens.py` does for the analyser).

### 4.2 `\b`, `\B`, `whole_word`

- **`\b`** holds where exactly one of the code points before and after the position is in `\w`. The start and end of
  a line count as non-word. **`\B`** is the negation.
- **`whole_word: true`** wraps the program as `not_word_before (?:P) not_word_after`. The code point before the
  match must not be in `\w`, and neither may the one after it; the line's start and end count as non-word. This is
  `grep -w`'s and ripgrep's meaning, not `\bP\b`'s. With `whole_word`, `$5` matches in `cost $5 each` (`\b\$5\b`
  would not). Both sides are not-word assertions, so the VM finds the leftmost-first match that satisfies them, with
  no retry loop (*argued*).

Because `\w` follows the analyser, a scan word is a `find` token. So `\bமழை\b` finds the Tamil word whole: its vowel
signs and virama are marks, inside the word (*argued* from the tables). The price is that `_` is not a word code
point. `snake_case` holds a boundary at `_`, unlike `grep`, Python and ripgrep (open question O-1). The judged folder
has 14 lines in 5 files with `_` (*shown*: `grep -rE '_'`). The `grep` agreement test therefore leaves `\w`, `\b` and
`-w` out on those lines, or out entirely (section 11).

### 4.3 Case

- **`sensitive`:** code points compared as they are.
- **`insensitive`:** the analyser's simple fold, `casefold_pairs` (`unicode_tables.zig` 1027;
  `analyzer_v2.casefoldCodepoint` 81–91; Python `core.simple_fold`, `src/search_platform/core.py` 96–110), is applied
  to each code point of the line and to each literal code point of the pattern. Because the fold is one code point
  to one code point, offsets into the folded line are offsets into the original line.
  - A class item matches a code point `x` when some code point with the same fold as `x` is in the item. A
    negated class matches when no item does. The engine tests the at most four members of `x`'s fold orbit
    against the item; the reference adds the fold images of the item's members to the class, on the folded line.
    The two are equivalent (*argued*; Part 2 tests it over the whole table).
- **`smart` (the default):** `insensitive`, unless some code point the pattern writes changes under the fold. That
  covers every code point in literal mode, and literal code points, class members and range ends in regex mode, but
  not the letters of escapes such as `\W` or `\S`. Then it is `sensitive`. This replaces the specification's
  "upper-case letter" with a test on the table the engine already has. Title-case letters, `K` (U+212A KELVIN SIGN)
  and `ſ` (U+017F LONG S) count. The answer says which case was applied (`case_applied`).

Facts the design relies on (*shown*, `docs/evidence/s6-t24/part1/fold-facts.txt`, by `fold_facts.py`, which reads
the generated table):

- 1,386 pairs.
- Only two code points outside ASCII fold into ASCII: U+017F → `s` and U+212A → `k`.
- The largest fold orbit has 4 code points (3 such orbits).
- 33 pairs change the UTF-8 length, so the engine never folds by rewriting bytes in place.
- No Tamil code point has a fold.

**Not done, by ruling 3:**

- No full case folding (`ß` does not match `ss`).
- No mark or accent folding (`cafe` does not match `café`).
- No NFC. A precomposed `é` and `e` + U+0301 differ. The text is matched as stored: `fileBytes` returns the
  file's exact bytes, checked against its SHA-256.

## 5. The literal fast path

1. **Literal, sensitive** (or `smart` resolved to sensitive):
   - The whole file is searched for the needle's bytes with `std.mem.indexOf`. `findPos` uses
     Boyer-Moore-Horspool when the needle is over 4 bytes and the haystack at least 52, and a linear search
     otherwise (`lib/std/mem.zig` 1535–1545 of Zig 0.16.0; read).
   - A file with no occurrence is never split into lines or decoded.
   - Otherwise `source.lineStarts` numbers the lines. Each occurrence's line comes from a binary search of the
     starts, and the occurrences within that line give the offsets (non-overlapping, leftmost first, as `finditer`
     of the escaped literal).
   - A byte match of valid UTF-8 in valid UTF-8 starts and ends on code-point boundaries, and a needle without a
     terminator cannot span two lines (*argued*: UTF-8 is self-synchronising, and section 2 refuses terminators).
2. **Literal, insensitive, ASCII needle with no `s`/`S` and no `k`/`K`:** the same, with
   `std.ascii.indexOfIgnoreCase` (`lib/std/ascii.zig` 382–394). This is exact. No ASCII letter folds outside ASCII,
   and the only code points outside ASCII that fold into ASCII fold to `s` and `k` (*shown*, `fold-facts.txt`).
3. **Every other insensitive literal:** compiled to a chain of `char` instructions and run by the VM with the fold.
   It is not split into a byte search over a folded copy, because 33 pairs change the length (*measured* cost:
   `ilit_vm` in section 9).
4. **`whole_word` with a literal:** the candidates from 1 or 2, then the two neighbouring code points are checked.
5. **A regex with no special character** (`mode: "regex"`, pattern `142`) takes the literal path.

A prefilter that pulls a required literal out of a regex is **not** proposed. The plain VM meets the budget on the
corpora with a wide margin (section 9). Ruling 6 leaves out the postings prefilter. A required-literal prefilter is
a separate optimisation, which can be measured later.

## 6. One iterator for both sources

`core/scan.zig` takes a `Source`: a list of files in scan order, each with `root_id`, root-relative `path` and a
function that yields the file's bytes or the reason it has none. The scan loop, the matcher, the hits, the cursor
and the budget never know which source they read.

| | Index source | Folder source |
| --- | --- | --- |
| Files | The source section's file table (`source.Section.file`, 245; `find`, 276; `scope.Folder.sourceSection`, 775–783). Kept: the files whose root the request allows (`scope.Folder.allowedRoots`, 845–860) and which are visible to its labels. | `indexer.walkFolder` (267–296), which already applies the S6-T23 text rule and is sorted. `walkFolder` rather than `collectCandidatePaths`, because the answer reports the walk's `not_read`. |
| Bytes | `Section.fileBytes` (v1 or v2; SHA-256 checked at every call). | The read-and-caps function extracted from `applyParsed` (below): `ok`, `too_large`, `unreadable` or `binary`. |
| `root_id` | The root's id. A record path maps to its root by `scope.rootOfPath` and `relativePath` (63–80). | `r-legacy` (`scope.legacy_root_id`, 42), the id `searchd index` gives a walked folder (`indexer.zig` 420). An index of a folder and the folder itself therefore give identical hits. |
| What cannot be scanned | Pending files, skipped files (`too_large`, `unreadable`, `budget_exhausted`; `scope.Folder` 577–620) and files of a root with no retention. | `too_large` and `unreadable`, met while reading, plus the walk's `not_read` kinds. |
| Generation | The handle's generation. | None. A walk fingerprint takes its place (section 7). |

**Visibility at file level.** `ScopedService.visibleFile` (`zig/src/ops/service.zig` 472–488) decides one file by a
linear pass over every document. That is O(documents) per file, about 2 × 10⁸ comparisons for 10,000 files and
20,000 documents (*argued*). The scan builds the same answer once per call instead: a map from record path to
visibility, made in one pass over the documents and the `unchunked` entries, with the same rule (the first document
of the path decides, then an `unchunked` entry by `listedVisible`).

**Order without a sort.** A named root's record paths are `<root_id>/<path>` (`scope.recordPath`, 57–60). They are
contiguous in the byte-ordered file table, and their order within that range is the order of their relative paths.
A legacy root's paths are bare and fall anywhere. The index source therefore visits roots in `root_id` byte order.
A named root is one binary-searched range; the legacy root is one pass over the table, keeping the paths
`rootOfPath` gives to it. A `path_prefix` narrows a named root's range by a second binary search. No per-call sort
is needed (*argued*).

**The read-and-caps extraction (ruling 8).** The block at `apply.zig` 1082–1145 is entangled with `work`: each
outcome calls `work.skip`, `markCarried`, `tombstone` or `work.gone.put`, and the budget counter crosses files. The
shared function is therefore the pure part only:

`readWalkedFile(allocator, io, dir, sub_path, max_file_bytes, remaining_budget: ?u64, sniff: bool) !ReadOutcome`

`ReadOutcome` is `ok: []u8`, `too_large: u64`, `unreadable`, `binary` or `over_budget`. The function does the stat,
the size cap, the budget test, `readContent`, the re-sniff (only when `sniff` is true, which is what
`options.readable` and "not one of the 19 names" decide today) and the UTF-8 check. `applyParsed` keeps every piece
of bookkeeping and maps each outcome to the same calls in the same order. The `.file` content kind, whose sizes come
from the pre-pass at 932–965, keeps its own size source and calls the function only for the read and the checks.
That commit changes no behaviour, shown by the existing tests and the 10k byte identity (ruling 8). The scan passes
`remaining_budget = null`, because its time budget governs instead.

## 7. Results, order, paging, and the cursor across a publish

**Order:** `root_id` (bytes), then the root-relative path (bytes), then the line. It does not depend on a score, so
two runs give the same pages. This is `find`'s tie-break order, not "roots in their listed order" (section 13, item
8).

**A hit is a line.** `text` is the line without its terminator, cut to at most 512 bytes at a code-point boundary,
with `text_truncated`. Line 1 excludes a leading BOM, as `read_span` does. `match_offsets` are `[start, end)`
code-point pairs into `text`, in the shape `find` uses (`find.result.schema.json`, `match_offsets`). A match that
runs past the cut ends at the cut. `before[]` and `after[]` are up to `context_lines` lines each, as
`{line, text, text_truncated}`, cut at the file's start and end. Neighbouring hits each carry their own context, so
lines may repeat.

**`max_hits_per_file`.** After that many hit lines, the rest of the file is skipped and the file is counted in
`files_capped`. A capped file is never presented as fully listed.

**The cursor.**

- Index source: `"<generation>:<request>:<file>:<line>:<listed>"`.
- Folder source: `"f<walk>:<request>:<file>:<line>:<listed>"`.

The fields:

- `<request>` is 16 hex digits of an XXH3-64 over the canonical request, without `cursor`, `page_size` and
  `time_budget_ms`, and with the effective roots and labels.
- `<file>` is the file's ordinal in this request's scan order. *Since rework 2 (section 18):* among all the files
  the caller may see, before `path_prefix` and `name_glob`, which are tested as the scan reaches each file.
- `<line>` is the next line to search.
- `<listed>` counts the hit lines already returned from that file, for `max_hits_per_file` and `files_matched`.

Resuming costs O(1): no earlier file is read again. `find` recomputes the whole ranked list on every page instead.

**Across a publish.**

- **Index source, the same as `find`:** a cursor whose generation is not the handle's is refused with
  `invalid_argument` and the message `stale cursor` (`find.stale_cursor_message`, `find.zig` 64). The caller starts
  again from the first page.
- **Request mismatch:** a cursor whose `<request>` differs (another pattern, scope or case) is refused with
  `cursor does not belong to this request`. A malformed cursor gives `malformed cursor`, as in `find`.
- **Folder source:** there is no generation. `<walk>` is 16 hex digits of an XXH3-64 over the walk's sorted path
  list. A file added, removed or renamed between pages makes the cursor stale (`stale cursor`). An edit that keeps
  the path is **not** detected. Every hit is still a true match of the file as read for that page, but lines may
  shift between pages (open question O-4).

**Counts.** A file is counted in `files_scanned`, `bytes_scanned` and (if it had a hit on any page) `files_matched`
on the page where its scan finishes. So the sums over all pages are the totals, with no double counting from a file
cut by a page boundary. A full page stops the scan, so the last page may be empty with `next_cursor: null`.
`next_cursor` present means "more may remain".

## 8. Budget and cancel

- **The budget.** `time_budget_ms`: 1 to 30,000, default 2,000 (ruling 5). The clock is monotonic. It is checked
  between files, every 256 lines, and inside the VM every 4,096 code points. *Superseded by section 17:* the clock
  starts before the pattern is parsed and every path charges a meter; the stated bound is the budget plus 50 ms.
- **When it runs out,** the page ends at once with `stopped: "time"` and a `next_cursor` at the resume point: the
  file, line and listed count. The page may hold fewer than `page_size` hits, or none. It never holds a hit
  whose offsets are incomplete. The line being searched is searched again from its start on the next page.
- **Never complete by mistake.** `stopped: "time"` always comes with a non-null `next_cursor`, so a partial page is
  never presented as complete (ruling 5).
- **A line longer than the budget.** A line that alone takes longer than the budget makes no progress. The page then
  carries the warning `line_over_budget` with the path and line, and the caller raises `time_budget_ms` (up to
  30 s) or narrows the scope. The scan does not skip the line, because skipping would make an oracle miss a match
  silently (open question O-7). At the cap of 8,192 instructions, a 10 MiB line can need more than 30 s
  (*argued*: the 12-instruction program took 33 ms per MiB, table in section 3).
- **Cancel: there is no mechanism to reuse** (section 1). `stopped` is therefore `"none"` or `"time"`; the schema's
  enum has these two values. Adding `"cancelled"` once a cancel exists is an additive enum value. The repository has
  treated such a value as a minor step (`docs/research/2026-10-luxir-learnings.md` 360). Over MCP, a scan holds the
  server for at most its budget, as every request does today (`mcp.zig` 16–17).

## 9. Measurements

**Setup.**

- Machine: this Mac (Apple M5 Pro, Mac17,9, 48 GiB, macOS 26.6.2), awake, load average 1.4 to 2.1.
- Prototype: `scan_bench`, ReleaseSmall, built against `main`'s core at `43a308d`.
- Indexes: built by `main`'s ReleaseSmall `searchd index --filename-index`.
- Corpora: the default-argument generators, in a scratch folder outside the repository.
  - `timing-10k`: `gen_timing_corpus.py`.
  - `prose-10k`: `gen_prose_corpus.py`.
  - `tamil-10k`: `gen_tamil_timing_corpus.py`, 10,000 files.
  - The judged folder: `gen_text_search_corpus.py`.
- Every index holds every file (270, 10,000, 10,000 and 10,000 files indexed, with `not_read` 0).
- Each measure ran 7 times, interleaved. The tables give the median in ms. Minimum and maximum are in
  `docs/evidence/s6-t24/part1/bench.txt`.
- The page cache was warm: every round reads the same files.
- *Measured* throughout. These are prototype numbers, not the engine's timing (ruling 10 keeps that for Part 2).

Patterns:

- `lit`: the literal `142.50`. It is in none of the four corpora, so every file is searched to the end, the worst
  case for a literal.
- `ilit`: `orchard`, case-insensitive, ASCII fast path.
- `ilit_vm`: the same through the VM, as `[oO][rR][cC][hH][aA][rR][dD]`.
- `re1`: `\d+\.\d\d`.
- `re2`: `\w+ing\b`.

Measures:

- `index_*` reads through `Section.fileBytes` on one open handle.
- `folder_*` walks, stats, reads and checks UTF-8.
- `memory_*` runs the matcher alone, over files already in memory.

| Corpus (files, bytes) | judged (270, 141,870) | timing-10k (10,000, 7,269,199) | prose-10k (10,000, 17,244,024) | tamil-10k (10,000, 27,708,457) |
| --- | --- | --- | --- | --- |
| `folder_read` (no pattern) | 2.28 | 100.08 | 106.53 | 115.88 |
| `index_bytes` (no pattern) | 0.16 | 6.55 | 10.06 | 13.37 |
| `memory_sha256` (the check alone) | 0.05 | 2.39 | 5.62 | 9.00 |
| **`index_lit`** | **0.25** | **10.84** | **18.83** | **26.85** |
| **`folder_lit`** | **2.35** | **101.98** | **112.14** | **126.97** |
| `memory_lit` | 0.09 | 4.16 | 8.70 | 13.39 |
| `index_ilit` | 0.27 | 12.14 | 28.31 | 20.37 |
| `folder_ilit` | 2.36 | 102.72 | 122.59 | 120.16 |
| `index_ilit_vm` | 1.44 | 70.41 | 163.36 | 164.51 |
| **`index_re1`** | **1.69** | **64.23** | **146.25** | **156.52** |
| **`folder_re1`** | **3.79** | **157.84** | **246.78** | **261.96** |
| `memory_re1` | 1.52 | 57.59 | 135.65 | 142.94 |
| **`index_re2`** | **2.73** | **146.72** | **232.25** | **417.92** |
| **`folder_re2`** | **4.88** | **245.19** | **337.03** | **527.74** |
| `memory_re2` | 2.56 | 139.16 | 221.47 | 404.31 |

The first use of the source section on a handle took 0.23, 0.81, 1.15 and 0.86 ms.

Matching lines and files, the same from the index and from the folder in every case:

| Pattern | judged | timing-10k | prose-10k | tamil-10k |
| --- | --- | --- | --- | --- |
| `lit` | 0 | 0 | 0 | 0 |
| `ilit` | 0 | 0 | 746 lines / 688 files | 0 |
| `re1` | 13 / 6 | 0 | 0 | 0 |
| `re2` | 287 / 135 | 5,000 / 2,500 | 61,434 / 9,751 | 0 |

**What the numbers say:**

- A literal over 10,000 files is far inside the specification's bar of 2 s (H3, "Time"). From an index it takes at
  most 27 ms, from a folder at most 127 ms.
- The slowest regex measured, `\w+ing\b` over the Tamil corpus, takes 418 ms from an index and 528 ms from a folder.
- From a folder, the floor is the walk and the reads: about 100–116 ms for 10,000 files, whatever the pattern.
- From an index, `fileBytes` costs 6.6–13.4 ms per 10,000 files (the v2 rebuild and SHA-256), and the matcher is the
  rest.
- Non-ASCII text is the matcher's slow case. `\w` on a code point outside ASCII binary-searches two range tables:
  Tamil `re2` takes 404 ms in memory against 221 ms for prose with 1.6 times the bytes. A two-level lookup table is a
  Part 2 option, measured before it is taken (*argued*).

**Agreement with `grep`** (*shown*, `docs/evidence/s6-t24/part1/grep-check.txt`, with `/usr/bin/grep`, BSD grep
2.6.0):

- The prototype's lines for `\d+\.\d\d` on the judged folder are the 13 `path:line` pairs that
  `grep -rnE '[0-9]+\.[0-9][0-9]'` gives, identical.
- The line and file counts of `ilit` (746 / 688) and of `re2` on three corpora equal `grep -ri orchard` and
  `grep -rE '[A-Za-z0-9]+ing\b'`. These are ASCII patterns over text where grep's classes agree.

A survey of the judged folder's bytes found one CRLF file and none of the other terminators `grep` would split
differently (CR alone, VT, FF, FS/GS/RS, NEL, LS, PS) and no BOM.

## 10. The prototype: what it does and what it cannot show

**What it is.** `scripts/prototypes/s6t24/scan_bench.zig` is a standalone program; its build line is in its
header. It imports the core module only:

- to open an index as the engine does (`snapshot_open.openScoped`, `Folder.sourceSection`, `Section.fileBytes`);
- to number lines (`source.lineStarts`);
- for the Unicode tables.

**What it holds:**

- the parser and compiler for the section 2 subset (most refusals, not all: no byte offset in the message, no
  terminator or `[`-in-class check, no instruction-count message);
- the Pike VM;
- the literal and ASCII-insensitive fast paths;
- three commands: `bench`, `linear` and `lines`.

`scripts/prototypes/s6t24/fold_facts.py` prints the fold facts.

**What it cannot show:**

- **The folder pass is a floor.** It does not sniff (every 10k corpus file is `.md`; 24 judged files are outside the
  19 names and would each cost one 8 KiB head read). It applies no size cap.
- **Not modelled:** the construction of hits (text cut, offsets, context), paging, visibility, the budget checks and
  case folding in the VM (`ilit_vm` stands in for it with ASCII classes). `\d` is ASCII.
- **Cache and machine:** a cold cache was not measured, and neither was any phone.
- **Rounds are warm.** Each round reads the same files, so the medians are warm-cache numbers.

## 11. The exact-string question set

**The aim.** A second, separately frozen set (ruling 7) that says, for each question, exactly which lines `scan`
must return, and checks both directions: every expected line comes back, and no other line does. It is judged
against the existing judged folder **unchanged**: same 270 files, same `corpus_sha256`. The 181 questions, their
judgments and `fixtures/text-search/question-digests.json` are not touched. A kind the folder cannot cover gets
fewer questions; the folder is never changed for it.

**Files** (Part 2):

- `fixtures/text-search/exact-strings.json`: questions, kinds, conventions.
- `fixtures/text-search/exact-string-digests.json`: one digest per question, rendered and checked as
  `question-digests.json` is (`tests/test_text_search_score.py` 316–322, `scripts/text_search_questions.py`).
- Generator and freezer: `scripts/exact_string_questions.py`, with `--freeze`.
- Scorer: `tests/test_exact_strings.py`.

**Kinds and count:** 64 questions, 8 per kind. What the folder holds was surveyed (*shown* by `grep -rE` counts on
the scratch copy of the folder):

- ISO dates: 1,616 lines in 28 files.
- Times `h:mm`: 1,019 lines in 21 files.
- Codes `AA-123`: 93 lines in 5 files.
- Headings: 303 lines in 165 files.
- Tab-separated lines: 12 in 3 files.
- Quoted strings: 38 lines in 11 files.
- `_`: 14 lines in 5 files.
- Tamil: 31 lines in 7 files.

| Kind | What | Example shape (not the final questions) | Mode |
| --- | --- | --- | --- |
| `number` | numbers with punctuation: amounts, decimals, dates, times, phone numbers | `45.00`, `2026-06-17`, `07:45`, `01632 960418` | literal |
| `code` | codes and identifiers | `TS-017`, `INV-2026-014`, `GCB-3307`, `48213-K`, a name with `_` | literal |
| `quoted` | exact phrases with stop words and punctuation, as the user would quote them | `do not tumble dry`, `out of order`, a phrase with an apostrophe | literal |
| `line-shape` | lines of a shape | `^\d{4}-\d{2}-\d{2}`, `^#{1,3} `, `\b[A-Z]{2,4}-\d{3}\b`, a tab-separated row | regex |
| `case` | the three case options, the same pattern with different answers | `ORCHARD` vs `orchard` under `smart`, `sensitive`, `insensitive` | literal |
| `whole-word` | `whole_word` on and off | `50` inside `142.50` vs on its own; a word inside a longer word | literal |
| `tamil` | Tamil script, literal and `\w+` with marks | a Tamil word; a Tamil word with `whole_word` | both |
| `no-answer` | near misses that occur nowhere: the expected answer is empty | `142.05`, `TS-0170`, a date one day off | both |

**Expected lines are derived without the engine, twice:**

1. **By the generator.** `scripts/exact_string_questions.py` regenerates the folder in memory
   (`gen_text_search_corpus.write_corpus`, `corpus_digest` checked) and computes each question's `(path, line)` set
   itself:
   - Lines are split by `core.line_starts`, the reference's line numbering.
   - Literal questions use `str.find` over each line, with `core.simple_fold` applied to both sides when insensitive,
     and an explicit neighbour test for `whole_word`.
   - Regex questions carry, beside the scan pattern, a hand-written ASCII-only Python pattern used only by the
     generator (`[0-9]` for `\d`; `[A-Za-z0-9]` where the line has no mark and no `_`), so the expectation does not
     go through the reference's subset compiler.
   - Literal questions also record the expected `match_offsets`.
2. **By `grep`.** The scorer runs `grep -rn` (`-F` for literals, `-E` for regex, `-i` for an ASCII insensitive
   question, `-w` where its word rule equals ours on the matched lines) over a written copy of the folder, with
   `LC_ALL=C.UTF-8`. Each question records `grep: true|false`, and a reason when false: a Tamil class, `\w` next to
   `_`, the CRLF file with `$`, or `smart`, which grep does not have. At `--freeze` the generator's set must equal
   `grep`'s for every `grep: true` question, or the freeze fails.

**Acceptance:**

- For every question, `scan` returns exactly the frozen set, across all pages, over the index and over the folder.
- Literal questions also return the frozen offsets.
- The Python reference returns the same.
- The set's digest test fails on any edit made without `--freeze`.

## 12. The version step (ruling 4)

**The written rule.**

- `CONTRIBUTING.md` 144–147: "A change that adds a capability or changes a promise to callers needs its capability
  document **before** code: a new or changed field in `contracts/` (and its `CONTRACTS_VERSION`), a new or changed
  index format, a new C ABI function, or a new interface."
- The header, `zig/include/search_simpli.h` 5–7: the header "never changes shape without a corresponding bump of
  contracts/CONTRACTS_VERSION".

`scan` adds:

- a new C ABI function, `ss_scan`;
- new files in `contracts/tools/`;
- a new MCP and RPC method;
- a new command.

So the rule requires a capability document first and a `CONTRACTS_VERSION` step. **It does not say whether the
step is minor or major** (section 13, item 1). No other written text does either (*shown*: `git grep` for
minor/major/semver over the repository outside tasks, reviews and evidence finds only practice).

**The practice** (read):

- **2.0.0 was the one major.** CAP-19 recorded it as "2.0.0 (a major: new methods, new result fields; old requests
  keep working)" (`docs/requirements/cap-19-folder-knowledge.md` 70). That release also changed existing answers:
  `SnapshotStatus` counts moved to the default scope, and `query` and `evidence` took `roots` and new item fields
  (`bindings/dart/search_simpli/CHANGELOG.md` 993–1037).
- **Every step since has been minor** (header 89–169; `docs/decisions/0004-callers-generation-number.md` 174–180):
  - 2.1.0 to 2.6.0: additive fields;
  - 2.7.0: a policy change;
  - 2.8.0: warnings;
  - 2.9.0: a policy and a field, "a minor step" (`docs/requirements/cap-24-which-files-are-text.md` 72).
- **CAP-21 proposes "New method; contracts minor"** for `list_unembedded` (`cap-21-host-supplied-vectors.md` 564).
- **The Dart package took "minor: new public API"** for new methods at 0.3.0 (`CHANGELOG.md` 934).

**Applied:** a new read-only operation that changes no existing answer is additive. **Contracts 2.9.0 → 2.10.0**,
and the Dart package **0.11.0 → 0.12.0** ("minor: new public API").

The Dart package accepts exactly its own contract version (`contracts_version.dart` 10, `CHANGELOG.md` 10), so a
2.9.0 library is refused as before. Its check for required functions gains `ss_scan`. The consumer app is not
touched; it moves at its own pin bump.

**Capability document first:** **CAP-25** is the next free number; the register ends at CAP-24
(`docs/requirements/README.md` 112). Its FR and NFR numbers follow FR-36 and NFR-18 (178, 207). Its status is
"Accepted under the maintainer's direction of 22 and 23 Nov 2026; recorded for his review".

## 13. Where the rulings and the specification do not fit the code

1. **Ruling 4: the written rule does not settle the size of the step.** CONTRIBUTING requires a step and a
   capability document but does not say minor or major. The specification's H3-Q4 says "the requirements say an
   optional field is a minor step". No such sentence exists in `docs/requirements/` (*shown*: `git grep`). The note
   applies the practice (2.10.0) and records it for the maintainer.
2. **Ruling 5 and the specification ("the existing cancel mechanism"): there is none** (section 1). `stopped:
   "cancelled"` cannot happen, so the schema has `"none"` and `"time"` only (section 8).
3. **Ruling 9: a folder scan exists only on the command line and in the Python reference.** `ss_scan` takes a handle,
   which is an index. MCP and RPC serve an index. Dart `scan` is a method on an open `SearchSimpli`. The
   specification's alternative, "through `ss_index_folder`'s direct path", is not the right shape: that function
   writes an index, and a folder scan writes nothing. A folder scan over the C ABI would be a second new function
   (`ss_scan_folder(dir_path, request_json)`), which ruling 9 does not name (open question O-5).
4. **Ruling 4's premise "changes no existing response" is nearly true.** MCP `tools/list` and `searchd --help` gain
   an entry. Tests pin the list: `tests/mcp_client.py` 54 and 239 ("the eight read tools"),
   `tests/test_tool_schemas.py` 31–32 and `tests/test_example_loop.py` 216. So do `cli.zig` 190 and
   `docs/folder-knowledge-implementation.md` 804. No ranked answer, `find` page or evidence item changes, so ruling
   7 holds.
5. **Ruling 3 ("usable as an oracle") holds only within each source's coverage.**
   - The index source holds the bytes of retained files only. A host's `local` root keeps none by default
     (`apply.zig` 230–234), so a scan of such a root searches nothing and says so (`not_scanned.not_retained`,
     `truncated: true`). Absence there is not proof (FR-25).
   - The folder source cannot see an edit between pages (section 7).
6. **Ruling 8: the block is not one function today.** Only its pure part can be shared; the bookkeeping stays in
   `applyParsed` (section 6).
7. **Specification: `truncated` as a paging flag.** `find`'s schema already gives `truncated` the meaning "the corpus
   may be incomplete". `scan` keeps that meaning, and paging is `next_cursor` alone.
8. **Specification: "roots in their listed order".** `find` orders by `root_id`, and so do the file table's contiguous
   ranges. `scan` uses `root_id` byte order, independent of the order of the request's `roots`.
9. **Specification: line numbering "is `chunker.splitLines`".** `read_span` numbers by `source.lineStarts`. The two
   agree on numbers but differ on the BOM (section 1). `scan` uses `lineStarts`: it works on bytes, and its text
   matches `read_span`'s.
10. **Specification: `smart` = "an upper-case letter".** Defined instead by the fold table (section 4.3).
11. **Specification: `\w` "as the analyser defines them".** This puts `_` outside words. `grep`, Python and
    ripgrep differ (open question O-1). The `grep` agreement test must avoid those lines.
12. **Specification: "the same (file, line) set as `grep -n`".** `grep` splits lines on LF only. In a file with any
    other terminator the line numbers differ. With CRLF, a pattern ending in `$` differs, because grep's line keeps
    the CR. The judged folder has one CRLF file and no other such terminator, so the agreement test runs there and
    records the exclusions.
13. **Specification: the time bar "on the reference machine".** Part 1 measured the prototype on this Mac only.
    Ruling 10 keeps the engine's timing for Part 2's orders.

None of these makes the shape wrong: one new read-only operation, two sources, the subset, linear time, path order,
paging by a generation-bound cursor, a time budget. They change field meanings, names and coverage, which the
schemas below already carry.

## 14. Open questions

- **O-1.** `\w` without `_` (the analyser's words, so a scan word is a `find` token) or with it (`grep`, Python,
  ripgrep)? The note proposes without, as the specification says.
- **O-2.** `\d` as Unicode Nd (a new generated table, consistent with `\w`) or as ASCII `0-9`? The note proposes Nd.
- **O-3.** The version: 2.10.0 (minor), by practice (section 12).
- **O-4.** A folder cursor that sees edits as well as adds and removes. This would need a stat of every file on
  every page, a cost not measured.
- **O-5.** `ss_scan_folder` for Dart and the app, or the folder scan on the command line only (this task, as ruled)?
- **O-6.** The command-line shape. Proposed: `searchd scan <dir> "<pattern>"` over an index and
  `searchd scan --folder <folder> "<pattern>"` over a folder. Telling the two apart by the presence of `MANIFEST`
  is fragile.
- **O-7.** A line that alone outlasts the budget: refuse to skip it (proposed), or skip it with a warning and the
  path?
- **O-8.** Escapes `\t`, `\n` (useless per line) and `\xHH`: refused now; `\t` would help tab-separated rows.
- **O-9.** Cancel: a later capability (an `ss_cancel` with a token, MCP `notifications/cancelled` served by a reader
  thread), not this task.

## 15. The schemas

### 15.1 Request (`contracts/tools/scan.request.schema.json`)

| Field | Type and range | Default | Notes |
| --- | --- | --- | --- |
| `pattern` | string, 1–1,024 bytes (UTF-8) | required | JSON Schema counts code points: the schema says `maxLength: 1024` and the engine checks bytes |
| `mode` | `"literal"` \| `"regex"` | `"literal"` | |
| `case` | `"sensitive"` \| `"insensitive"` \| `"smart"` | `"smart"` | |
| `whole_word` | boolean | `false` | |
| `roots` | array of 1–64 non-empty strings, or null | null (every root the caller allows) | as `find` (`ops.zig` 59, 161–170) |
| `path_prefix` | string or null | null | a byte prefix of the root-relative path, as `find` (`find.zig` 279–286) |
| `name_glob` | string, 1–255 bytes, no `/`, or null | null | matched against the last path component. `*` is any run of code points, `?` one code point, every other code point itself. No classes. Case-sensitive. |
| `context_lines` | integer 0–20 | 0 | `source.max_context_lines` (45) |
| `max_hits_per_file` | integer 1–1,000 | 50 | |
| `page_size` | integer 1–100 | 20 | as `find` |
| `cursor` | string or null | null | section 7 |
| `time_budget_ms` | integer 1–30,000 | 2,000 | ruling 5 |

As in `find`, an unknown field is refused (`Reader.only`, `ops.zig` 96–104) and `principal_labels` is accepted only
from a trusted caller (`scopeOf` 161–170). Like `find`'s schema, the tool schema does not list `principal_labels`.
Messages follow `find`'s form: `page_size must be 1..100`, `context_lines must be 0..20`,
`max_hits_per_file must be 1..1000`, `time_budget_ms must be 1..30000`,
`mode must be literal or regex`, `case must be sensitive, insensitive or smart`,
`name_glob must be 1..255 bytes with no /`.

### 15.2 Result (`contracts/tools/scan.result.schema.json`)

```json
{
  "request": {"pattern": "142.50", "mode": "literal", "case": "smart", "whole_word": false, "roots": null,
              "path_prefix": null, "name_glob": null, "context_lines": 0, "max_hits_per_file": 50,
              "page_size": 20, "cursor": null, "time_budget_ms": 2000},
  "source": "index",
  "generation": 7,
  "scope": {"roots": ["r-legacy"], "labels_applied": true},
  "warnings": [],
  "case_applied": "insensitive",
  "hits": [
    {"root_id": "r-legacy", "path": "home/money/house-costs-2026.csv", "line": 4,
     "text": "2026-03-02,electricity,142.50", "text_truncated": false,
     "match_offsets": [[23, 29]], "before": [], "after": []}
  ],
  "files_matched": 1,
  "files_scanned": 270,
  "files_capped": 0,
  "bytes_scanned": 141870,
  "pending_files": 0,
  "not_scanned": {"too_large": 0, "unreadable": 0, "budget_exhausted": 0, "not_retained": 0},
  "not_read": null,
  "truncated": false,
  "stopped": "none",
  "next_cursor": null
}
```

(The hit is invented for the shape; that line is not in the judged folder.)

| Field | Meaning |
| --- | --- |
| `request` | The request echoed with defaults filled in, as `find` does (`ops.zig` 279–310). |
| `source` | `"index"` or `"folder"`. |
| `generation` | The index generation; `null` for a folder. |
| `scope`, `warnings` | As `find` (`writeCommon`, `ops.zig` 248–272). For a folder, `scope.roots` is `["r-legacy"]`. Warning codes: `pattern_matches_empty`, `line_over_budget`. |
| `case_applied` | `"sensitive"` or `"insensitive"`: what `smart` resolved to. |
| `hits[]` | `root_id`, `path` (root-relative), `line` (1-based), `text` (at most 512 bytes), `text_truncated`, `matches_truncated` (section 18), `match_offsets` (`[start, end)` code points into `text`, non-empty matches only, at most those starting within `text`), `before[]` and `after[]` (`{line, text, text_truncated}`). |
| `files_matched`, `files_scanned`, `files_capped`, `bytes_scanned` | Counted on the page where a file's scan finishes; the sums over pages are the totals (section 7). |
| `pending_files` | As `find`: files in scope still waiting for their bytes (index only; 0 for a folder). |
| `not_scanned` | Files in scope that `scan` could not search, by reason. Index: scope-wide, the same on every page (the manifest's skipped list and the files of roots without retention). Folder: counted on the page that reached the file. |
| `not_read` | Folder only: the walk's FR-35 counts by kind (`bad_name`, `binary`, `image`, …), scope-wide; `null` for an index. These do not set `truncated`, as decision 0005 ruled for photos and the like. |
| `truncated` | "The corpus may be incomplete": `pending_files` > 0 or any `not_scanned` count > 0. `find`'s meaning, not paging. |
| `stopped` | `"none"` or `"time"`. With `"time"`, `next_cursor` is never null. |
| `next_cursor` | The cursor for the next page; null when the scan reached the end of the last file. |

Refusals (`invalid_argument` unless stated):

- the field errors in 15.1;
- the pattern errors in section 2;
- `stale cursor`, `malformed cursor`, `cursor does not belong to this request`;
- `capacity` "re-index required: source section unavailable (…)" or the absent-source message, as `read_span` does
  (`service.sourceUnavailable`, 583–586);
- over a folder, a missing or non-directory path is a usage error, as `searchd search` (`cli.zig` usage).

## 16. Part 2: what would change, file by file, and the tests

Commits in this order:

1. The read-and-caps extraction alone (ruling 8).
2. CAP-25 and the register, before any code.
3. Core.
4. Operations, interfaces, contracts and the version.
5. Dart and the Python reference.
6. The exact-string set.
7. Natives, rebuilt and restamped, with sizes in bytes against `main` (ruling 10).

Then the timing orders are prepared and pushed, and the work stops before any timing is taken.

| File | Change |
| --- | --- |
| `zig/src/core/apply.zig` | `readWalkedFile` and `ReadOutcome` (section 6); `applyParsed` calls it; no behaviour change. |
| `docs/requirements/cap-25-pattern-search.md`, `docs/requirements/README.md` | CAP-25; FR-37 onwards (the operation, the subset, the two sources, the cursor, the budget) and NFR-19 onwards (linear time, no allocation per line, one file in memory, answers byte-identical). |
| `zig/src/core/pattern.zig` (new) | Parser, compiler, Pike VM, fold, classes, literal fast paths; refusal messages as section 2. |
| `zig/src/core/scan.zig` (new) | `Source`, the index and folder sources, ordering, visibility map, hits, cursor, budget, counts. |
| `zig/src/core/unicode_tables.zig`, `scripts/gen_unicode_tables.py` | `digit_ranges` (Nd); if O-2 goes the other way, nothing. |
| `zig/src/core/core.zig` | `api.scan`: request, result, entry. |
| `zig/src/ops/ops.zig` | `scan_fields`, `parseScan`, `ops.scan`, JSON writer. |
| `zig/src/ops/service.zig` | `ScopedService.scan`: resolves the scope and builds the index source. |
| `zig/src/interfaces/cli.zig` | `searchd scan` (index and `--folder`); flags `--regex`, `--case`, `--word`, `--roots`, `--path-prefix`, `--glob`, `--context`, `--max-per-file`, `--page-size`, `--cursor`, `--time-ms`, `--max-file-bytes` (folder), `--json`. Plain output `path:line:text`. Usage text; "the eight read tools" becomes nine. |
| `zig/src/interfaces/abi.zig`, `zig/include/search_simpli.h` | `ss_scan(handle, request_json)` beside `ss_find` (`abi.zig` 439–443; header 680–696). Header paragraph "Contract 2.10.0". |
| `zig/src/interfaces/rpc.zig` | `scan` beside `find` (207). |
| `zig/src/interfaces/mcp.zig` | The `scan` tool, read-only hints (96–104, 292–296, 373); not in `--baseline`. |
| `zig/build.zig` | `"scan"` in `tool_names` (117). |
| `contracts/tools/scan.request.schema.json`, `scan.result.schema.json` | Section 15. |
| `contracts/CONTRACTS_VERSION` | 2.10.0. |
| `bindings/dart/search_simpli/` | `scan(...)`, `ScanRequest`, `ScanResult`, `ScanHit`, `ScanContextLine`, `ScanStopped`; `contracts_version.dart` 2.10.0; the `ss_scan` presence check; regenerated bindings; `CHANGELOG.md` 0.12.0; `pubspec.yaml`. |
| `src/search_platform/scan.py` (new), `folders.py`, `tool_server.py` | The reference: the subset parser (same refusals), translation to `re` with explicit classes, folding, `scan(index, …)` over `source_files` (`core._source_bytes`, 668–678) and `scan_folder(root, …)` over the reference walk. |
| `scripts/check_layers.py`, `docs/layers.md` | `core/pattern.zig`, `core/scan.zig` in `FILES` (beside `core/find.zig`, 119). |
| `scripts/exact_string_questions.py` (new), `fixtures/text-search/exact-strings.json`, `exact-string-digests.json` | Section 11. |
| `docs/mcp-server.md`, `docs/folder-knowledge-implementation.md`, `skills/folder-knowledge/` | Tool lists; whether the skill's loop gains `scan` is Part 2's call (`tests/test_example_loop.py` reads the schemas directory, 63). |
| `native/` | Rebuilt and restamped (ruling 10). |

**Tests:**

- **`pattern.zig` unit tests.**
  - A table of every accepted construct and every refusal, with its exact message and byte offset.
  - Matches with expected offsets: empty matches, `finditer` adjacency, anchors, classes, negated classes under
    the fold, `ſ`/`K`, Tamil with marks, `whole_word`, smart-case resolution.
  - A 1 MiB line without a newline. Invalid UTF-8 in the text: U+FFFD and no read out of bounds.
  - The program cap: `(a{255}){255}` is refused.
  - **Linear time:** `(a+)+b` over 2^16 and 2^20 `a`s, with the ratio of times at most 32 for 16 times the length.
    The test checks a ratio, not an absolute time.
- **`scan.zig` unit tests,** over a fake source:
  - every hit exactly once across pages, for every page size from 1 to 7;
  - `max_hits_per_file` across a page boundary; context at the file's edges;
  - the 512-byte cut on a code-point boundary, with offsets clipped;
  - the BOM and CRLF lines;
  - cursors: stale across a publish, refused on another request, malformed;
  - an injected clock forces `stopped: "time"` mid-file and mid-line, and resuming loses and repeats nothing;
  - `line_over_budget`;
  - order with a legacy root and named roots in one table;
  - a hidden file never appears and is not counted.
- **Workspace:** a 64 MiB arena cap over a 10 MiB file (NFR-13's test form).
- **Operations and interfaces:** each field's range message; an unknown field; the CLI (plain and `--json`), RPC and
  MCP (`tools/list` lists nine read tools); the C ABI through the Python gateway; the schemas (`test_tool_schemas.py`).
- **Python, `tests/test_scan.py`.**
  - The reference against the engine (`searchd scan --folder --json`) on a seeded generated folder, with random
    subset patterns and lines (ASCII, Tamil, marks, fold specials), comparing hits and offsets.
  - `grep` agreement on the judged folder (section 11).
  - An index of a folder and the folder itself give identical pages.
- **Exact-string set:** `tests/test_exact_strings.py`, with acceptance and digests (section 11).
- **Unchanged answers (ruling 7):**
  - `scripts/capture_query_outputs.py` and `scripts/capture_find_pages.py` on the three 10k corpora, byte-identical
    against `main`, after the extraction commit and again at the end;
  - `tests/test_text_search_score.py` unchanged and passing.
- **Dart:** `scan` over a fixture index; the contract pin test at 2.10.0.
- **Repository checks:** `check_requirements.py` (CAP-25), `check_layers.py`, `check_no_home_paths.py`,
  `check_test_counts.py`.

## 17. After the Verdict (rework 1, 23 Nov 2026)

The verifier's Verdict on Part 2 found the promise "a scan holds the caller for at most its budget" broken on four
paths, and the orchestrator ruled (recorded in `docs/tasks/S6-T24.md`, "Ruling after the Verdict"). What changed,
in the engine (`pattern.zig`, `scan.zig`, `source_v2.zig`) and the reference (`scan.py`) alike:

- **Compiling is bounded by work, not by output.** The compiler counts every node it expands, emitting or not;
  over 8,192 it refuses with `the pattern is too large (over 8,192 steps)`. A repeat whose body can only match
  the empty string is kept at most once (`{0,1}` or `{1}`), so nested empty repeats cost nothing. The budget's
  clock starts before the pattern is parsed.
- **Every path is metered.** The VM charges one unit a thread step, the literal search and the line reader one a
  byte; the clock is read once 65,536 units have built up. The literal search is Knuth-Morris-Pratt over each
  line (the standard library's `findPos` and `findIgnoreCasePos` grew with the needle on the verifier's input:
  `scripts/prototypes/s6t24/rework1/literal_search.zig`).
- **Listing matches is linear.** In regex mode at most 16 matches a line are looked for; a 17th that starts
  within `text` cuts `text` where it starts. No field was added: `text_truncated` already says the text is
  shorter than the line.
- **No per-line table.** `scan.zig` reads a file one line at a time and keeps a ring of `2 × context + 1` line
  positions; `source_v2.rebuildChecked` reads a file kept whole straight into its one buffer.
- **The first line of a page gets 10 ms of grace**, and the `capacity` refusal says whether the budget went on
  the line or on reading before it.
- **The stated bound:** budget plus 50 ms, the folder walk and the read of the file in hand excepted
  (`docs/scan.md`, "Time" and "Memory").

## 18. After Verdict 2 (rework 2, 24 Nov 2026)

Verdict 2 found two costs outside the meter's reach and two lows; the orchestrator ruled (`docs/tasks/S6-T24.md`,
"Rulings after Verdict 2"). What changed, in the engine and the reference alike:

- **The scope filter is inside the budget** (ruling 1). `path_prefix` and `name_glob` are tested on each file's
  path as the scan reaches it, one unit a byte, so a page can stop on time among names that do not match and
  resume through them. The cursor's `<file>` is therefore an ordinal among all the files the caller may see. A
  glob match is linear: the glob's items (at most 255; a run of `*` is one) are the states of an automaton held as
  one 256-bit set, and each unit of the name moves all of them at once (shift-and), so a name costs one step a
  byte whatever the glob (`scan.Glob`). Outside the budget, stated: the folder walk, and over an index the list
  of files the caller may see, whose pending and skipped files are tested against the scope there (linear).
- **A unit of the meter is bounded work** (ruling 2). A class is normalised when compiled (its ranges sorted and
  merged; `\w`, `\d`, `\s` each kept once), so a test is at most five binary searches; a step on a class over a
  code point outside ASCII charges one unit per search it may do (`Class.cost`, at most 6); a position charges one
  more unit when it folds and two when the program tests word boundaries, and the word test is done once per code
  point instead of once per assertion followed. The folds a class adds are found per range, not over the whole
  table. Test builds count the elementary steps behind the units (`pattern.work`); the tests hold them to at most
  12 a unit and 139,268 units between two reads of the clock.
- **No wall-clock threshold in a default test** (ruling 3). The meter-interval and compile-time tests count work;
  the times are measured by `scripts/prototypes/s6t24/rework2/meter_bench.zig` and `bound_probe.py`.
- **`matches_truncated`** (ruling 4). A hit says when its text was cut at the 17th non-empty match, apart from the
  512-byte cut. Empty matches neither count towards the 16 nor cut the text.

