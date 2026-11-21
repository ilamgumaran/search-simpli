#!/bin/sh
# S6-T16: the error sets of the public core functions, from the compiler.
#   sh scripts/prototypes/s6t16/error_probe.sh SCRATCH_DIR REV
# Extracts zig/src/core of REV into SCRATCH_DIR/probe-errors, writes a scratch test
# that prints @typeInfo of each function's error set, and runs it with its own caches.
# Then: python3 -I scripts/prototypes/s6t16/error_sets.py SCRATCH_DIR/probe-errors/out.txt "$(dirname "$(command -v zig)")/lib/std"
set -eu
scratch="$1"; rev="$2"
mkdir -p "$scratch/probe-errors"
git archive "$rev" zig/src/core | tar -x -C "$scratch/probe-errors"
cd "$scratch/probe-errors/zig/src/core"
python3 -I - <<'PY'
fns = """apply.applyChanges apply.writeReportJson benchmark.run filename_field.tokenize find.find find.writeFields
generation_alloc.nextFreeGeneration hybrid.search importer.importJson importer.importJsonKeeping indexer.buildFolderDetached
indexer.indexFolder indexer.indexFolderIncremental lexical_segment.encode lifecycle.publishSerialized manifest.create
manifest.decode manifest.encode postings.build scope.recordPath scope.visibleCollection segment.encode
snapshot_open.open snapshot_open.openDetached snapshot_open.openScoped snapshot_open.openScopedDetached snapshot_open.openScopedWith
source.outline source.readSpan source.writeOutlineFields source.writeSpanFields title_field.derive""".split()
out = ['const std = @import("std");']
out += [f'const {f} = @import("{f}.zig");' for f in sorted({f.split(".")[0] for f in fns})]
out += ['fn show(comptime label: []const u8, comptime F: type) void {',
        '    const R = @typeInfo(F).@"fn".return_type.?;',
        '    switch (@typeInfo(R)) {',
        '        .error_union => |eu| {',
        '            const set = @typeInfo(eu.error_set).error_set;',
        '            std.debug.print("{s} -> {s}:", .{ label, @typeName(eu.payload) });',
        '            if (set) |errors| { inline for (errors) |e| std.debug.print(" {s}", .{e.name}); } else std.debug.print(" anyerror", .{});',
        '            std.debug.print("\\n", .{});',
        '        },',
        '        else => std.debug.print("{s} -> {s}: no error union\\n", .{ label, @typeName(R) }),',
        '    }',
        '}',
        'test "error sets" {']
out += [f'    show("{f}", @TypeOf({f}));' for f in fns]
out += ['}']
open('zz_probe_errors.zig', 'w').write('\n'.join(out) + '\n')
PY
# The other files' tests run too (one needs the repository's working directory and fails); only the printed lines matter.
zig test -lc --global-cache-dir "$scratch/probe-errors/g" --cache-dir "$scratch/probe-errors/l" zz_probe_errors.zig > "$scratch/probe-errors/out.txt" 2>&1 || true
