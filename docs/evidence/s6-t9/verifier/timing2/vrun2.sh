#!/bin/bash
# S6-T9 verifier, timing set 2: one gated run on timing-10k.   vrun2.sh RUN   (RUN 1..5, or 1b.. for a retake)
# The builds one at a time in orders2.txt's order for the run's number; tim/bench.py unchanged; the gate before the
# run and before every build process; a refused gate stops the run (exit 1) and the run is discarded whole.
set -u
unset SEARCH_SIMPLI_LIBRARY_PATH
V=$HOME/workspace/repos/search-simpli-wt/S6-T9-vscratch
T=$V/tim2
export GATES=$T/gates.txt
run=$1; num=${run%b}
order=$(grep "^run${num}q:" $T/orders2.txt | cut -d: -f2)
[ -n "$order" ] || { echo "no order for run $run"; exit 3; }
out=$T/q-run$run.jsonl
[ -e $out ] && { echo "q-run$run.jsonl exists: a retake takes a new name"; exit 4; }
bash $V/tim/gate.sh "vS6T9 set2 r$run pre" || { echo "$(date '+%F %T') gate-closed-before run$run" >> $T/runlog.txt; exit 1; }
echo "$(date '+%F %T') start run$run set2" >> $T/runlog.txt
for name in $order; do
  bash $V/tim/gate.sh "vS6T9 set2 r$run $name" > /dev/null || { echo "gate refused $name"; echo "$(date '+%F %T') gate-stop run$run set2" >> $T/runlog.txt; exit 1; }
  python3 -I $V/tim/bench.py bench $V/libs/$name/libsearch_simpli.dylib $V/idx.noindex/oc/$name/timing-10k $V/tim/q/timing-10k.json $name $num $out > /dev/null || exit 2
done
echo "$(date '+%F %T') end run$run set2" >> $T/runlog.txt
bash $T/sleepcheck2.sh $run | tee -a $T/sleepcheck.txt
echo "done run$run $(date +%T)"
