# S6-T3 evidence: index size

Raw tables for [`docs/index-size.md`](../../index-size.md) ([task](../../tasks/S6-T3.md)).
Measured 16 Nov 2026 on `main` at `7cd2c16` (engine sources as `efbdd0e`), macOS
arm64, Zig 0.16.0, `searchd` built with `zig build -Doptimize=ReleaseSmall`.
The corpora are generated, not committed; every text in them is invented.

| File | What |
| --- | --- |
| `raw/budget-<corpus>[-fn].json` | every file of the index, split into parts that sum to its size; counts |
| `raw/duplication-<corpus>-fn.json` | text and fields stored more than once |
| `raw/candidates-<corpus>-fn.json` | each candidate's re-encoded bytes |
| `tables.md` | the Markdown tables rendered from `raw/` (`index_size_budget.py tables`) |
| `probes.txt` | Zig probe runs: codec decode and encode, posting decode, binary sizes |
| `generations.txt` | directory size over five one-file updates, with and without `--keep-generations 2` |
| `timings.jsonl` | whole-process baselines (`scripts/prototypes/s6t3/timings.py`) |
| `find-bench.txt` | `zig/src/find_bench.zig` runs: open, warm query, `find` with and without the offsets section |

`<corpus>` is `timing-1k`, `timing-10k`, `prose-1k`, `prose-10k`, `tamil-1k`,
`tamil-10k`, `fixtures` (the repository's `fixtures/`, 232 files indexed) or
`family` (`fixtures/family-folder/`); `-fn` means indexed with `--filename-index`.

## Reproduce

From the repository root, with the pinned Zig on `PATH` and
`SEARCH_SIMPLI_LIBRARY_PATH` unset; `S` is any scratch directory.

```sh
(cd zig && zig build -Doptimize=ReleaseSmall --prefix "$S/rs")
python3 scripts/gen_timing_corpus.py "$S/timing-10k" 10000     # also 1000
python3 scripts/gen_prose_corpus.py "$S/prose-10k" 10000       # also 1000
python3 scripts/gen_tamil_timing_corpus.py "$S/tamil-10k" 10000 # also 1000
"$S/rs/bin/searchd" index "$S/timing-10k" --out "$S/idx/timing-10k"
"$S/rs/bin/searchd" index "$S/timing-10k" --out "$S/idx/timing-10k-fn" --filename-index
python3 -I scripts/index_size_budget.py budget "$S/idx/timing-10k-fn" --out raw/budget-timing-10k-fn.json
python3 -I scripts/index_size_budget.py duplication "$S/idx/timing-10k-fn" --out raw/duplication-timing-10k-fn.json
python3 -I scripts/index_size_budget.py candidates "$S/idx/timing-10k-fn" --lz4 --out raw/candidates-timing-10k-fn.json
python3 -I scripts/index_size_budget.py tables docs/evidence/s6-t3/raw --out docs/evidence/s6-t3/tables.md
```

The fixtures are indexed from `fixtures/` and `fixtures/family-folder/` in place
(`searchd` only reads them).

Probes (outside `zig/src/`, so the native digest is untouched):

```sh
python3 -I scripts/index_size_budget.py codec-blocks "$S/idx/timing-10k-fn" --blocks-dir "$S/codec/timing-10k"
for p in base flate_decode flate_both lz4_decode lz4_both postings_decode; do
  zig build-exe -O ReleaseSmall scripts/prototypes/s6t3/$p.zig -femit-bin="$S/probe/$p"
done
"$S/probe/flate_decode" "$S/codec/timing-10k"   # and the others; base only prints counts
size -m "$S/probe/base" "$S/probe/flate_decode"  # __TEXT segment sizes
```

Whole-process baselines and `find_bench` (time only when the 5-minute load is
below 4.0; both record it):

```sh
python3 -I scripts/prototypes/s6t3/timings.py "$S/rs/bin/searchd" "$S/idx/timing-10k-fn" "$S/timing-10k" "$S/work-timing"
zig build-exe -O ReleaseSmall zig/src/find_bench.zig -femit-bin="$S/probe/find_bench"
"$S/probe/find_bench" "$S/idx/timing-10k-fn" knowledge words words-recompute phrase phrase-recompute
```

The generations run is described at the top of `generations.txt`.
