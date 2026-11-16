#!/bin/bash
# Verifier's timing run (S6-T4): one run of five libraries on one corpus,
# rotated by RUN, the builder's gate.sh before every library, the builder's
# bench.py (read) as the per-library process.  vrun.sh CORPUS RUN OUT.jsonl
set -u
V=$HOME/workspace/repos/search-simpli-wt/S6-T4-vscratch
S=$HOME/workspace/repos/search-simpli-wt/S6-T4-verify/scripts/prototypes/s6t4
corpus="$1"; run="$2"; out="$3"
export GATES=$V/timing/gates.txt
variants=(
  "main|$V/libs/main/libsearch_simpli.dylib|$V/idx/v2/$corpus"
  "main2|$V/libs/main2/libsearch_simpli.dylib|$V/idx/v2/$corpus"
  "vctl1|$V/libs/vctl1/libsearch_simpli.dylib|$V/idx/v2/$corpus"
  "vctl2|$V/libs/vctl2/libsearch_simpli.dylib|$V/idx/v2/$corpus"
  "head|$V/libs/head/libsearch_simpli.dylib|$V/idx/v3/$corpus"
)
n=${#variants[@]}
for ((k = 0; k < n; k++)); do
  IFS='|' read -r name library index <<< "${variants[$(( (k + run) % n ))]}"
  if [ -f "$out" ] && grep -qF "\"variant\": \"$name\", \"round\": $run, \"index\": \"$index\"" "$out"; then continue; fi
  bash "$S/gate.sh" "vS6T4 $corpus r$run $name" || exit 1
  python3 -I "$S/bench.py" bench "$library" "$index" "$V/q/$corpus.json" "$name" "$run" "$out" || exit 2
done
echo "done $corpus r$run $(date +%T)"
