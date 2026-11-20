#!/usr/bin/env bash
# One Zig plant: a fresh archive of the head, one line changed, its own global
# and local Zig caches, `zig build test --summary all`.
# Usage: v_zig_plant.sh NAME FILE(relative to zig/src) LINE OLD NEW [extra zig build args]
set -uo pipefail
unset SEARCH_SIMPLI_LIBRARY_PATH
export PATH=$HOME/development/zig/zig-0.16.0-macos-aarch64:$PATH
S="$HOME/workspace/repos/search-simpli-wt/S6-T14-vscratch.noindex"
name=$1 file=$2 line=$3 old=$4 new=$5; shift 5
d="$S/zplant-$name"
mkdir "$d" || exit 2
git -C "$HOME/workspace/repos/search-simpli-wt/S6-T14" archive a54c7f8 | tar -x -C "$d"
python3 -I - "$d/zig/src/$file" "$line" "$old" "$new" <<'EOF'
import sys
path, line, old, new = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4]
lines = open(path, encoding="utf-8").read().split("\n")
assert lines[line - 1].count(old) == 1, (lines[line - 1], old)
lines[line - 1] = lines[line - 1].replace(old, new)
open(path, "w", encoding="utf-8").write("\n".join(lines))
EOF
echo "plant $name: diff"
diff -u "$S/head-arch/zig/src/$file" "$d/zig/src/$file"
cd "$d/zig"
ZIG_GLOBAL_CACHE_DIR="$S/cache-zplant-$name-g" zig build test --summary all --cache-dir "$S/cache-zplant-$name-l" "$@" > "$S/zplant-$name.log" 2>&1
code=$?
echo "zig build test exit $code"
grep -E 'Build Summary|^\+- run test|error: .*(expected|TestExpected|failed)|^error: \x27|FAIL' "$S/zplant-$name.log" | grep -v NFR-13 | head -12
