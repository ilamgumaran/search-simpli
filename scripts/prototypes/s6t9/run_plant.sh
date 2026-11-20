#!/bin/bash
# S6-T9 ruling 7: one plant (plants_sites.py NAME) in a fresh git archive of COMMIT (default f9b3489) with its own
# Zig caches; the planted tree diffed against an unplanted archive first (a plant that changes nothing stops here);
# then Debug `zig build test --summary all`. Up to two names: run side by side, then wait for both.
#   run_plant.sh NAME [NAME]      (the name `unplanted` runs the archive as it is)
# SITES (the work folder) defaults to the task's scratch; it must hold `none/` (an unplanted archive of COMMIT).
set -u
unset SEARCH_SIMPLI_LIBRARY_PATH
export PATH=$HOME/development/zig/zig-0.16.0-macos-aarch64:$PATH
W=$HOME/workspace/repos/search-simpli-wt/S6-T9
V=${SITES:-$HOME/workspace/repos/search-simpli-wt/S6-T9-scratch/sites.noindex}
[ $# -ge 1 ] && [ $# -le 2 ] || { echo "one or two names"; exit 2; }
one() {
  name=$1
  tree=$V/src/$name
  if [ -d "$tree" ]; then echo "$name: copy exists, not reused"; return 5; fi
  mkdir -p "$tree" "$V/out" "$V/diff" "$V/tmp"
  git -C "$W" archive "${COMMIT:-f9b3489}" | tar -x -C "$tree"
  if [ "$name" = unplanted ]; then nd=0; else
    python3 -I "$W/scripts/prototypes/s6t9/plants_sites.py" "$tree" "$name" > /dev/null || { echo "$name: plant failed"; return 3; }
    diff -ru "$V/none/zig/src" "$tree/zig/src" > "$V/diff/$name.diff"
    nd=$(grep -c '^[-+][^-+]' "$V/diff/$name.diff")
    if [ "$nd" = 0 ]; then echo "$name: NOT PLANTED"; return 4; fi
  fi
  mkdir -p "$V/cache/$name/g" "$V/cache/$name/l"
  (cd "$tree/zig" && TMPDIR=$V/tmp zig build test --global-cache-dir "$V/cache/$name/g" --cache-dir "$V/cache/$name/l" --summary all > "$V/out/$name.txt" 2>&1)
  echo "$name exit=$? changed-lines=$nd | $(grep -E 'run test [0-9]' "$V/out/$name.txt" | head -1 | sed 's/^[^r]*//')"
}
for n in "$@"; do one "$n" > "$V/res-$n.txt" 2>&1 & done
wait
for n in "$@"; do cat "$V/res-$n.txt"; done
