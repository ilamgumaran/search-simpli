#!/bin/bash
# S6-T5 verifier: ReleaseSmall macOS library (zig build lib) and searchd for one source copy, own caches.
# buildlibs.sh NAME [searchd]
set -eu
unset SEARCH_SIMPLI_LIBRARY_PATH
export PATH=$HOME/development/zig/zig-0.16.0-macos-aarch64:$PATH
V=$HOME/workspace/repos/search-simpli-wt/S6-T5-vscratch
name=$1
src=$V/src.noindex/$name/zig
mkdir -p $V/cache.noindex/$name/g $V/cache.noindex/$name/l $V/libs/$name $V/tmp
export TMPDIR=$V/tmp
cd $src
zig build lib -Doptimize=ReleaseSmall --global-cache-dir $V/cache.noindex/$name/g --cache-dir $V/cache.noindex/$name/l 2>&1 | tail -3
cp zig-out/lib/aarch64-macos/libsearch_simpli.dylib $V/libs/$name/libsearch_simpli.dylib
if [ "${2:-}" = searchd ]; then
  zig build -Doptimize=ReleaseSmall --prefix $V/bin/$name --global-cache-dir $V/cache.noindex/$name/g --cache-dir $V/cache.noindex/$name/l 2>&1 | tail -3
fi
ls -l $V/libs/$name/libsearch_simpli.dylib
echo "built $name $(date +%T)"
