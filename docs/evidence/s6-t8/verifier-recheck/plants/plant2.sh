#!/bin/bash
# S6-T8 verifier (recheck): one plant in a fresh git archive of fa61957 with its own Zig caches; Debug zig build test.
# Before the build, the planted tree is diffed against an unplanted archive (src.noindex/head2) and the diff kept,
# so a plant that changed nothing is seen. plant2.sh NAME   (NAME none = the unplanted baseline)
set -u
unset SEARCH_SIMPLI_LIBRARY_PATH
export PATH=$HOME/development/zig/zig-0.16.0-macos-aarch64:$PATH
V=$HOME/workspace/repos/search-simpli-wt/S6-T8-vscratch
name=$1
tree=$V/plants2.noindex/src/$name
mkdir -p $V/plants2/out $V/plants2/diff $V/tmp
if [ ! -d $tree ]; then
  mkdir -p $tree
  git -C $HOME/workspace/repos/search-simpli-wt/S6-T8 archive fa61957 | tar -x -C $tree
  [ $name = none ] || python3 -I $V/plants/plants2.py $tree $name || exit 3
fi
diff -ru $V/src.noindex/head2/zig/src $tree/zig/src > $V/plants2/diff/$name.diff
nd=$(grep -c '^[-+][^-+]' $V/plants2/diff/$name.diff)
if [ $name != none ] && [ "$nd" = 0 ]; then echo "$name: NOT PLANTED (no source change)"; exit 4; fi
mkdir -p $V/plants2.noindex/cache/$name/g $V/plants2.noindex/cache/$name/l
export TMPDIR=$V/tmp
cd $tree/zig
s=$(date +%s)
zig build test --global-cache-dir $V/plants2.noindex/cache/$name/g --cache-dir $V/plants2.noindex/cache/$name/l --summary all > $V/plants2/out/$name.txt 2>&1
rc=$?
sum=$(grep -E "tests? passed|Build Summary" $V/plants2/out/$name.txt | tail -1)
echo "$name exit=$rc changed-lines=$nd $(( $(date +%s)-s ))s | $sum"
