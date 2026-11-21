#!/bin/bash
# S6-T18: one timed run (ruling 4) of qbench.py: every corpus of the run in the order ORDERS gives (`corpora<N>:`),
# and in each every build in the order it gives (`run<N>:`), S6-T4's load gate before each process. A refused gate
# stops the run (exit 1); it is not retried here.
#   run_timing.sh RUN ORDERS BINS INDEXES QUERIES_DIR OUT_DIR
# BINS/bin-<build>/bin/searchd; INDEXES/<build>/<corpus>; QUERIES_DIR/<corpus>.json. Rows go to OUT_DIR/run<RUN>.jsonl,
# gates to OUT_DIR/gates.txt.
set -u
run="$1"; orders="$2"; bins="$3"; indexes="$4"; queries="$5"; out="$6"
here="$(cd "$(dirname "$0")" && pwd)"
export GATES="$out/gates.txt"
builds=$(grep "^run$run:" "$orders" | cut -d: -f2)
corpora=$(grep "^corpora$run:" "$orders" | cut -d: -f2)
[ -n "$builds" ] && [ -n "$corpora" ] || { echo "no order for run $run"; exit 3; }
echo "run $run start $(date '+%Y-%m-%d %H:%M:%S')"
for corpus in $corpora; do
  for name in $builds; do
    bash "$here/../s6t4/gate.sh" "s6t18 r$run $corpus $name" > /dev/null || { echo "run $run: gate refused before $corpus $name"; exit 1; }
    python3 -I "$here/qbench.py" "$bins/bin-$name/bin/searchd" "$indexes/$name/$corpus" "$queries/$corpus.json" \
      "$name" "$corpus" "$run" "$out/run$run.jsonl" || exit 2
  done
done
echo "run $run end $(date '+%Y-%m-%d %H:%M:%S')"
