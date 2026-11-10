# Word-form groups v1 (`fold-groups-v1`)

Status: shipped by [S5-T4](tasks/S5-T4.md), contracts 2.5.0; succeeded by
[fold-groups-v2](fold-groups-v2.md) (S5-T5, contracts 2.6.0), which keeps K,
the key map, the order and the scoring below and adds `-ing`/`-ed` verb forms
as members. This page stays v1's record. Query side only:
no index format, writer or analyzer changes, and an index written before
S5-T4 groups its words the same way. The key function K is implemented twice
and held equal byte for byte by a golden: the Zig engine (`zig/src/fold.zig`)
and the Python mirror (`src/search_platform/analyzer_v3.py`,
`scripts/gen_analyzer_v3_golden.py`, `fixtures/analyzer-v3-golden.json`, 49,122
terms). The Python reference (`src/search_platform/core.py`) groups with the
mirror.

## Why

A child types `dinosaurs` and the notes say `dinosaur`; types `resume` and the
file says `résumé`; types `யானைகள்` ("elephants") and the passage says
`யானை`. Before S5-T4 each of these was a different word, and J2's morphology,
accent and Tamil slices had a third or fewer of their answers at rank 1. The
index's own words are grouped at query time instead: a query word is also
searched as the words the files hold that share its key.

## The key

