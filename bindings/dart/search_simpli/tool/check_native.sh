#!/usr/bin/env bash
# tool/check_native.sh — verify the shipped native binaries (docs/tasks/S1-T21.md
# ruling 2): the macOS dylib, the Android .so and the iOS framework are all
# arm64 (aarch64), the framework binary's segments are 16 KiB page-aligned
# (docs/tasks/S1-T22.md ruling 2), and the framework's Info.plist carries the
# required keys.
# Needs macOS (lipo, plutil, vtool, otool); run from anywhere.
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

# Every segment 16 KiB (0x4000) page-aligned (docs/tasks/S1-T22.md ruling 2):
# fileoff, vmsize and filesize. __PAGEZERO (executables only) is skipped.
# __LINKEDIT's filesize is exempt: it is the last segment and ends at the end
# of the file, unrounded, in Apple-linked iOS dylibs too (its fileoff and
# vmsize are page multiples there, so they are checked here).
PAGE=16384
nseg=0
while read -r seg vmsize fileoff filesize; do
  nseg=$((nseg + 1))
  [ "$seg" = "__PAGEZERO" ] && continue
  for field in fileoff vmsize filesize; do
    [ "$seg" = "__LINKEDIT" ] && [ "$field" = "filesize" ] && continue
    value="${!field}"
    if [ $((value % PAGE)) -ne 0 ]; then
      bad "ios-arm64 framework segment $seg $field $(printf '0x%x' "$value") is not a multiple of 16 KiB (0x4000)"
    fi
  done
