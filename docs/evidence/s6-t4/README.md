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

Variants: `today` and `today-b` (`main`'s library on the v2 index, two processes); `eager-v3`; `lazy-nocache`
(`SS_PROTO_CACHE_BYTES=0`), `lazy-1mib` (1,048,576), `lazy-keep` (no budget), `lazy-all`
(`SS_PROTO_LAZY_ALL=1`: every list at the first use of any), `lazy-checked` (`SS_PROTO_LAZY_VALIDATE=1`: every
list decoded and discarded at open, then as `lazy-keep`). Memory is `ri_phys_footprint` growth over the process
before `ss_open`.
