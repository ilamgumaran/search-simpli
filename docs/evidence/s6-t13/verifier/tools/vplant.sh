#!/bin/zsh
# S6-T13 verifier: vplant.sh COMMIT PLANT [FILTER]. A fresh archive of COMMIT's zig/ (pristine and planted copies),
# the plant, the verifier's test file added beside both, the diff, then the filtered engine tests with fresh caches.
unset SEARCH_SIMPLI_LIBRARY_PATH
export PATH=$HOME/development/zig/zig-0.16.0-macos-aarch64:$PATH
V=$HOME/workspace/repos/search-simpli-wt/S6-T13-vscratch
W=$HOME/workspace/repos/search-simpli-wt/S6-T13
commit=$1; plant=$2; filter=${3:-S6-T13}
P=$V/plants.noindex/$commit-$plant
[ -e $P ] && { echo "exists: $P"; exit 2; }
mkdir -p $P/pristine $P/planted $P/cache/l $P/cache/g $V/plants
for d in pristine planted; do
  (cd $W && git archive $commit zig) | tar -x -C $P/$d
  cp $V/tools/verifier_s6t13_test.zig $P/$d/zig/src/
  print '\ntest {\n    _ = @import("verifier_s6t13_test.zig");\n}' >> $P/$d/zig/src/lazy_open_test.zig
done
case $plant in
  p*) python3 -I $W/scripts/prototypes/s6t13/plants.py $plant $P/planted/zig || exit 3;;
  *) python3 -I $V/tools/vplants.py $plant $P/planted/zig || exit 3;;
esac
diff -ru $P/pristine/zig/src $P/planted/zig/src | sed "s#$P/##g" > $V/plants/$commit-$plant.diff
echo "diff lines $(wc -l < $V/plants/$commit-$plant.diff)"
cd $P/planted/zig
export TMPDIR=$V/tmp
zig test $V/opts/fastmem.o -ODebug --dep build_options --dep tool_schemas -Mroot=src/root.zig -Mbuild_options=$V/opts/build_options.zig -Mtool_schemas=$V/opts/tool_schemas.zig -lc --cache-dir $P/cache/l --global-cache-dir $P/cache/g --test-filter "load every engine module" --test-filter "test_" --test-filter "$filter" > $V/plants/$commit-$plant.log 2>&1
echo "exit=$?" | tee -a $V/plants/$commit-$plant.log
grep -E "passed|failed|FAIL|error:|^VB|^VC|^VD|^VE|not whole|expected|stat said|found" $V/plants/$commit-$plant.log | grep -v '^VSWEEP' | cut -c1-260 | head -30
grep -E "^VSWEEP" $V/plants/$commit-$plant.log | awk '{print $2,$3,$4,$5,$6,$7,$8,$9,$10}'
