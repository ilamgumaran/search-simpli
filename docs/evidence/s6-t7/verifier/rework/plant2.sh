#!/bin/bash
# S6-T7 verifier: one plant. plant.sh NAME [step]  (step: test (default) | test-abi)
# Fresh git archive of 8236c1e at src.noindex/p2/NAME, the plant applied, Debug `zig build STEP` with its own caches.
set -u
unset SEARCH_SIMPLI_LIBRARY_PATH
export PATH=$HOME/development/zig/zig-0.16.0-macos-aarch64:$PATH
V=$HOME/workspace/repos/search-simpli-wt/S6-T7-vscratch
name=$1; step=${2:-test}
tree=$V/src.noindex/p2/$name
if [ ! -d $tree ]; then
  mkdir -p $tree
  git -C $HOME/workspace/repos/search-simpli-wt/S6-T7 archive 8236c1e | tar -x -C $tree
  python3 -I $V/plants/plants.py apply $name $tree || exit 3
fi
mkdir -p $V/cache.noindex/p2/$name/g $V/cache.noindex/p2/$name/l $V/plants/out2 $V/tmp
export TMPDIR=$V/tmp
cd $tree/zig
s=$(date +%s)
zig build $step --global-cache-dir $V/cache.noindex/p2/$name/g --cache-dir $V/cache.noindex/p2/$name/l --summary all > $V/plants/out2/$name.$step.txt 2>&1
rc=$?
sum=$(grep -E "^Build Summary" $V/plants/out2/$name.$step.txt | tail -1)
fails=$(grep -cE "^error: '.*' failed|^.*\) failed$" $V/plants/out2/$name.$step.txt)
echo "$name $step exit=$rc $(( $(date +%s)-s ))s | $sum"
