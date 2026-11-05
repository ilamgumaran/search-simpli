//! S4-T6 ruling 3(a): reads after `apply_changes` on the served generation.
//!
//! `searchd serve --allow-write` answers `apply_changes` and then reloads the
//! index (`rpc.Served`); before S4-T6 the reloaded generation's `scope.Loads`
//! kept an allocator that pointed at a freed `ArenaAllocator`, so the first
//! lazy load after a write (`read_span`, `outline`, `find`,
//! `search_knowledge`, `list_files`) called through freed memory: a crash in
//! a release build, silence in Debug (the Debug allocator never reuses a
//! freed block). These tests drive the request lines through the same path
//! `searchd serve` uses (`rpc.Served.handle`: `rpc.handleLineWith`, its
//! `apply_changes` handler, the reload) and then read from the reloaded
//! generation.
//!
//! Each runs over two general-purpose allocators: the testing allocator
//! behind a wrapper that overwrites every freed block with 0xAA before
//! freeing it (leak detection from the testing allocator; a use after free
//! through a stale pointer reads the pattern and faults at once instead of
//! finding the old bytes intact), and the C allocator, the one a release
//! `searchd` gets (it links libc), which hands a freed block to the next
//! allocation of that size: the mechanism of the original crash. Run under
//! `zig build test` (Debug) and `zig build test -Doptimize=ReleaseSmall`.
const std = @import("std");
const apply = @import("apply.zig");
const rpc = @import("rpc.zig");

const io = std.testing.io;

/// Overwrites each block with 0xAA before `backing` frees it.
const Poisoning = struct {
    backing: std.mem.Allocator,

    fn allocator(self: *Poisoning) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *Poisoning = @ptrCast(@alignCast(ctx));
        return self.backing.rawAlloc(len, alignment, ret_addr);
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *Poisoning = @ptrCast(@alignCast(ctx));
        if (new_len < memory.len) @memset(memory[new_len..], 0xAA);
        return self.backing.rawResize(memory, alignment, new_len, ret_addr);
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        // A remap may move the block and free the old one inside `backing`,
        // where it cannot be poisoned: refuse, so callers allocate, copy and
        // free through `free` below.
        _ = ctx;
        _ = memory;
        _ = alignment;
        _ = new_len;
        _ = ret_addr;
        return null;
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *Poisoning = @ptrCast(@alignCast(ctx));
        @memset(memory, 0xAA);
        self.backing.rawFree(memory, alignment, ret_addr);
    }
};

const initial_request =
    \\{"roots":[{"root_id":"school","label":"School","kind":"host"},{"root_id":"home","label":"Home","kind":"host"}],
    \\"changes":[{"op":"add","root_id":"school","path":"week.md","content_base64":"IyBXZWVrCgojIyBUaWRlcwoKdGlkZSB0YWJsZSBvbiBNb25kYXkK"},
    \\{"op":"add","root_id":"school","path":"notes.md","content_base64":"IyBOb3RlcwoKdGlkZSBwb29scyBhbmQgc2hlbGxzCg=="},
    \\{"op":"add","root_id":"home","path":"chores.md","content_base64":"IyBDaG9yZXMKCnN3ZWVwIHRoZSBwb3JjaAo="}]}
;

/// One request line through `served`; the answer, owned by `a`.
fn call(served: *rpc.Served, a: std.mem.Allocator, method: []const u8, params: []const u8) ![]const u8 {
    const line = try std.fmt.allocPrint(a, "{{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"{s}\",\"params\":{s}}}", .{ method, params });
    var out: std.Io.Writer.Allocating = .init(a);
    try served.handle(line, &out.writer);
    return out.written();
}

fn expectHas(haystack: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, haystack, needle) == null) {
        std.debug.print("expected {s} in {s}\n", .{ needle, haystack });
        return error.TestExpectedSubstring;
    }
}

fn expectLacks(haystack: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, haystack, needle) != null) {
        std.debug.print("did not expect {s} in {s}\n", .{ needle, haystack });
        return error.TestUnexpectedSubstring;
    }
}

/// The served generation's lazy loads allocate through its own arena.
fn expectOwnArena(served: *const rpc.Served) !void {
    const loads = served.generation.service.folder.?.loads;
    try std.testing.expect(loads.allocator.ptr == @as(*anyopaque, served.generation.arena));
}

