# Searching a folder directly (`searchd search`)

Status: Diagnostic · implemented (S6-T2, [CAP-20](requirements/cap-20-direct-folder-search.md),
FR-26, NFR-15). Code: `zig/src/cli.zig` (`runSearchFolder`, `buildAndOpen`),
`zig/src/indexer.zig` (`buildFolderDetached`), `zig/src/apply.zig`
(`buildDetached`), `zig/src/snapshot_open.zig` (`openDetached`,
`openScopedDetached`). Tests: `zig/src/direct_search_test.zig`,
`tests/test_direct_search.py`.

## What it is

```sh
searchd search <folder> "<query>" [--top-k N] [--json] [--evidence]
               [--search-field content|filename|both]
               [--max-file-bytes N] [--max-total-bytes N]
```

One command answers a query over a folder. There is no index directory: the
folder is walked and read by `index`'s rules (the same 19 extensions, the same
ignored directories and dotfiles, analyzer v2, the default chunker, the same
byte caps), the index is built in memory, the query is answered, and the
process exits. Nothing is written anywhere: not in the folder, not beside it,
not in the working directory, not in the temporary directory.

The answer is byte for byte what you would get from

```sh
searchd index <folder> --out X --filename-index
searchd query X "<query>"            # or: query X --json, with --json
searchd evidence X "<query>"         # with --evidence
```

with the same `--top-k` and `--search-field`. Because the in-memory build is
generation 1, as a fresh `index` is, even the `index.generation` field in the
`filename`/`both` JSON is the same; there is no field that differs.

- `--json` prints `query --json`'s envelope; `--evidence` prints `evidence`'s
  answer, which is always JSON; `--evidence --json` is accepted and prints the
  same.
- The file-name channel is always built, as `--filename-index` builds it, so
  `--search-field filename` and `both` work on any folder.
- Files left out by the caps or because they cannot be read are counted on one
  stderr line, `searchd: search: N files not searched (too_large=… unreadable=…
  budget_exhausted=…)`, only when there are any; stdout is unaffected.
- A missing folder, a path that is not a folder, an empty (or whitespace-only)
  query, an unknown flag or a bad value is a usage error: exit 2, one stderr
  line, nothing on stdout. Any other failure (for example a folder you may not
  read) is exit 1. A flag given twice takes its last value, as for `query`.
- **The one difference from `query`:** `query <index> ""` (or a query of only
  white space) is accepted there, exit 0, a header line and no results; `search`
  refuses it as a usage error (exit 2), since it would read and build the whole
  folder to match nothing.
- An empty folder, or one with no supported file, answers with no results and
  exit 0, exactly as an empty index does.

## How it works

`index` builds a generation in memory (`apply.buildGeneration`) and then
publishes it: the writer lease, the section files, the manifest and the
current-generation pointer. `search` stops before the lease and keeps the
encoded sections in memory (`apply.buildDetached`); the open path then takes
the sections from memory instead of reading files
(`snapshot_open.openDetached` for `content`, `openScopedDetached` for
`filename` and `both`, the same two opens `query` uses). A test compares the
in-memory sections with the files `index` writes, byte for byte, so the
checksums and versions are the ones a published index carries and the open
path checks them the same way. No temporary directory is used.

## When to use it, and when to build an index

Every `search` reads and builds the whole folder again; `query` on an index
reads only what it needs. The measured crossover is below.

Measured on 16 Nov 2026 on macOS arm64 (18 cores), `searchd` built
`ReleaseSmall`, with `scripts/direct_search_crossover.py`: five runs of each
way, in turn, after the folder's files were read once (a warm file cache for
all three); the median and, in brackets, the range. Wall time includes
starting the process. The folders are the generated timing corpus
(`scripts/gen_timing_corpus.py`, invented text with a 24,000-word vocabulary,
query `hybrid retrieval`) and one folder of invented ordinary prose (2,000
Markdown notes from an everyday vocabulary, written by the same script's
`--prose`, query `garden lantern`). The 5-minute load average before and
after each folder is given. The Mac was in a maintenance wake with no user
active and slept between short wakes; a folder whose runs a sleep interrupted
was run again (the JSON gives each folder's wall-clock bounds, checked against
`pmset -g log`). Single runs taken earlier while the Mac was in use agreed
(1,000 files 80 ms, 5,000 files 330 ms). The results are in
[`docs/evidence/s6-t2/`](evidence/s6-t2/).

`--search-field content`:

| Folder | Files | Bytes | Load (5 min) | `search` ms | `index`+`query` ms | `query` ms | `search` MiB | `index`+`query` MiB | `query` MiB |
| --- | ---: | ---: | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| t100 | 100 | 254,275 | 3.93 → 3.93 | 29.9 (29.8–30.0) | 36.0 (35.4–36.2) | 5.3 (5.2–5.5) | 11.7 | 10.9 | 5.4 |
| t1000 | 1,000 | 916,353 | 3.93 → 3.93 | 83.0 (78.4–84.0) | 86.7 (86.3–87.0) | 7.3 (7.2–7.7) | 23.6 | 20.8 | 8.4 |
| t2000 | 2,000 | 1,614,179 | 3.93 → 3.93 | 142.9 (137.6–144.3) | 145.9 (144.1–148.7) | 9.6 (9.5–9.9) | 37.7 | 33.5 | 11.9 |
| t5000 | 5,000 | 3,720,228 | 3.66 → 3.62 | 321.6 (308.3–323.9) | 320.0 (318.1–325.4) | 16.3 (15.9–16.8) | 78.8 | 70.1 | 22.4 |
| t10000 | 10,000 | 7,269,199 | 3.90 → 3.88 | 624.0 (604.7–698.4) | 621.3 (610.3–672.4) | 27.4 (27.0–28.1) | 149.0 | 133.2 | 40.2 |
| t20000 | 20,000 | 14,418,886 | 3.88 → 3.77 | 1248.2 (1198.5–1309.7) | 1238.5 (1219.4–1240.8) | 49.5 (47.5–50.5) | 287.1 | 256.7 | 75.8 |
| prose | 2,000 | 3,362,012 | 3.62 → 3.58 | 248.2 (240.7–249.0) | 253.4 (252.6–255.8) | 12.9 (12.6–13.3) | 62.1 | 56.1 | 18.1 |

