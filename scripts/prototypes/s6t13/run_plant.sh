#!/bin/zsh
# usage: run.sh <plant>; a fresh scratch copy of HEAD + the fix, the plant, its diff, the filtered tests on fresh caches
S=$HOME/workspace/repos/search-simpli-wt/S6-T13-scratch
W=$HOME/workspace/repos/search-simpli-wt/S6-T13
P=$S/plants/$1
mkdir -p $P/fixed $P/planted
(cd $W && git archive HEAD zig) | tar -x -C $P/fixed
(cd $P/fixed && git apply --directory=. $S/fix.diff 2>/dev/null || patch -s -p1 < $S/fix.diff)
(cd $W && git archive HEAD zig) | tar -x -C $P/planted
(cd $P/planted && patch -s -p1 < $S/fix.diff)
python3 -I $W/scripts/prototypes/s6t13/plants.py $1 $P/planted/zig || exit 3
diff -ru $P/fixed/zig/src $P/planted/zig/src > $S/plants/$1.diff
echo "diff lines: $(wc -l < $S/plants/$1.diff)"
$W/scripts/prototypes/s6t13/run_filtered.sh $P/planted/zig $S/plants/cache-$1 "S6-T13" > $S/plants/$1.log 2>&1
echo "exit=$?"
grep -E "^[0-9]+/[0-9]+ manifest_read_test|FAIL|passed;|tests passed|expected|against the stat|stat said|MANIFEST .* bytes" $S/plants/$1.log | cut -c1-400
