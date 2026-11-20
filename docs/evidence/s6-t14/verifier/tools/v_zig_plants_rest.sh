#!/usr/bin/env bash
# The remaining Zig plants, one after another (one build at a time).
S="$HOME/workspace/repos/search-simpli-wt/S6-T14-vscratch.noindex"
cd "$S" || exit 2
bash v_zig_plant.sh core-infile core/postings.zig 869 '@as(usize, 3)' '@as(usize, 4)' 2>&1 | tee zplant-core-infile.out
bash v_zig_plant.sh ops ops/ops.zig 1425 '@as(u64, 5)' '@as(u64, 6)' 2>&1 | tee zplant-ops.out
bash v_zig_plant.sh interfaces interfaces/field_warnings_test.zig 110 'tomatoes' 'tomatoesX' 2>&1 | tee zplant-interfaces.out
bash v_zig_plant.sh tests tests/compat_s6t9_test.zig 182 '@as(u64, 2)' '@as(u64, 3)' 2>&1 | tee zplant-tests.out
bash v_zig_plant.sh via-other-test core/manifest_inplace_test.zig 180 '"Truncated"' '"TruncatedX"' 2>&1 | tee zplant-via-other-test.out
bash v_zig_plant.sh fastmem core/fastmem.zig 197 '16 * 16 * 257' '16 * 16 * 258' 2>&1 | tee zplant-fastmem.out
# The module wiring by itself: a core file importing operations, by name and by path.
bash v_zig_plant.sh wiring-name core/scoring.zig 1 'const std = @import("std");' 'const std = @import("std"); const plant_ops = @import("operations").service; comptime { _ = plant_ops; }' 2>&1 | tee zplant-wiring-name.out
bash v_zig_plant.sh wiring-path core/scoring.zig 1 'const std = @import("std");' 'const std = @import("std"); const plant_ops = @import("../ops/service.zig"); comptime { _ = plant_ops; }' 2>&1 | tee zplant-wiring-path.out
echo ALL-PLANTS-DONE
