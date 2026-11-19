#!/bin/bash
# S6-T8 verifier: one plant in a fresh git archive of 6b340b4 with its own Zig caches; Debug zig build test.
# plant.sh KIND NAME   (KIND: builder | mine | none)
set -u
unset SEARCH_SIMPLI_LIBRARY_PATH
export PATH=$HOME/development/zig/zig-0.16.0-macos-aarch64:$PATH
V=$HOME/workspace/repos/search-simpli-wt/S6-T8-vscratch
kind=$1; name=$2
tree=$V/plants.noindex/src/$name
if [ ! -d $tree ]; then
  mkdir -p $tree
  git -C $HOME/workspace/repos/search-simpli archive 6b340b4 | tar -x -C $tree
  case $kind in
    builder) python3 -I $V/plants/builder_plants.py $tree $name || exit 3;;
    mine) python3 -I $V/plants/my_plants.py $tree $name || exit 3;;
  esac
fi
mkdir -p $V/plants.noindex/cache/$name/g $V/plants.noindex/cache/$name/l $V/plants/out $V/tmp
export TMPDIR=$V/tmp
cd $tree/zig
s=$(date +%s)
zig build test --global-cache-dir $V/plants.noindex/cache/$name/g --cache-dir $V/plants.noindex/cache/$name/l --summary all > $V/plants/out/$name.txt 2>&1
rc=$?
sum=$(grep -E "tests? passed|Build Summary" $V/plants/out/$name.txt | tail -1)
echo "$name ($kind) exit=$rc $(( $(date +%s)-s ))s | $sum"