K maps one analyzer-v2 term to zero or more pieces through four parts, in
order (Unicode 13.0.0, the version of the engine's other tables):

1. **F, fold.** Each code point through the fold table (the 3,746 code points
   whose NFKC(casefold(NFKC(c))) fixpoint differs from NFC of analyzer-v2's
   simple fold) or else analyzer-v2's simple fold, then NFC. The result is
   split again by analyzer-v2's rule, so `½` gives `1` and `2`, `ｇａｒｄｅｎ`
   gives `garden`, `ﬂute` gives `flute`, `straße` gives `strasse`.
2. **A, Latin marks.** An ASCII piece is untouched. Otherwise: the canonical
   decomposition; the eight letters `ø đ ł ħ ŧ ı æ œ` mapped to `o d l h t i
   ae oe`; every U+0300–U+036F whose nearest preceding non-mark is a–z
   dropped; then NFC. So `résumé` gives `resume` and `łódź` gives `lodz`, while
   a Greek or Tamil letter keeps its marks.
3. **S, English plural.** A piece of 3–49 letters a–z, ending in `s` but not
   in `ss`, `us` or `is`, and not in the 50-word keep list (`news`, `species`,
   `series`, `maths`, `physics`, `glasses`, `thanks`, `does`, `was`, `this`,
   `bus`, `gas` and the rest in `fold.zig`), by the first rule that applies:
   - `-ies` → `-y` when the piece has 5 or more letters (`ponies` → `pony`),
     else drop the `s` (`ties` → `tie`);
   - `-sses`, `-xes`, `-ches`, `-shes`, `-zzes` → drop `es` (`boxes` → `box`);
   - `-oes` with 6 or more letters → drop `es` (`potatoes` → `potato`;
     `shoes` → `shoe` by the next rule);
   - otherwise, with 4 or more letters, drop the `s`.
4. **T, Tamil.** A piece of U+0B80–U+0BFF code points only, not in the keep
   list (`நாங்கள்`, `நீங்கள்`, `உங்கள்`, `எங்கள்`, `தங்கள்`, `அவர்கள்`,
   `இவர்கள்`, `மக்கள்`), by the first of seven suffix rules whose condition
   holds and whose result keeps two Tamil letters (U+0B85–U+0BB9):

   | Suffix | Becomes | The stem must end in |
   |---|---|---|
   | `-ங்கள்` (plural of an `-ம்` noun) | `-ம்` | anything |
   | `-கள்` (plural) | (dropped) | anything |
   | `-த்தில்` (locative of an `-ம்` noun) | `-ம்` | anything |
   | `-த்தின்` (genitive of an `-ம்` noun) | `-ம்` | anything |
   | `-க்கு` (dative) | (dropped) | a vowel sign |
   | `-யில்` (locative) | (dropped) | `ி`, `ீ` or `ை` |
   | `-யின்` (genitive) | (dropped) | `ி`, `ீ` or `ை` |

A term's **key** is its pieces joined by one space, or the term itself when K
leaves nothing. A key of two pieces never equals an indexed term, so `½` forms
no group. S and T never apply to the same piece, and no rule touches a piece
of any other script.

An ASCII term of letters and digits takes a path with no table lookup (F is
lowercasing, A and T cannot apply), and an all-Tamil term already in NFC takes
T alone (the block has no fold table entry and only four composing pairs; a
test checks this path against the full one on every one- and two-code-point
string of the block).

## The groups

- **The key map.** The terms of the opened generation whose key is not
  themselves, sorted by key: the index's body terms, then the title field's
  terms ([title-field-v1](title-field-v1.md)) the body does not hold. It is
  built once per opened generation, at the first `content` or `both` query
  (`scope.Folder.keyMap`), and kept with the generation: on the 10k timing
  corpus 7 entries in 114 bytes.
- **The members of a query word t.** The term equal to K(t), when its own key
  is itself, and the map's terms with key K(t), each kept only if the caller
  may see it:
  - a body term some chunk in scope holds (roots, labels and the path prefix),
    keyed by its document frequency over the chunks the caller can see (roots
    and labels: **a prefix narrows membership, not statistics**, as fuzzy-v1);
  - a title term of a visible file under the prefix, keyed at document
    frequency 0.
- **The order.** t first when it is a member, then the higher key document
  frequency, then bytes. Every member weighs **1.0**.
- **When a group is used.** When it is not empty and not {t} alone. A query
  word with a group is not also expanded by [fuzzy-v1](fuzzy-v1.md); fuzzy-v1
  runs on the words without one.
- **The score** is fuzzy-v1's. In the body: one document frequency for the
  group (the largest of its body members'), each chunk its best member's BM25,
  never the sum. In the title part ([title-field-v1](title-field-v1.md)): every
  member the title field holds, body member or title member, weighs 1.0; the
  group takes one document frequency, the largest of its members' title
  document frequencies over the files the caller may see (roots and labels,
  not the prefix); each file takes its best member's title BM25 at that
  frequency, never the sum; the group counts as one query word in the file's
  coverage; the part is 2.5 × that BM25 × coverage. A title member's key
  document frequency 0 orders the group only and never enters a score.
  `both` computes the groups once for its body and title parts. The
  `filename` field is never grouped.

A word that only hidden chunks or files hold is never a member, so it is
neither searched nor named. A query with no group runs the arithmetic of
before S5-T4.

## What the caller sees

- `retrieval.fold_policy_id` is `"fold-groups-v1"` whenever the lexical
  channel ran under `content` or `both` on an analyzer-v2 index.
- In `ss_query`'s report (and `searchd query`), a grouped word gets a
  `query_term_grouped` warning: `term` the typed word, `members` the other
  words searched (t left out), best first, `message` "also searched as: …".
  An unmatched word's grouped warning follows its own `query_term_unmatched`;
  a grouped word the files hold has no other warning, and its grouped warning
  follows all the unmatched words' warnings, in query order. JSON-RPC
  `search_knowledge` results carry no warnings (the schema's rule since
  contract 1.2.0).

## Cost

Measured on the 10k timing corpus, `ReleaseSmall`, against the engine before
S5-T4 ([S5-T4's Report](tasks/S5-T4.md)):

- **The first `content` query after an open** builds the key map: +1.04 to
  +1.12 ms (the build alone 1.09 ms, of which K is 0.6 to 0.7 ms; 7 entries,
  114 bytes kept). Nothing else is kept, and nothing is kept between queries.
- **A query whose words form no group** costs at most +0.016 ms warm
  (`content`) and +0.004 ms (`both`).
- **A grouped word** pays its members' postings: `system` (with `systems`,
  2,520 chunks) +0.056 ms `content`, +0.065 ms `both`.
- **An unmatched word with a group** is cheaper than before, because the group
  replaces fuzzy-v1's dictionary scan: `bazechas` −0.48 ms.
- **A Tamil-heavy folder** (a generated 10k corpus, `scripts/gen_tamil_timing_corpus.py`:
  21,600 terms, every inflected form a key map entry) keeps a map of 16,800
  entries in 445,993 bytes; its build takes 8.4 ms (55.7 ms without the
  all-Tamil fast path), and the first query after an open 13.0 ms against
  3.1 ms before.

## Known residuals

- **`-ing` and `-ed`** are not grouped (`painting` / `painted` / `paint`);
  stripping them needs a stemmer's undoubling rules, and Porter's `-ed` rule
  costs J2's control slice (`c22`). Closed by
  [fold-groups-v2](fold-groups-v2.md), which generates the forms at query time.
- **True pairs that move a rank.** Grouping a real singular and plural can let
  another chunk's BM25 win: the mixed pack's five named moves (`readers` /
  `reader`, `candidates` / `candidate`, `file` / `files`, `document` /
  `documents`), recorded in [evaluation](evaluation.md).
- **Index side.** The index keeps analyzer-v2's terms, so `find` and the
  `filename` field do not group, and the snippet holds the form the file holds.
