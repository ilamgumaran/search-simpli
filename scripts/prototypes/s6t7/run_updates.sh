#!/bin/bash
# S6-T7 Phase 2: migrate.py over one corpus, main's searchd and this
# branch's on copies of main's index, in the order main, head, head, main,
# each behind S6-T4's load gate.
#   run_updates.sh MAIN_SEARCHD HEAD_SEARCHD MAIN_INDEX CORPUS ROUNDS WORK OUT.jsonl
# WORK must not exist. A refused gate stops (exit 1).
set -u
main="$1"; head="$2"; index="$3"; corpus="$4"; rounds="$5"; work="$6"; out="$7"
here="$(cd "$(dirname "$0")" && pwd)"
export GATES="${GATES:-$(dirname "$out")/gates.txt}"
k=0
for v in main head head main; do
  bash "$here/../s6t4/gate.sh" "s6t7 update $(basename "$index") $v $k" > /dev/null || exit 1
  if [ "$v" = main ]; then searchd="$main"; else searchd="$head"; fi
  result="$(python3 -I "$here/migrate.py" "$searchd" "$index" "$corpus" "$work/$k-$v" "$rounds")" || exit 2
  echo "{\"variant\": \"$v\", \"set\": $k, \"corpus\": \"$(basename "$index")\", \"result\": $result}" >> "$out"
  k=$((k + 1))
done
