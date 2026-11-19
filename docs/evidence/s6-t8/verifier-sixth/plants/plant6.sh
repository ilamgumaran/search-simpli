#!/bin/bash
# S6-T8 verifier (sixth check): one plant in a fresh git archive of 965cce7 with its own Zig caches; Debug zig build test.
# Before the build, the planted tree is diffed against an unplanted archive (src.noindex/suite6) and the diff kept,
# so a plant that changed nothing is seen. plant6.sh NAME   (NAME none = the unplanted baseline;
# b-* = the builder's sweep plant, applied by its own plants_bounds.py from my archive)
set -u
unset SEARCH_SIMPLI_LIBRARY_PATH
export PATH=$HOME/development/zig/zig-0.16.0-macos-aarch64:$PATH
V=$HOME/workspace/repos/search-simpli-wt/S6-T8-vscratch
name=$1
tree=$V/plants6.noindex/src/$name
mkdir -p $V/plants6/out $V/plants6/diff $V/tmp
if [ ! -d $tree ]; then
  mkdir -p $tree
  git -C $HOME/workspace/repos/search-simpli-wt/S6-T8 archive 965cce7 | tar -x -C $tree
  case $name in
    none) ;;
    b-*) python3 -I $V/src.noindex/suite6/scripts/prototypes/s6t8/plants_bounds.py $tree $name || exit 3 ;;
    *) python3 -I $V/plants/plants6.py $tree $name || exit 3 ;;
  esac
fi
diff -ru $V/src.noindex/suite6/zig/src $tree/zig/src > $V/plants6/diff/$name.diff
nd=$(grep -c '^[-+][^-+]' $V/plants6/diff/$name.diff)
if [ $name != none ] && [ "$nd" = 0 ]; then echo "$name: NOT PLANTED (no source change)"; exit 4; fi
mkdir -p $V/plants6.noindex/cache/$name/g $V/plants6.noindex/cache/$name/l
export TMPDIR=$V/tmp
cd $tree/zig
s=$(date +%s)
zig build test --global-cache-dir $V/plants6.noindex/cache/$name/g --cache-dir $V/plants6.noindex/cache/$name/l --summary all > $V/plants6/out/$name.txt 2>&1
rc=$?
sum=$(grep -E "tests? passed|Build Summary" $V/plants6/out/$name.txt | tail -1)
echo "$name exit=$rc changed-lines=$nd $(( $(date +%s)-s ))s | $sum"
