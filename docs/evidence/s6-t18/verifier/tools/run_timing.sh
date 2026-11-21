#!/bin/bash
# S6-T18 verifier: one timed run, as the builder's scripts/prototypes/s6t18/run_timing.sh: every corpus of the run in
# the order ORDERS gives (`corpora<N>:`), in each every build in the order it gives (`run<N>:`), S6-T4's load gate
# (scripts/prototypes/s6t4/gate.sh) before each qbench.py process. A refused gate stops the run (exit 1); no retry.
#   run_timing.sh RUN ORDERS BINS INDEXES QUERIES_DIR OUT_DIR GATE_SH
set -u
run="$1"; orders="$2"; bins="$3"; indexes="$4"; queries="$5"; out="$6"; gate="$7"
here="$(cd "$(dirname "$0")" && pwd)"
export GATES="$out/gates.txt"
builds=$(grep "^run$run:" "$orders" | cut -d: -f2)
corpora=$(grep "^corpora$run:" "$orders" | cut -d: -f2)
[ -n "$builds" ] && [ -n "$corpora" ] || { echo "no order for run $run"; exit 3; }
echo "run $run start $(date '+%Y-%m-%d %H:%M:%S')"
for corpus in $corpora; do
  for name in $builds; do
    bash "$gate" "s6t18-verifier r$run $corpus $name" > /dev/null || { echo "run $run: gate refused before $corpus $name"; exit 1; }
    python3 -I "$here/qbench.py" "$bins/bin-$name/bin/searchd" "$indexes/$name/$corpus" "$queries/$corpus.json" \
      "$name" "$corpus" "$run" "$out/run$run.jsonl" || exit 2
  done
done
echo "run $run end $(date '+%Y-%m-%d %H:%M:%S')"
