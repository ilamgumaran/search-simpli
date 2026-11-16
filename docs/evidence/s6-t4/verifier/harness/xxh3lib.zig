const std = @import("std");
export fn vxxh3(ptr: [*]const u8, len: usize) u64 {
    return std.hash.XxHash3.hash(0, ptr[0..len]);
}
