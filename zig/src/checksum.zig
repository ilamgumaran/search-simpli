//! Section integrity checksums (S4-T1 ruling 2).
//!
//! Every immutable section (`HYBSEG01` documents, `HYBLEX01`/`HYBLEX02`
//! lexical, `HYBSRC01` source) ends its header with a 64-bit checksum over
//! the header bytes before it and then the whole payload, and the manifest
//! records each section's checksum. It is an accidental-corruption check,
//! not authentication. Until S4-T1 it was always FNV-1a 64, one byte per
//! step (about 1.15 GB/s on the benchmark machine, 26 ms per pass over the
//! 30 MB of a 10k-file generation in `ReleaseSmall`). Since S4-T1 a section
//! whose header sets `flag_xxh3` uses XXH3-64 (seed 0) instead (about 17
//! GB/s in `ReleaseSmall`): every section a folder writer (`index_folder`,
//! `apply_changes`) writes sets it, and the v2 manifest that binds them sets
//! its own `flag_xxh3_sections` (`docs/manifest-format-v2.md` v2.1).
//! Sections without the flag (every generation written before S4-T1, and
//! `import-json`'s v1-manifest generations, which stay byte for byte as
//! they were) keep FNV-1a 64 and are read as before. SHA-256 stays the
//! per-file content id (the source section's file table, `INDEX-STATE`).
const std = @import("std");

pub const Kind = enum {
    fnv1a64,
    xxh3_64,

    pub fn label(kind: Kind) []const u8 {
        return switch (kind) {
            .fnv1a64 => "fnv1a-64",
            .xxh3_64 => "xxh3-64",
        };
    }
};

/// Bit 0 of a section header's u16 flags: the checksum is XXH3-64.
pub const flag_xxh3: u16 = 1;

/// The checksum kind a section header's flags select.
pub fn kindOfFlags(flags: u16) Kind {
    return if (flags & flag_xxh3 != 0) .xxh3_64 else .fnv1a64;
}

/// The flags bit a writer sets for `kind`.
pub fn flagsOf(kind: Kind) u16 {
    return if (kind == .xxh3_64) flag_xxh3 else 0;
}

/// The checksum of `header_without_checksum` followed by `payload`.
pub fn compute(kind: Kind, header_without_checksum: []const u8, payload: []const u8) u64 {
    switch (kind) {
        .fnv1a64 => {
            var value: u64 = fnv_offset_basis;
            value = fnvUpdate(value, header_without_checksum);
            return fnvUpdate(value, payload);
        },
        .xxh3_64 => {
            var state = std.hash.XxHash3.init(0);
            state.update(header_without_checksum);
            state.update(payload);
            return state.final();
        },
    }
}

const fnv_offset_basis: u64 = 14_695_981_039_346_656_037;
const fnv_prime: u64 = 1_099_511_628_211;

fn fnvUpdate(initial: u64, bytes: []const u8) u64 {
    var value = initial;
    for (bytes) |byte| {
        value ^= byte;
        value *%= fnv_prime;
    }
    return value;
}

test "FNV-1a 64 is the pre-S4-T1 section checksum" {
    // The published FNV-1a 64 test vectors.
    try std.testing.expectEqual(@as(u64, 0xcbf29ce484222325), compute(.fnv1a64, "", ""));
    try std.testing.expectEqual(@as(u64, 0xaf63dc4c8601ec8c), compute(.fnv1a64, "a", ""));
    try std.testing.expectEqual(compute(.fnv1a64, "foobar", ""), compute(.fnv1a64, "foo", "bar"));
}

test "XXH3-64 with seed 0 over the header then the payload" {
    // The reference implementation's XXH3_64bits("") with seed 0.
    try std.testing.expectEqual(@as(u64, 0x2d06800538d394c2), compute(.xxh3_64, "", ""));
    // Two slices hash as their concatenation, at every split.
    var buffer: [1031]u8 = undefined;
    for (&buffer, 0..) |*byte, index| byte.* = @truncate(index *% 31 +% 7);
    const whole = std.hash.XxHash3.hash(0, &buffer);
    for ([_]usize{ 0, 1, 16, 48, 64, 128, 240, 241, 512, 1030, 1031 }) |split| {
        try std.testing.expectEqual(whole, compute(.xxh3_64, buffer[0..split], buffer[split..]));
    }
    try std.testing.expect(compute(.xxh3_64, "abc", "") != compute(.fnv1a64, "abc", ""));
}

test "flags select the kind" {
    try std.testing.expectEqual(Kind.fnv1a64, kindOfFlags(0));
    try std.testing.expectEqual(Kind.xxh3_64, kindOfFlags(flag_xxh3));
    try std.testing.expectEqual(flag_xxh3, flagsOf(.xxh3_64));
    try std.testing.expectEqual(@as(u16, 0), flagsOf(.fnv1a64));
}
