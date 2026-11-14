#!/bin/bash
# S5-T12 Phase 1 rounds: 8 rounds, the four libraries in a rotated order
# (each in each position twice), one process per library per round, the
# gate before every start. Usage: run.sh RUN_NAME. A refusal stops the run
# (nothing more is timed); the run's file is then incomplete and not used.
set -u
unset SEARCH_SIMPLI_LIBRARY_PATH
S="$(cd "$(dirname "$0")" && pwd)"
name="$1"
out="$S/$name.jsonl"
[ -e "$out" ] && { echo "exists: $out"; exit 2; }
variants=(main main2 proto noview)
for r in 1 2 3 4 5 6 7 8; do
  shift_by=$(( (r - 1) % 4 ))
  for i in 0 1 2 3; do
    v="${variants[$(( (i + shift_by) % 4 ))]}"
    "$S/gate.sh" "$name r$r $v" || { echo "REFUSED at $name r$r $v"; echo "{\"refused\": \"r$r $v\"}" >> "$out"; exit 1; }
    python3 -I "$S/bench.py" "$S/$v/zig/zig-out/lib/aarch64-macos/libsearch_simpli.dylib" "$S/idx10k-fn" "$v" "$r" "$out" || exit 3
  done
done
echo "complete: $out"
