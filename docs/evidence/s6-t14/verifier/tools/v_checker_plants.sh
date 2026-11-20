#!/usr/bin/env bash
# Verifier's checker plants for S6-T14: each in its own fresh copy of the head's
# archive (only scripts/, docs/ and zig/ are needed), checker run with --root.
set -uo pipefail
S="$HOME/workspace/repos/search-simpli-wt/S6-T14-vscratch.noindex"
CHECK="$S/head-arch/scripts/check_layers.py"
fresh() {
  local d="$S/cplant-$1"
  mkdir "$d" || exit 2
  git -C "$HOME/workspace/repos/search-simpli-wt/S6-T14" archive a54c7f8 scripts docs/layers.md zig/src | tar -x -C "$d"
  echo "$d"
}
run() {
  echo "--- checker on $1:"
  python3 -I "$CHECK" --root "$1"
  echo "exit $?"
}

echo "=== C0 unchanged copy"
d=$(fresh c0); run "$d"

echo "=== C1 a core file imports an operations file through the module name"
d=$(fresh c1)
printf 'const plant_ops = @import("operations").service;\n' >> "$d/zig/src/core/scoring.zig"
diff -u "$S/head-arch/zig/src/core/scoring.zig" "$d/zig/src/core/scoring.zig" | tail -3
run "$d"

echo "=== C2 a file in the wrong folder (ops/report.zig moved to core/)"
d=$(fresh c2)
mv "$d/zig/src/ops/report.zig" "$d/zig/src/core/report.zig"
ls "$d/zig/src/core/report.zig"
run "$d"

echo "=== C3 a new unassigned file in core/"
d=$(fresh c3)
printf 'const std = @import("std");\npub fn plant() void {}\n' > "$d/zig/src/core/plant_new.zig"
run "$d"

echo "=== C4 a test in a layer folder that reaches two layers (core/plant_x_test.zig imports core and operations)"
d=$(fresh c4)
printf 'const engine = @import("engine.zig");\nconst service = @import("operations").service;\n' > "$d/zig/src/core/plant_x_test.zig"
run "$d"

echo "=== C4b the same test reaching operations by path"
d=$(fresh c4b)
printf 'const engine = @import("engine.zig");\nconst service = @import("../ops/service.zig");\n' > "$d/zig/src/core/plant_y_test.zig"
run "$d"

echo "=== C5 a path import escaping a module root (ops/service.zig imports ../core/engine.zig)"
d=$(fresh c5)
printf 'const plant_engine = @import("../core/engine.zig");\n' >> "$d/zig/src/ops/service.zig"
run "$d"

echo "=== C5b a path import leaving zig/src (core/scoring.zig imports ../../build.zig)"
d=$(fresh c5b)
printf 'const plant_build = @import("../../build.zig");\n' >> "$d/zig/src/core/scoring.zig"
run "$d"

echo "=== C6 --write-doc on an unchanged copy leaves docs/layers.md unchanged"
d=$(fresh c6)
python3 -I "$CHECK" --root "$d" --write-doc; echo "exit $?"
cmp "$d/docs/layers.md" "$S/head-arch/docs/layers.md" && echo "docs/layers.md unchanged by --write-doc"

echo "=== C7 a test in tests/ that reaches one layer only"
d=$(fresh c7)
printf 'const fold = @import("core").fold;\n' > "$d/zig/src/tests/plant_one_layer_test.zig"
run "$d"

echo "=== C8 an interface importing another interface, a pair not in ALLOWED (interfaces/cli.zig imports rpc.zig)"
d=$(fresh c8)
printf 'const plant_rpc = @import("rpc.zig");\n' >> "$d/zig/src/interfaces/cli.zig"
run "$d"
