#!/bin/bash
# S6-T7 Phase 2: bench.py over one corpus, main and head interleaved
# (ROUNDS of main,head,head,main), each run behind S6-T4's load gate.
#   run_bench.sh MAIN_LIB MAIN_INDEX HEAD_LIB HEAD_INDEX ROUNDS OUT.jsonl
# GATES names the gate log (default: beside OUT). A refused gate stops (exit 1).
set -u
main_lib="$1"; main_index="$2"; head_lib="$3"; head_index="$4"; rounds="$5"; out="$6"
here="$(cd "$(dirname "$0")" && pwd)"
export GATES="${GATES:-$(dirname "$out")/gates.txt}"
for ((r = 0; r < rounds; r++)); do
  for v in main head head main; do
    bash "$here/../s6t4/gate.sh" "s6t7 bench $(basename "$head_index") r$r $v" > /dev/null || exit 1
    if [ "$v" = main ]; then lib="$main_lib"; index="$main_index"; else lib="$head_lib"; index="$head_index"; fi
    python3 -I "$here/bench.py" "$lib" "$index" "$v" "$r" "$out" > /dev/null || exit 2
  done
done
