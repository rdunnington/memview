const std = @import("std");
const zgui = @import("libs/zgui/build.zig");
const zglfw = @import("libs/zglfw/build.zig");
const zgpu = @import("libs/zgpu/build.zig");
const zpool = @import("libs/zpool/build.zig");
const network = @import("libs/zig-network/build.zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe_memview = b.addExecutable(.{
        .name = "memview",
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });

    const zgui_pkg = zgui.package(b, target, optimize, .{
        .options = .{ .backend = .glfw_wgpu },
    });

    // Needed for glfw/wgpu rendering backend
    const zglfw_pkg = zglfw.package(b, target, optimize, .{});
    const zpool_pkg = zpool.package(b, target, optimize, .{});
    const zgpu_pkg = zgpu.package(b, target, optimize, .{
        .deps = .{ .zpool = zpool_pkg.zpool, .zglfw = zglfw_pkg.zglfw },
    });

    const network_module = b.addModule("network", .{
        .source_file = .{ .path = "libs/zig-network/network.zig" },
    });

    zgui_pkg.link(exe_memview);
    zglfw_pkg.link(exe_memview);
    zgpu_pkg.link(exe_memview);
    exe_memview.addModule("network", network_module);

    // This declares intent for the exe_memviewcutable to be installed into the
    // standard location when the user invokes the "install" step (the default
    // step when running `zig build`).
    exe_memview.install();

    // This *creates* a RunStep in the build graph, to be exe_memviewcuted when another
    // step is evaluated that depends on it. The next line below will establish
    // such a dependency.
    const run_memview_cmd = exe_memview.run();

    // By making the run step depend on the install step, it will be run from the
    // installation directory rather than directly from within the cache directory.
    // This is not necessary, however, if the application depends on other installed
    // files, this ensures they will be present and in the expected location.
    run_memview_cmd.step.dependOn(b.getInstallStep());

    // This allows the user to pass arguments to the application in the build
    // command itself, like this: `zig build run -- arg1 arg2 etc`
    if (b.args) |args| {
        run_memview_cmd.addArgs(args);
    }

    // This creates a build step. It will be visible in the `zig build --help` menu,
    // and can be selected like this: `zig build memview`
    // This will evaluate the `memview` step rather than the default, which is "install".
    const memview_step = b.step("memview", "Run memview");
    memview_step.dependOn(&run_memview_cmd.step);

    // Creates a step for unit testing.
    const exe_memview_tests = b.addTest(.{
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });

    // Similar to creating the run step earlier, this exposes a `test` step to
    // the `zig build --help` menu, providing a way for the user to request
    // running the unit tests.
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&exe_memview_tests.step);
}
