#!/bin/bash
# S6-T4 rework, item 2 (an investigation, not a bar run): one library, this
# branch's, on the same corpus written as v2 (by 98c4a2b) and as v3 (by this
# branch), alternated ABBA so neither format holds a fixed place in the order.
# Code placement is then the same for both; only the index format differs.
#   format_ab.sh SCRATCH CORPUS ROUNDS OUT.jsonl
# SCRATCH as run2.sh's (br/out, p2/v2/CORPUS, p2/v3/CORPUS, q/CORPUS.json).
# The gate (gate.sh, GATES set by the caller) before every process; a refused
# gate stops the run (exit 1).
set -u
scratch="$1"; corpus="$2"; rounds="$3"; out="$4"
here="$(cd "$(dirname "$0")" && pwd)"
library="$scratch/br/out/lib/aarch64-macos/libsearch_simpli.dylib"
queries="$scratch/q/$corpus.json"
for ((r = 1; r <= rounds; r++)); do
  if (( r % 2 )); then formats="v2 v3"; else formats="v3 v2"; fi
  for f in $formats; do
    bash "$here/gate.sh" "s6t4rw-ab $corpus r$r head-$f" || exit 1
    python3 -I "$here/bench.py" bench "$library" "$scratch/p2/$f/$corpus" "$queries" "head-$f" "$r" "$out" || exit 2
  done
done
