#!/bin/bash
# S6-T4 Phase 1: one run of every variant on one corpus, rotated by RUN.
#   run.sh SCRATCH CORPUS RUN OUT.jsonl
# SCRATCH holds main/ (today's library), proto/out-{eager,lazy}/ (the
# prototype's), idx/v2/CORPUS and idx/v3/CORPUS, and q/CORPUS.json. Before
# every variant the load gate (gate.sh, S5-T12's: the app check lock absent,
# the 5-minute load at most 4.0, no toolchain in the top eight) must pass;
# a refused gate stops the run (exit 1); a rerun resumes it. One bench
# process per variant.
set -u
scratch="$1"; corpus="$2"; run="$3"; out="$4"
here="$(cd "$(dirname "$0")" && pwd)"
gate="$here/gate.sh"
main_lib="$scratch/main/lib/lib/aarch64-macos/libsearch_simpli.dylib"
eager_lib="$scratch/proto/out-eager/lib/aarch64-macos/libsearch_simpli.dylib"
lazy_lib="$scratch/proto/out-lazy/lib/aarch64-macos/libsearch_simpli.dylib"
queries="$scratch/q/$corpus.json"
v2="$scratch/idx/v2/$corpus"
v3="$scratch/idx/v3/$corpus"
# name|library|index|knobs
variants=(
  "today|$main_lib|$v2|"
  "today-b|$main_lib|$v2|"
  "eager-v3|$eager_lib|$v3|"
  "lazy-nocache|$lazy_lib|$v3|SS_PROTO_CACHE_BYTES=0"
  "lazy-1mib|$lazy_lib|$v3|SS_PROTO_CACHE_BYTES=1048576"
  "lazy-keep|$lazy_lib|$v3|"
  "lazy-all|$lazy_lib|$v3|SS_PROTO_LAZY_ALL=1"
  "lazy-checked|$lazy_lib|$v3|SS_PROTO_LAZY_VALIDATE=1"
)
n=${#variants[@]}
for ((k = 0; k < n; k++)); do
  IFS='|' read -r name lib index knobs <<< "${variants[$(( (k + run) % n ))]}"
  # Resume: a variant this run already measured is not measured again.
  if [ -f "$out" ] && grep -qF "\"variant\": \"$name\", \"round\": $run, \"index\": \"$index\"" "$out"; then continue; fi
  GATES_LABEL="s6t4 $corpus r$run $name"
  bash "$gate" "$GATES_LABEL" || exit 1
  # shellcheck disable=SC2086
  python3 -I "$here/bench.py" bench "$lib" "$index" "$queries" "$name" "$run" "$out" $knobs || exit 2
done
