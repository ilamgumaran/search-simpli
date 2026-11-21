#!/usr/bin/env bash
# vplants.sh REPO COMMIT DIR : fresh git archive of COMMIT into DIR (must not exist), plant five uses of the
# two dropped names (forms other than the builder's), run the copy's own check_layers.py. Removes nothing.
set -uo pipefail
repo="$1"; commit="$2"; dir="$3"
if [ -e "$dir" ]; then echo "exists: $dir" >&2; exit 2; fi
mkdir -p "$dir" && git -C "$repo" archive "$commit" | tar -x -C "$dir"
s="$dir/zig/src"
# 1 ops, whole-api alias at top level, used in a test
printf 'const planted_api = @import("core").api;\ntest "vplant 1" {\n    _ = planted_api.manifest.decode;\n}\n' >> "$s/ops/report.zig"
# 2 ops, shipped-looking code: a pub fn returning the id inline
printf 'pub fn vplantedId() []const u8 {\n    return @import("core").api.analyzer_v2.analyzer_id;\n}\n' >> "$s/ops/ops.zig"
# 3 interfaces, alias bound inside a test block
printf 'test "vplant 3" {\n    const a2 = @import("core").api.analyzer_v2;\n    _ = a2.analyzer_id;\n}\n' >> "$s/interfaces/cli.zig"
# 4 interfaces, top-level alias of the name itself
printf 'const vplanted_decode = @import("core").api.manifest.decode;\n' >> "$s/interfaces/mcp.zig"
# 5 interfaces, the file-of-tests beside the code
printf 'test "vplant 5" {\n    _ = @import("core").api.manifest.decode;\n}\n' >> "$s/interfaces/field_warnings_test.zig"
(cd "$dir" && python3 -I scripts/check_layers.py --root "$dir" 2>&1 | sed "s#$dir#<copy>#g")
echo "check_layers.py exit ${PIPESTATUS[0]}"
