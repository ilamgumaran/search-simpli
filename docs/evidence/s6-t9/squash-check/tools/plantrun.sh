#!/bin/bash
# plantrun.sh PLANT : restore incremental_state.zig, plant, zig build test (Debug), log in out/plant-PLANT.txt
set -u
unset SEARCH_SIMPLI_LIBRARY_PATH
export PATH=$HOME/development/zig/zig-0.16.0-macos-aarch64:$PATH
S=$HOME/workspace/repos/search-simpli-wt/S6-T9m-vscratch.noindex
F=$S/src/plant/zig/src/incremental_state.zig; C=$S/cache/plant; mkdir -p $C/g $C/l
git -C $S/repo show 1439d6a:zig/src/incremental_state.zig > $F
python3 -I $S/tools/plant.py $F $1; grep -n "planted\|FileNotFound => return error.InvalidState" $F
git -C $S/repo diff --no-index --stat <(git -C $S/repo show 1439d6a:zig/src/incremental_state.zig) $F | tail -1
export TMPDIR=$S/tmp
cd $S/src/plant/zig && zig build test --global-cache-dir $C/g --cache-dir $C/l --summary all > $S/out/plant-$1.txt 2>&1
echo "plant $1 exit $?"; grep -E "Build Summary|^error: '|FAIL|expected|panic" $S/out/plant-$1.txt | head -12
git -C $S/repo show 1439d6a:zig/src/incremental_state.zig > $F
