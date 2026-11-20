#!/bin/bash
# S6-T13: one timed run of the open on the three 10k corpora, in the order orders.txt fixes for run N.
#   run_open.sh N TIM_DIR OUT.jsonl
# TIM_DIR holds libs/<build>/libsearch_simpli.dylib and idx.noindex/<build>/<corpus> (each build its own copy).
# The gate before every process; a refused gate stops the run (exit 1).
set -u
n="$1"; tim="$2"; out="$3"
here="$(cd "$(dirname "$0")" && pwd)"
export GATES="${GATES:-$(dirname "$out")/gates.txt}"
line="$(grep "^run$n " "$here/orders.txt")" || { echo "no order for run $n"; exit 2; }
corpora="$(echo "$line" | sed 's/.*corpora: \([^|]*\) |.*/\1/')"
builds="$(echo "$line" | sed 's/.*builds: //')"
echo "run$n start $(date '+%Y-%m-%d %H:%M:%S') corpora: $corpora builds: $builds"
for c in $corpora; do
  for b in $builds; do
    bash "$here/gate.sh" "s6t13 open run$n $c $b" > /dev/null || { echo "gate refused before run$n $c $b"; exit 1; }
    python3 -I "$here/open_bench.py" "$tim/libs/$b/libsearch_simpli.dylib" "$tim/idx.noindex/$b/$c" "$b" "$c" "$n" "$out" || exit 2
  done
done
echo "run$n end $(date '+%Y-%m-%d %H:%M:%S')"
