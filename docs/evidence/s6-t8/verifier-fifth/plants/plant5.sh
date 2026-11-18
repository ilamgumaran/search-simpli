#!/bin/bash
# S6-T8 verifier (fifth check): one plant in a fresh git archive of 284a0e7 with its own Zig caches; Debug zig build test.
# Before the build, the planted tree is diffed against an unplanted archive (src.noindex/suite5) and the diff kept,
# so a plant that changed nothing is seen. plant2.sh NAME   (NAME none = the unplanted baseline)
set -u
unset SEARCH_SIMPLI_LIBRARY_PATH
export PATH=$HOME/development/zig/zig-0.16.0-macos-aarch64:$PATH
V=$HOME/workspace/repos/search-simpli-wt/S6-T8-vscratch
name=$1
tree=$V/plants5.noindex/src/$name
mkdir -p $V/plants5/out $V/plants5/diff $V/tmp
if [ ! -d $tree ]; then
  mkdir -p $tree
  git -C $HOME/workspace/repos/search-simpli-wt/S6-T8 archive 284a0e7 | tar -x -C $tree
  [ $name = none ] || python3 -I $V/plants/plants5.py $tree $name || exit 3
fi
diff -ru $V/src.noindex/suite5/zig/src $tree/zig/src > $V/plants5/diff/$name.diff
nd=$(grep -c '^[-+][^-+]' $V/plants5/diff/$name.diff)
if [ $name != none ] && [ "$nd" = 0 ]; then echo "$name: NOT PLANTED (no source change)"; exit 4; fi
mkdir -p $V/plants5.noindex/cache/$name/g $V/plants5.noindex/cache/$name/l
export TMPDIR=$V/tmp
cd $tree/zig
s=$(date +%s)
zig build test --global-cache-dir $V/plants5.noindex/cache/$name/g --cache-dir $V/plants5.noindex/cache/$name/l --summary all > $V/plants5/out/$name.txt 2>&1
rc=$?
sum=$(grep -E "tests? passed|Build Summary" $V/plants5/out/$name.txt | tail -1)
echo "$name exit=$rc changed-lines=$nd $(( $(date +%s)-s ))s | $sum"
