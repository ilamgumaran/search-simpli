#!/bin/zsh
# S6-T13 after the Verdict: one of the verifier's plants through the whole `zig build test` (Debug), on a commit
# that carries the adopted tests. The verifier's `tools/vfull.sh` with the commit as an argument and the builder's
# scratch: a fresh `git archive` of COMMIT (pristine and planted copies), the plant by the verifier's own
# `tools/vplants.py`, the diff, fresh global and local caches.
#   run_vplant_full.sh COMMIT PLANT
unset SEARCH_SIMPLI_LIBRARY_PATH
export PATH=$HOME/development/zig/zig-0.16.0-macos-aarch64:$PATH
W=$HOME/workspace/repos/search-simpli-wt/S6-T13
S=$HOME/workspace/repos/search-simpli-wt/S6-T13-scratch/vplants-full
commit=$1; plant=$2
P=$S/$commit-$plant
[ -e $P ] && { echo "exists: $P"; exit 2; }
mkdir -p $P/pristine $P/planted $P/cache/l $P/cache/g $P/tmp
for d in pristine planted; do (cd $W && git archive $commit) | tar -x -C $P/$d; done
python3 -I $W/docs/evidence/s6-t13/verifier/tools/vplants.py $plant $P/planted/zig || exit 3
diff -ru $P/pristine/zig/src $P/planted/zig/src | sed "s#$P/##g" > $S/$commit-$plant.diff
echo "diff lines $(wc -l < $S/$commit-$plant.diff)"
cd $P/planted/zig
export TMPDIR=$P/tmp
echo "start $(date +%T)" > $S/$commit-$plant.log
zig build test --summary all --global-cache-dir $P/cache/g --cache-dir $P/cache/l >> $S/$commit-$plant.log 2>&1
echo "exit=$? end $(date +%T)" >> $S/$commit-$plant.log
grep -E "Build Summary|^\+- run test [0-9]|^error: '|exit=" $S/$commit-$plant.log | cut -c1-220
