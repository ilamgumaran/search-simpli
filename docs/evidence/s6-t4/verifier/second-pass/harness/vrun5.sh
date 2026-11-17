#!/bin/bash
# Second verification (S6-T4): one run of five libraries on one corpus in the
# fixed order for RUN (timing2/orders.txt), the builder's gate.sh before
# every library, bench.py (read) per library.  vrun5.sh CORPUS RUN OUT.jsonl
set -u
V=$HOME/workspace/repos/search-simpli-wt/S6-T4-vscratch
S=$HOME/workspace/repos/search-simpli-wt/S6-T4-verify/scripts/prototypes/s6t4
corpus="$1"; run="$2"; out="$3"
export GATES=$V/timing2/gates.txt
order=$(grep "^run$run:" "$V/timing2/orders.txt" | cut -d: -f2)
[ -n "$order" ] || { echo "no order for run $run"; exit 3; }
for name in $order; do
  case $name in head) index=$V/idx/v3/$corpus ;; *) index=$V/idx/v2/$corpus ;; esac
  library=$V/libs/$name/libsearch_simpli.dylib
  if [ -f "$out" ] && grep -qF "\"variant\": \"$name\", \"round\": $run, \"index\": \"$index\"" "$out"; then continue; fi
  bash "$S/gate.sh" "vS6T4b $corpus r$run $name" || exit 1
  python3 -I "$S/bench.py" bench "$library" "$index" "$V/q/$corpus.json" "$name" "$run" "$out" || exit 2
done
echo "done $corpus r$run $(date +%T)"
