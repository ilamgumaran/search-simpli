#!/bin/bash
# S5-T12: the first-query bound, six rounds, (main, main2, final) rotated by
# one each round, the gate before every start, a refusal ends the run.
# Usage: runfirst.sh RUN_NAME.
set -u
unset SEARCH_SIMPLI_LIBRARY_PATH
S="$(cd "$(dirname "$0")" && pwd)"
name="$1"
out="$S/$name.jsonl"
[ -e "$out" ] && { echo "exists: $out"; exit 2; }
variants=(main main2 final)
for r in 1 2 3 4 5 6; do
  shift_by=$(( (r - 1) % 3 ))
  for i in 0 1 2; do
    v="${variants[$(( (i + shift_by) % 3 ))]}"
    "$S/gate.sh" "$name r$r $v" || { echo "REFUSED at $name r$r $v"; echo "{\"refused\": \"r$r $v\"}" >> "$out"; exit 1; }
    python3 -I "$S/firstq.py" "$S/$v/zig/zig-out/lib/aarch64-macos/libsearch_simpli.dylib" "$S/idx10k-fn" "$v" "$r" filename "$out" || exit 3
  done
done
echo "complete: $out"
