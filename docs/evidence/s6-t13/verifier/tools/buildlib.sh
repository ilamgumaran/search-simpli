#!/bin/bash
# S6-T13 verifier: ReleaseSmall macOS dylib (and optionally searchd) of one source copy, its own fresh caches.
#   buildlib.sh NAME [searchd]
set -eu
unset SEARCH_SIMPLI_LIBRARY_PATH
export PATH=$HOME/development/zig/zig-0.16.0-macos-aarch64:$PATH
V=$HOME/workspace/repos/search-simpli-wt/S6-T13-vscratch
name=$1
mkdir -p $V/cache.noindex/$name/g $V/cache.noindex/$name/l $V/libs/$name $V/tmp
export TMPDIR=$V/tmp
cd $V/src.noindex/$name/zig
zig build lib -Doptimize=ReleaseSmall --global-cache-dir $V/cache.noindex/$name/g --cache-dir $V/cache.noindex/$name/l 2>&1 | tail -2
cp zig-out/lib/aarch64-macos/libsearch_simpli.dylib $V/libs/$name/libsearch_simpli.dylib
if [ "${2:-}" = searchd ]; then
  zig build -Doptimize=ReleaseSmall --prefix $V/bin/$name --global-cache-dir $V/cache.noindex/$name/g --cache-dir $V/cache.noindex/$name/l 2>&1 | tail -2
  echo "searchd $(wc -c < $V/bin/$name/bin/searchd) B"
fi
echo "built $name $(date +%T): dylib $(wc -c < $V/libs/$name/libsearch_simpli.dylib) B sha256 $(shasum -a 256 $V/libs/$name/libsearch_simpli.dylib | cut -c1-16) __text $(size -m $V/libs/$name/libsearch_simpli.dylib | awk '/Section __text:/{print $3; exit}') B"
