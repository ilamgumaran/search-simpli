#!/bin/bash
# S6-T8 verifier (recheck): tool/build_native.sh on a fresh archive of fa61957 (src.noindex/nat2), own caches, then
# cmp with the committed files (saved to natives/rc before the build) and SOURCE-SHA256, then check_native.sh.
set -u
unset SEARCH_SIMPLI_LIBRARY_PATH
export PATH=$HOME/development/zig/zig-0.16.0-macos-aarch64:$PATH
V=$HOME/workspace/repos/search-simpli-wt/S6-T8-vscratch
mkdir -p $V/cache.noindex/nat2/g $V/cache.noindex/nat2/l $V/tmp
export TMPDIR=$V/tmp ZIG_GLOBAL_CACHE_DIR=$V/cache.noindex/nat2/g ZIG_LOCAL_CACHE_DIR=$V/cache.noindex/nat2/l SS_ANDROID_NDK=$HOME/development/android-sdk/ndk/28.2.13676358
N=$V/src.noindex/nat2/bindings/dart/search_simpli
R=$V/natives/rc
out=$V/natives/recheck-natives.txt
cd $N
s=$(date +%s)
bash tool/build_native.sh > $V/natives/recheck-build.txt 2>&1
rc=$?
{
  echo "build_native.sh on a fresh archive of fa61957 (own caches): exit $rc, $(( $(date +%s)-s )) s"
  grep "wrote" $V/natives/recheck-build.txt
  for pair in "native/macos-arm64/libsearch_simpli.dylib committed-macos.bin" "native/android-arm64/libsearch_simpli.so committed-android.bin" \
              "example/android/app/src/main/jniLibs/arm64-v8a/libsearch_simpli.so committed-jni.bin" \
              "native/ios-arm64/search_simpli.framework/search_simpli committed-ios.bin" "native/ios-arm64/search_simpli.framework/Info.plist committed-ios-plist.bin" \
              "native/SOURCE-SHA256 committed-SOURCE-SHA256"; do
    set -- $pair
    if cmp -s $N/$1 $R/$2; then echo "cmp $1: identical to the committed file ($(wc -c < $N/$1 | tr -d ' ') B)"; else echo "cmp $1: DIFFERS from the committed file"; fi
  done
  cmp -s $N/native/macos-arm64/libsearch_simpli.dylib $V/libs/head2/libsearch_simpli.dylib && echo "macOS dylib identical to my own ReleaseSmall build of fa61957 (libs/head2)"
  echo "SOURCE-SHA256 written: $(cat $N/native/SOURCE-SHA256)"
  echo "check_native.sh:"
  bash tool/check_native.sh 2>&1
} > $out
cat $out
