const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const executable_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    const executable = b.addExecutable(.{
        .name = "searchd",
        .root_module = executable_module,
    });
    b.installArtifact(executable);

    const run_command = b.addRunArtifact(executable);
    if (b.args) |args| run_command.addArgs(args);
    const run_step = b.step("run", "Run the search engine seed");
    run_step.dependOn(&run_command.step);

    // === S1-T0: contracts/CONTRACTS_VERSION -> abi.zig's ss_version() =====
    // @embedFile can't reach outside zig/'s module package, so build.zig
    // reads it directly and hands it in as a build option instead. Every
    // module that (transitively) imports src/abi.zig needs this import.
    const contracts_version_options = contractsVersionOptions(b);
    // === end S1-T0 ==========================================================

    const test_module = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        // root.zig now pulls in abi.zig (see S1-T0 below), which uses the C
        // allocator.
        .link_libc = true,
    });
    test_module.addOptions("build_options", contracts_version_options);
    const unit_tests = b.addTest(.{ .root_module = test_module });
    const test_command = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run engine unit tests");
    test_step.dependOn(&test_command.step);

    // === S1-T0: C ABI library builds and conformance harness =============
    // Additive only; owned by S1-T0 (docs/tasks/S1-T0.md). Keep this section
    // small and self-contained so it merges cleanly alongside S1-T1's own
    // `build.zig` additions.
    const lib_step = b.step("lib", "Build the C ABI static+shared libraries (aarch64-macos, aarch64-linux-android, x86_64-linux)");
    addAbiLibraries(b, lib_step, optimize, contracts_version_options);

    const test_abi_step = b.step("test-abi", "Build and run the C ABI conformance harness (zig/tests/abi_test.c) against a native build of the library");
    addAbiTest(b, test_abi_step, target, optimize, contracts_version_options);
    // === end S1-T0 =========================================================
}

/// Reads `../contracts/CONTRACTS_VERSION` (relative to `zig/`) at configure
/// time and exposes it as `@import("build_options").contracts_version`.
fn contractsVersionOptions(b: *std.Build) *std.Build.Step.Options {
    var buffer: [256]u8 = undefined;
    const raw = b.build_root.handle.readFile(b.graph.io, "../contracts/CONTRACTS_VERSION", &buffer) catch |err| {
        std.debug.print("build.zig: could not read contracts/CONTRACTS_VERSION: {s}\n", .{@errorName(err)});
        @panic("missing contracts/CONTRACTS_VERSION");
    };
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    const options = b.addOptions();
    options.addOption([:0]const u8, "contracts_version", b.allocator.dupeZ(u8, trimmed) catch @panic("OOM"));
    return options;
}

const AbiTargetSpec = struct {
    /// Install subdirectory under zig-out/lib/, and the ADR 0002 target name.
    dir_name: []const u8,
    query: std.Target.Query,
    /// aarch64-linux-android has no libc of its own to cross-compile
    /// against; it needs the Android NDK's sysroot (SS_ANDROID_NDK below).
    needs_android_libc: bool = false,
};

const abi_targets = [_]AbiTargetSpec{
    .{ .dir_name = "aarch64-macos", .query = .{ .cpu_arch = .aarch64, .os_tag = .macos } },
    .{
        .dir_name = "aarch64-linux-android",
        .query = .{ .cpu_arch = .aarch64, .os_tag = .linux, .abi = .android },
        .needs_android_libc = true,
    },
    .{ .dir_name = "x86_64-linux", .query = .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .gnu } },
};

