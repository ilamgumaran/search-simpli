#!/usr/bin/env bash
# Plant "unnamed": a new core test file with a failing test, named in no module root.
set -uo pipefail
unset SEARCH_SIMPLI_LIBRARY_PATH
export PATH=$HOME/development/zig/zig-0.16.0-macos-aarch64:$PATH
S="$HOME/workspace/repos/search-simpli-wt/S6-T14-vscratch.noindex"
d="$S/zplant-unnamed"
mkdir "$d" || exit 2
git -C "$HOME/workspace/repos/search-simpli-wt/S6-T14" archive a54c7f8 | tar -x -C "$d"
cat > "$d/zig/src/core/plant_unnamed_test.zig" <<'EOF'
const std = @import("std");
const scoring = @import("scoring.zig");

test "plant: a new core test named in no module root" {
    _ = scoring;
    try std.testing.expectEqual(@as(u32, 1), 2);
}
EOF
echo "plant unnamed: new file zig/src/core/plant_unnamed_test.zig:"
cat "$d/zig/src/core/plant_unnamed_test.zig"
cd "$d/zig"
ZIG_GLOBAL_CACHE_DIR="$S/cache-zplant-unnamed-g" zig build test --summary all --cache-dir "$S/cache-zplant-unnamed-l" > "$S/zplant-unnamed.log" 2>&1
echo "zig build test exit $?"
grep -E 'Build Summary|^\+- run test' "$S/zplant-unnamed.log" | grep -v ' w$' | head -8
echo "--- the checker on this copy:"
python3 -I "$S/head-arch/scripts/check_layers.py" --root "$d"; echo "check_layers exit $?"
