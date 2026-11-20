#!/bin/zsh
# S6-T13 verifier: a plant through the whole `zig build test` (Debug), without the verifier's test file.
#   vfull.sh PLANT     (a fresh archive of eb53311's zig/, the plant, the diff, fresh caches)
unset SEARCH_SIMPLI_LIBRARY_PATH
export PATH=$HOME/development/zig/zig-0.16.0-macos-aarch64:$PATH
V=$HOME/workspace/repos/search-simpli-wt/S6-T13-vscratch
W=$HOME/workspace/repos/search-simpli-wt/S6-T13
P=$V/plants.noindex/full-$1
[ -e $P ] && { echo "exists: $P"; exit 2; }
mkdir -p $P/pristine $P/planted $P/cache/l $P/cache/g
for d in pristine planted; do (cd $W && git archive eb53311) | tar -x -C $P/$d; done
python3 -I $V/tools/vplants.py $1 $P/planted/zig || exit 3
diff -ru $P/pristine/zig/src $P/planted/zig/src | sed "s#$P/##g" > $V/plants/full-$1.diff
echo "diff lines $(wc -l < $V/plants/full-$1.diff)"
cd $P/planted/zig
export TMPDIR=$V/tmp
echo "start $(date +%T)" > $V/plants/full-$1.log
zig build test --summary all --global-cache-dir $P/cache/g --cache-dir $P/cache/l >> $V/plants/full-$1.log 2>&1
echo "exit=$? end $(date +%T)" >> $V/plants/full-$1.log
grep -E "Build Summary|^\+- run test [0-9]|exit=" $V/plants/full-$1.log
