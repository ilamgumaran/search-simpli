#!/bin/bash
# S6-T10 verifier: one ruling-2 plant in a fresh `git archive` of 4d18ccb with its own global and local
# Zig caches, the planted zig/src diffed against an unplanted archive, then Debug `zig build test`.
# zig_plant.sh NAME
set -u
unset SEARCH_SIMPLI_LIBRARY_PATH
export PATH="$HOME/development/zig/zig-0.16.0-macos-aarch64:$PATH"
V="$HOME/workspace/repos/search-simpli-wt/S6-T10-vscratch/second"
W="$HOME/workspace/repos/search-simpli-wt/S6-T10"
NAME="$1"
D="$V/zp.noindex/$NAME"
OUT="$V/ev/zig-plants/$NAME.txt"
mkdir -p "$V/ev/zig-plants"
if [ -e "$D" ]; then echo "copy $NAME exists already" >&2; exit 2; fi
mkdir -p "$D/src" "$D/gcache" "$D/lcache"
git -C "$W" archive 4d18ccb | tar -x -C "$D/src"
if [ ! -d "$V/zp.noindex/ref" ]; then mkdir -p "$V/zp.noindex/ref" && git -C "$W" archive 4d18ccb zig/src | tar -x -C "$V/zp.noindex/ref"; fi
{
  date
  if [ "$NAME" = v-r11-first-only ]; then
    python3 -I "$HOME/workspace/repos/search-simpli-wt/S6-T8-vscratch/plants/plants6.py" "$D/src" "$NAME" || exit 3
  else
    python3 -I "$V/scripts/zig_plants.py" "$D/src" "$NAME" || exit 3
  fi
  echo "--- diff -r ref/zig/src $NAME/src/zig/src"
  diff -r -u "$V/zp.noindex/ref/zig/src" "$D/src/zig/src" | sed -e "s#$V#<vscratch>#g"
  echo "--- zig build test (Debug), own caches"
  (cd "$D/src/zig" && zig build test --summary all --global-cache-dir "$D/gcache" --cache-dir "$D/lcache" 2>&1 | sed -e "s#$V#<vscratch>#g" -e "s#$HOME#<home>#g"; exit ${PIPESTATUS[0]})
  echo "exit $?"
  date
} > "$OUT" 2>&1
grep -E "^(planted|exit)|^error: '|Build Summary|S6-T10 rule 11( v2)?: the|\+- run test [0-9]" "$OUT"
