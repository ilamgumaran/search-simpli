# S5-T5 prototype: `-ing` and `-ed` relatives at query time over J2 (builder, 9 Nov 2026)

This is the builder's Phase 1 record for `docs/tasks/S5-T5.md` (rulings 2, 3 and 5). It runs on the Python reference only; no Zig engine code is written in Phase 1.

## The order kept (ruling 4)

| Step | Commit | What exists at that commit |
|---|---|---|
| Step 0, the regrade pass | `2c7ca97` | No code of R. |
| The held-out slice `verbform-heldout`, judged, recorded with today's engine | `f4cb29d` | No code of R on either surface; no candidate has run those queries. |
| This record: R restated and the candidates A–D declared | `02fe99f` | No code of R; no held-out run through a candidate. |
| The builder's own candidate E declared | `6f84df7` | The prototype's R existed, uncommitted, in the builder's worktree. It had run only with the 21 held-out queries left out (listed below). |
| The first run of the held-out queries through any candidate | after `6f84df7` (progress file, 9 Nov) | The full grid below. |
| The prototype and these results | the commit that adds `scripts/prototypes/s5t5/` | |

The prototype's code (`scripts/prototypes/s5t5/`) was written after `02fe99f`. The builder's own candidate was declared in this file, in a commit of its own (`6f84df7`), before the first run of a `verbform-heldout` row or of `vhn1` / `vhn2` through any candidate. The runs made before that declaration left those 21 queries out; they are listed under the declaration.

## R restated (ruling 2)

Ruling 2's text holds; these points make it exact where it leaves a choice. Nothing here widens it.

**The words R looks at.** The query's group terms exactly as fold-groups-v1 takes them: under `content` the body terms and the title terms of the query, under `both` its file-name tokens; `find` is never grouped. For a term *t*:
1. *u* = A(F(*t*)). If F splits *t* into more than one piece, R does not apply.
2. R applies only when *u* is 4 to 49 letters, every one `a`–`z`. The length is *u*'s, before S.
3. *p* = S(*u*), fold-groups-v1's plural step (*p* = *u* when S leaves it alone). Every remainder below is measured on *p*.

**Vowels and consonants.** A vowel is `a e i o u`. Two exceptions, both from ruling 2's text:
- the "holds a vowel" test on a remainder also counts `y` (ruling 2 lists `a e i o u y`);
- everywhere else, `y` is a consonant. This includes the consonant-vowel-consonant test and the consonant before a final `y`.

**The bases of *t*.** The bases are the union of every line whose condition holds:
- *p*.
- **`-ing`.** *p* ends in `ing`, and *r* = *p* less `ing` is 3 or more letters and holds a vowel. Bases: *r*, *r* + `e`, and the undoubled *r*. The undoubled *r* is *r* less its last letter, taken only when *r*'s last two letters are the same consonant and that letter is not `l`, `s` or `z`. A doubled `l`, `s` or `z` gives no undoubled base; *r* stays a base, as for every remainder.
- **`-ed`.** *p* ends in `ed`, and *r* = *p* less `ed` is 3 or more letters and holds a vowel. Bases: *r*, *r* + `e`, and the undoubled *r* as above.
- **`-ied`.** *p* ends in `ied` and is 5 or more letters. Base: *p* less `ied`, plus `y`.

The `-ed` and `-ied` lines are not exclusive. **`tidied`** satisfies both:
- `-ed` gives `tidi` and `tidie`;
- `-ied` gives `tidy`.

All three are bases. A base that is not a word costs lookups and finds nothing.

**The relatives of a base *b*.** Each relative is a string of `a`–`z`:
- *b*, *b* + `s`, *b* + `es`, *b* + `ed`, *b* + `ing`;
- *b* + `d`, and *b* less its final `e` + `ing`, when *b* ends in `e`;
- *b* + its last letter + `ed`, and the same + `ing`, when *b* ends consonant-vowel-consonant. This is the last three letters, under the vowel rule above; there is no `w`/`x`/`y` exception, because ruling 2 names none and an unheld form is never a member.
- *b* less `y` + `ies`, and the same + `ied`, when *b* ends in a consonant followed by `y`.