done < <(otool -l "$FW/search_simpli" | awk '
  $1 == "cmd" { inseg = ($2 == "LC_SEGMENT_64") }
  inseg && $1 == "segname" { seg = $2 }
  inseg && $1 == "vmsize" { vmsize = $2 }
  inseg && $1 == "fileoff" { fileoff = $2 }
  inseg && $1 == "filesize" { print seg, vmsize, fileoff, $2; inseg = 0 }')
[ "$nseg" -gt 0 ] || bad "ios-arm64 framework binary has no LC_SEGMENT_64 (otool -l)"

plist_value() { plutil -extract "$1" raw -o - "$FW/Info.plist" 2>/dev/null || true; }
[ "$(plist_value CFBundleIdentifier)" = "family.vizhi.searchsimpli" ] || bad "CFBundleIdentifier"
[ "$(plist_value CFBundleExecutable)" = "search_simpli" ] || bad "CFBundleExecutable"
[ -n "$(plist_value CFBundleName)" ] || bad "CFBundleName"
[ "$(plist_value CFBundlePackageType)" = "FMWK" ] || bad "CFBundlePackageType"
[ "$(plist_value MinimumOSVersion)" = "17.0" ] || bad "MinimumOSVersion"
[ "$(plist_value CFBundleSupportedPlatforms.0)" = "iPhoneOS" ] || bad "CFBundleSupportedPlatforms"

# S4-T18: memcpy is the library's word-wise copy (zig/src/fastmem.zig), not
# compiler_rt's byte loop. In each binary memcpy is the most-called function
# (calls plus tail calls; 0.3.11: 182 against 101 on Apple, 356 against 140 on
# Android, whose .so is stripped); the code there and in the functions it
# calls must move 16-byte q registers (ldr/str/ldp/stp q, ld1/st1) and hold
# no loop that loads and stores single bytes (a backward branch over at most
# eight instructions with ldrb, strb and a step of one). Shaped for the
# shipped ReleaseSmall natives; Debug code has other most-called functions. On Apple it must be the local
# `_memcpy`, and memcpy, memmove and memset must not be exported.
copy_check() {
  python3 -I - "$1" "$2" <<'PY'
import collections, re, subprocess, sys
label, binary = sys.argv[1], sys.argv[2]
text = subprocess.run(["objdump", "-d", "--no-show-raw-insn", binary], capture_output=True, text=True, check=True).stdout
ins = []
for line in text.splitlines():
    m = re.match(r"^\s+([0-9a-f]+):\s+(\S+)\s*(.*)$", line)
    if m:
        ins.append((int(m.group(1), 16), m.group(2), m.group(3)))
calls, entries = collections.Counter(), set()
for _, mnemonic, operands in ins:
    t = re.match(r"0x([0-9a-f]+)", operands)
    if mnemonic in ("bl", "b") and t:
        calls[int(t.group(1), 16)] += 1
        if mnemonic == "bl":
            entries.add(int(t.group(1), 16))
(target, count), (_, runner_up) = calls.most_common(2)
index = {a: i for i, (a, _, _) in enumerate(ins)}
def window(start):
    later = [e for e in entries if e > start]
    end = min(later) if later else start + 0x800
    return [x for x in ins[index[start]:] if x[0] < min(end, start + 0x800)]
body = window(target)
for a, mnemonic, operands in list(body):
    t = re.match(r"0x([0-9a-f]+)", operands)
    if mnemonic == "bl" and t and int(t.group(1), 16) in index:
        body += window(int(t.group(1), 16))
vector = [x for x in body if x[1] in ("ld1", "st1") or (x[1] in ("ldr", "str", "ldur", "stur", "ldp", "stp") and x[2].startswith("q"))]
loops = []
for i, (a, mnemonic, operands) in enumerate(body):
    t = re.match(r"(?:[wx]\d+, )?(?:#\d+, )?0x([0-9a-f]+)", operands)
    if (mnemonic == "b" or mnemonic.startswith("b.") or mnemonic in ("cbz", "cbnz", "tbz", "tbnz")) and t:
        back = int(t.group(1), 16)
        if back <= a:
            loop = [(m, o) for (x, m, o) in body if back <= x <= a]
            names = [m for m, _ in loop]
            # compiler_rt's loops: a byte load, a byte store and a step of one
            # (an add or sub of #0x1, or a post-indexed #0x1) in a few
            # instructions.
            step = any(o.endswith("#0x1") for _, o in loop)
            if len(loop) <= 8 and "ldrb" in names and "strb" in names and step:
                loops.append(hex(back))
problems = []
if not vector:
    problems.append("no 16-byte (q register) load or store")
if loops:
    problems.append("byte loop at " + ", ".join(loops))
print(f"{label}\t0x{target:x}\t{count}\t{runner_up}\t{len(vector)}\t{'; '.join(problems)}")
PY
}
for spec in "macos-arm64:$NATIVE/macos-arm64/libsearch_simpli.dylib" \
            "android-arm64:$NATIVE/android-arm64/libsearch_simpli.so" \
            "ios-arm64:$FW/search_simpli"; do
  label="${spec%%:*}"; binary="${spec#*:}"
  IFS=$'\t' read -r _ address count runner_up vectors problems < <(copy_check "$label" "$binary")
  if [ -n "$problems" ]; then
    bad "$label memcpy (most-called, $address, $count calls against $runner_up) is not a word-wise copy: $problems"
  else
    echo "check_native: $label memcpy at $address ($count calls against $runner_up): word-wise ($vectors q-register moves, no byte loop)"
  fi
  if [ "$label" != "android-arm64" ]; then
    symbol="$(nm -m "$binary" | awk '$NF == "_memcpy" && /__TEXT,__text/ {print "0x" $1}' | head -1)"
    [ "$((symbol))" = "$((address))" ] || bad "$label most-called target $address is not _memcpy ($symbol)"
    exported="$(nm -gU "$binary" | awk '{print $3}' | grep -x -e _memcpy -e _memmove -e _memset || true)"
    [ -z "$exported" ] || bad "$label exports $exported"
  else
    if nm -D --undefined-only "$binary" | grep -q -E ' (memcpy|memmove|memset)(@|$)'; then
      bad "$label imports memcpy, memmove or memset (the word-wise copy should be bound inside)"
    fi
  fi
done

if [ "$fail" -eq 0 ]; then echo "check_native: ok (macos-arm64, android-arm64, ios-arm64 framework; $nseg segments 16 KiB aligned; memcpy word-wise in all three)"; fi
exit "$fail"
