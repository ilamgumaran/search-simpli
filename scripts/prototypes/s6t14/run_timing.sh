#!/bin/bash
# S6-T14: one timed run (ruling 5) of scripts/prototypes/s6t9/bench.py bench: every corpus of the run in the
# order ORDERS gives (`corpora<N>:`), and in each every build in the order it gives (`run<N>:`), this folder's
# load gate (gate.sh) before each process. A refused gate stops the run (exit 1); it is not retried here.
#   run_timing.sh RUN ORDERS LIBS_DIR INDEXES QUERIES_DIR OUT_DIR
# LIBS_DIR/<build>/libsearch_simpli.dylib; INDEXES/<build>/<corpus> (each build its own copy of the index);
# QUERIES_DIR/<corpus>.json (bench.py queries). Rows go to OUT_DIR/query-run<RUN>.jsonl, gates to OUT_DIR/gates.txt.
set -u
run="$1"; orders="$2"; libs="$3"; indexes="$4"; queries="$5"; out="$6"
here="$(cd "$(dirname "$0")" && pwd)"
export GATES="$out/gates.txt"
builds=$(grep "^run$run:" "$orders" | cut -d: -f2)
corpora=$(grep "^corpora$run:" "$orders" | cut -d: -f2)
[ -n "$builds" ] && [ -n "$corpora" ] || { echo "no order for run $run"; exit 3; }
echo "run $run start $(date '+%Y-%m-%d %H:%M:%S')"
for corpus in $corpora; do
  for name in $builds; do
    bash "$here/gate.sh" "s6t14 r$run $corpus $name" > /dev/null || { echo "run $run: gate refused before $corpus $name"; exit 1; }
    python3 -I "$here/../s6t9/bench.py" bench "$libs/$name/libsearch_simpli.dylib" "$indexes/$name/$corpus" \
      "$queries/$corpus.json" "$name" "$run" "$out/query-run$run.jsonl" > /dev/null || exit 2
  done
done
echo "run $run end $(date '+%Y-%m-%d %H:%M:%S')"
