#!/bin/bash
# Verifier: S5-T8 first-query bound, 10 rounds, main main2 ctl1 ctl2 head2 rotated
# by one each round, the gate before every start, both snapshots per start.
set -u
unset SEARCH_SIMPLI_LIBRARY_PATH
S="$(cd "$(dirname "$0")" && pwd)"
name="$1"
out="$S/$name.jsonl"
[ -e "$out" ] && { echo "exists: $out"; exit 2; }
variants=(main main2 ctl1 ctl2 head2)
for r in 1 2 3 4 5 6 7 8 9 10; do
  shift_by=$(( (r - 1) % 5 ))
  for i in 0 1 2 3 4; do
    v="${variants[$(( (i + shift_by) % 5 ))]}"
    "$S/gate.sh" "$name r$r $v" || { echo "REFUSED at $name r$r $v"; echo "{\"refused\": \"r$r $v\"}" >> "$out"; exit 1; }
    python3 -I "$S/vfirst.py" "$S/lib/$v/libsearch_simpli.dylib" "$S/../idx10k-fn" "$v" "$r" filename "$out" || exit 3
    python3 -I "$S/vfirst.py" "$S/lib/$v/libsearch_simpli.dylib" "$S/../idx10k-plain" "$v" "$r" plain "$out" || exit 3
  done
done
echo "complete: $out"
