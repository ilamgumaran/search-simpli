#!/bin/bash
# S6-T7 verifier: one phase of one timed run. vrun.sh RUN PHASE   (PHASE: q r o u)
set -u
unset SEARCH_SIMPLI_LIBRARY_PATH
V=$HOME/workspace/repos/search-simpli-wt/S6-T7-vscratch
T=$V/tim
export GATES=$T/gates.txt
run=$1; phase=$2
order=$(grep "^run$run:" $T/orders.txt | cut -d: -f2)
[ -n "$order" ] || { echo "no order for run $run"; exit 3; }
ix() { if [ "$1" = head ]; then echo $V/idx.noindex/head/$2; else echo $V/idx.noindex/main/$2; fi; }
case $phase in
q) for c in timing-10k prose-10k tamil-10k; do for name in $order; do
     out=$T/q-run$run.jsonl; index=$(ix $name $c)
     if [ -f $out ] && grep -qF "\"variant\": \"$name\", \"round\": $run, \"index\": \"$index\"" $out; then continue; fi
     bash $T/gate.sh "vS6T7 q $c r$run $name" > /dev/null || { echo "gate refused q $c $name"; exit 1; }
     python3 -I $T/bench.py bench $V/libs/$name/libsearch_simpli.dylib $index $T/q/$c.json $name $run $out || exit 2
   done; done;;
r) for c in j2 family fixtures timing-10k prose-10k tamil-10k; do for name in $order; do
     out=$T/r-run$run.jsonl; index=$(ix $name $c)
     if [ -f $out ] && grep -qF "\"variant\": \"$name\", \"run\": $run, \"index\": \"$index\"" $out; then continue; fi
     bash $T/gate.sh "vS6T7 r $c r$run $name" > /dev/null || { echo "gate refused r $c $name"; exit 1; }
     python3 -I $T/rbench.py $V/libs/$name/libsearch_simpli.dylib $index $T/files/$c.json $name $run $out || exit 2
   done; done;;
o) k=0; for c in j2 family fixtures timing-10k prose-10k tamil-10k; do k=$((k+1))
     out=$T/o-run$run.jsonl
     if [ -f $out ] && grep -qF "\"run\": $run, \"corpus\": \"$c\"" $out; then continue; fi
     bash $T/gate.sh "vS6T7 o $c r$run" > /dev/null || { echo "gate refused o $c"; exit 1; }
     python3 -I $T/openx.py $V $c 200 $((1000*run+k)) $run $out || exit 2
   done;;
o2) k=0; for c in j2 family fixtures timing-10k prose-10k tamil-10k; do k=$((k+1))
     out=$T/o2-run$run.jsonl
     if [ -f $out ] && grep -qF "\"run\": $run, \"corpus\": \"$c\"" $out; then continue; fi
     bash $T/gate.sh "vS6T7 o2 $c r$run" > /dev/null || { echo "gate refused o2 $c"; exit 1; }
     python3 -I $T/openx2.py $V $c 200 $((2000*run+k)) $run $out || exit 2
   done;;
u) for c in timing-10k prose-10k tamil-10k family; do for name in $order; do
     out=$T/u-run$run.jsonl
     if [ -f $out ] && grep -qF "\"variant\": \"$name\", \"corpus\": \"$c\", \"run\": $run," $out; then continue; fi
     [ -e $V/work.noindex/$name-$c ] && { echo "stale work dir $name-$c"; exit 4; }
     bash $T/gate.sh "vS6T7 u $c r$run $name" > /dev/null || { echo "gate refused u $c $name"; exit 1; }
     python3 -I $T/upd.py $V $name $c 3 $run $out || exit 2
   done; done;;
esac
echo "done run$run $phase $(date +%T)"
