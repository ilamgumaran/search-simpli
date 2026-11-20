#!/usr/bin/env bash
# S6-T15 verifier, check 4: natives from a fresh archive of HEAD vs MAIN's committed files;
# searchd ReleaseSmall from fresh archives of HEAD and MAIN. Own caches each.
# natives.sh REPO HEAD MAIN OUTDIR   (SS_ANDROID_NDK set; Zig on PATH)
set -uo pipefail
repo="$1"; head="$2"; main="$3"; out="$4"
pkg=bindings/dart/search_simpli
mkdir "$out" || exit 2
mkdir "$out/nat" && git -C "$repo" archive "$head" | tar -x -C "$out/nat"
echo "# build_native.sh in a fresh archive of $head; NDK $(basename "$SS_ANDROID_NDK")"
( cd "$out/nat/$pkg" && ZIG_GLOBAL_CACHE_DIR="$out/nat-gc" tool/build_native.sh > "$out/build_native.log" 2>&1 )
echo "build_native.sh exit $?"
for rel in native/macos-arm64/libsearch_simpli.dylib native/android-arm64/libsearch_simpli.so \
           example/android/app/src/main/jniLibs/arm64-v8a/libsearch_simpli.so \
           native/ios-arm64/search_simpli.framework/search_simpli native/ios-arm64/search_simpli.framework/Info.plist \
           native/SOURCE-SHA256; do
  git -C "$repo" show "$main:$pkg/$rel" > "$out/m.bin"
  git -C "$repo" show "$head:$pkg/$rel" > "$out/h.bin"
  b="$out/nat/$pkg/$rel"
  cmp -s "$b" "$out/m.bin" && vm=identical || vm=differs
  cmp -s "$b" "$out/h.bin" && vh=identical || vh=differs
  echo "$rel: $(wc -c < "$b" | tr -d ' ') B $(shasum -a 256 "$b" | cut -c1-16); vs main $main committed: $vm; vs head committed: $vh"
done
( cd "$out/nat/$pkg" && tool/check_native.sh > "$out/check_native.log" 2>&1 ); echo "check_native.sh exit $?"
tail -6 "$out/check_native.log"
for c in "$head" "$main"; do
  mkdir "$out/sd-$c" && git -C "$repo" archive "$c" | tar -x -C "$out/sd-$c"
  ( cd "$out/sd-$c/zig" && zig build -Doptimize=ReleaseSmall --cache-dir "$out/sd-$c-lc" --global-cache-dir "$out/sd-$c-gc" > "$out/sd-$c.log" 2>&1 )
  echo "searchd ReleaseSmall $c: exit $? $(wc -c < "$out/sd-$c/zig/zig-out/bin/searchd" | tr -d ' ') B $(shasum -a 256 "$out/sd-$c/zig/zig-out/bin/searchd" | cut -c1-16)"
done
cmp "$out/sd-$head/zig/zig-out/bin/searchd" "$out/sd-$main/zig/zig-out/bin/searchd" && echo "searchd: identical"