/// Open a published folder, read from generation 1 (its lazy loads run),
/// apply one batch through `apply_changes`, then `read_span`, `find`,
/// `search_knowledge`, `outline` and `list_files` on the reloaded
/// generation; a second batch, the same reads on generation 3. `warm`:
/// whether generation 1 loads its source and statistics before the write.
fn readsAfterApply(gpa: std.mem.Allocator, warm: bool) !void {
    var scratch_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer scratch_state.deinit();
    const a = scratch_state.allocator();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    _ = (try apply.applyChanges(a, io, tmp.dir, initial_request, .{})).ok;
    const path = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    var served = try rpc.Served.open(gpa, io, path, .{ .allow_write = true, .dir_path = path, .io = io });
    defer served.close();
    try expectOwnArena(&served);

    if (warm) {
        try expectHas(try call(&served, a, "read_span", "{\"root_id\":\"school\",\"path\":\"notes.md\",\"start_line\":3,\"end_line\":3}"), "\"text\":\"tide pools and shells\\n\"");
        try expectHas(try call(&served, a, "find", "{\"query\":\"tide\"}"), "\"path\":\"notes.md\"");
        try expectHas(try call(&served, a, "index_status", "{}"), "\"source\":\"verified\"");
    }

    const applied = try call(&served, a, "apply_changes", "{\"expect_generation\":1,\"changes\":[{\"op\":\"remove\",\"root_id\":\"school\",\"path\":\"notes.md\"}]}");
    try expectHas(applied, "\"result\":{\"generation\":2,");
    try expectOwnArena(&served);
    // The reloaded generation has loaded nothing yet.
    try expectHas(try call(&served, a, "index_status", "{}"), "\"source\":\"unverified\"");
    try expectHas(try call(&served, a, "index_status", "{}"), "\"generation\":2,");

    const removed = try call(&served, a, "read_span", "{\"root_id\":\"school\",\"path\":\"notes.md\",\"start_line\":1,\"end_line\":1}");
    try expectHas(removed, "\"error\":{\"code\":-32004,");
    const kept = try call(&served, a, "read_span", "{\"root_id\":\"school\",\"path\":\"week.md\",\"start_line\":5,\"end_line\":5}");
    try expectHas(kept, "\"text\":\"tide table on Monday\\n\"");
    const found = try call(&served, a, "find", "{\"query\":\"tide\"}");
    try expectHas(found, "\"path\":\"week.md\"");
    try expectLacks(found, "notes.md");
    const searched = try call(&served, a, "search_knowledge", "{\"query\":\"tide\",\"retrieval_mode\":\"lexical\"}");
    try expectHas(searched, "school/week.md");
    try expectLacks(searched, "notes.md");
    const outline = try call(&served, a, "outline", "{\"root_id\":\"school\",\"path\":\"week.md\"}");
    try expectHas(outline, "\"text\":\"Tides\"");
    const listed = try call(&served, a, "list_files", "{}");
    try expectHas(listed, "\"total\":2");
    try expectHas(try call(&served, a, "index_status", "{}"), "\"source\":\"verified\"");
    const loads = served.generation.service.folder.?.loads;
    try std.testing.expectEqual(@as(u32, 1), loads.source_loads);
    try std.testing.expectEqual(@as(u32, 1), loads.statistics_loads);
    try std.testing.expectEqual(@as(u32, 1), loads.positions_loads);

    // A second write: generation 3 gets its own arena and loads again.
    const again = try call(&served, a, "apply_changes", "{\"expect_generation\":2,\"changes\":[{\"op\":\"add\",\"root_id\":\"home\",\"path\":\"trip.md\",\"content_base64\":\"IyBUcmlwCgp0aGUgdGlkZSBtdXNldW0gb2Yga2l0ZXMK\"}]}");
    try expectHas(again, "\"result\":{\"generation\":3,");
    try expectOwnArena(&served);
    try expectHas(try call(&served, a, "read_span", "{\"root_id\":\"home\",\"path\":\"trip.md\",\"start_line\":3,\"end_line\":3}"), "\"text\":\"the tide museum of kites\\n\"");
    try expectHas(try call(&served, a, "find", "{\"query\":\"kites\"}"), "\"path\":\"trip.md\"");
    try expectHas(try call(&served, a, "search_knowledge", "{\"query\":\"museum\",\"retrieval_mode\":\"lexical\"}"), "home/trip.md");
    try expectHas(try call(&served, a, "outline", "{\"root_id\":\"home\",\"path\":\"trip.md\"}"), "\"text\":\"Trip\"");
    try expectHas(try call(&served, a, "list_files", "{}"), "\"total\":3");
}

test "S4-T6: reads after apply_changes on the reloaded generation (poisoned testing allocator)" {
    var poisoning = Poisoning{ .backing = std.testing.allocator };
    try readsAfterApply(poisoning.allocator(), false);
    try readsAfterApply(poisoning.allocator(), true);
}

test "S4-T6: reads after apply_changes on the reloaded generation (C allocator, as a release searchd)" {
    try readsAfterApply(std.heap.c_allocator, false);
    try readsAfterApply(std.heap.c_allocator, true);
}

test "S4-T6: a failed reload leaves the old generation served" {
    var poisoning = Poisoning{ .backing = std.testing.allocator };
    const gpa = poisoning.allocator();
    var scratch_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer scratch_state.deinit();
    const a = scratch_state.allocator();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    _ = (try apply.applyChanges(a, io, tmp.dir, initial_request, .{})).ok;
    const path = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var served = try rpc.Served.open(gpa, io, path, .{ .allow_write = true, .dir_path = path, .io = io });
    defer served.close();
    const before = served.generation.arena;
    // The directory is gone: the reload cannot open it.
    served.path = try std.fmt.allocPrint(a, "{s}-missing", .{path});
    try std.testing.expectError(error.FileNotFound, served.reload());
    try std.testing.expect(served.generation.arena == before);
    try expectHas(try call(&served, a, "read_span", "{\"root_id\":\"school\",\"path\":\"week.md\",\"start_line\":5,\"end_line\":5}"), "\"text\":\"tide table on Monday\\n\"");
}
