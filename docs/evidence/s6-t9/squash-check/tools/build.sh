#!/bin/bash
# build.sh NAME COMMIT : fresh git archive, ReleaseSmall searchd + macOS dylib, own caches
set -eu
unset SEARCH_SIMPLI_LIBRARY_PATH
export PATH=$HOME/development/zig/zig-0.16.0-macos-aarch64:$PATH
S=$HOME/workspace/repos/search-simpli-wt/S6-T9m-vscratch.noindex
name=$1; commit=$2
src=$S/src/$name; C=$S/cache/$name
[ -e "$src" ] && { echo "$src exists"; exit 1; }
mkdir -p $src $C/g $C/l $S/bin/$name
git -C $S/repo archive $commit | tar -x -C $src
export TMPDIR=$S/tmp ZIG_GLOBAL_CACHE_DIR=$C/g ZIG_LOCAL_CACHE_DIR=$C/l
cd $src/zig
zig build -Doptimize=ReleaseSmall --prefix $S/bin/$name --global-cache-dir $C/g --cache-dir $C/l 2>&1 | tail -3
zig build lib -Doptimize=ReleaseSmall --global-cache-dir $C/g --cache-dir $C/l 2>&1 | tail -3
cp zig-out/lib/aarch64-macos/libsearch_simpli.dylib $S/bin/$name/libsearch_simpli.dylib
ls -l $S/bin/$name/bin/searchd $S/bin/$name/libsearch_simpli.dylib
echo "built $name $commit"
