#!/bin/bash
# S6-T9 verifier: the natives rebuilt by tool/build_native.sh in a fresh git archive of e3e8125 (own Zig caches), each
# compared (cmp) with the committed file; SOURCE-SHA256 compared; check_native.sh. Log: $V/suites/natives.txt
set -u
unset SEARCH_SIMPLI_LIBRARY_PATH
export PATH=$HOME/development/zig/zig-0.16.0-macos-aarch64:$PATH
export SS_ANDROID_NDK=$HOME/development/android-sdk/ndk/28.2.13676358
V=$HOME/workspace/repos/search-simpli-wt/S6-T9-vscratch; W=$HOME/workspace/repos/search-simpli-wt/S6-T9
N=$V/src.noindex/nat; C=$V/cache.noindex/nat; L=$V/suites/natives.txt
[ -d $N ] && { echo "nat exists" > $L; exit 1; }
mkdir -p $N $C/g $C/l $V/tmp; git -C $W archive e3e8125 | tar -x -C $N
export TMPDIR=$V/tmp ZIG_GLOBAL_CACHE_DIR=$C/g ZIG_LOCAL_CACHE_DIR=$C/l
D=$N/bindings/dart/search_simpli
rm -f $D/native/macos-arm64/libsearch_simpli.dylib $D/native/android-arm64/libsearch_simpli.so $D/example/android/app/src/main/jniLibs/arm64-v8a/libsearch_simpli.so $D/native/ios-arm64/search_simpli.framework/search_simpli $D/native/ios-arm64/search_simpli.framework/Info.plist $D/native/SOURCE-SHA256
( cd $D && bash tool/build_native.sh ) > $V/suites/natives-build.txt 2>&1; echo "build_native.sh exit $?" > $L; grep -c "NOT rebuilt" $V/suites/natives-build.txt | sed "s/^/NOT-rebuilt lines: /" >> $L
# the archive carries the committed natives: remove them first so a file not rebuilt cannot compare identical
grep "wrote" $V/suites/natives-build.txt >> $L
for f in native/macos-arm64/libsearch_simpli.dylib native/android-arm64/libsearch_simpli.so example/android/app/src/main/jniLibs/arm64-v8a/libsearch_simpli.so native/ios-arm64/search_simpli.framework/search_simpli native/ios-arm64/search_simpli.framework/Info.plist native/SOURCE-SHA256; do
  if cmp -s $D/$f $W/bindings/dart/search_simpli/$f; then echo "identical $(wc -c < $D/$f | tr -d ' ') B $f"; else echo "DIFFERS $f"; fi
done >> $L
cmp -s $D/native/macos-arm64/libsearch_simpli.dylib $V/libs/head/libsearch_simpli.dylib && echo "macOS dylib identical to my ReleaseSmall head build (libs/head)" >> $L || echo "macOS dylib differs from libs/head" >> $L
( cd $W/bindings/dart/search_simpli && bash tool/check_native.sh ) >> $L 2>&1; echo "check_native.sh (worktree, committed natives) exit $?" >> $L
( cd $D && bash tool/check_native.sh ) >> $L 2>&1; echo "check_native.sh (rebuilt natives) exit $?" >> $L
