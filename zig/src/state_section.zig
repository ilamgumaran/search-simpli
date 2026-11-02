//! The generation's recovery state as its own immutable section,
//! `state-N.hybstate` (S4-T2 ruling R3, `docs/manifest-format-v2.md` v2.2,
//! flag bit 4). PR #21 bound a generation's mutation state (own labels,
//! hashes, sizes, mtimes, chunkers, moves) to the commit point by copying it
//! into the manifest's `meta`, which every open then read and parsed (a 10k
//! index's MANIFEST grew from about 540 B to 2.5 MB). Here it is a section
//! like the others: written and checksummed with XXH3-64, published before
//! the manifest, bound in the manifest by length and checksum, allocated and
//! pruned with its generation, and read **only by writers**
//! (`apply.zig`'s previous-generation path). An open never touches it.
//!
//! Layout (little-endian, 32-byte header):
//!
//! | Offset | Size | Field |
//! |---:|---:|---|
//! | 0 | 8 | magic `HYBSTA01` |
//! | 8 | 2 | version `1` |
//! | 10 | 2 | flags: bit 0 XXH3-64 (`checksum.flag_xxh3`); other bits zero |
//! | 12 | 4 | reserved, zero |
//! | 16 | 8 | payload byte length |
//! | 24 | 8 | checksum over bytes 0-23 then the payload |
//!
//! The payload is the state's version 2 JSON exactly as `INDEX-STATE.json`
//! holds it (`incremental_state.encode`).
const checksum_mod = @import("checksum.zig");
const std = @import("std");

pub const magic = "HYBSTA01";
pub const version: u16 = 1;
pub const header_length: usize = 32;

pub const DecodeError = error{ BadMagic, UnsupportedVersion, UnsupportedFlags, Truncated, TrailingData, ChecksumMismatch, SizeOverflow };

pub const Header = struct {
    payload_bytes: usize,
    checksum: u64,
    checksum_kind: checksum_mod.Kind,
};

/// The section for `json` (the state JSON), XXH3-64. Owned by `allocator`.
pub fn encode(allocator: std.mem.Allocator, json: []const u8) error{OutOfMemory}![]u8 {
    const out = try allocator.alloc(u8, header_length + json.len);
    @memcpy(out[0..magic.len], magic);
    std.mem.writeInt(u16, out[8..10], version, .little);
    std.mem.writeInt(u16, out[10..12], checksum_mod.flag_xxh3, .little);
    std.mem.writeInt(u32, out[12..16], 0, .little);
    std.mem.writeInt(u64, out[16..24], json.len, .little);
    @memcpy(out[header_length..], json);
    std.mem.writeInt(u64, out[24..32], checksum_mod.compute(.xxh3_64, out[0..24], json), .little);
    return out;
}

/// Validate the header, the declared size and the checksum.
pub fn inspect(encoded: []const u8) DecodeError!Header {
    if (encoded.len < header_length) return error.Truncated;
    if (!std.mem.eql(u8, encoded[0..magic.len], magic)) return error.BadMagic;
    if (std.mem.readInt(u16, encoded[8..10], .little) != version) return error.UnsupportedVersion;
    const flags = std.mem.readInt(u16, encoded[10..12], .little);
    if (flags & ~checksum_mod.flag_xxh3 != 0 or std.mem.readInt(u32, encoded[12..16], .little) != 0) return error.UnsupportedFlags;
    const kind = checksum_mod.kindOfFlags(flags);
    const payload_bytes = std.math.cast(usize, std.mem.readInt(u64, encoded[16..24], .little)) orelse return error.SizeOverflow;
    const expected = std.math.add(usize, header_length, payload_bytes) catch return error.SizeOverflow;
    if (encoded.len < expected) return error.Truncated;
    if (encoded.len > expected) return error.TrailingData;
    const checksum = std.mem.readInt(u64, encoded[24..32], .little);
    if (checksum_mod.compute(kind, encoded[0..24], encoded[header_length..]) != checksum) return error.ChecksumMismatch;
    return .{ .payload_bytes = payload_bytes, .checksum = checksum, .checksum_kind = kind };
}

/// The state JSON of a section `inspect` accepted.
pub fn payload(encoded: []const u8) []const u8 {
    return encoded[header_length..];
}

test "state section round trip, XXH3-64 over header and payload" {
    const allocator = std.testing.allocator;
    const json = "{\"state_version\":2,\"generation\":3,\"analyzer_id\":\"analyzer-v2\",\"roots\":[],\"files\":[]}";
    const encoded = try encode(allocator, json);
    defer allocator.free(encoded);
    try std.testing.expectEqualStrings(magic, encoded[0..8]);
    const header = try inspect(encoded);
    try std.testing.expectEqual(checksum_mod.Kind.xxh3_64, header.checksum_kind);
    try std.testing.expectEqual(json.len, header.payload_bytes);
    try std.testing.expectEqual(checksum_mod.compute(.xxh3_64, encoded[0..24], json), header.checksum);
    try std.testing.expectEqualStrings(json, payload(encoded));
}

test "state section refuses a flipped byte, a short or long file and unknown flags" {
    const allocator = std.testing.allocator;
    const encoded = try encode(allocator, "{\"state_version\":2}");
    defer allocator.free(encoded);
    for ([_]usize{ 16, 24, header_length, encoded.len - 1 }) |at| {
        const copy = try allocator.dupe(u8, encoded);
        defer allocator.free(copy);
        copy[at] ^= 0x01;
        try std.testing.expect(std.meta.isError(inspect(copy)));
    }
    try std.testing.expectError(error.Truncated, inspect(encoded[0 .. encoded.len - 1]));
    try std.testing.expectError(error.Truncated, inspect(encoded[0..10]));
    const copy = try allocator.dupe(u8, encoded);
    defer allocator.free(copy);
    copy[10] = 3;
    try std.testing.expectError(error.UnsupportedFlags, inspect(copy));
    copy[10] = 1;
    copy[0] = 'X';
    try std.testing.expectError(error.BadMagic, inspect(copy));
}
