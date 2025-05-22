const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    var absoluteLibsPaths = std.mem.splitScalar(u8, b.option([]const u8, "absoluteLibsPaths", "").?, ',');

    var absoluteIncludesPaths = std.mem.splitScalar(u8, b.option([]const u8, "absoluteIncludesPaths", "").?, ',');

    const exe = b.addExecutable(.{
        .name = "acn",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    while (absoluteLibsPaths.next()) |path| {
        exe.addLibraryPath(.{ .cwd_relative = path });
    }
    while (absoluteIncludesPaths.next()) |path| {
        exe.addIncludePath(.{ .cwd_relative = path });
    }

    exe.linkSystemLibrary("nftnl");
    exe.linkSystemLibrary("nl-3");
    exe.linkSystemLibrary("mnl");
    exe.linkLibC();

    b.installArtifact(exe);
}
