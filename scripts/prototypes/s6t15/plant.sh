#!/usr/bin/env bash
# S6-T15 ruling 1: one Zig plant in its own copy and Zig caches.
#
#   scripts/prototypes/s6t15/plant.sh NAME COMMIT SCRATCH
#
# Makes SCRATCH/plant-NAME from `git archive COMMIT` (a fresh copy, nothing shared),
# applies plants.py NAME, prints the diff against SCRATCH/base (a pristine archive of
# COMMIT, made once), runs `zig build test --summary all` (Debug) with the copy's own
# local and global caches, and the copy's own checker. Zig on PATH. Never removes
# anything.
set -uo pipefail
name="$1"; commit="$2"; scratch="$3"
here="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd -P "$here/../../.." && pwd)"
copy="$scratch/plant-$name"
base="$scratch/base"
if [ ! -d "$base" ]; then
  mkdir -p "$base" && git -C "$repo" archive "$commit" | tar -x -C "$base"
fi
if [ -e "$copy" ]; then echo "plant.sh: $copy exists" >&2; exit 2; fi
mkdir -p "$copy" && git -C "$repo" archive "$commit" | tar -x -C "$copy"
python3 -I "$here/plants.py" "$name" "$copy" || exit 2
echo "################ plant $name (from $commit)"
echo "--- diff against the archive:"
diff -ruN "$base/zig/src" "$copy/zig/src" | sed "s#$scratch#<scratch>#g"
echo "--- zig build test --summary all (Debug), own caches:"
(
  cd "$copy/zig" && zig build test --summary all \
    --cache-dir "$copy/.zig-local-cache" --global-cache-dir "$copy/.zig-global-cache" > "$copy/zig-build-test.txt" 2>&1
)
code=$?
grep -E "Build Summary|run test|error: '|failed\.|passed;|^error:" "$copy/zig-build-test.txt" | sed "s#$scratch#<scratch>#g" | head -40
grep -E "^.*plant.*(FAIL|fail)|plant .*: a failing test|expected 1, found 2" "$copy/zig-build-test.txt" | sed "s#$scratch#<scratch>#g" | head -10
echo "zig build test exit $code"
echo "--- the checker on this copy:"
python3 -I "$copy/scripts/check_layers.py" --root "$copy" | sed "s#$scratch#<scratch>#g" | tail -4
echo "check_layers exit ${PIPESTATUS[0]}"
