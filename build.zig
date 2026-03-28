const std = @import("std");
const builtin = @import("builtin");

const library_name = "maxmind";

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const strip = b.option(bool, "strip", "Strip debug symbols from the binary") orelse false;

    const pyoz = b.dependency("PyOZ", .{
        .target = target,
        .optimize = optimize,
    });

    const mmdb = b.dependency("maxminddb", .{
        .target = target,
        .optimize = optimize,
    });

    const lib_mod = b.createModule(.{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
        .imports = &.{
            .{ .name = "PyOZ", .module = pyoz.module("PyOZ") },
            .{ .name = "maxminddb", .module = mmdb.module("maxminddb") },
        },
    });

    // Build the Python extension as a dynamic library.
    const lib = b.addLibrary(.{
        .name = library_name,
        .linkage = .dynamic,
        .root_module = lib_mod,
    });

    // Otherwise it doesn't build on macOS.
    lib.linker_allow_shlib_undefined = true;

    // Link libc (required for Python C API).
    lib.linkLibC();

    // On Windows, link against the Python stable ABI library (python3.lib).
    // These options are passed automatically by `pyoz build`.
    // For manual `zig build` on Windows, pass: -Dpython-lib-dir=<path> -Dpython-lib-name=python3
    if (b.option([]const u8, "python-lib-dir", "Python library directory")) |dir| {
        lib.addLibraryPath(.{ .cwd_relative = dir });
    }
    if (b.option([]const u8, "python-lib-name", "Python library name")) |name| {
        lib.linkSystemLibrary(name);
    }

    // Determine extension based on target OS (.pyd for Windows, .so otherwise).
    const ext = if (builtin.os.tag == .windows) ".pyd" else ".so";

    // Install the shared library.
    const install = b.addInstallArtifact(lib, .{
        .dest_sub_path = library_name ++ ext,
    });
    b.getInstallStep().dependOn(&install.step);
}
