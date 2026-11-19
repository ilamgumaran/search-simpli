#!/bin/bash
# S6-T8 (ruling after the Third Verdict): one site plant (plants_sites.py; or the verifier's plants3.py for a name
# starting "v:") in a fresh git archive of 7d5e8c1 with its own Zig caches; the planted tree diffed against an
# unplanted archive first; Debug zig build test.
set -u
unset SEARCH_SIMPLI_LIBRARY_PATH
export PATH=$HOME/development/zig/zig-0.16.0-macos-aarch64:$PATH
W=$HOME/workspace/repos/search-simpli-wt/S6-T8
V=${SITES:-$HOME/workspace/repos/search-simpli-wt/S6-T8-scratch/sites.noindex}
arg=$1
case $arg in
  v:*) name=${arg#v:}; planter="$V/vdefs/plants3.py" ;;
  v4:*) name=${arg#v4:}; planter="$V/vdefs/plants4.py" ;;
  *) name=$arg; planter="$W/scripts/prototypes/s6t8/plants_sites.py" ;;
esac
tree=$V/src/$name
mkdir -p $V/out $V/diff $V/tmp
if [ -d $tree ]; then echo "$name: copy exists, not reused"; exit 5; fi
mkdir -p $tree
git -C $W archive ${COMMIT:-7d5e8c1} | tar -x -C $tree
python3 -I $planter $tree $name > /dev/null || { echo "$name: plant failed"; exit 3; }
diff -ru $V/none/zig/src $tree/zig/src > $V/diff/$name.diff
nd=$(grep -c '^[-+][^-+]' $V/diff/$name.diff)
if [ "$nd" = 0 ]; then echo "$name: NOT PLANTED"; exit 4; fi
mkdir -p $V/cache/$name/g $V/cache/$name/l
export TMPDIR=$V/tmp
cd $tree/zig
zig build test --global-cache-dir $V/cache/$name/g --cache-dir $V/cache/$name/l --summary all > $V/out/$name.txt 2>&1
echo "$name exit=$? changed-lines=$nd | $(grep -E 'run test [0-9]' $V/out/$name.txt | head -1)"
