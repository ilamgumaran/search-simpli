# ADR 0005 · Which files are text: read a file when its bytes are text

**Status:** design note of [S6-T23](../tasks/S6-T23.md), Part 1, written from `main` at `8ffc41c` before any code
(22 Nov 2026). Plan step [H2](../plans/2026-11-16-objective-plan.md#h-text-search-done-well-the-priority-of-22-nov-2026):
"take all the text in first". Line numbers are `main`'s at `8ffc41c`. Each claim says how it is known: *read* (from
the code), *shown* (a run, with its evidence file in [`docs/evidence/s6-t23/part1/`](../evidence/s6-t23/part1/)),
*measured* (a timed run) or *argued*. No file under `zig/src/`, `contracts/`, `zig/include/` or `bindings/` is
changed; the prototype is in [`scripts/prototypes/s6t23/`](../../scripts/prototypes/s6t23/) and is described in
[section 9](#9-the-prototype-what-it-does-and-what-it-cannot-show).

**The recommendation in one paragraph.** A walked file is read when its bytes are text. The extension does two things
only: a short list of known non-text kinds (images, audio, video, archives, office documents and PDF, fonts, programs,
databases) is skipped without opening the file, and `.md`/`.markdown` choose the Markdown chunker as today. Every
other file, with any extension or none, is sniffed: its first 8,192 bytes must hold no NUL, at most 1 % control
bytes, no UTF-16 byte order mark, and be valid UTF-8. Dot-files and the six ignored directories stay out. A name
holding a carriage return or line feed is skipped (today such a name breaks the whole index). The size cap stays
10 MiB, whole files only. Files not read are counted by kind in a new report field, without paths. On the judged
set this reads all 270 files instead of 246 and raises complete answers from 100 / 109 to 109 / 127 (`both`, typed /
query) and from 110 / 118 to 120 / 137 (`content`); it also makes some readable-now questions worse, by ranking and
by envelope size ([section 7](#7-the-judged-set-before-and-after)). It is a contract change (2.9.0, additive: a
policy, one report field, one manifest meta key), so the note stops here for the orchestrator.

## 1. Where the 19 extensions are decided, where the list is used, and what happens to other files

**The one decision point in the engine** (read): `zig/src/core/indexer.zig`

| Line | What |
| --- | --- |
| 38–42 | `default_extensions`: `.c .cpp .css .go .h .html .java .js .json .md .py .rs .rst .toml .ts .txt .yaml .yml .zig`, commented as `search_platform.core.DEFAULT_EXTENSIONS` |
| 44–47 | `ignored_directories`: `.git .search .zig-cache __pycache__ node_modules zig-out` |
| 64–75 | `hasAllowedExtension`: the last `.` suffix, lowercased; a name with no `.` is refused (line 65), and so is a suffix longer than 16 bytes (line 68) |
| 77–91 | `isIgnoredComponent` / `isIgnoredPath`: any path component starting with `.`, or one of the six |
| 101–115 | `collectCandidatePaths`: the walk (`root.walk`), regular files only, ignored paths out (107), then the extension test (108), sorted bytewise |

**Every use** (read):

| Surface | Path to the list | Where |
| --- | --- | --- |
| `searchd index` (full rebuild) | `cli.runIndex` → `indexer.indexFolder` → `walkAndApply` → `walkBatch` → `collectCandidatePaths` | `cli.zig:856`, `indexer.zig:171`, `185`, `213–214` |
| `searchd index --update` | `indexer.indexFolderIncremental` → the same `walkAndApply` | `cli.zig:795`, `indexer.zig:398` |
| `searchd search` (direct, [docs](../direct-search.md)) | `cli.buildAndOpen` → `indexer.buildFolderDetached` → `walkBatch` | `cli.zig:1048`, `indexer.zig:249` |
| `ss_index_folder` (C ABI) and so the Dart `SearchSimpli.indexFolder` | `abi.zig` → `indexFolderIncremental` / `indexFolder` | `abi.zig:806`, `854`; `bindings/dart/.../contracts.dart:957` (report only, no list) |
| file-name channel and title field | built from the generation's documents (`apply.zig:3063`, `filename_field.group` at `filename_field.zig:105`), so only files that were read have a name entry; the text is the file's stem (`filename_field.zig:63`, `132`) | — |
| `apply_changes` (host-fed, `ss_apply_changes`) | **no list**: any path the host names is read; invalid UTF-8 is rejected `invalid_utf8` (`apply.zig:1122–1123`) | — |
| the importer (`ss_import_json`, `searchd import`) | no list: it takes the documents the exporter wrote (`importer.zig:22`); the Python export walks with Python's list | — |
| chunker choice | `chunker.kindForPath`, `.md`/`.markdown` → `md-section-v1`, else `line-window-v1` (`chunker.zig:263–270`), called at `apply.zig:1136`; it already handles `.markdown`, which the walk never yields | — |
| MCP resource type | `text/markdown` for `.md`/`.markdown` (`mcp.zig:644`) | — |
| Python reference | `DEFAULT_EXTENSIONS`, `IGNORED_DIRECTORIES` (`src/search_platform/core.py:42–70`), used by `_iter_text_files` (`core.py:232–238`), which `build_index` (`core.py:701`), `folders.folder_changes` (`folders.py:758–763`) and `scripts/gen_chunk_golden.py:34` walk with | — |
| judged set | `READABLE_EXTENSIONS` (`scripts/text_search_questions.py:76–79`), the fixed `readable_now` list; `tests/test_text_search_score.py:592–598` checks the engine's unread files equal the files outside it | — |
| documents | [`direct-search.md`](../direct-search.md) line 19 ("the same 19 extensions"), [`incremental-indexing.md`](../incremental-indexing.md) line 31, [`text-search-score.md`](../text-search-score.md) line 187, [S3-T1](../tasks/S3-T1.md) ruling 2 (`.markdown` left out of the walk on purpose "because adding it would change the indexed file set of every folder") | — |

**What happens today to a file outside the list: nothing, silently.** It is not a candidate, so it is not read, not
counted in any report field (`too_large`, `unreadable` and `budget_exhausted` count candidates only, `apply.zig`
1065–1112), not on the `search` stderr line (`cli.zig:1085`), not in `list-files`, not in the manifest's `skipped`
list (read). Shown: in the edge folder ([`edge.txt`](../evidence/s6-t23/part1/edge.txt)) 35 files are walked and
`index` reports `files_indexed=4 too_large=0 unreadable=2`; the other 29 are mentioned nowhere. The usage scenarios
found the same (I02, I10 in [scenarios](../testing/scenarios-engine-2026-11-22.md)).

**Plain-text kinds a folder holds, and today's rule** (read from the list):

| Family | Read today | Not read today |
| --- | --- | --- |
| notes, prose | `.md` `.txt` `.rst` | `.markdown` `.text` `.org` `.adoc` `.tex` |
| data | `.json` `.yaml` `.yml` `.toml` | `.csv` `.tsv` `.jsonl` `.ndjson` `.xml` `.ini` `.cfg` `.conf` `.properties` |
| markup | `.html` | `.htm` `.xhtml` |
| source | `.c` `.cpp` `.h` `.go` `.java` `.js` `.ts` `.py` `.rs` `.zig` `.css` | `.sh` `.bash` `.zsh` `.rb` `.php` `.swift` `.kt` `.m` `.lua` `.pl` `.r` `.sql` `.scala` `.cs` `.hpp` `.cc` `.jsx` `.tsx` `.vue` `.dart` |
| logs | — | `.log` `.out` |
| exports | — | `.ics` `.vcf` `.eml` `.mbox` `.srt` `.vtt` `.ipynb` |
| no extension | — | `README` `TODO` `NOTES` `Makefile` `Dockerfile` `LICENSE` |

## 2. The rule, `text-sniff-v1` (confirmed, with three corrections)

The proposed rule is confirmed: **a file is read when its bytes are text**, the extension used only to skip known
binary kinds cheaply and to choose the chunker. Corrections: (a) dot-files and ignored directories stay out (b, below);
(b) a name that cannot be a record path is skipped first; (c) SVG and RTF are on the skip list although their bytes
are text (they are an image and a word-processor document; "other formats come after text").

**The rule, in order**, for every regular file the walk keeps (no component starting with `.`, none of the six
ignored directories, as today):

1. **The name.** A relative path holding `\r` or `\n`, or not valid UTF-8, is not read: kind `bad_name`. (Why this is
   needed: [section 10](#10-what-makes-the-tasks-shape-wrong), finding 1.)
2. **A known non-text extension** (lowercased last suffix) is not opened: kind `image` (png jpg jpeg gif bmp tif tiff
   webp heic heif ico icns psd svg avif raw cr2 nef dng), `audio` (mp3 m4a aac wav flac ogg opus aif aiff mid midi),
   `video` (mp4 m4v mov avi mkv webm wmv mpg mpeg), `archive` (zip gz tgz bz2 xz zst 7z rar tar dmg iso pkg jar),
   `document` (pdf doc docx xls xlsx ppt pptx odt ods odp pages numbers key rtf epub), `font` (ttf otf woff woff2),
   `program` (exe dll so dylib o a class pyc wasm bin), `database` (sqlite sqlite3 db). The list is
   `textsniff.py`'s `DENY_KINDS`.
3. **The sniff**, on the first 8,192 bytes (the whole file when smaller; 8,000 is git's figure, a page is 4,096):
   - an empty file is text;
   - a UTF-16 or UTF-32 byte order mark (`FF FE`, `FE FF`, `00 00 FE FF`) is text in another encoding: not read,
     counted as `unreadable` (see 4);
   - a NUL byte is `binary`;
   - more than 1 % control bytes (0x01–0x08, 0x0E–0x1A, 0x1C–0x1F, 0x7F; TAB, LF, VT, FF, CR and ESC are allowed,
     ESC for coloured logs) is `binary`;
   - after an optional UTF-8 byte order mark, the head must be valid UTF-8; a sequence cut by the 8,192nd byte is
     allowed when the file is longer. Invalid is not-UTF-8 text: counted as `unreadable`;
   - otherwise text.
4. **A text file is then read whole by today's code**, unchanged: over `max_file_bytes` (10 MiB) it is `too_large`,
   invalid UTF-8 anywhere is `unreadable` (`apply.zig:1086`, `1110`). Both keep their paths in the report and the
   manifest's `skipped` list as today.

**How it is placed** (argued): for a name today's list already reads, the bytes are read whole as today and only
the NUL and control checks are new, on the head of a buffer already in memory (the whole-file UTF-8 check at
`apply.zig:1110` covers the third). For any other name the walk reads the head first (one open), then the whole file
if it is text; or, below a small size (say 64 KiB), the whole file at once, so most small files are opened once.

**Its cost** (measured, [`sniff-bench-*.txt`](../evidence/s6-t23/part1/), `sniff_bench.zig`, ReleaseSmall, warm
cache, median of 11 or 21 rounds):

| Folder | Files | NUL + control on the head, in memory | the same with the UTF-8 step | head read (stat, open, read 8 KiB, close) + sniff | today's whole read + UTF-8 check |
| --- | ---: | ---: | ---: | ---: | ---: |
| judged | 270 | 133 ns/file | 156 ns | 7.9 µs | 7.5 µs |
| timing-10k | 10,000 | 206 ns (2.1 ms in all) | 233 ns | 9.7 µs | 9.2 µs |
| prose-10k | 10,000 | 421 ns (4.2 ms) | 475 ns | 10.5 µs | 9.8 µs |
| tamil-10k | 10,000 | 683 ns (6.8 ms) | 2,119 ns | 11.9 µs | 10.9 µs |

So a file read whole anyway costs under 0.7 µs more; a file that must be looked into first costs about one more
open, 8 to 12 µs, which is the whole cost of a binary file under the rule and about doubles the read of a small text
file of an unknown name.

**What it does with each case** (shown by [`edge.txt`](../evidence/s6-t23/part1/edge.txt), an invented folder of 35
files, `edge.py`; the Zig and Python sniffs give the same verdicts there, `sniff-bench-edge.txt`):

| Case | Verdict | Then |
| --- | --- | --- |
| empty file (`empty.note`) | text | indexed with no chunk, as an empty `.md` is today (`unchunked` in the manifest) |
| very large text (`huge.log`, 13.9 MB) | text | `too_large`, path listed (`--update`, ABI); a larger `--max-file-bytes` reads it |
| text with one bad byte at 15,000 (`one-bad-byte.txt`) | text (head) | `unreadable`, path listed, as today |
| Latin-1 text (`latin1-note.txt`) | not UTF-8 | `unreadable`, as today for `.txt` |
| UTF-16 export with a BOM (`utf16-export.tsv`) | UTF-16 | `unreadable`; not decoded in H2 |
| a NUL after 8 KiB (`nul-late.txt`) | text | read, and the NUL is in the passage, as today for any known extension (a limit of a head sniff) |
| PDF (`%PDF-1.7` header, compressed stream) | `document` by name; `binary` by content without the extension | not read |
| JPEG with EXIF text | `image` by name; `binary` without the extension | not read |
| zip, SQLite, Mach-O header with no extension | `archive` / `database` by name; `binary` by content | not read |
| 2 % control bytes, no NUL (`controls`) | binary | not read |
| minified one-line file (`app.min.js`, 295 KB, read today) | text | one chunk: a query returns a **294,805-byte passage** (the line window never splits a line, `chunker.zig:16–33`) |
| lock file (`package-lock.json`, 301 KB, read today) | text | read, as today |
| coloured log (ESC bytes), UTF-8 BOM | text | read |
| dot-file, file in a dot-folder, file in `node_modules` | not walked | no result for their words, as today |
| `README`, `Makefile`, `.org`, `.ini`, `.srt`, `.ics`, `.vcf`, `.eml`, `.text`, `.markdown` | text | read (`.markdown` with the Markdown chunker) |
| `Icon\r` (macOS custom-icon file) | `bad_name` | not read |

**Dot-files stay out** (recommendation). Reason: they are where secrets and machine state live (`.env`, `.netrc`,
`.npmrc`, `.ssh/`, `.git/`, `.Trash/`, `.DS_Store`), and a person searching their notes does not expect them. They
are not counted either: counting would mean walking `.git` and caches for numbers no one reads. (Read, a side
note: today's walk already descends into ignored and dot directories and drops their entries one by one,
`indexer.zig:103–108`; `std.Io.Dir.Walker.leave` would skip them. Not needed for H2.)

## 3. Limits a person would expect

- **Size: keep the 10 MiB cap, skip the whole file, report it** (recommendation). A text file over `max_file_bytes`
  is `too_large`, with its path in the `--update` and ABI reports and in the manifest's `skipped` list, as today
  (`apply.zig:1086`); `--max-file-bytes` / `max_file_bytes` raise it. Reason for not reading a part: an index that
  holds the first 10 MiB of a log answers as if it had searched the file, and the incremental hash, `read_span` and
  the stale-copy rules all assume whole files. Shown: `huge.log` is `too_large=1` under the rule.
- **Text that is rarely wanted: none excluded by content in H2** (recommendation). Lock files and minified bundles
  are text and are read today as `.json` and `.js`; excluding them would drop files from today's indexes. The cost
  they carry is the chunker's, not the walk's: a one-line file comes back whole (shown above), which is H5's
  (a line-window chunker that splits a line over `max_chars` is a new chunker identity). The only text kinds not
  read are SVG and RTF, by the skip list.
- **How a caller includes a skipped kind: through `apply_changes`**, which reads any path it is given (read: no list
  in `apply.zig`). No new request option in H2 (recommendation; it would be a request field and a second rule to
  keep).

## 4. What the caller is told

**A new report field `not_read`: counts of files the rule does not read, by kind, no paths** (recommendation).
Kinds: the eight name kinds, `binary`, `bad_name`; only non-zero kinds appear, keys sorted, `{}` when none. Text that
could not be read stays where it is today, with its paths: `too_large`, `unreadable` (now also UTF-16 and
not-UTF-8 text of any name).

| Interface | Today | Proposed |
| --- | --- | --- |
| `searchd index` line (`cli.zig:874`) | `files_indexed too_large unreadable budget_exhausted …`, no paths | add ` not_read=N` (the total) |
| `searchd index --update` JSON (`cli.zig:805–848`) | counts and `too_large_paths`, `unreadable_paths` | add `"not_read": {"binary": 1, "image": 2}` |
| `ss_index_folder` JSON (`abi.zig:806–880`), Dart `IndexFolderReport` (`contracts.dart:957`) | the same fields | the same object; Dart `notRead`, `{}` when the field is absent (an older library) |
| `searchd search` stderr (`cli.zig:1085`) | `N files not searched (too_large=… unreadable=… budget_exhausted=…)` when N > 0 | add `not_read=M` to the line and to N; printed when any is non-zero, so it now appears for most real folders |
| manifest `skipped`, `index_status` `truncated`, `list-files` | — | **unchanged**: not-read files are not "given but could not index in full"; a photo must not make every scope `truncated` |

**Is it a contract change?** Yes: an additive result field on `ss_index_folder` and `index --update`, and the policy
of which files a walk reads. That is a minor step, **contract 2.9.0**, in the form of 2.7.0 ("changes one policy,
with no request field … no signature or index format change", `search_simpli.h:145`), plus the one field. No request
field, no signature, no JSON schema under `contracts/tools/` (`apply_changes` is untouched).

## 5. Tables and structured text read as plain lines

Measured with the prototype (`--search-field both` / `content`, typed / query; [`compare.md`](../evidence/s6-t23/part1/compare.md)):

| Kind | complete before → after, `both` | `content` | complete within 4,096 bytes, `content` |
| --- | --- | --- | --- |
| `table` (10) | 6 → 7 / 6 → **10** | 6 → 7 / 6 → **10** | 4 → 6 / 5 → 7 |
| `where-is-it` (10) | 3 → 4 / 3 → **8** | 3 → 4 / 3 → **8** | 1 / 1 → 3 |

**What plain lines give.** Every CSV and TSV of the judged folder is under 1,600 characters (the largest, the loans
file, 988 bytes, 44 lines), so one window holds the whole table: the header line and the row come back together,
and the four table questions missed before (all in a CSV or TSV) are complete with the query words. The loans and
budget spreadsheets, the shell script, the June log and the XML sitemap are found by their words (where-01, 02, 03,
06, 07). where-04 ("website stylesheet") and where-09 ("to-do list": the words are not `TODO`) still miss, and with
the typed questions most table and where-is-it questions still miss (7 of 10 and 4 of 10 complete).

**What they do not give** (left to H4 and H5; no table parsing here):

- **A row with its header in a larger table.** In a 600-row CSV, a row query returns lines 270–305 (1,574 bytes)
  and not line 1, so the column names are gone (shown: `edge.txt`, `tilecutter300`).
- **A row cited alone.** A row comes back inside its window; the judged share stays low.
- **Repetitive logs crowd the answer.** The 12 server logs repeat the same line shapes (`INFO request GET …`,
  `reminder run`); with the query words and `content`, 10 questions lose "complete within 4,096 bytes", for
  example `content-06` ("server.yaml") from 979 to 15,365 bytes, because ten log windows now match `server`. No
  de-duplication of near-identical lines or files exists.
- **Sums, ranges, a log's dates, a JSON or YAML key path.** None.
- **Typed questions about the folder's files.** The 4-line `toolshare/README` ("the data files are in data/") now
  ranks first for 12 typed questions whose answer it is not ("Which files are about …", "What is in …"): a short
  file holding the question's common words. That is the common-word weakness the scenarios found (finding 2), H6's.

## 6. An existing index

- **More files at the next update, no rebuild** (shown, [`update-probe.txt`](../evidence/s6-t23/part1/update-probe.txt)):
  an index of the judged folder under today's rule, updated from the renamed copy, reports `added 24, unchanged 246,
  removed 0`, 454 documents, the fresh index's count. Read: `--update` walks and hashes every candidate
  (`indexer.zig:398`, [incremental-indexing](../incremental-indexing.md) line 31), so a new candidate is `added`.
  A file of a known extension that the sniff now calls binary leaves the walk and is `removed` at that update
  (`complete_root`, `indexer.zig:238`); the repository's fixtures hold none (shown: `textsniff.py survey` on every
  `fixtures/` folder reads every file today and calls each text).
- **The identity: a manifest meta key** (recommendation): `"readable":{"id":"text-sniff-v1","head_bytes":8192,
  "control_share_max":0.01}`, written by every walk-built generation, beside `chunkers`
  ([manifest v2](../manifest-format-v2.md)). Absent means the 19-extension list (call it `ext19-v1`). Read: older
  readers ignore unknown meta keys (`manifest.zig:957`, `ignore_unknown_fields = true`), so no header, flag or
  version changes; the format note gains a minor section (2.7). No read path needs it for correctness (an update
  re-walks everything); it lets `inspect`, a test or a host tell which rule built an index. Its consequence, argued:
  an older engine updating a newer index drops the newly read files again (`removed`), and the newer one adds them
  back; two engine versions sharing one index directory would alternate.
- **An app that pins the engine** (argued; the app repository was not opened):
  - if it indexes folders through `ss_index_folder`, it gets the rule with its next pin; the first update after
    the pin reports every newly readable file as `added` and reads them (cost: section 8); it may show `notRead`;
  - if it feeds `ss_apply_changes` with its own file list, nothing changes until the app widens that list: the
    engine reads whatever it is given. The app would apply the same rule itself (or a later step exposes the
    sniff);
  - its tests that pin a folder's file set change where the folder holds files outside the 19.

## 7. The judged set before and after

Before: `main`'s `searchd` (sha256 `5ad3de31…`, the same binary for `87bfd35` and `8ffc41c`), the S6-T22 baseline
[`baseline-rework-2.json`](../evidence/s6-t22/baseline-rework-2.json) (a rerun at `8ffc41c` is byte-identical apart
from its label). After: the same binary through the prototype,
[`prototype.json`](../evidence/s6-t23/part1/prototype.json) / [`prototype.md`](../evidence/s6-t23/part1/prototype.md);
both by the unchanged scorer. Direct search and the index agree byte for byte on all 181 questions in every
configuration, before and after. The `readable_now` list is unchanged. Cells are typed / query.

| `both` | n | file@1 | file@10 | passage@10 | complete | within 4,096 B | evidence bytes, median | judged share | stale first |
| --- | ---: | --- | --- | --- | --- | --- | --- | --- | --- |
| total | 169 | 94 → 97 / 116 → 130 | 132 → 138 / 135 → 155 | 120 → 129 / 123 → 144 | **100 → 109 / 109 → 127** | 9 → 10 / 36 → 36 | 11,814 → 12,042 / 9,475 → 10,553 | 0.065 → 0.070 / 0.148 → 0.152 | 10 / 5 (of 22), unchanged |
| readable now | 146 | 94 → **90** / 115 → 115 | 131 → **129** / 133 → 133 | 119 → 120 / 121 → 122 | 100 → 102 / 109 → **108** | 9 → 9 / 36 → **32** | 11,769 → 11,829 / 8,566 → 10,473 | 0.075 → 0.078 / 0.164 → **0.162** | 10 / 5 |
| without single-source | 116 | 62 → 60 / 80 → 87 | 90 → 91 / 92 → 103 | 78 → 82 / 82 → 93 | 68 → 72 / 75 → 85 | 8 → 8 / 25 → 24 |  11,774 → 11,876 / 8,574 → 10,616 | 0.071 → 0.075 / 0.175 → 0.174 | 9 / 5 |

| `content` | n | file@1 | file@10 | passage@10 | complete | within 4,096 B | evidence bytes, median | judged share | stale first |
| --- | ---: | --- | --- | --- | --- | --- | --- | --- | --- |
| total | 169 | 94 → 97 / 116 → 130 | 130 → 138 / 134 → 154 | 123 → 132 / 125 → 145 | **110 → 120 / 118 → 137** | 91 → 94 / 100 → 102 | 3,482 → 3,582 / 2,809 → 2,944 | 0.069 → 0.070 / 0.145 → 0.148 | 9 → **10** / 5 |
| readable now | 146 | 94 → **90** / 115 → 115 | 129 / 132, unchanged | 122 → 123 / 123 | 110 → 113 / 118 → 118 | 91 → **90** / 100 → **91** | 3,404 → 3,478 / 2,719 → 2,914 | 0.080 → **0.078** / 0.161 → **0.158** | 9 → **10** / 5 |
| without single-source | 116 | 62 → 60 / 80 → 87 | 89 → 91 / 91 → 102 | 82 → 85 / 82 → 93 | 76 → 79 / 78 → 89 | 65 / 67 → 68 |  3,404 → 3,496 / 2,695 → 2,774 | 0.076 → 0.075 / 0.165 → 0.166 | 8 → 9 / 5 |

Not read: 31 → 0 questions name an unread file. No-answer: 11 / 8 return something, unchanged. Per kind
(`compare.md`): with the query words and `content`, `word` 12 → 15, `number` 10 → 12, `table` 6 → 10, `where-is-it`
3 → 8, `file-content` 8 → 11, `filename` 11 → 12, `phrase` 11 → 12 complete; typed, `about` file@1 falls 8 → 4.

**Questions that get worse** (every one, `compare.md`, "Questions that got worse"; direct and index agree):

- **complete lost (3):** `name-09` typed (`both`, `content`; the AGM notes fall from rank 8 out of the ten),
  `content-01` typed (`both`; `inventory.yaml` from rank 10 out), `about-08` query (`both`; `inbox/NOTES` takes a
  slot and the bathroom passage returned is another one);
- **stale copy now first (1):** `cur-04` typed (`content`): the committee file falls from rank 10 out, the 2025 copy
  at rank 6 stays;
- **file ranked later:** typed, 17 with `both` and 15 with `content`, mostly `about` and `file-content`, by the
  README (section 5); with the query words, 4 (`number-12`, `span-11`, `about-09`, `syn-09`), each by one rank;
- **complete within 4,096 bytes lost:** `content`, query 10, typed 5; `both`, query 4, typed 1 (`spell-10`, whose
  second file `loans-2026.csv` now comes back and is needed);
- **judged share lower by more than 0.005:** 20 to 32 per configuration; more files match, so more non-answer text
  fills the ten results.

**Where the changes come from.** The chunks of the 246 files read before are the same (argued: same bytes, names,
order and chunker; [section 9](#9-the-prototype-what-it-does-and-what-it-cannot-show)). Their *ranking* is not:
the new text changes BM25's document count, document frequencies and average length, so old passages score
differently. Shown ([`order-check.txt`](../evidence/s6-t23/part1/order-check.txt), `order_check.py`, `--top-k 10`,
the 181 questions): with the query words, 87 result lists are unchanged, 42 (`both`) and 37 (`content`) change only
by newly read files being inserted, and 52 and 57 also reorder or replace old passages; typed, 31 or 32 are
unchanged and about 140 reorder. So a later rank is partly the new files taking places and partly the shifted
statistics.

**Where the gains come from.** Of the 23 questions not readable now, 19 are complete with the query words and 7
typed (either field). The four still incomplete: `pair-06` and `about-11` find one of their parts, `about-09` needs
eight files, `where-09` ("to-do list") does not reach `TODO`. With the typed form, four readable-now questions become
complete through the shifted ranking (`spell-04` or `span-04`, `pair-03`, `syn-03`, `cur-05`).

## 8. Index size and time

Measured ([`index-cost.json`](../evidence/s6-t23/part1/index-cost.json), `index_cost.py`): main's ReleaseSmall
`searchd`, seven interleaved rounds, wall time of the process, warm cache, 5-minute load 2.6 to 3.2, 22 Nov 21:35.
"After" for the judged folder is the renamed copy; for the 10k corpora the rule changes no file (all 30,000 are
`.md` and text: [`survey-10k.txt`](../evidence/s6-t23/part1/survey-10k.txt)), so the index is byte-identical
(argued: same files, same bytes, same code path) and the time grows by the sniff alone (section 2's in-memory NUL
and control check, measured).

| Folder | Files read | Index bytes before → after | `index` ms, median (range) | after | `search … --search-field both` ms | after |
| --- | --- | --- | --- | --- | --- | --- |
| judged | 246 → 270 (text 92,956 → 141,870 B, +53 %) | 213,525 → 303,016 (+89,491, +41.9 %) | 15.6 (15.2–17.2) | 18.2 (17.4–19.1), +2.6 ms | 12.3 (11.8–12.9) | 15.9 (15.5–16.7) |
| timing-10k | 10,000 → 10,000 | 13,712,980, unchanged | 604.7 (592.3–639.5) | + 2.1 ms (+0.34 %) | 589.7 | + 2.1 ms |
| prose-10k | 10,000 → 10,000 | 30,815,993, unchanged | 1,246.5 (1,239.8–1,326.0) | + 4.2 ms (+0.34 %) | 1,244.1 | + 4.2 ms |
| tamil-10k | 10,000 → 10,000 | 34,633,368, unchanged | 1,509.2 (1,486.5–1,581.5) | + 6.8 ms (+0.45 %) | 1,499.6 | + 6.8 ms |

On the judged folder the growth is the newly read text: documents +53,322 B, lexical +31,655 B (the logs' timestamps
and numbers), the file-name sections +1,537 B, source +2,113 B, state +864 B. The head reads of the 24 newly
considered names would add about 24 × 8 µs ≈ 0.2 ms if each were opened twice (section 2).

**Which timing rule applies** (read, as ADR 0003 section 7 read it): the rule of 2026-11-17
([ROLES](../process/ROLES.md), "Rule added 2026-11-17") compares the head with `main`, `main2` and a placement
control matching the head's compiled-code delta, "for every request, changed path or not": five gated runs in
Latin-square orders written first, every open, query and find cell of the three 10k corpora. The change is on the
walk only (no open, query or find source changes), and on the 10k corpora the indexes are byte-identical, so a cell
can differ only by code placement; the rule still applies as written. Index and direct-search time are not cells of
that rule; they are reported here and should be remeasured on the built engine in Part 2.

## 9. The prototype: what it does and what it cannot show

**What it does.** [`textsniff.py`](../../scripts/prototypes/s6t23/textsniff.py) is the rule in Python (`survey`
classifies every walked file; `rename` writes a copy). The copy gives every file the sniff calls text, and that
today's list skips, a name today's engine reads: its last extension replaced by `.txt` (or `.txt` appended; a
`.markdown` would become `.md`), checked to collide with nothing, to keep the bytewise order of all paths, and to
occur in no file's text. [`searchd_renamed.py`](../../scripts/prototypes/s6t23/searchd_renamed.py) is handed to the
**unchanged** scorer as `--searchd`: it writes the copy on the first `index` or `search`, runs main's `searchd` on
it, and replaces every new path in stdout by the real one, so the scorer checks the real corpus digest, reads real
paths and counts the real paths' bytes. On the judged folder the 24 names become `.txt` with the stem, folder and
order unchanged ([`rename-map.json`](../evidence/s6-t23/part1/rename-map.json)). So the file-name channel and the
title field see the same text (`filename_field.zig:63`, the stem), the chunker is `line-window-v1` as the rule
gives a CSV or a log, document indexes and path tie-breaks are the same, and the scoring is the real engine's.

**Why this and not a patched engine.** It changes no engine source and runs the scorer as it is; a patched copy of
`zig/src` would measure the same files through the same code, plus the sniff's cost, which `sniff_bench.zig`
measures on its own (standalone, `std` only).

**What it cannot show:**

- the sniff's cost inside the engine's walk (measured apart, section 2), nor the cost of two opens per new file;
- chunk ids: they hash the path, so a tie between two chunks of one renamed file could order differently (argued;
  no such tie was looked for);
- the report field, the stderr line and the manifest key (not built);
- files the rule would skip: the judged folder has none (`survey-judged.json`: 270 text); the edge folder shows the
  verdicts and today's engine on the renamed copy, not the built rule;
- `bad_name` handling: the copy keeps `Icon\r` unread; what the built rule does with it is a design, shown only to be
  needed (section 10).

**How to rerun** (from the worktree, `<scratch>` a `.noindex` folder):

```sh
(cd zig && zig build -Doptimize=ReleaseSmall --prefix <scratch>/prefix-main)
S6T23_SEARCHD=<scratch>/prefix-main/bin/searchd python3 -I scripts/text_search_score.py \
    --searchd "$PWD/scripts/prototypes/s6t23/searchd_renamed.py" --scratch <scratch>/after/run \
    --out-json prototype.json --out-md prototype.md --engine-label "…"
python3 -I scripts/prototypes/s6t23/compare.py docs/evidence/s6-t22/baseline-rework-2.json prototype.json
python3 -I scripts/prototypes/s6t23/edge.py <scratch>/prefix-main/bin/searchd <scratch>/edge
zig build-exe -OReleaseSmall scripts/prototypes/s6t23/sniff_bench.zig -femit-bin=<scratch>/sniff_bench
<scratch>/sniff_bench <folder> 11
python3 -I scripts/prototypes/s6t23/index_cost.py <scratch>/prefix-main/bin/searchd <scratch>/cost 7 judged-before=… judged-after=…
S6T23_SEARCHD=… python3 -I scripts/prototypes/s6t23/order_check.py <searchd> "$PWD/scripts/prototypes/s6t23/searchd_renamed.py" \
    <before index> <scratch>/after/run/index docs/evidence/s6-t22/baseline-rework-2.json
```

Two scorer runs of the prototype gave the same JSON apart from the `engine` field (the builder's run;
`prototype.json` is the second), and a rerun of the baseline at `8ffc41c` equals `baseline-rework-2.json` apart from
its label.

## 10. What makes the task's shape wrong

1. **A name with a carriage return breaks every index today, and the rule would meet such names in ordinary
   folders.** Shown (`edge.txt`): with `a\r.md` in a folder, `searchd index` and `searchd search` both fail,
   `error: InvalidPath`, exit 1, even with `--search-field content`; the walk does not validate names and the
   source section refuses them (`source.zig:504`; `apply.validRelativePath` at `apply.zig:195` guards host requests
   only). macOS writes `Icon\r` into any folder given a custom icon. Today it has no extension and is never a
   candidate (shown: a folder with `Icon\r` searches fine); under a sniff it would be one. So the walk's name check
   (rule step 1) is a prerequisite of H2, not a refinement, and it also fixes today's failure for a known extension.
2. **H2 alone is not a pure gain.** It completes 9 / 18 more questions with `both` and 10 / 19 with `content`, but on
   the 146 readable-now questions typed file@1 falls 94 → 90, `content` complete-within-budget falls 100 → 91 with the
   query words, and three questions lose their answer from the ten (section 7). The causes are not the walk's: a
   short README holding common question words, repetitive logs, BM25 statistics that any added text shifts, and the
   ten-result cut. An acceptance line such as
   "no readable-now question gets worse" cannot be met by H2; H5 (passages, de-duplication) and H6 (common words)
   are where those are fixed.
3. **One test pins today's unread set.** `tests/test_text_search_score.py:592–598` asserts the engine's unread files
   are exactly those outside `READABLE_EXTENSIONS`. Part 2 must change that assertion (to: nothing unread on this
   folder), which is not a change of the judged set; `readable_now` and the questions stay frozen. Other tests Part 2
   changes: `indexer.zig:487–498` (`noext` refused), `zig/src/tests/direct_search_test.zig:49` (`README` with no
   extension expected unread), `tests/test_direct_search.py:159–160` (the exact stderr line, on a folder holding
   `picture.png`). The `.png` and `.pdf` files with text bytes in `tests/test_direct_search.py:37` and
   `tests/test_filename_cli.py:286` stay unread under the rule, by the skip list.
4. **The Python reference is part of the change.** Its walk (`core.py:232`) mirrors the engine's candidate set on
   purpose; the rule goes there too, or the two engines read different files. The chunk goldens do not move: every
   repository fixture folder is read in full today (shown, survey).
5. **The task says 264 files; the folder has 270** (rework 2 of S6-T22). The 24 unread are as stated.