The same over the timing corpus with `--search-field both` (no prose row):

| Folder | Files | Bytes | Load (5 min) | `search` ms | `index`+`query` ms | `query` ms | `search` MiB | `index`+`query` MiB | `query` MiB |
| --- | ---: | ---: | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| t100 | 100 | 254,275 | 3.55 → 3.55 | 31.9 (29.6–34.7) | 38.3 (37.5–41.1) | 5.7 (5.2–6.2) | 11.5 | 10.9 | 5.2 |
| t1000 | 1,000 | 916,353 | 3.55 → 3.55 | 82.8 (82.4–85.1) | 90.8 (87.2–92.0) | 6.8 (6.7–7.0) | 23.5 | 20.8 | 8.2 |
| t2000 | 2,000 | 1,614,179 | 3.55 → 3.55 | 142.2 (140.2–142.8) | 148.5 (144.4–151.8) | 8.2 (8.2–8.3) | 37.6 | 33.4 | 11.7 |
| t5000 | 5,000 | 3,720,228 | 3.55 → 3.59 | 320.7 (304.3–323.7) | 316.6 (314.2–325.0) | 13.1 (12.8–13.5) | 78.6 | 70.1 | 22.3 |
| t10000 | 10,000 | 7,269,199 | 3.59 → 3.57 | 619.0 (594.3–639.8) | 611.4 (605.4–646.9) | 20.9 (20.5–21.5) | 148.9 | 133.2 | 40.0 |
| t20000 | 20,000 | 14,418,886 | 3.57 → 3.58 | 1230.3 (1183.3–1260.8) | 1210.2 (1205.9–1217.5) | 35.6 (35.0–36.1) | 287.0 | 256.7 | 75.7 |

What the numbers say:

- **Within 100 ms:** up to about **1,000 files / 0.9 MB of text** (83 ms,
  peak memory 24 MiB; 2,000 files / 1.6 MB take 143 ms).
- **Within 1 s:** up to about **10,000 files / 7.3 MB** (624 ms, peak memory
  **149 MiB**; 20,000 files / 14.4 MB take 1.25 s and 287 MiB; by linear
  interpolation the line is near 16,000 files or 11–12 MB). The time grows
  about linearly with the folder: roughly 60 ms per 1,000 files of this corpus.
- **Rerun by the verifier** (same Mac, its own `ReleaseSmall` build and timing
  script, five interleaved runs, 5-minute load 3.74 → 3.70): 1,000 files
  79.5 ms (78.1–81.1), 23.6 MiB; 10,000 files 599.3 ms (591.5–602.2),
  149.0 MiB ([S6-T2 Verdict](tasks/S6-T2.md#verdict-verifier-fills-in)).
- **Cost per byte depends on the text.** The prose folder (2,000 files,
  3.4 MB) took 248 ms, less than the 5,000-file corpus folder of similar size
  (3.7 MB, 322 ms); it has fewer, longer files and a far smaller vocabulary,
  which is the likely reason (not measured separately).
- **One `search` costs the same as `index` plus one `query`**: within 5 % from
  1,000 files up (at 100 files `search` is faster, 30 against 36 ms). Writing
  the index is a small part of building it. So for a single question a direct
  search costs no more than indexing first, and **from the second question on
  an index wins**: a `query` on an existing
  index is 5–50 ms at these sizes, about 20 times less than a `search` at
  5,000 files and 25 times less at 20,000.
- **Memory:** a `search` peaks 7–13 % above `index` (about 15 MiB per 1,000
  files of this corpus: 149 MiB at 10,000 files, 287 MiB at 20,000); it holds
  the built sections and the opened engine in one process.

**So:** use `search` for a one-off question over a folder of up to a few
thousand files; build an index (`searchd index <folder> --out X`, then `query
X`, refreshed with `apply`) for a larger folder, or for any folder you will ask
more than one question of. These numbers are from one machine; a phone or an
older laptop will be slower.

## Compared with an indexed query

| | `search <folder>` | `index` once, then `query <index>` |
| --- | --- | --- |
| Answers | the same bytes (tested on every J2 query, every field and form) | the same bytes |
| Freshness | always the folder as it is now | as of the last `index` or `apply` |
| Disk | nothing written | an index directory, about 4.4 times the corpus on the timing corpus (objective plan) |
| Time and memory per query | the whole build, every time (table above) | the build once; then a whole `query` process is tens of milliseconds |
| Other commands | `search` only | `find`, `outline`, `read-span`, `list-files`, `serve`, `mcp`, the C ABI and the Dart binding |

## Limits

- No caching: two `search` calls on the same folder do the whole work twice.
- One root, no labels, no authorization scope: the folder is searched as
  `index <folder>` indexes it.
- Lexical only, as a folder indexed by `searchd` is.
