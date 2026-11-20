#!/bin/bash
# S6-T13 verifier: timed run N in the order of orders.txt.   vrun.sh N VSCRATCH OUTDIR
# The gate before every process; a refusal stops the run (exit 1).
set -u
n=$1; V=$2; O=$3; here="$(cd "$(dirname "$0")" && pwd)"; export GATES=$O/gates.txt
line="$(grep "^run$n " "$here/../timing/orders.txt")" || exit 2
corpora="$(echo "$line" | sed 's/.*corpora: \([^|]*\) |.*/\1/')"; builds="$(echo "$line" | sed 's/.*builds: //')"
echo "run$n start $(date '+%F %T')" >> $O/windows.txt
for c in $corpora; do for b in $builds; do
  bash $here/vgate.sh "run$n $c $b" || { echo "run$n refused at $c $b $(date '+%F %T')" >> $O/windows.txt; exit 1; }
  python3 -I $here/vopen.py $V/libs/$b/libsearch_simpli.dylib $V/idx.noindex/$b/$c $b $c $n $O/open.jsonl || exit 3
done; done
echo "run$n end $(date '+%F %T')" >> $O/windows.txt
