#!/bin/bash
# S6-T8 verifier: one phase of one timed run. vrun.sh RUN PHASE [CORPORA]   (PHASE: q o2 u; CORPORA splits a phase
#  into commands under 10 minutes, default all of the phase's corpora, always in the phase's order)
#  q : S6-T4 bench.py bench (query, find, open, memory, first query/find), each build its OWN copy of its index
#      (idx.noindex/oc/<build>/<corpus>), the builder's committed query sets (339 find cells), six corpora.
#  o2: openx2.py, six pairs interleaved in one process, each its own index copy, 200 rounds.
#  u : upd.py, first publish from main's format and a one-file update, each build's own searchd, 3 trials, four corpora.
set -u
unset SEARCH_SIMPLI_LIBRARY_PATH
V=$HOME/workspace/repos/search-simpli-wt/S6-T8-vscratch
T=$V/tim
export GATES=$T/gates.txt
run=$1; phase=$2; only="${3:-}"
order=$(grep "^run$run:" $T/orders.txt | cut -d: -f2)
[ -n "$order" ] || { echo "no order for run $run"; exit 3; }
echo "$(date '+%F %T') start run$run $phase $only" >> $T/runlog.txt
case $phase in
q) for c in j2 family fixtures timing-10k prose-10k tamil-10k; do [ -n "$only" ] && [[ " $only " != *" $c "* ]] && continue; for name in $order; do
     out=$T/q-run$run.jsonl; index=$V/idx.noindex/oc/$name/$c
     if [ -f $out ] && grep -qF "\"variant\": \"$name\", \"round\": $run, \"index\": \"$index\"" $out; then continue; fi
     bash $T/gate.sh "vS6T8 q $c r$run $name" > /dev/null || { echo "gate refused q $c $name"; exit 1; }
     python3 -I $T/bench.py bench $V/libs/$name/libsearch_simpli.dylib $index $T/q/$c.json $name $run $out > /dev/null || exit 2
   done; done;;
o2) k=0; for c in j2 family fixtures timing-10k prose-10k tamil-10k; do k=$((k+1)); [ -n "$only" ] && [[ " $only " != *" $c "* ]] && continue
     out=$T/o2-run$run.jsonl
     if [ -f $out ] && grep -qF "\"run\": $run, \"corpus\": \"$c\"" $out; then continue; fi
     bash $T/gate.sh "vS6T8 o2 $c r$run" > /dev/null || { echo "gate refused o2 $c"; exit 1; }
     python3 -I $T/openx2.py $V $c 200 $((3000*run+k)) $run $out > /dev/null || exit 2
   done;;
u) for c in timing-10k prose-10k tamil-10k family; do [ -n "$only" ] && [[ " $only " != *" $c "* ]] && continue; for name in $order; do
     out=$T/u-run$run.jsonl
     if [ -f $out ] && grep -qF "\"variant\": \"$name\", \"corpus\": \"$c\", \"run\": $run," $out; then continue; fi
     [ -e $V/work.noindex/r$run/$name-$c ] && { echo "stale work dir r$run/$name-$c"; exit 4; }
     bash $T/gate.sh "vS6T8 u $c r$run $name" > /dev/null || { echo "gate refused u $c $name"; exit 1; }
     python3 -I $T/upd.py $V $name $c 3 $run $out > /dev/null || exit 2
   done; done;;
esac
echo "$(date '+%F %T') end run$run $phase $only" >> $T/runlog.txt
echo "done run$run $phase $(date +%T)"
