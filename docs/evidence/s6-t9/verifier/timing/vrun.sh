#!/bin/bash
# S6-T9 verifier: one phase of one timed run.  vrun.sh RUN PHASE [CORPORA]   (RUN 1..5; PHASE q or u)
#  q : bench.py bench (warm query and find p50, open p50 of 30, memory after open, first content query and find, first
#      filename and first both query), each build on its OWN copy of its index (idx.noindex/oc/<build>/<corpus>), the
#      S6-T8 committed query sets, six corpora, the libraries in the run's written order.
#  u : upd.py, each build's own searchd, 3 trials: first publish from main's format, one-file update, unchanged update;
#      four corpora, the builds in the run's written u order.
# The gate before every process; a refused gate stops the phase (exit 1); rerunning skips what is done.
set -u
unset SEARCH_SIMPLI_LIBRARY_PATH
V=$HOME/workspace/repos/search-simpli-wt/S6-T9-vscratch
T=$V/tim
export GATES=$T/gates.txt
run=$1; phase=$2; only="${3:-}"
order=$(grep "^run$run$phase:" $T/orders.txt | cut -d: -f2)
[ -n "$order" ] || { echo "no order for run $run $phase"; exit 3; }
echo "$(date '+%F %T') start run$run $phase $only" >> $T/runlog.txt
case $phase in
q) for c in j2 family fixtures timing-10k prose-10k tamil-10k; do [ -n "$only" ] && [[ " $only " != *" $c "* ]] && continue; for name in $order; do
     out=$T/q-run$run.jsonl; index=$V/idx.noindex/oc/$name/$c
     if [ -f $out ] && grep -qF "\"variant\": \"$name\", \"round\": $run, \"index\": \"$index\"" $out; then continue; fi
     bash $T/gate.sh "vS6T9 q $c r$run $name" > /dev/null || { echo "gate refused q $c $name"; echo "$(date '+%F %T') gate-stop run$run $phase" >> $T/runlog.txt; exit 1; }
     python3 -I $T/bench.py bench $V/libs/$name/libsearch_simpli.dylib $index $T/q/$c.json $name $run $out > /dev/null || exit 2
   done; done;;
u) for c in timing-10k prose-10k tamil-10k family; do [ -n "$only" ] && [[ " $only " != *" $c "* ]] && continue; for name in $order; do
     out=$T/u-run$run.jsonl
     if [ -f $out ] && grep -qF "\"variant\": \"$name\", \"corpus\": \"$c\", \"run\": \"$run\"," $out; then continue; fi
     [ -e $V/work.noindex/r$run/$name-$c ] && { echo "stale work dir r$run/$name-$c"; exit 4; }
     bash $T/gate.sh "vS6T9 u $c r$run $name" > /dev/null || { echo "gate refused u $c $name"; echo "$(date '+%F %T') gate-stop run$run $phase" >> $T/runlog.txt; exit 1; }
     python3 -I $T/upd.py $V $name $c 3 $run $out > /dev/null || exit 2
   done; done;;
esac
echo "$(date '+%F %T') end run$run $phase $only" >> $T/runlog.txt
echo "done run$run $phase $(date +%T)"
