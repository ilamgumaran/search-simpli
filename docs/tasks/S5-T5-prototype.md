# S5-T5 prototype: `-ing` and `-ed` relatives at query time over J2 (builder, 9 Nov 2026)

This is the builder's Phase 1 record for `docs/tasks/S5-T5.md` (rulings 2, 3 and 5). It runs on the Python reference only; no Zig engine code is written in Phase 1.

## The order kept (ruling 4)

| Step | Commit | What exists at that commit |
|---|---|---|
| Step 0, the regrade pass | `2c7ca97` | No code of R. |
| The held-out slice `verbform-heldout`, judged, recorded with today's engine | `f4cb29d` | No code of R on either surface; no candidate has run those queries. |
| This record: R restated and the candidates declared | the commit that adds this file | No code of R; no held-out run through a candidate. |

The prototype's code (`scripts/prototypes/s5t5/`) is written after this commit. Any candidate of the builder's own is declared in this file, in a commit of its own, before the first run of a `verbform-heldout` row or of `vhn1` / `vhn2` through any candidate. Runs made before that declaration leave those 21 queries out, and the record says which runs they were.

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

**The builder's own candidates.** None declared at this commit.

## How it is measured

- J2 through `core.search` with `core._query_groups` replaced by the candidate's group function, the same hook `scripts/prototypes/s5t4/j2run.py` used. The Python reference's body fold is the engine's simple fold (S5-T4's trap is resolved upstream).
- With no candidate installed, the run must equal every Python and every `searchd` cell of `fixtures/j2/baseline.json` at `f4cb29d`. The prototype checks this on every run.
- Gate: `scripts/j2_gate.py` against that baseline.
- Old packs: as `scripts/prototypes/s5t4/proto_s5t4_packs.py`.
- Cost: on the 10k timing corpus (`scripts/gen_timing_corpus.py`), the dictionary lookups R generates per query term and the key-map entries a key-based placement would hold.
