#!/usr/bin/env bash
# Verifier's builds for S6-T16, one after another. Each in its own fresh archive copy and caches.
#   batch.sh REPO SCRATCH
set -uo pipefail
unset SEARCH_SIMPLI_LIBRARY_PATH
export PATH=$HOME/development/zig/zig-0.16.0-macos-aarch64:$HOME/development/flutter/bin:$PATH
export SS_ANDROID_NDK=$HOME/development/android-sdk/ndk/28.2.13676358
repo="$1"; S="$2"; HEAD=30858a8; MAIN=10f3d40
cd "$S" || exit 2
out="$S/batch-results.txt"
: > "$out"
log() { echo "$*" | tee -a "$out"; }
caches() { echo "--cache-dir $1/.zig-local-cache --global-cache-dir $1/.zig-global-cache"; }
fresh() { if [ -e "$2" ]; then log "EXISTS $2"; return 1; fi; mkdir -p "$2" && git -C "$repo" archive "$1" | tar -x -C "$2"; }
t0=$(date +%s)
stamp() { log "   [$(( $(date +%s) - t0 ))s]"; }

# 1. build cases
for b in B1 B2 B3 B4 B5 B6 B7 B8; do
  d="$S/builds/$b"
  # shellcheck disable=SC2046
  (cd "$d/zig" && zig build test --summary all $(caches "$d")) > "$d/build.txt" 2>&1
  code=$?
  log "== $b zig build test exit $code"
  grep -E "error:|Build Summary|note: .*not marked|peek (answered|refused)" "$d/build.txt" | head -8 | sed "s#$S#<s>#g" | tee -a "$out"
  stamp
done

# 2. check_test_counts --run, head, Debug then ReleaseSmall
for mode in Debug ReleaseSmall; do
  d="$S/counts-$mode"; fresh $HEAD "$d" || continue
  # shellcheck disable=SC2046
  (cd "$d" && python3 -I scripts/check_test_counts.py --root "$d" --run -- -Doptimize=$mode $(caches "$d")) > "$d/counts.txt" 2>&1
  log "== check_test_counts --run $mode exit $?"
  grep -E "^check_(test_counts|layers):|Build Summary" "$d/counts.txt" | sed "s#$S#<s>#g" | tee -a "$out"
  stamp
done

# 3. C ABI Debug
d="$S/abi"; fresh $HEAD "$d" && {
  # shellcheck disable=SC2046
  (cd "$d/zig" && zig build test-abi -Doptimize=Debug --summary all $(caches "$d")) > "$d/abi.txt" 2>&1
  log "== test-abi Debug exit $?"; grep -E "Build Summary|abi_test" "$d/abi.txt" | tee -a "$out"; stamp; }

# 4. searchd ReleaseSmall, head and main
for c in $HEAD $MAIN; do
  d="$S/searchd-$c"; fresh $c "$d" || continue
  # shellcheck disable=SC2046
  (cd "$d/zig" && zig build -Doptimize=ReleaseSmall --prefix "$d/out" $(caches "$d")) > "$d/build.txt" 2>&1
  log "== searchd $c ReleaseSmall exit $?; $(wc -c < "$d/out/bin/searchd" | tr -d ' ') B $(shasum -a 256 "$d/out/bin/searchd" | cut -c1-16)"
  stamp
done
if cmp "$S/searchd-$HEAD/out/bin/searchd" "$S/searchd-$MAIN/out/bin/searchd"; then log "searchd head vs main: cmp-identical"; else log "searchd head vs main: DIFFER"; fi

# 5. 20-query spot check, head vs main searchd, family-folder fixture
q=0; same=0
for w in school week tide plan math homework lunch doctor birthday piano soccer library trip budget recipe garden holiday teacher bus reading; do
  q=$((q+1))
  a=$("$S/searchd-$HEAD/out/bin/searchd" search "$S/searchd-$HEAD/fixtures/family-folder" "$w" 2>&1; echo "exit $?")
  b=$("$S/searchd-$MAIN/out/bin/searchd" search "$S/searchd-$HEAD/fixtures/family-folder" "$w" 2>&1; echo "exit $?")
  [ "$a" = "$b" ] && same=$((same+1)) || log "spot $w DIFFERS"
  [ $q = 1 ] && log "spot sample ($w): $(echo "$a" | head -c 300 | tr '\n' ' ')"
