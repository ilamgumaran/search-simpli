#!/usr/bin/env bash
# S6-T16 ruling 3 (copied from s6t15/natives.sh): rebuild the natives from a fresh `git archive COMMIT` with fresh
# local and global Zig caches and compare every output with MAIN's committed file.
#
#   SS_ANDROID_NDK=... scripts/prototypes/s6t16/natives.sh COMMIT MAIN SCRATCH
#
# Zig on PATH. Never removes anything.
set -uo pipefail
commit="$1"; main="$2"; scratch="$3"
here="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd -P "$here/../../.." && pwd)"
copy="$scratch/natives-$commit"
if [ -e "$copy" ]; then echo "natives.sh: $copy exists" >&2; exit 2; fi
mkdir -p "$copy" && git -C "$repo" archive "$commit" | tar -x -C "$copy"
pkg="bindings/dart/search_simpli"
echo "# S6-T16 ruling 3: tool/build_native.sh in a fresh git archive of $commit, fresh caches, NDK $(basename "$SS_ANDROID_NDK")"
(
  cd "$copy/$pkg" && ZIG_GLOBAL_CACHE_DIR="$copy/.zig-global-cache" tool/build_native.sh > "$copy/build_native.txt" 2>&1
)
code=$?
grep "tool/build_native.sh:" "$copy/build_native.txt" | sed "s#$scratch#<scratch>#g"
echo "build_native.sh exit $code"
bad=0
for rel in native/macos-arm64/libsearch_simpli.dylib native/android-arm64/libsearch_simpli.so \
           example/android/app/src/main/jniLibs/arm64-v8a/libsearch_simpli.so \
           native/ios-arm64/search_simpli.framework/search_simpli native/ios-arm64/search_simpli.framework/Info.plist \
           native/SOURCE-SHA256; do
  built="$copy/$pkg/$rel"
  git -C "$repo" show "$main:$pkg/$rel" > "$copy/main-file"
  git -C "$repo" show "$commit:$pkg/$rel" > "$copy/head-file"
  size=$(wc -c < "$built" | tr -d ' ')
  sum=$(shasum -a 256 "$built" | cut -c1-16)
  if cmp -s "$built" "$copy/head-file"; then vs_head=identical; else vs_head=DIFFERS; fi
  if cmp -s "$built" "$copy/main-file"; then vs_main=identical; else vs_main=differs; fi
  echo "$rel: $size B, sha256 $sum...; committed at $commit: $vs_head; committed at $main: $vs_main"
  [ "$vs_head" = identical ] || bad=1
  if [ "$rel" != native/SOURCE-SHA256 ] && [ "$vs_main" != identical ]; then bad=1; fi
done
echo "SOURCE-SHA256 at $main: $(git -C "$repo" show "$main:$pkg/native/SOURCE-SHA256")"
echo "SOURCE-SHA256 at $commit: $(git -C "$repo" show "$commit:$pkg/native/SOURCE-SHA256")"
(cd "$copy/$pkg" && tool/check_native.sh 2>&1 | tail -5)
echo "check_native.sh exit ${PIPESTATUS[0]}"
echo "every library cmp-identical to $main's, the digest to $commit's: $([ $bad = 0 ] && echo yes || echo NO)"
