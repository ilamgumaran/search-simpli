#!/bin/bash
# S6-T7 Phase 2: one run of S6-T4's query/find bench (bench.py bench,
# unchanged) over one corpus: five libraries in the order ORDERS gives for
# RUN, S6-T4's gate before each. `main`, `main2` and the controls open the
# index `main` wrote; the head opens the index it wrote (same files).
#   run_queries.sh CORPUS RUN ORDERS LIBS_DIR HEAD_LIB MAIN_INDEX HEAD_INDEX QUERIES OUT.jsonl
# LIBS_DIR/<name>/libsearch_simpli.dylib for main, main2, ctl1, ctl2.
set -u
corpus="$1"; run="$2"; orders="$3"; libs="$4"; head_lib="$5"; main_index="$6"; head_index="$7"; queries="$8"; out="$9"
here="$(cd "$(dirname "$0")" && pwd)"
export GATES="${GATES:-$(dirname "$out")/gates.txt}"
order=$(grep "^run$run:" "$orders" | cut -d: -f2)
[ -n "$order" ] || { echo "no order for run $run"; exit 3; }
for name in $order; do
  if [ "$name" = head ]; then lib="$head_lib"; index="$head_index"; else lib="$libs/$name/libsearch_simpli.dylib"; index="$main_index"; fi
  bash "$here/../s6t4/gate.sh" "s6t7 query $corpus r$run $name" > /dev/null || exit 1
  python3 -I "$here/../s6t4/bench.py" bench "$lib" "$index" "$queries" "$name" "$run" "$out" > /dev/null || exit 2
done
echo "done $corpus r$run"
