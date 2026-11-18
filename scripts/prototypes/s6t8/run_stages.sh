#!/bin/bash
# S6-T8 (rulings on the Report, item 1a): stages.py over one corpus, main's
# searchd and this branch's on copies of main's index, in the order ORDERS
# gives for stg-run<RUN> (written before the first run), each set behind
# S6-T4's load gate.
#   run_stages.sh RUN ORDERS MAIN_SEARCHD HEAD_SEARCHD MAIN_INDEX CORPUS ROUNDS WORK OUT.jsonl
# WORK must not exist. A refused gate stops (exit 1).
set -u
run="$1"; orders="$2"; main="$3"; head="$4"; index="$5"; corpus="$6"; rounds="$7"; work="$8"; out="$9"
here="$(cd "$(dirname "$0")" && pwd)"
export GATES="${GATES:-$(dirname "$out")/gates.txt}"
order=$(grep "^stg-run$run:" "$orders" | cut -d: -f2)
[ -n "$order" ] || { echo "no order for stg-run $run"; exit 3; }
k=0
for v in $order; do
  bash "$here/../s6t4/gate.sh" "s6t8 stages $(basename "$index") r$run $v $k" > /dev/null || exit 1
  if [ "$v" = main ]; then searchd="$main"; else searchd="$head"; fi
  result="$(python3 -I "$here/stages.py" "$searchd" "$index" "$corpus" "$work/$k-$v" "$rounds")" || exit 2
  echo "{\"variant\": \"$v\", \"run\": \"$run\", \"set\": $k, \"corpus\": \"$(basename "$index")\", \"result\": $result}" >> "$out"
  k=$((k + 1))
done
echo "done $(basename "$index") stg-run$run"