/// `zig build lib`: static and shared `search_simpli` libraries over the C
/// ABI (`src/abi.zig`) for every target in `abi_targets`, installed under
/// `zig-out/lib/<target>/`.
///
/// The Android target needs the NDK's bundled libc (Zig ships no Android
/// libc of its own): set `SS_ANDROID_NDK` to the NDK root (the directory
/// containing `toolchains/`) before running `zig build lib`. Without it, the
/// Android artifacts are skipped (a warning is printed) and the other two
/// targets still build.
fn addAbiLibraries(
    b: *std.Build,
    step: *std.Build.Step,
    optimize: std.builtin.OptimizeMode,
    contracts_version_options: *std.Build.Step.Options,
) void {
    const android_libc_file = androidLibcFile(b);
    if (android_libc_file == null) {
        std.debug.print(
            "zig build lib: SS_ANDROID_NDK is not set; skipping the aarch64-linux-android libraries.\n",
            .{},
        );
    }

    for (abi_targets) |spec| {
        if (spec.needs_android_libc and android_libc_file == null) continue;
        const resolved_target = b.resolveTargetQuery(spec.query);

        inline for (.{ std.builtin.LinkMode.static, std.builtin.LinkMode.dynamic }) |linkage| {
            const module = b.createModule(.{
                .root_source_file = b.path("src/abi.zig"),
                .target = resolved_target,
                .optimize = optimize,
                .link_libc = true,
            });
            module.addOptions("build_options", contracts_version_options);
            const library = b.addLibrary(.{
                .name = "search_simpli",
                .linkage = linkage,
                .root_module = module,
            });
            if (spec.needs_android_libc) library.setLibCFile(android_libc_file.?);
            const install = b.addInstallArtifact(library, .{
                .dest_dir = .{ .override = .{ .custom = b.fmt("lib/{s}", .{spec.dir_name}) } },
            });
            step.dependOn(&install.step);
        }
    }
}

/// Writes a Zig `--libc` paths file pointing at the Android NDK's sysroot
/// (`$SS_ANDROID_NDK/toolchains/llvm/prebuilt/<host>/sysroot`), or null if
/// `SS_ANDROID_NDK` is unset. API level 29 is an arbitrary modern default;
/// the NDK ships every level from 21 to the current one under the same
/// sysroot, so this is a one-line change if the app needs a different floor.
fn androidLibcFile(b: *std.Build) ?std.Build.LazyPath {
    const ndk_path = b.graph.environ_map.get("SS_ANDROID_NDK") orelse return null;
    const host_tag = switch (@import("builtin").os.tag) {
        .macos => "darwin-x86_64",
        .windows => "windows-x86_64",
        else => "linux-x86_64",
    };
    const sysroot = b.fmt("{s}/toolchains/llvm/prebuilt/{s}/sysroot", .{ ndk_path, host_tag });
    const crt_dir = b.fmt("{s}/usr/lib/aarch64-linux-android/29", .{sysroot});
    const contents = b.fmt(
        \\include_dir={s}/usr/include
        \\sys_include_dir={s}/usr/include
        \\crt_dir={s}
        \\msvc_lib_dir=
        \\kernel32_lib_dir=
        \\gcc_dir=
        \\
    , .{ sysroot, sysroot, crt_dir });
    const write_files = b.addWriteFiles();
    return write_files.add("android-libc.txt", contents);
}

/// `zig build test-abi`: compile `tests/abi_test.c` against `include/` and
/// link it with a native (host-target) static build of the C ABI library,
/// then run it. Criterion 3 of docs/tasks/S1-T0.md.
fn addAbiTest(
    b: *std.Build,
    step: *std.Build.Step,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    contracts_version_options: *std.Build.Step.Options,
) void {
    const native_module = b.createModule(.{
        .root_source_file = b.path("src/abi.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    native_module.addOptions("build_options", contracts_version_options);
    const native_library = b.addLibrary(.{
        .name = "search_simpli",
        .linkage = .static,
        .root_module = native_module,
    });

    const harness = b.addExecutable(.{
        .name = "abi_test",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    harness.root_module.addCSourceFile(.{ .file = b.path("tests/abi_test.c"), .flags = &.{ "-std=c11", "-Wall", "-Wextra" } });
    harness.root_module.addIncludePath(b.path("include"));
    harness.root_module.linkLibrary(native_library);

    const run_harness = b.addRunArtifact(harness);
    step.dependOn(&run_harness.step);
}
