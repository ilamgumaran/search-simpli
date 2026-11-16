#!/bin/bash
# S6-T4 Phase 2: one run of every library on one corpus, rotated by RUN.
#   run2.sh SCRATCH CORPUS RUN OUT.jsonl
# SCRATCH holds main98/out, mainb/out (a second build of 98c4a2b), ctl1/out
# and ctl2/out (the placement controls: 98c4a2b plus an inert addition,
# docs/evidence/s6-t4/phase2/control-ctl{1,2}.diff), br/out (this branch),
# p2/v2/CORPUS (built by 98c4a2b's searchd), p2/v3/CORPUS (by the branch's)
# and q/CORPUS.json. The gate (gate.sh) before every library; a refused gate
# stops the run (exit 1); a rerun resumes it. One bench process per library.
set -u
scratch="$1"; corpus="$2"; run="$3"; out="$4"
here="$(cd "$(dirname "$0")" && pwd)"
lib() { echo "$scratch/$1/out/lib/aarch64-macos/libsearch_simpli.dylib"; }
queries="$scratch/q/$corpus.json"
v2="$scratch/p2/v2/$corpus"
v3="$scratch/p2/v3/$corpus"
# name|library|index
variants=(
  "main|$(lib main98)|$v2"
  "main2|$(lib mainb)|$v2"
  "ctl1|$(lib ctl1)|$v2"
  "ctl2|$(lib ctl2)|$v2"
  "v3|$(lib br)|$v3"
)
n=${#variants[@]}
for ((k = 0; k < n; k++)); do
  IFS='|' read -r name library index <<< "${variants[$(( (k + run) % n ))]}"
  if [ -f "$out" ] && grep -qF "\"variant\": \"$name\", \"round\": $run, \"index\": \"$index\"" "$out"; then continue; fi
  bash "$here/gate.sh" "s6t4p2 $corpus r$run $name" || exit 1
  python3 -I "$here/bench.py" bench "$library" "$index" "$queries" "$name" "$run" "$out" || exit 2
done