Nothing else is generated. In particular, no relative of a relative and no plural of an `-ing` form (`paintings`).

**The members.**
- R's forms are every relative of every base of *t*, less *t* itself.
- A form is a member only if the opened index holds it exactly, by bytes, either as a body term of a chunk in scope or as a title term of a visible file under the prefix. This is fold-groups-v1's vocabulary, under its visibility rule unchanged.
- A form is ASCII by construction. A held term carrying a mark is not matched by its unmarked form here; fold-groups-v1 already groups those by key.

**The group.**
- *t*'s group is fold-groups-v1's members (the key-mates, *t* first if held) together with R's members.
- The order is fold-groups-v1's: *t* first, then key df descending (the visible chunks' df, as v1), then UTF-8 bytes.
- The group is used when it is not empty and not *t* alone.
- It is scored by fuzzy-v1's group code unchanged: one shared df, the largest member df; each chunk takes its best member's weight × BM25, and the title part is computed the same way.
- fuzzy-v1 runs, as today, on every term that has no group after R.

**The weights.** A member that is *t* or one of *t*'s key-mates (fold-groups-v1's group) always weighs 1.0. A member that only R gives (an **R-only member**) weighs the candidate's R weight.

## The candidates (ruling 3)

"v1 group empty" means *t*'s fold-groups-v1 vocabulary holds no term with *t*'s key: the files in scope hold neither *t* nor a plural form of it. This is candidate C's trigger, and it also decides D's split.

| Candidate | When R runs | R-only member weight | fuzzy-v1 |
|---|---|---|---|
| **A** | every term R applies to | 1.0 | only on a term left with no group |
| **B** | every term R applies to | 0.5 | only on a term left with no group |
| **C** | only when the v1 group is empty | 1.0 | only on a term left with no group, so not when R gives a member |
| **D** | every term R applies to | 1.0 when the v1 group is empty; 0.5 otherwise | only on a term left with no group |

- D is "C's members at 1.0 for a word the files do not hold; B's at 0.5 for a word they do", taking "do not hold" to be C's trigger. A word the files do not hold while they hold a plural form of it is therefore on B's side.
- No keep list in any candidate.
- Any candidate of the builder's own (at most two) is declared below, before any held-out run.

**The builder's own candidates.** One is declared, in a commit of its own, before any held-out run.

- **E: D with a df cap on the held side.**
  - When the v1 group is empty, R-only members join at 1.0, exactly as C and D.
  - When it is not empty, an R-only member joins at 0.5 only if its in-scope body df is no larger than the largest in-scope body df among the v1 members (the word itself when held, and its key-mates).
  - The df compared is the one fuzzy-v1's group scoring takes for the shared df (the chunks in scope, the path prefix applied). So on the held side R never changes the word's body df, and so never its idf. It only adds a half-weight match in the chunks that hold the rarer relative.
  - This is a membership filter only: the group code and its scoring are unchanged.
  - When every v1 member is title-only, the cap is 0, so only title-only relatives join.

**The runs made before this declaration** all left out the 19 `verbform-heldout` rows and `vhn1` / `vhn2` (`proto_s5t5.py --no-heldout`).
- **The grid.** A, B, C, D on every other row.
- **A weight sweep on the held side.** D's R-only weight for a held word at 0.5, 0.25, 0.1 and 0.05.
  - Control `c22` (`tomato seedlings potted`) went 1 → 2 under every weight, in both modes.
  - The cause is the shared df: `pot` and `pots` are commoner than `potted`, so adding them lowers the word's idf whatever their weight.
  - That is what E's cap addresses.
