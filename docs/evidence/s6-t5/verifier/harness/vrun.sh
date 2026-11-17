#!/bin/bash
# S6-T5 verification: one run of five libraries on one corpus in the fixed
# order for RUN (timing/orders.txt), gate.sh (S6-T4's, unchanged) before every
# library, bench.py (S6-T4's, unchanged) per library.  vrun.sh CORPUS RUN OUT.jsonl
set -u
V=$HOME/workspace/repos/search-simpli-wt/S6-T5-vscratch
S=$V/s6t4h
corpus="$1"; run="$2"; out="$3"
export GATES=$V/timing/gates.txt
order=$(grep "^run$run:" "$V/timing/orders.txt" | cut -d: -f2)
[ -n "$order" ] || { echo "no order for run $run"; exit 3; }
index=$V/idx/$corpus
for name in $order; do
  library=$V/libs/$name/libsearch_simpli.dylib
  if [ -f "$out" ] && grep -qF "\"variant\": \"$name\", \"round\": $run, \"index\": \"$index\"" "$out"; then continue; fi
  bash "$S/gate.sh" "vS6T5 $corpus r$run $name" || exit 1
  python3 -I "$S/bench.py" bench "$library" "$index" "$V/q/$corpus.json" "$name" "$run" "$out" || exit 2
done
echo "done $corpus r$run $(date +%T)"
