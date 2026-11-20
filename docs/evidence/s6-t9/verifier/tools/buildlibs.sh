#!/bin/bash
# S6-T9 verifier: ReleaseSmall macOS library and searchd for one source copy, own caches. buildlibs.sh NAME
set -eu
unset SEARCH_SIMPLI_LIBRARY_PATH
export PATH=$HOME/development/zig/zig-0.16.0-macos-aarch64:$PATH
V=$HOME/workspace/repos/search-simpli-wt/S6-T9-vscratch
name=$1
src=$V/src.noindex/$name/zig
mkdir -p $V/cache.noindex/$name/g $V/cache.noindex/$name/l $V/libs/$name $V/tmp
export TMPDIR=$V/tmp
cd $src
zig build lib -Doptimize=ReleaseSmall --global-cache-dir $V/cache.noindex/$name/g --cache-dir $V/cache.noindex/$name/l 2>&1 | tail -3
cp zig-out/lib/aarch64-macos/libsearch_simpli.dylib $V/libs/$name/libsearch_simpli.dylib
zig build -Doptimize=ReleaseSmall --prefix $V/bin/$name --global-cache-dir $V/cache.noindex/$name/g --cache-dir $V/cache.noindex/$name/l 2>&1 | tail -3
ls -l $V/libs/$name/libsearch_simpli.dylib $V/bin/$name/bin/searchd
echo "built $name $(date +%T)"
