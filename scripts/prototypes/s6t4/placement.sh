#!/bin/bash
# S6-T4 second rework (an investigation, not a bar run): is the head's cost on
# the small cells the format, or where the linker put the code?
#   placement.sh SCRATCH CORPUS ROUNDS OUT.jsonl
# Six variants in one process each, rotated one place per round:
#   main        98c4a2b's library on the v2 index
#   head        this branch's library on the v2 index
#   headctl1    this branch plus control-ctl1.diff (inert code, never run) on v2
#   headctl2    this branch plus control-ctl2.diff on v2
#   head-v3     this branch's library on the v3 index
#   headctl1-v3 this branch plus control-ctl1.diff on the v3 index
# SCRATCH holds main98/out, br/out, rw2/head-ctl1/out, rw2/head-ctl2/out (each a
# `zig build lib -Doptimize=ReleaseSmall --prefix` tree), p2/v2/CORPUS,
# p2/v3/CORPUS and q/CORPUS.json. The gate (gate.sh, GATES set by the caller)
# before every process; a refused gate stops the run (exit 1).
set -u
scratch="$1"; corpus="$2"; rounds="$3"; out="$4"
here="$(cd "$(dirname "$0")" && pwd)"
lib() { echo "$scratch/$1/lib/aarch64-macos/libsearch_simpli.dylib"; }
variants=("main|$(lib main98/out)|v2" "head|$(lib br/out)|v2" "headctl1|$(lib rw2/head-ctl1/out)|v2"
  "headctl2|$(lib rw2/head-ctl2/out)|v2" "head-v3|$(lib br/out)|v3" "headctl1-v3|$(lib rw2/head-ctl1/out)|v3")
n=${#variants[@]}
for ((r = 1; r <= rounds; r++)); do
  for ((k = 0; k < n; k++)); do
    IFS='|' read -r name library format <<< "${variants[$(( (k + r) % n ))]}"
    bash "$here/gate.sh" "s6t4rw2-place $corpus r$r $name" || exit 1
    python3 -I "$here/bench.py" bench "$library" "$scratch/p2/$format/$corpus" "$scratch/q/$corpus.json" "$name" "$r" "$out" || exit 2
  done
done
