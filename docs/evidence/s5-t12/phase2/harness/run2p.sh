#!/bin/bash
# S5-T12 Phase 2 rounds: as run.sh (8 rounds, the four libraries rotated by
# one each round, the gate before every start, a refusal ends the run), with
# main, main2, part1 (the check alone) and part2 (the check and the lazy
# view: the branch's engine). Usage: run2p.sh RUN_NAME.
set -u
unset SEARCH_SIMPLI_LIBRARY_PATH
S="$(cd "$(dirname "$0")" && pwd)"
name="$1"
out="$S/$name.jsonl"
[ -e "$out" ] && { echo "exists: $out"; exit 2; }
variants=(${VARIANTS:-main main2 part1 part2})
for r in 1 2 3 4 5 6 7 8; do
  shift_by=$(( (r - 1) % 4 ))
  for i in 0 1 2 3; do
    v="${variants[$(( (i + shift_by) % 4 ))]}"
    "$S/gate.sh" "$name r$r $v" || { echo "REFUSED at $name r$r $v"; echo "{\"refused\": \"r$r $v\"}" >> "$out"; exit 1; }
    python3 -I "$S/bench2.py" "$S/$v/zig/zig-out/lib/aarch64-macos/libsearch_simpli.dylib" "$S/idx10k-fn" "$S/idx10k-2r" "$v" "$r" "$out" || exit 3
  done
done
echo "complete: $out"
