#!/usr/bin/env bash
# docs/tasks/S1-T10.md criterion 3: prove openSearchSimpliLibrary() finds
# libsearch_simpli.dylib inside a BUILT macOS .app (Contents/Frameworks), with
# SEARCH_SIMPLI_LIBRARY_PATH unset, cwd "/", with the app sandbox off and on.
# Builds a throwaway Flutter app in a temp directory (never inside the repo).
# Exits non-zero if any run that should answer does not print PROBE_ANSWER.
# The app's cwd is "/" only unsandboxed; a sandboxed process starts in its
# container. macOS leaves ~/Library/Containers/com.example.probeApp behind
# after a run; this script does not (and cannot sensibly) remove it.
# --decoy (docs/tasks/S1-T12.md): instead of the sandbox runs, plant a decoy
# libsearch_simpli.dylib (ss_version() returns "decoy") in the app's cwd and
# prove (a) with the library bundled, the bundled copy loads; (b) with none
# bundled, the app fails with "did not ship" and the decoy is never loaded.
# Every answer prints the file dyld mapped (dladdr on ss_version), not only the
# version string. PROBE_PKG=<dir> points the app at another copy of the package
# (e.g. a `git archive` of origin/main) to compare loaders.
# Usage: tool/bundle_probe.sh [--decoy]   (needs: source ~/development/env.sh; Xcode)
set -euo pipefail

MODE=sandbox
[ "${1:-}" = "--decoy" ] && MODE=decoy
PKG="$(cd "$(dirname "$0")/.." && pwd)"
APPPKG="${PROBE_PKG:-$PKG}"
DYLIB="$PKG/native/macos-arm64/libsearch_simpli.dylib"
SNAP="$PKG/example/assets/demo_snapshot"
TMPBASE="${TMPDIR:-/tmp}"
WORK="$(mktemp -d "${TMPBASE%/}/ss-bundle-probe.XXXXXX")"
echo "probe workdir (removed on exit): $WORK"
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"
unset SEARCH_SIMPLI_LIBRARY_PATH

