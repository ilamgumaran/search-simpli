#!/bin/bash
# S6-T5 verifier: tool/build_native.sh on a git-archive copy of 3056e65, empty caches, TMPDIR in scratch.
set -u
unset SEARCH_SIMPLI_LIBRARY_PATH
export PATH=$HOME/development/zig/zig-0.16.0-macos-aarch64:$PATH
V=$HOME/workspace/repos/search-simpli-wt/S6-T5-vscratch
mkdir -p $V/natcache.noindex/g $V/natcache.noindex/l $V/nattmp
export ZIG_GLOBAL_CACHE_DIR=$V/natcache.noindex/g ZIG_LOCAL_CACHE_DIR=$V/natcache.noindex/l TMPDIR=$V/nattmp
export SS_ANDROID_NDK=$HOME/development/android-sdk/ndk/28.2.13676358
cd $V/src.noindex/nat/bindings/dart/search_simpli
bash tool/build_native.sh
echo "exit $?"
