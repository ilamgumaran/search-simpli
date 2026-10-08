#!/usr/bin/env bash
# docs/tasks/S1-T10.md criterion 3: prove openSearchSimpliLibrary() finds
# libsearch_simpli.dylib inside a BUILT macOS .app (Contents/Frameworks), with
# SEARCH_SIMPLI_LIBRARY_PATH unset, cwd "/", with the app sandbox off and on.
# Builds a throwaway Flutter app in a temp directory (never inside the repo).
# Usage: tool/bundle_probe.sh   (needs: source ~/development/env.sh; Xcode)
set -euo pipefail

PKG="$(cd "$(dirname "$0")/.." && pwd)"
DYLIB="$PKG/native/macos-arm64/libsearch_simpli.dylib"
SNAP="$PKG/example/assets/demo_snapshot"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/ss-bundle-probe.XXXXXX")"
echo "probe workdir: $WORK"
cd "$WORK"
unset SEARCH_SIMPLI_LIBRARY_PATH

flutter create --platforms macos --project-name probe_app probe_app >/dev/null
cd probe_app
mkdir -p assets/demo_snapshot
cp "$SNAP"/* assets/demo_snapshot/
python3 - "$PKG" <<'PY'
import sys
pkg = sys.argv[1]
s = open('pubspec.yaml').read()
s = s.replace('dependencies:\n  flutter:\n    sdk: flutter\n',
  f'dependencies:\n  flutter:\n    sdk: flutter\n  search_simpli:\n    path: {pkg}\n  path: ^1.9.0\n', 1)
s = s.replace('  uses-material-design: true',
  '  uses-material-design: true\n  assets:\n    - assets/demo_snapshot/', 1)
assert 'assets/demo_snapshot/' in s
open('pubspec.yaml', 'w').write(s)
PY
cat > lib/main.dart <<'DART'
import 'dart:io';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as p;
import 'package:search_simpli/search_simpli.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  var code = 0;
  try {
    final dir = Directory.systemTemp.createTempSync('ss_probe_');
    for (final n in ['MANIFEST', 'documents-1.hybseg', 'lexical-1.hyblex']) {
      final b = await rootBundle.load('assets/demo_snapshot/$n');
      File(p.join(dir.path, n)).writeAsBytesSync(b.buffer.asUint8List(b.offsetInBytes, b.lengthInBytes));
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
  await stdout.flush();
  exit(code);
}
DART
flutter pub get >/dev/null

set_sandbox() { # $1 = true|false
  for f in macos/Runner/DebugProfile.entitlements macos/Runner/Release.entitlements; do
    /usr/libexec/PlistBuddy -c "Set :com.apple.security.app-sandbox $1" "$f"
  done
  echo "--- entitlement com.apple.security.app-sandbox = $(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.app-sandbox' macos/Runner/DebugProfile.entitlements)"
}

run_app() { # run from cwd "/" with the env var unset; 40 s bound
  local app="$PWD/build/macos/Build/Products/Debug/probe_app.app"
  echo "command: cd / && env -u SEARCH_SIMPLI_LIBRARY_PATH <app>/Contents/MacOS/probe_app"
  ( cd / && env -u SEARCH_SIMPLI_LIBRARY_PATH perl -e 'alarm 40; exec @ARGV' -- "$app/Contents/MacOS/probe_app" 2>&1 ) \
    | grep -E 'PROBE_|search_simpli: could not|^/|^libsearch' | head -12 || true
}

APP=build/macos/Build/Products/Debug/probe_app.app
# Re-signing must pass the entitlements again, or codesign drops them (and the
# "sandbox on" run would silently not be sandboxed).
sign_app() { codesign --force --deep -s - --entitlements macos/Runner/DebugProfile.entitlements "$APP" 2>/dev/null; }
show_sandbox() { echo "--- signed app-sandbox entitlement: $(codesign -d --entitlements - "$APP" 2>&1 | grep -c 'com.apple.security.app-sandbox') (1 = present; value below)"; codesign -d --entitlements - "$APP" 2>&1 | grep -A1 app-sandbox | tr -d '\n'; echo; }
for sandbox in false true; do
  echo "=== sandbox=$sandbox ==="
  set_sandbox "$sandbox"
  flutter build macos --debug >/dev/null
  echo "--- negative control: no dylib in Contents/Frameworks (expect PROBE_FAIL listing candidates)"
  rm -f "$APP/Contents/Frameworks/libsearch_simpli.dylib"
  sign_app
  run_app
  echo "--- dylib copied into Contents/Frameworks, signed with the app"
  cp "$DYLIB" "$APP/Contents/Frameworks/"
  codesign --force -s - "$APP/Contents/Frameworks/libsearch_simpli.dylib" 2>/dev/null
  sign_app
  show_sandbox
  run_app
done
echo "probe workdir (delete when done): $WORK"
