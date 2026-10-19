#!/usr/bin/env bash
# tool/build_native.sh — rebuild native/{macos-arm64,android-arm64}/libsearch_simpli.*
# and native/ios-arm64/search_simpli.framework (docs/tasks/S1-T21.md)
# from the pinned Zig 0.16.0 toolchain (docs/tasks/S1-T2.md criterion 1).
#
# Usage:
#   zig on PATH (or ZIG pointing at the binary), then:
#   SS_ANDROID_NDK=/path/to/ndk/28.2.13676358 tool/build_native.sh
#
# Without SS_ANDROID_NDK set, `zig build lib` still builds the macOS arm64
# library (Zig's own bundled libc covers it); the Android arm64 library is
# skipped with a warning from `zig build lib` itself, and this script exits
# 1 (visibly, rather than silently leaving a stale native/android-arm64/
# library in place) — set SS_ANDROID_NDK and re-run to get both.
#
# The iOS framework needs macOS with Xcode (`xcrun --sdk iphoneos`); without
# it `zig build lib` prints its skip line and this script exits 1 the same way.
#
# What this does NOT do: build x86_64-linux (`zig build lib` also builds
# it, for the Zig engine's own S1-T0 targets, but this package ships only
# macOS arm64, Android arm64 and iOS arm64) or run
# any Dart/ffigen step (`dart run ffigen --config ffigen.yaml`, run
# separately, only when zig/include/search_simpli.h changes shape).
set -euo pipefail

ZIG="${ZIG:-zig}"
if ! command -v "$ZIG" >/dev/null 2>&1; then
  echo "tool/build_native.sh: '$ZIG' not found on PATH. Set ZIG to the pinned" >&2
  echo "  Zig 0.16.0 binary, or add it to PATH." >&2
  exit 1
fi

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKAGE_DIR="$(cd -P "$SCRIPT_DIR/.." && pwd)"
ZIG_DIR="$(cd -P "$PACKAGE_DIR/../../../zig" && pwd)"

echo "tool/build_native.sh: building with $("$ZIG" version) from $ZIG_DIR"

(
  cd "$ZIG_DIR"
  "$ZIG" build lib -Doptimize=ReleaseSmall --summary all
)

MACOS_LIB="$ZIG_DIR/zig-out/lib/aarch64-macos/libsearch_simpli.dylib"
ANDROID_LIB="$ZIG_DIR/zig-out/lib/aarch64-linux-android/libsearch_simpli.so"

mkdir -p "$PACKAGE_DIR/native/macos-arm64" "$PACKAGE_DIR/native/android-arm64"

if [ -f "$MACOS_LIB" ]; then
  cp "$MACOS_LIB" "$PACKAGE_DIR/native/macos-arm64/libsearch_simpli.dylib"
  echo "tool/build_native.sh: wrote native/macos-arm64/libsearch_simpli.dylib ($(wc -c < "$MACOS_LIB") bytes)"
else
  echo "tool/build_native.sh: ERROR — $MACOS_LIB was not produced" >&2
  exit 1
fi

if [ -f "$ANDROID_LIB" ]; then
  cp "$ANDROID_LIB" "$PACKAGE_DIR/native/android-arm64/libsearch_simpli.so"
  echo "tool/build_native.sh: wrote native/android-arm64/libsearch_simpli.so ($(wc -c < "$ANDROID_LIB") bytes)"
  # Keep the example app's jniLibs copy in sync (docs/tasks/S1-T2.md
  # criterion 3's instrumentation smoke test loads this exact file).
  EXAMPLE_JNI_DIR="$PACKAGE_DIR/example/android/app/src/main/jniLibs/arm64-v8a"
  if [ -d "$PACKAGE_DIR/example" ]; then
    mkdir -p "$EXAMPLE_JNI_DIR"
    cp "$ANDROID_LIB" "$EXAMPLE_JNI_DIR/libsearch_simpli.so"
    echo "tool/build_native.sh: wrote example/android/app/src/main/jniLibs/arm64-v8a/libsearch_simpli.so"
  fi
else
  echo "tool/build_native.sh: SS_ANDROID_NDK was not set (or the NDK build failed)," >&2
  echo "  so native/android-arm64/libsearch_simpli.so was NOT rebuilt. Set" >&2
  echo "  SS_ANDROID_NDK to the NDK root and re-run to update it." >&2
  exit 1
fi

# iOS: wrap the dylib as a flat (iOS-layout) framework, unsigned; the app signs
# it when it embeds it (docs/tasks/S1-T21.md ruling 2).
IOS_LIB="$ZIG_DIR/zig-out/lib/aarch64-ios/libsearch_simpli.dylib"
if [ -f "$IOS_LIB" ]; then
  FRAMEWORK="$PACKAGE_DIR/native/ios-arm64/search_simpli.framework"
  rm -rf "$PACKAGE_DIR/native/ios-arm64"
  mkdir -p "$FRAMEWORK"
  cp "$IOS_LIB" "$FRAMEWORK/search_simpli"
  chmod u+w "$FRAMEWORK/search_simpli"
  # The install name (@rpath/search_simpli.framework/search_simpli) is set by
  # zig/build.zig at link time; install_name_tool cannot grow the header.
  codesign --remove-signature "$FRAMEWORK/search_simpli" 2>/dev/null || true
  cat > "$FRAMEWORK/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleIdentifier</key>
	<string>family.vizhi.searchsimpli</string>
	<key>CFBundleExecutable</key>
	<string>search_simpli</string>
	<key>CFBundleName</key>
	<string>search_simpli</string>
	<key>CFBundlePackageType</key>
	<string>FMWK</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleVersion</key>
	<string>1</string>
	<key>CFBundleShortVersionString</key>
	<string>1.0</string>
	<key>MinimumOSVersion</key>
	<string>17.0</string>
	<key>CFBundleSupportedPlatforms</key>
	<array>
		<string>iPhoneOS</string>
	</array>
</dict>
</plist>
PLIST
  echo "tool/build_native.sh: wrote native/ios-arm64/search_simpli.framework ($(wc -c < "$FRAMEWORK/search_simpli") bytes binary)"
else
  echo "tool/build_native.sh: ERROR — $IOS_LIB was not produced (needs macOS with Xcode;" >&2
  echo "  see the 'iOS SDK was not found' line from zig build lib)." >&2
  exit 1
fi

# Freshness stamp: tests/test_native_freshness.py recomputes this digest with
# the same script and fails when the Zig source has moved on.
python3 "$SCRIPT_DIR/source_digest.py" > "$PACKAGE_DIR/native/SOURCE-SHA256"
echo "tool/build_native.sh: wrote native/SOURCE-SHA256 ($(cat "$PACKAGE_DIR/native/SOURCE-SHA256"))"