flutter create --platforms macos --project-name probe_app probe_app >/dev/null
cd probe_app
mkdir -p assets/demo_snapshot
cp "$SNAP"/* assets/demo_snapshot/
python3 - "$APPPKG" <<'PY'
import sys
pkg = sys.argv[1]
s = open('pubspec.yaml').read()
s = s.replace('dependencies:\n  flutter:\n    sdk: flutter\n',
  f'dependencies:\n  flutter:\n    sdk: flutter\n  search_simpli:\n    path: {pkg}\n  path: ^1.9.0\n  ffi: ^2.1.0\n', 1)
s = s.replace('  uses-material-design: true',
  '  uses-material-design: true\n  assets:\n    - assets/demo_snapshot/', 1)
assert 'assets/demo_snapshot/' in s
open('pubspec.yaml', 'w').write(s)
PY
cat > lib/main.dart <<'DART'
import 'dart:ffi';
import 'dart:io';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter/widgets.dart';
import 'package:ffi/ffi.dart' show calloc;
import 'package:path/path.dart' as p;
import 'package:search_simpli/search_simpli.dart';

final class DlInfo extends Struct {
  external Pointer<Uint8> fname;
  external Pointer<Void> fbase;
  external Pointer<Uint8> sname;
  external Pointer<Void> saddr;
}

String _cstr(Pointer<Uint8> p) {
  final bytes = <int>[];
  for (var i = 0; p[i] != 0; i++) {
    bytes.add(p[i]);
  }
  return String.fromCharCodes(bytes);
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  var code = 0;
  Directory? dir;
  try {
    // Which file did the loader map? ss_version() as the library answers it,
    // and the path dladdr reports for that symbol's address.
    final lib = openSearchSimpliLibrary();
    final ver = lib.lookupFunction<Pointer<Uint8> Function(), Pointer<Uint8> Function()>('ss_version');
    final addr = lib.lookup<NativeFunction<Pointer<Uint8> Function()>>('ss_version');
    final info = calloc<DlInfo>();
    final dladdr = DynamicLibrary.process().lookupFunction<
        Int32 Function(Pointer<Void>, Pointer<DlInfo>),
        int Function(Pointer<Void>, Pointer<DlInfo>)>('dladdr');
    final ok = dladdr(addr.cast(), info);
    stdout.writeln('LOADED_FROM ss_version=${_cstr(ver())} '
        'file=${ok != 0 ? _cstr(info.ref.fname) : "unknown"}');
    dir = Directory.systemTemp.createTempSync('ss_probe_');
    for (final n in ['MANIFEST', 'documents-1.hybseg', 'lexical-1.hyblex']) {
      final b = await rootBundle.load('assets/demo_snapshot/$n');
      File(p.join(dir!.path, n)).writeAsBytesSync(b.buffer.asUint8List(b.offsetInBytes, b.lengthInBytes));
    }
    final engine = SearchSimpli.open(dir.path);
    final r = engine.query('hybrid ranking', queryVector: [1.0, 0.0], topK: 1, mode: RetrievalMode.hybrid);
    final hit = r.results.first;
    stdout.writeln('PROBE_ANSWER cwd=${Directory.current.path} exe=${Platform.resolvedExecutable} '
        'SEARCH_SIMPLI_LIBRARY_PATH=${Platform.environment['SEARCH_SIMPLI_LIBRARY_PATH']} '
        'chunk_id=${hit.chunkId} path=${hit.citation.path} content="${hit.content}"');
    engine.close();
  } catch (e) {
    stdout.writeln('PROBE_FAIL $e');
    code = 1;
  }
  try {
    dir?.deleteSync(recursive: true);
  } catch (_) {}
  await stdout.flush();
  exit(code);
}
DART
flutter pub get >/dev/null

set_sandbox() { # $1 = true|false
  for f in macos/Runner/DebugProfile.entitlements macos/Runner/Release.entitlements; do
    /usr/libexec/PlistBuddy -c "Set :com.apple.security.app-sandbox $1" "$f"
  done
  echo "--- entitlement (plist) com.apple.security.app-sandbox = $(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.app-sandbox' macos/Runner/DebugProfile.entitlements)"
}

FAILED=0
RUNDIR=/
run_app() { # $1 = expect (answer|fail); run from $RUNDIR with the env var unset; 40 s bound
  local expect="$1" out
  local app="$PWD/build/macos/Build/Products/Debug/probe_app.app"
  echo "command: cd $RUNDIR && env -u SEARCH_SIMPLI_LIBRARY_PATH <app>/Contents/MacOS/probe_app"
  out="$( ( cd "$RUNDIR" && env -u SEARCH_SIMPLI_LIBRARY_PATH perl -e 'alarm 40; exec @ARGV' -- "$app/Contents/MacOS/probe_app" 2>&1 ) \
    | grep -E 'PROBE_|LOADED_FROM|search_simpli: could not|search_simpli: the app did not|^/|^libsearch' | head -12 || true )"
  echo "$out"; out_last="$out"
  if [ "$expect" = answer ] && ! grep -q PROBE_ANSWER <<<"$out"; then
    echo "!!! FAIL: expected PROBE_ANSWER"; FAILED=1
  elif [ "$expect" = fail ] && ! grep -q PROBE_FAIL <<<"$out"; then
    echo "!!! FAIL: expected PROBE_FAIL (negative control)"; FAILED=1
  fi
}

APP=build/macos/Build/Products/Debug/probe_app.app
# Re-signing must pass the entitlements again, or codesign drops them (and the
# "sandbox on" run would silently not be sandboxed).
sign_app() { codesign --force --deep -s - --entitlements macos/Runner/DebugProfile.entitlements "$APP" 2>/dev/null; }
show_sandbox() { echo "--- signed app-sandbox entitlement: $(codesign -d --entitlements - "$APP" 2>&1 | grep -A2 'com.apple.security.app-sandbox' | tr -s '\n\t' ' ')"; }
if [ "$MODE" = decoy ]; then
  echo "=== decoy mode (sandbox off) ==="
  mkdir -p "$WORK/decoy/cwd"
  printf 'const char *ss_version(void) { return "decoy"; }\n' >"$WORK/decoy/decoy.c"
  xcrun clang -shared -o "$WORK/decoy/cwd/libsearch_simpli.dylib" "$WORK/decoy/decoy.c"
  RUNDIR="$WORK/decoy/cwd"
  set_sandbox false
  flutter build macos --debug >/dev/null
  echo "--- (a) library bundled + decoy in cwd: the bundled copy must load"
  rm -f "$APP/Contents/Frameworks/libsearch_simpli.dylib"
  cp "$DYLIB" "$APP/Contents/Frameworks/"
  codesign --force -s - "$APP/Contents/Frameworks/libsearch_simpli.dylib" 2>/dev/null
  sign_app
  show_sandbox
  run_app answer
  last="$out_last"
  grep -q 'LOADED_FROM ss_version=1.0.0 file=.*/Contents/Frameworks/libsearch_simpli.dylib' <<<"$last" \
    || { echo "!!! FAIL: (a) not loaded from Contents/Frameworks as 1.0.0"; FAILED=1; }
  echo "--- (b) NO library bundled + decoy in cwd: StateError, decoy never loaded"
  rm -f "$APP/Contents/Frameworks/libsearch_simpli.dylib"
  sign_app
  run_app fail
  last="$out_last"
  grep -q 'did not ship' <<<"$last" || { echo "!!! FAIL: (b) no 'did not ship' error"; FAILED=1; }
  ! grep -q 'decoy' <<<"$(grep -E 'LOADED_FROM' <<<"$last")" || { echo "!!! FAIL: (b) the decoy was loaded"; FAILED=1; }
  if [ "$FAILED" -ne 0 ]; then echo "PROBE RESULT: FAILED"; exit 1; fi
  echo "PROBE RESULT: ok (decoy)"
  exit 0
fi
for sandbox in false true; do
  echo "=== sandbox=$sandbox ==="
  set_sandbox "$sandbox"
  flutter build macos --debug >/dev/null
  echo "--- negative control: no dylib in Contents/Frameworks (expect PROBE_FAIL listing candidates)"
  rm -f "$APP/Contents/Frameworks/libsearch_simpli.dylib"
  sign_app
  run_app fail
  echo "--- dylib copied into Contents/Frameworks, signed with the app"
  cp "$DYLIB" "$APP/Contents/Frameworks/"
  codesign --force -s - "$APP/Contents/Frameworks/libsearch_simpli.dylib" 2>/dev/null
  sign_app
  show_sandbox
  run_app answer
done
if [ "$FAILED" -ne 0 ]; then echo "PROBE RESULT: FAILED"; exit 1; fi
echo "PROBE RESULT: ok"
