#!/bin/bash
# S6-T8 F3: one of the verifier's plants (verifier-recheck/plants/plants2.py) in a fresh git archive of bb92ae5 with
# its own Zig caches; the planted tree diffed against an unplanted archive first; Debug zig build test.
set -u
unset SEARCH_SIMPLI_LIBRARY_PATH
export PATH=$HOME/development/zig/zig-0.16.0-macos-aarch64:$PATH
W=$HOME/workspace/repos/search-simpli-wt/S6-T8
V=$HOME/workspace/repos/search-simpli-wt/S6-T8-scratch/plants-f3.noindex
name=$1
tree=$V/src/$name
mkdir -p $V/out $V/diff $V/tmp
[ -d $V/src/none ] || { mkdir -p $V/src/none && git -C $W archive bb92ae5 | tar -x -C $V/src/none; }
if [ -d $tree ]; then echo "$name: copy exists, not reused"; exit 5; fi
mkdir -p $tree
git -C $W archive bb92ae5 | tar -x -C $tree
python3 -I $W/docs/evidence/s6-t8/verifier-recheck/plants/plants2.py $tree $name || exit 3
diff -ru $V/src/none/zig/src $tree/zig/src > $V/diff/$name.diff
nd=$(grep -c '^[-+][^-+]' $V/diff/$name.diff)
if [ "$nd" = 0 ]; then echo "$name: NOT PLANTED"; exit 4; fi
mkdir -p $V/cache/$name/g $V/cache/$name/l
export TMPDIR=$V/tmp
cd $tree/zig
zig build test --global-cache-dir $V/cache/$name/g --cache-dir $V/cache/$name/l --summary all > $V/out/$name.txt 2>&1
echo "$name exit=$? changed-lines=$nd | $(grep -E 'run test [0-9]' $V/out/$name.txt | head -1)"
