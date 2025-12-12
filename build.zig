const std = @import("std");

const buildZon = @import("build.zig.zon");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const rootModule = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    const exe = b.addExecutable(.{
        .name = @tagName(buildZon.name),
        .root_module = rootModule,
    });

    // ---Options--- //
    //
    const buildZigZon = b.createModule(.{
        .root_source_file = b.path("build.zig.zon"),
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addImport("build.zig.zon", buildZigZon);
    //
    // ---Options--- //

    // ---Zig Deps--- //
    //
    const zliDep = b.dependency("zli", .{ .target = target });
    exe.root_module.addImport("zli", zliDep.module("zli"));
    //
    // ---Zig Deps--- //

    // ---Link Libs--- //
    //
    exe.linkLibC();
    exe.linkSystemLibrary("nftnl");
    exe.linkSystemLibrary("nl-3");
    exe.linkSystemLibrary("mnl");
    //
    // ---Link Libs--- //

    b.installArtifact(exe);
}
