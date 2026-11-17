#!/bin/bash
# S6-T4 Phase 2: whole-process timings, the one-file update and the first
# v2 -> v3 publish, one run over one corpus (order rotated by RUN).
#   updates2.sh SCRATCH CORPUS RUN OUT.jsonl
# `timings.py` (S6-T3) with 98c4a2b's searchd on the v2 index and with this
# branch's on the v3 index (query, find, read-span, one-file update: median
# of 3); `migrate.py` with this branch's searchd on the v2 index (the first
# update publishes v3; the second is v3 -> v3) and with 98c4a2b's (v2 -> v2
# both times). Work directories go under SCRATCH/p2/upd.noindex/ and must
# not exist. The gate (gate.sh) before each; a refusal stops (exit 1).
set -u
scratch="$1"; corpus="$2"; run="$3"; out="$4"
here="$(cd "$(dirname "$0")" && pwd)"
old="$scratch/main98/out/bin/searchd"
new="$scratch/br/out/bin/searchd"
files="$scratch/corpora/$corpus"
work="$scratch/p2/upd.noindex/r$run-$corpus"
jobs=(
  "timings|main|$old|$scratch/p2/v2/$corpus"
  "timings|v3|$new|$scratch/p2/v3/$corpus"
  "migrate|v3|$new|$scratch/p2/v2/$corpus"
  "migrate|main|$old|$scratch/p2/v2/$corpus"
)
n=${#jobs[@]}
for ((k = 0; k < n; k++)); do
  IFS='|' read -r kind name searchd index <<< "${jobs[$(( (k + run) % n ))]}"
  bash "$here/gate.sh" "s6t4p2 $kind $corpus r$run $name" || exit 1
  if [ "$kind" = timings ]; then
    result="$(python3 -I "$here/../s6t3/timings.py" "$searchd" "$index" "$files" "$work-$kind-$name")" || exit 2
  else
    result="$(python3 -I "$here/migrate.py" "$searchd" "$index" "$files" "$work-$kind-$name")" || exit 2
  fi
  echo "{\"kind\": \"$kind\", \"variant\": \"$name\", \"corpus\": \"$corpus\", \"run\": $run, \"result\": $result}" >> "$out"
done
