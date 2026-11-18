#!/bin/bash
# S6-T8: one run of S6-T4's query/find bench (bench.py bench, unchanged) over
# one corpus: five libraries in the order ORDERS gives for RUN, S6-T4's load
# gate before each. Each library opens its own copy of the index
# (INDEXES/<name>/<corpus>; the head's copy is the index the head wrote, the
# others' copies of the index `main` wrote).
#   run_queries.sh CORPUS RUN ORDERS LIBS_DIR HEAD_LIB INDEXES QUERIES OUT.jsonl
# LIBS_DIR/<name>/libsearch_simpli.dylib for main, main2, ctl1, ctl2.
set -u
corpus="$1"; run="$2"; orders="$3"; libs="$4"; head_lib="$5"; indexes="$6"; queries="$7"; out="$8"
here="$(cd "$(dirname "$0")" && pwd)"
export GATES="${GATES:-$(dirname "$out")/gates.txt}"
order=$(grep "^run$run:" "$orders" | cut -d: -f2)
[ -n "$order" ] || { echo "no order for run $run"; exit 3; }
for name in $order; do
  if [ "$name" = head ]; then lib="$head_lib"; else lib="$libs/$name/libsearch_simpli.dylib"; fi
  bash "$here/../s6t4/gate.sh" "s6t8 query $corpus r$run $name" > /dev/null || exit 1
  python3 -I "$here/../s6t4/bench.py" bench "$lib" "$indexes/$name/$corpus" "$queries" "$name" "$run" "$out" > /dev/null || exit 2
done
echo "done $corpus r$run"
