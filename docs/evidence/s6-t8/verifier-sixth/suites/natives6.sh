#!/bin/bash
# S6-T8 verifier (sixth check): tool/build_native.sh on a fresh archive of 965cce7 with its own caches, each output
# compared (cmp) with the committed file in the worktree, then check_native.sh on the fresh copy.
set -u
unset SEARCH_SIMPLI_LIBRARY_PATH
export PATH=$HOME/development/zig/zig-0.16.0-macos-aarch64:$PATH
W=$HOME/workspace/repos/search-simpli-wt/S6-T8
V=$HOME/workspace/repos/search-simpli-wt/S6-T8-vscratch/nat6.noindex
[ -d $V/src ] && { echo "copy exists"; exit 5; }
mkdir -p $V/src $V/cache/g $V/cache/l $V/tmp
git -C $W archive 965cce7 | tar -x -C $V/src
export TMPDIR=$V/tmp ZIG_GLOBAL_CACHE_DIR=$V/cache/g ZIG_LOCAL_CACHE_DIR=$V/cache/l SS_ANDROID_NDK=$HOME/development/android-sdk/ndk/28.2.13676358
N=$V/src/bindings/dart/search_simpli
C=$W/bindings/dart/search_simpli
cd $N
bash tool/build_native.sh > $V/build.txt 2>&1
echo "build_native.sh on a fresh archive of 965cce7 (own caches): exit $?"
for f in native/macos-arm64/libsearch_simpli.dylib native/android-arm64/libsearch_simpli.so \
         example/android/app/src/main/jniLibs/arm64-v8a/libsearch_simpli.so \
         native/ios-arm64/search_simpli.framework/search_simpli native/ios-arm64/search_simpli.framework/Info.plist native/SOURCE-SHA256; do
  if cmp -s $N/$f $C/$f; then echo "cmp $f: identical ($(wc -c < $N/$f | tr -d ' ') B)"; else echo "cmp $f: DIFFERS"; fi
done
echo "SOURCE-SHA256: $(cat $N/native/SOURCE-SHA256)"
echo "check_native.sh (fresh copy):"
bash tool/check_native.sh 2>&1 | tail -2
