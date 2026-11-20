//! The operations layer as one module, `operations` (S6-T14; docs/layers.md).
//! zig/build.zig builds zig/src/ops/ as this module; it imports `core`. The
//! interfaces and the tests in zig/src/tests/ reach an operations file as
//! `@import("operations").<file name>`, never by a path into ops/.

pub const filename_response = @import("filename_response.zig");
pub const ops = @import("ops.zig");
pub const report = @import("report.zig");
pub const service = @import("service.zig");

// `zig build test` runs this module's tests in a step of their own (zig/build.zig):
// a test build only collects the tests of its root module's files. The reference
// below is made in a test build only, and adds no test of its own.
comptime {
    if (@import("builtin").is_test) {
        _ = filename_response;
        _ = ops;
        _ = report;
        _ = service;
    }
}
