# Misspelling tolerance v1 (`fuzzy-v1`)

Status: shipped by [S5-T3](tasks/S5-T3.md), contracts 2.4.0. The Python
reference (`src/search_platform/core.py`) and the Zig engine
(`zig/src/fuzzy.zig`) implement the same rule; a golden generated from the
reference (`scripts/gen_fuzzy_golden.py`, `fixtures/fuzzy-golden.json`) holds
them equal: the expansions exactly, the scores to f32 tolerance.

## Why

A child types `dinosuar`, `tournamnet`, `choclate`. Before S5-T3 such a word
matched nothing, and J2's misspelling slice had one answer at rank 1 in
sixteen (`content` success@1 0.062). The word is looked for in the index's own
dictionary instead, at query time: no index format, writer or analyzer
changes, and a query whose words are all found ranks exactly as before.

## When a word is expanded

A query term (analyzer-v2: NFC, simple case fold) is expanded only when all
four hold, checked cheapest first:

1. **Length.** At least 5 code points.
2. **Script.** Every code point is a digit or a Latin letter: 0-9, a-z,
   U+00DF-00FF except U+00F7, U+0100-024F, U+1E00-1EFF. Tamil, mixed-script
   and other words are never expanded: their edits change meaning in ways an
   edit distance does not measure.
3. **No chunk in scope holds it.** Roots, labels and the path prefix: a word
   held only outside the prefix, or only in chunks the caller cannot see, is
   unmatched for this request and may be expanded.
4. **No visible file's name holds it.** The title field's words
   ([title-field-v1](title-field-v1.md)) of the files the caller can see
   (roots and labels; the prefix does not narrow this guard): a word that
   names a file is not a misspelling.

Only analyzer-v2 indexes expand; an `ascii-alnum-v1` index never does. The
`filename` field is never expanded. Since S5-T4 a word that has a
[fold-groups-v1](fold-groups-v1.md) group (other forms of it that the files
hold) is searched as that group and is not expanded, so J2's `boxes` (below)
now searches `box`, not `bones`. Since S5-T5 ([fold-groups-v2](fold-groups-v2.md))
that includes a word no file holds whose `-ing` or `-ed` forms the files hold:
`painting` searches `paint` and `painted`, not `planting`.

## The candidates

- **The distance.** Optimal string alignment (insertions, deletions,
  substitutions, and a swap of two neighbours, no substring edited twice) on
  code points: at most **1** for a 5-code-point word, at most **2** for 6 or
  more.
- **The first code point is kept.** Only dictionary words that start with
  the typed word's first code point are compared (one range of the sorted
  dictionary). A first-letter slip is not caught; the rule pays for that
  with a scan of one range instead of the whole dictionary, and with fewer
  wrong expansions (any-first-letter costs J2's morphology slice 0.308 →
  0.231 under `content`).
- **Body words** that some chunk holds under the prefix (the roots and labels
  as above), keyed by their document frequency over the chunks the caller can
  see (roots and labels: **a path prefix narrows membership, not
  statistics**, as S3-T3 and S5-T2).
- **Title words** of visible files under the prefix that no chunk in scope
  holds, keyed at document frequency 1.
- **The order.** Fewest edits, then the higher key document frequency, then
  bytes. **At most 3** are kept.

A word only hidden chunks or files hold is never a candidate, so it is
neither searched nor named.

## The score

The kept words (the group) score as one query word:

- **The body.** One document frequency for the group, the largest of its
  body members' key frequencies (a title-only member adds none). Each chunk
  adds its best member's BM25 at that frequency, weighted **1.0** at one edit
  and **0.5** at two: never the sum, so a chunk holding three near spellings
  gains no more than one holding the best.
- **The title part.** The same over the file names: one frequency (the
  largest of the members' visible title frequencies), each file its best
  member, and the group counts once in the title's coverage of the query.
- **`both`** computes the groups once and uses them in its body and title
  parts.

A query with no group (every word found, or none qualifying) runs the
arithmetic of before S5-T3 bit for bit.

## What the caller sees

- `retrieval.fuzzy_policy_id` is `"fuzzy-v1"` whenever the lexical channel
  ran under `content` or `both` on an analyzer-v2 index.
- In `ss_query`'s report (and `searchd query`), the typed word keeps its
  `query_term_unmatched` warning, followed by a `query_term_expanded`
  warning: `term` the typed word, `expansions` the words searched, best
  first, `message` "also searched: …". JSON-RPC `search_knowledge` results
  carry no warnings (the schema's rule since contract 1.2.0).

## Cost

Nothing is kept between queries and nothing is written. One triggering word
scans its first letter's range with a 64-bucket bag-distance prefilter before
the banded OSA: on the 10k timing corpus about 0.55 ms for one word and
1.1 ms for two (`ReleaseSmall`, S5-T3's Report); one scan's working memory is
under 1 KiB.

## Known residuals

- **`ß`.** The reference's body tokenizer folds `ß` to `ss` (full case
  folding) and the engine keeps `ß` (simple folding), so a word with `ß` can
  trigger on one surface and not the other (J2 `a09`); the golden leaves such
  queries out.
- **Wrong near words.** `boxes` is not in J2 and expands to `bones` (`o10`
  2 → 4); `painting` reaches `planting` at two edits. The trigger only fires
  for a word nothing holds, so a right word is never displaced, but a wrong
  one can be added.
- **Intro chunks.** J2's `m03`, `m04`, `m15`, `m16` now rank the right file
  first through its H1/intro chunk, which J2 grades 0 (a regrade is a 03-next
  row).
- **`find`** does not expand; a "did you mean" there is a 03-next row.