- **F: E with 1.0 on the held side.** Also run. It lost `c22` (1 → 2: `pots` passes the cap at weight 1.0), so it is not declared.

None of these runs touched a held-out row.

## How it is measured

- J2 through `core.search` with `core._query_groups` replaced by the candidate's group function, the same hook `scripts/prototypes/s5t4/j2run.py` used. The Python reference's body fold is the engine's simple fold (S5-T4's trap is resolved upstream).
- With no candidate installed, the run must equal every Python and every `searchd` cell of `fixtures/j2/baseline.json` at `f4cb29d`. The prototype checks this on every run.
- Gate: `scripts/j2_gate.py` against that baseline.
- Old packs: as `scripts/prototypes/s5t4/proto_s5t4_packs.py`.
- Cost: on the 10k timing corpus (`scripts/gen_timing_corpus.py`), the dictionary lookups R generates per query term and the key-map entries a key-based placement would hold.

## The scripts (`scripts/prototypes/s5t5/`)

| Script | What it does |
|---|---|
| `verbforms.py` | R as restated above (`word_of`, `bases`, `relatives`, `forms`). The candidates, as a replacement for `core._query_groups` (`install`, `restore`). `today` is fold-groups-v1 rewritten there with no R; `today-orig` is core's own function. |
| `proto_s5t5.py` | The grid: every candidate in both variants, the baseline check, the per-slice table, the first grade-2 moves, bars (a)–(e), the gate against the `searchd` cells and the negatives. `--no-heldout` leaves out the 21 held-out queries. |
| `proto_s5t5_packs.py` | The old packs at each candidate against today, bar (f). |
| `cost.py` | R's counts on a corpus's dictionary: lookups per word, and the entries a key map would hold. |

**Reproduce** from a checkout (about 20 s in all). `$S` is a scratch directory.

```
export TMPDIR=$S
PYTHONHASHSEED=0 python3 scripts/prototypes/s5t5/proto_s5t5.py --candidates today A B C D E --detail --json $S/grid.json
PYTHONHASHSEED=0 python3 scripts/prototypes/s5t5/proto_s5t5.py --no-heldout --detail
PYTHONHASHSEED=0 python3 scripts/prototypes/s5t5/proto_s5t5_packs.py A B C D E
python3 scripts/gen_timing_corpus.py $S/corpus10k 10000 && python3 scripts/prototypes/s5t5/cost.py $S/corpus10k
```

**The baseline reproduces.** On every run, `today-orig` and `today` each equal all 536 cells of both surfaces of `fixtures/j2/baseline.json`. They also equal every old pack (`proto_s5t5_packs.py` prints `True`).

## Results

The per-candidate table, the bars and the recommendation are in the Report of `docs/tasks/S5-T5.md` (Phase 1). This section keeps the detail behind them.

**The groups R forms on J2.** From `--detail`, `content` and `both` together.
- **C**: R gives a member to 19 words, all with an empty v1 group: `buried`, `cancelled`, `cycled`, `danced`, `diving`, `drip`, `drummed`, `hopping`, `juggling`, `knead`, `knitting`, `painting` (`paint`, `painted`), `scrubbed`, `sketching`, `skip`, `stir`, `tidied`, `tidying`, `wobbled`. Each takes exactly the other form the files hold.
- **E**: the same 19 words, plus 20 held words that take an R-only member at 0.5 under the cap:
  - `book` (`booked`, `booking`) and `books` (the same);
  - `feeds` (`feeding`), `flour` (`floured`), `hands` (`handed`), `herring` (`hers`), `names` (`named`), `opening` (`opened`), `paddling` (`paddled`), `pasted` (`paste`), `petting` (`pet`, `pets`), `plans` (`planned`), `planting` (`planted`), `pots` (`potted`), `potted` (`pots`), `reading` (`reads`, `read`), `saving` (`saved`, `saves`), `shopping` (`shop`, `shops`), `sledging` (`sledged`), `swimming` (`swim`, `swims`).
