# Title field v1 (`title-field-v1`)

Status: shipped by [S5-T2](tasks/S5-T2.md), contracts 2.3.0. The Python
reference (`src/search_platform/core.py`) and the Zig engine
(`zig/src/title_field.zig`) implement the same field; a golden generated from
the reference (`scripts/gen_title_golden.py`,
`fixtures/title-field-golden.json`) holds them equal to f32 tolerance.

## Why

A question that names a file or a folder ("the swimming lessons for autumn
term") was lost in the body: before S5-T2, J2's title-intent slice had no
answer at rank 1 under `content`, and `both` (RRF of the body and the file-name
stem) recovered most of them but cost three control answers. The title field
adds what the path says to the lexical channel, so a file whose name and
folders hold the query's words ranks by them, without a second channel to fuse.

## The field

For each file (each distinct record path with at least one body chunk):

- **The relative path.** The part after the file's root
  (`scope.rootOfPath`, `scope.relativePath`). A legacy `r-legacy` path, or a
  path under no root, is taken whole. **The root id is never a word**: the
  app's root ids are opaque, and on J2 the root `school` cost a title row.
- **The folders.** Every component but the last.
- **The stem.** The last component without its final `.ext`, where a name
  whose only dot is its first character keeps the whole name (Python's
  `Path.stem`): `notes.v2.md` gives `notes.v2`, `.bashrc` gives `.bashrc`.
  This is not the file-name channel's stem, which gives `""` for a dot-first
  name (a 03-next row; the extension filter keeps such files out today).
- **The tokens.** The folders, then the stem, each tokenized with analyzer-v2
  (NFC, variation selectors dropped, simple case fold). `swimming-lessons/
  autumn-term.md` gives `swimming lessons autumn term`. Repeats count:
  `garden/garden/garden-diary.md` holds `garden` three times.

## The score

For a query q and a file f, over the files the request can see:

- Q is the set of q's distinct analyzer-v2 tokens.
- BM25 with the engine's parameters (k1 1.2, b 0.75), its N, average length
  and each document frequency counted over the **visible files**: roots and
  labels narrow them, a path prefix does not (as the body's statistics,
  S3-T3).
- coverage(f) = |{t ∈ Q : t in f's title}| / |Q|.
- **title(f) = w · BM25_title(f, Q) · coverage(f), with w = 2.5.** The weight
  was chosen on J2's title slice and confirmed, not re-tuned, on the held-out
  slice `title-heldout` (success@1 1.000 on both surfaces against a bar of
  0.667).

Coverage keeps a one-word name match from outranking a full body answer
(without it, J2's control row `c02` loses rank 1).

Since S5-T4 the title terms are also in [fold-groups-v1](fold-groups-v1.md)'s
key map, so a word that only a file's name holds joins its other forms' group,
scored here as a fuzzy-v1 group is (each file its best member, counted once in
coverage). Since S5-T5 ([fold-groups-v2](fold-groups-v2.md)) a visible file's
title term can also join as a query word's `-ing` or `-ed` form.

## Where the part goes

- **`content`** (the default), with a lexical channel (`lexical` or `hybrid`
  mode): the part is added to the file's best in-scope body chunk (the higher
  BM25, an exact tie to the smaller chunk id), or, when no chunk of the file
  matches the body, to its first chunk (smallest start line, end line, id).
  The sum is ranked; `candidate_k` cuts after it. `ranking.lexical.score` is
  body plus part, and the chunk that received it carries `ranking.title`
  `{score}`.
- **`both`**: a score-level merge, one result per file: the file's best body
  chunk's BM25 plus its part (the first chunk for a title-only file), ordered
  by score, then path, then chunk id, cut to `top_k`. `candidate_k` is
  validated but cuts no channel before the sum; `ranking.lexical.rank` and
  `ranking.filename.rank` are positions within each channel's first
  `candidate_k`, and every result carries `ranking.title` (`null` when the
  file's title took no part). Where no title field is supplied (an engine
  opened without its folder) `both` keeps S4-T2's RRF.
- **`filename`** is unchanged. **`vector`** mode has no lexical channel and
  no part.

`retrieval.title_policy_id` is `"title-field-v1"` whenever the lexical
channel ran with the field under `content` or `both`.

## The derive, and why there is no section

The field is **derived** from the opened generation's documents and roots at
the first `content` or `both` query on a handle (`scope.Folder.titleField`),
once per opened generation, under the folder's load lock, and never at
`ss_open`. Its tables live in one exact block (10k-file timing corpus:
691,584 B kept; the derive's working arrays peak at 1,541,164 B and are all
released before it returns; 2,153,560 B above the live bytes at its peak,
block included). A first content query after a cold open costs about 3.2 ms
more at 10k and 4.6 ms at 20k (`ReleaseSmall`, S5-T2's Report); later queries
reuse it.

Nothing is written: no manifest flag, no section, no writer change. Every
index a 0.3.x library wrote opens unchanged and gets the field by the derive
(`compat_292cb568_test.zig`), and a reader before 2.3.0 is not refused a
generation. A written section was weighed and rejected (ruling 1 of S5-T2):
a flag bit would stop the app from ever downgrading, every writer and the
S4-T13 carry would change, and older generations would still need the derive;
all to save a few milliseconds once per opened generation. It is filed in
03-next "only if a phone measurement shows the derive matters".

**The grouping.** When the documents come in path order (every generation
`buildGeneration` writes) one pass groups them by file, and the content path
streams per file; otherwise a fallback groups by path and the content path
drains its matches first. Both give the same results (a test drives both).

## Known residuals

- **Stop words in names.** `the`, `and`, `of` count as title words: J2's
  negative `on2` ("painting the fence") now tops `pets/biscuit-the-dog.md`.
  Left to S5-T3 (03-next).
- **Half-covered names.** A file whose name holds one of two query words gets
  half its BM25 (`p06` 1 → 2 under `content`). Left to S5-T3 (03-next).
- **The root's display label** (the app's Shared-folder name) is not a word;
  a 03-next row asks for a J2 row first.
- **`FolderIndex.search`** (the Python folder lifecycle runner) keeps the
  ranking before S5-T2; `core.search` is the reference (03-next).
