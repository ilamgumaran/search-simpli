//! The interfaces as one module, `interfaces` (S6-T14; docs/layers.md), for the
//! tests in zig/src/tests/ only: they reach an interface file as
//! `@import("interfaces").<file name>`. The searchd executable and the C ABI
//! libraries are built from main.zig and abi.zig themselves (zig/build.zig);
//! main.zig is left out (it has no test and no test build compiles it).

pub const abi = @import("abi.zig");
pub const cli = @import("cli.zig");
pub const field_warnings_test = @import("field_warnings_test.zig");
pub const mcp = @import("mcp.zig");
pub const rpc = @import("rpc.zig");

// `zig build test` runs this module's tests in a step of their own (zig/build.zig):
// a test build only collects the tests of its root module's files. The reference
// below is made in a test build only, and adds no test of its own.
comptime {
    if (@import("builtin").is_test) {
        _ = abi;
        _ = cli;
        _ = field_warnings_test;
        _ = mcp;
        _ = rpc;
    }
}
