#!/bin/bash
# S6-T8 (ruling after the Fourth Verdict): tool/build_native.sh on a fresh archive of 30b4cdb with its own caches, then cmp each output with the
# committed file of the worktree, then check_native.sh.
set -u
unset SEARCH_SIMPLI_LIBRARY_PATH
export PATH=$HOME/development/zig/zig-0.16.0-macos-aarch64:$PATH
W=$HOME/workspace/repos/search-simpli-wt/S6-T8
V=$HOME/workspace/repos/search-simpli-wt/S6-T8-scratch/nat-f5.noindex
[ -d $V/src ] && { echo "copy exists"; exit 5; }
mkdir -p $V/src $V/cache/g $V/cache/l $V/tmp
git -C $W archive 30b4cdb | tar -x -C $V/src
export TMPDIR=$V/tmp ZIG_GLOBAL_CACHE_DIR=$V/cache/g ZIG_LOCAL_CACHE_DIR=$V/cache/l SS_ANDROID_NDK=$HOME/development/android-sdk/ndk/28.2.13676358
N=$V/src/bindings/dart/search_simpli
C=$W/bindings/dart/search_simpli
cd $N
bash tool/build_native.sh > $V/build.txt 2>&1
echo "build_native.sh on a fresh archive of 30b4cdb (own caches): exit $?"
grep "wrote" $V/build.txt
for f in native/macos-arm64/libsearch_simpli.dylib native/android-arm64/libsearch_simpli.so \
         example/android/app/src/main/jniLibs/arm64-v8a/libsearch_simpli.so \
         native/ios-arm64/search_simpli.framework/search_simpli native/ios-arm64/search_simpli.framework/Info.plist native/SOURCE-SHA256; do
  if cmp -s $N/$f $C/$f; then echo "cmp $f: identical to the committed file ($(wc -c < $N/$f | tr -d ' ') B)"; else echo "cmp $f: DIFFERS"; fi
done
echo "check_native.sh:"
bash tool/check_native.sh 2>&1 | tail -1
