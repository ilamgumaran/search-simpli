#!/bin/bash
# natives.sh : tool/build_native.sh in a fresh git archive of 1439d6a (committed natives removed first, own caches), cmp each with the committed file, check_native.sh on both
set -u
unset SEARCH_SIMPLI_LIBRARY_PATH
export PATH=$HOME/development/zig/zig-0.16.0-macos-aarch64:$PATH
export SS_ANDROID_NDK=$HOME/development/android-sdk/ndk/28.2.13676358
S=$HOME/workspace/repos/search-simpli-wt/S6-T9m-vscratch.noindex; W=$HOME/workspace/repos/search-simpli-wt/S6-T9m
N=$S/src/nat; C=$S/cache/nat; L=$S/out/natives.txt
[ -e $N ] && { echo "nat exists"; exit 1; }
mkdir -p $N $C/g $C/l; git -C $S/repo archive 1439d6a | tar -x -C $N
export TMPDIR=$S/tmp ZIG_GLOBAL_CACHE_DIR=$C/g ZIG_LOCAL_CACHE_DIR=$C/l
D=$N/bindings/dart/search_simpli
files="native/macos-arm64/libsearch_simpli.dylib native/android-arm64/libsearch_simpli.so example/android/app/src/main/jniLibs/arm64-v8a/libsearch_simpli.so native/ios-arm64/search_simpli.framework/search_simpli native/ios-arm64/search_simpli.framework/Info.plist native/SOURCE-SHA256"
for f in $files; do rm -f $D/$f; done
( cd $D && bash tool/build_native.sh ) > $S/out/natives-build.txt 2>&1; echo "build_native.sh exit $?" > $L
grep -E "wrote|Build Summary|NOT rebuilt" $S/out/natives-build.txt >> $L
for f in $files; do
  if cmp -s $D/$f $W/bindings/dart/search_simpli/$f; then echo "identical $(wc -c < $D/$f | tr -d ' ') B $f"; else echo "DIFFERS $f"; fi
done >> $L
( cd $W/bindings/dart/search_simpli && bash tool/check_native.sh ) >> $L 2>&1; echo "check_native.sh (worktree, committed natives) exit $?" >> $L
cat $L
