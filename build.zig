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
    const testExe = b.addTest(.{ .root_module = rootModule, });

    // ---Options--- //
    //
    const buildZigZon = b.createModule(.{
        .root_source_file = b.path("build.zig.zon"),
        .target = target,
        .optimize = optimize,
    });
    rootModule.addImport("build.zig.zon", buildZigZon);
    //
    // ---Options--- //

    // ---Zig Deps--- //
    //
    const zliDep = b.dependency("zli", .{ .target = target });
    rootModule.addImport("zli", zliDep.module("zli"));
    //
    // ---Zig Deps--- //

    // ---Link Libs--- //
    //
    for ([_]*std.Build.Step.Compile {exe, testExe}) |art| {
        art.linkLibC();
        art.linkSystemLibrary("nftnl");
        art.linkSystemLibrary("nl-3");
        art.linkSystemLibrary("mnl");
    }
    //
    // ---Link Libs--- //

    b.installArtifact(exe);
    const runUnitTest = b.addRunArtifact(testExe);
    const testStep = b.step("test", "run all tests");
    testStep.dependOn(&runUnitTest.step);
}
