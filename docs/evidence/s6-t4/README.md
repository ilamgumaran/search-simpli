# S6-T4 Phase 1 evidence

Raw rows behind the Phase 1 Report in [`docs/tasks/S6-T4.md`](../../tasks/S6-T4.md). The scripts are in
`scripts/prototypes/s6t4/`; the prototype is `scripts/prototypes/s6t4/prototype.diff` applied to `main`'s `zig/`
(`9419ace`), built ReleaseSmall twice: eager (no option) and lazy (`-Dlex_lazy=true`).

| File | What |
|---|---|
| `run3.jsonl`, `run4.jsonl` | `bench.py bench` rows, one per (corpus, variant), the two runs of the Report's §3 (`run.sh`, rotated) |
| `superseded/` | the first two runs, made with a lazy build that resolved only 16 query terms per query (see Report §8), and `updates-early.jsonl`, an earlier whole-process run with that build |
| `updates.jsonl` | `scripts/prototypes/s6t3/timings.py` rows: whole-process `query`, `find`, `read-span` and one-file update; per corpus `main` (v2), eager prototype (v3), lazy prototype (v3), in that order |
| `migrate.jsonl` | `migrate.py`: the first update of a v2 index by the eager prototype (v2 → v3) and the second (v3 → v3) |
| `gates.txt` | every gate check (pass or refusal) with the load and the top eight |
| `answers.txt` | answer-hash comparison of every variant against `main` on v2 |
| `sizes/` | `sizes.py` per corpus: every section's bytes in both formats |
| `queries/` | the query sets (`bench.py queries` / `j2queries`) |
| `summary.md` | `summarize.py run3.jsonl run4.jsonl` |
| `old-library-on-v3.txt` | Phase 2, ruling 4: `searchd` and `libsearch_simpli.dylib` built from `98c4a2b` (ReleaseSmall) on a copy of `tests/fixtures/index-v3-s6t4/`: every command and `ss_open` refuse it with `UnsupportedFlags` |
| `same-answers.txt` | Phase 2, ruling 3: `same_answers.py` over J2, `fixtures/`, the family-folder pack and the three 10k corpora (main's library on v2 against this branch's on v3, and this branch's on v2), then the J2 native run and gate |
| `plants.txt` | Phase 2, ruling 5: the three plants, each in its own scratch copy and caches, and the test summary each gave |
| `phase2/run1.jsonl`, `phase2/run2.jsonl` | Phase 2 timing, `run2.sh`: `main` (98c4a2b), `main2` (a second build of it), `ctl1`, `ctl2` (the placement controls) on the v2 indexes and this branch on v3, rotated by the run, one bench process each; open, first query and first `find`, warm query and `find` cells, memory |
| `phase2/bars.md` | `bars.py run1.jsonl run2.jsonl`: the bars table, the bands, every cell over the band or at +0.010 ms in one run |
| `phase2/updates.jsonl`, `phase2/updates.md` | `updates2.sh`: the one-file update (v2 by `main`, v3 by this branch), the first publish over a v2 index by each, whole-process `query`, `find`, `read-span` |
| `phase2/gates.txt` | the load gate before every library and update measurement (68 passed, 1 refused) |
| `phase2/discarded-run1-partial-load.jsonl` | the three rows of the first attempt at run 1, stopped by a refused gate; not used |
| `phase2/sizes/*.json` | every index file's bytes, v2 by `main` and v3 by this branch, per corpus |
| `phase2/control-ctl1.diff`, `phase2/control-ctl2.diff` | the two placement controls, as diffs against 98c4a2b |
| `rework/plants.txt` | the rework (after the first Verdict): plants P3 (the verifier's), L1, L2, L3 against the last element of each v3 section, on the reworked suite and on the suite before it |
| `rework/find-path.txt` | the rework, item 2: what differs on the find path between v2 and v3 after open, why the three cells' sign follows the run number, and the format alone (`find_cells.py`) |
| `rework/format-ab.jsonl`, `rework/format-ab-gates.txt` | `format_ab.sh`: this branch's library on the v2 and the v3 index of timing-10k and tamil-10k, ABBA, four rounds; an investigation, not a bar run |

Variants: `today` and `today-b` (`main`'s library on the v2 index, two processes); `eager-v3`; `lazy-nocache`
(`SS_PROTO_CACHE_BYTES=0`), `lazy-1mib` (1,048,576), `lazy-keep` (no budget), `lazy-all`
(`SS_PROTO_LAZY_ALL=1`: every list at the first use of any), `lazy-checked` (`SS_PROTO_LAZY_VALIDATE=1`: every
list decoded and discarded at open, then as `lazy-keep`). Memory is `ri_phys_footprint` growth over the process
before `ss_open`.