- **The cap at work.** It keeps out the four commoner look-alikes: `her` (df 6), `out` (df 17), `past` (df 8) and `wed` (df 2), each above its word's df of 1. It also keeps out `pot` for `potted` (`c22`), and `paint` for `painted` (`o12`). It lets `pet` in for `petting`, both at df 1; guard `vg5` holds at weight 0.5 (7.810 against `§Pet passport` 4.335).

**fuzzy-v1 replaced.** Today four of these words reach fuzzy-v1 and take a wrong neighbour:
- `hopping` → `helping`;
- `tidied` → `tied`, `tried`;
- `diving` → `divide`, `doing`, `drying`;
- `painting` → `planting`.

Under every candidate R gives each of them a member, so fuzzy-v1 no longer runs on it. Every other fuzzy-v1 expansion is unchanged under every candidate.

**Margins worth knowing** (`content` lexical scores, E):
- `c22`: the answer 4.602, against 4.564 for `rasam.md` (today's margin, unchanged). `chores.md` rises to 4.249 with `pots` at 0.5.
- `vt1`: `§Winter notices` 8.615 against the answer 8.335.

**What R as ruling 2 writes also generates.** A base not ending in `e` also takes *b* + `es` / `ed` / `ing`. For `hop` that gives `hopes`, `hoped` and `hoping`, which are forms of `hope`. No J2 group took such a form. It is a residual of the rule's text, not of a candidate.

**The cost** (`cost.py`, the 10k timing corpus: 10,000 files; 24,057 body terms, 10,102 title terms, 34,159 distinct).
- **Where R applies.** 24,039 dictionary words are 4–49 letters `a`–`z`. Only 5 have a base other than their own plural form: `distributed`, `hashing`, `indexing`, `operating`, `ranking`.
- **By generated form.**
  - Over the dictionary: 4 to 16 lookups per word, median 4.
  - The timing words: `system`, `systems`, `hybrid`, `retrieval`, `schedulers`, `tables` take 6 each; `benico` and `bazechas` take 4; `indexing` and `operating` take 14; `hashing` and `ranking` take 12.
  - Across J2's words, at most 19 (`drummed`, `scrubbed`, `potted`).
  - C runs R only on a word with an empty v1 group, so a held word costs C no lookup. A, B, D and E run R on every word.
- **By key.** A base → words map over the whole dictionary holds 24,049 (base, word) pairs. Only 10 pairs (over the 5 words above) are beyond each word's own base. A map that keeps only those, as S5-T4's key map keeps only the words whose key differs, holds 10 entries.
- **E's cap** reads one df per held form. On the 10k corpus only `hashing` has one (`hash`).

## Phase 2: E as ruled (`Er`)

Ruling 1 at `0d16100` words E's cap on the word's own key df, not on the largest key df of its fold-groups-v1 members, and splits on whether the word is held (a chunk in scope or a visible title holds it), not on whether its v1 group is empty. The prototype carries that wording as candidate `Er` (`verbforms.py`), the form the engine and the reference ship as fold-groups-v2:

- the word is held: an R-only member joins at 0.5 only when its key df (the visible chunks) is no higher than the word's own key df;
- the word is not held: R's members join at 1.0 with no cap, whether or not the word has v1 key-mates.

`PYTHONHASHSEED=0 python3 scripts/prototypes/s5t5/proto_s5t5.py --candidates today E Er --detail` on 9 Nov: `Er` equals `E` on every judged cell of both modes (success@1, MRR@10, nDCG@10, recall@5, first grade-2 rank and ties for all 198 queries); bars (a)–(e) as E's. Two groups differ: `feeds` (not held, key-mate `feed`) takes `feeding` at 1.0 instead of 0.5, and `names` (held, df 1) no longer takes `named` (df 2). They move only grade-0 hits at ranks 7–10 of `o03` and a score of `o07`.