done
log "spot check: $same of $q queries byte-identical (searchd search, head vs main)"

# 6. natives from a fresh archive of head, against main's committed files
d="$S/natives"; fresh $HEAD "$d" && {
  pkg="bindings/dart/search_simpli"
  (cd "$d/$pkg" && ZIG_GLOBAL_CACHE_DIR="$d/.zig-global-cache" tool/build_native.sh) > "$d/build_native.txt" 2>&1
  log "== build_native.sh exit $?"
  for rel in native/macos-arm64/libsearch_simpli.dylib native/android-arm64/libsearch_simpli.so \
             example/android/app/src/main/jniLibs/arm64-v8a/libsearch_simpli.so \
             native/ios-arm64/search_simpli.framework/search_simpli native/ios-arm64/search_simpli.framework/Info.plist \
             native/SOURCE-SHA256; do
    git -C "$repo" show "$MAIN:$pkg/$rel" > "$d/main-file"; git -C "$repo" show "$HEAD:$pkg/$rel" > "$d/head-file"
    vm=$(cmp -s "$d/$pkg/$rel" "$d/main-file" && echo identical || echo differs)
    vh=$(cmp -s "$d/$pkg/$rel" "$d/head-file" && echo identical || echo differs)
    log "$rel: $(wc -c < "$d/$pkg/$rel" | tr -d ' ') B; vs main committed: $vm; vs head committed: $vh"
  done
  (cd "$d/$pkg" && tool/check_native.sh) > "$d/check_native.txt" 2>&1; log "check_native.sh exit $?"; tail -2 "$d/check_native.txt" | tee -a "$out"
  stamp; }

# 7. header and exports
log "git diff main head -- zig/include contracts: $(git -C "$repo" diff --stat $MAIN $HEAD -- zig/include contracts | wc -l | tr -d ' ') lines"
nm -gU "$S/natives/bindings/dart/search_simpli/native/macos-arm64/libsearch_simpli.dylib" | awk '{print $3}' | sort > "$S/exports-head.txt"
git -C "$repo" show "$MAIN:bindings/dart/search_simpli/native/macos-arm64/libsearch_simpli.dylib" > "$S/main.dylib"
nm -gU "$S/main.dylib" | awk '{print $3}' | sort > "$S/exports-main.txt"
log "exports: head $(wc -l < "$S/exports-head.txt" | tr -d ' '), main $(wc -l < "$S/exports-main.txt" | tr -d ' '), diff lines $(diff "$S/exports-head.txt" "$S/exports-main.txt" | wc -l | tr -d ' ')"

# 8. Python with Zig, fresh archive of head
d="$S/python"; fresh $HEAD "$d" && {
  (cd "$d" && env -u SEARCH_SIMPLI_NO_ZIG -u SEARCHD_BINARY python3 -m unittest discover -s tests) > "$d/python.txt" 2>&1
  log "== python with zig exit $?"; grep -E "^Ran |^OK|^FAILED" "$d/python.txt" | tee -a "$out"; stamp; }

# 9. Dart, fresh archive of head, committed natives
d="$S/dart"; fresh $HEAD "$d" && {
  (cd "$d/bindings/dart/search_simpli" && dart pub get > "$d/pub.txt" 2>&1; echo "pub get exit $?"
   dart analyze lib test 2>&1 | tail -2; echo "analyze exit ${PIPESTATUS[0]}"
   dart test > "$d/test.txt" 2>&1; echo "dart test exit $?"; tail -1 "$d/test.txt") 2>&1 | tee -a "$out"
  stamp; }
log "BATCH DONE"
