#!/bin/bash
# S6-T9: one run of bench.py bench (S6-T4's, with the first file-name and
# `both` query cells) over one corpus: five libraries in the order ORDERS
# gives for RUN, S6-T4's load gate before each. Each library opens its own
# copy of the index: INDEXES/<variant>/<corpus> (main, main2 and the
# controls copies of main's index; head a copy of the index it wrote).
#   run_queries.sh CORPUS RUN ORDERS LIBS_DIR INDEXES QUERIES OUT.jsonl
# LIBS_DIR/<variant>/libsearch_simpli.dylib for every variant in ORDERS.
set -u
corpus="$1"; run="$2"; orders="$3"; libs="$4"; indexes="$5"; queries="$6"; out="$7"
here="$(cd "$(dirname "$0")" && pwd)"
export GATES="${GATES:-$(dirname "$out")/gates.txt}"
order=$(grep "^run$run:" "$orders" | cut -d: -f2)
[ -n "$order" ] || { echo "no order for run $run"; exit 3; }
for name in $order; do
  bash "$here/../s6t4/gate.sh" "s6t9 query $corpus r$run $name" > /dev/null || exit 1
  python3 -I "$here/bench.py" bench "$libs/$name/libsearch_simpli.dylib" "$indexes/$name/$corpus" "$queries" "$name" "$run" "$out" > /dev/null || exit 2
done
echo "done $corpus r$run"
