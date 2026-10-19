#!/usr/bin/env bash
# tool/check_native.sh — verify the shipped native binaries (docs/tasks/S1-T21.md
# ruling 2): the macOS dylib, the Android .so and the iOS framework are all
# arm64 (aarch64), and the framework's Info.plist carries the required keys.
# Needs macOS (lipo, plutil, vtool); run from anywhere.
set -euo pipefail
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NATIVE="$(cd -P "$SCRIPT_DIR/../native" && pwd)"
fail=0
bad() { echo "check_native: FAIL — $*" >&2; fail=1; }

archs() { lipo -archs "$1" 2>/dev/null || true; }

[ "$(archs "$NATIVE/macos-arm64/libsearch_simpli.dylib")" = "arm64" ] || bad "macos-arm64 dylib is not arm64"
FW="$NATIVE/ios-arm64/search_simpli.framework"
[ "$(archs "$FW/search_simpli")" = "arm64" ] || bad "ios-arm64 framework binary is not arm64"
# Android .so is ELF: e_machine 0xB7 (183) at offset 18, little-endian.
machine="$(od -An -tx1 -j18 -N2 "$NATIVE/android-arm64/libsearch_simpli.so" | tr -d ' \n')"
[ "$machine" = "b700" ] || bad "android-arm64 .so is not ELF aarch64 (e_machine $machine)"

vtool -show-build "$FW/search_simpli" | grep -q 'platform IOS$' || bad "framework binary platform is not IOS"
vtool -show-build "$FW/search_simpli" | grep -q 'minos 17.0$' || bad "framework binary minos is not 17.0"
[ "$(otool -D "$FW/search_simpli" | tail -1)" = "@rpath/search_simpli.framework/search_simpli" ] || bad "framework install name is wrong"

plist_value() { plutil -extract "$1" raw -o - "$FW/Info.plist" 2>/dev/null || true; }
[ "$(plist_value CFBundleIdentifier)" = "family.vizhi.searchsimpli" ] || bad "CFBundleIdentifier"
[ "$(plist_value CFBundleExecutable)" = "search_simpli" ] || bad "CFBundleExecutable"
[ -n "$(plist_value CFBundleName)" ] || bad "CFBundleName"
[ "$(plist_value CFBundlePackageType)" = "FMWK" ] || bad "CFBundlePackageType"
[ "$(plist_value MinimumOSVersion)" = "17.0" ] || bad "MinimumOSVersion"
[ "$(plist_value CFBundleSupportedPlatforms.0)" = "iPhoneOS" ] || bad "CFBundleSupportedPlatforms"

if [ "$fail" -eq 0 ]; then echo "check_native: ok (macos-arm64, android-arm64, ios-arm64 framework)"; fi
exit "$fail"
