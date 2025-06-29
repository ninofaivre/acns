const std = @import("std");

const buildZon: struct {
    name: @Type(.enum_literal),
    version: []const u8,
    fingerprint: u64,
    dependencies: struct {
        zli: struct { path: []const u8 },
    },
    paths: []const []const u8,
} = @import("build.zig.zon");

fn missingOption(optionName: []const u8) void {
    std.debug.panic("Build option '{s}' is missing, build cannot proceed, this option is mandatory.", .{optionName});
}

fn getEnvVar(allocator: std.mem.Allocator, name: []const u8) ?[]u8 {
    return std.process.getEnvVarOwned(allocator, name) catch {
        return null;
    };
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "acns",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // ---Options--- //
    //
    const options = b.addOptions();

    if (std.SemanticVersion.parse(buildZon.version)) |version| {
        options.addOption(std.SemanticVersion, "version", version);
    } else |err| {
        std.debug.panic("Version need to be semantic ([major].[minor].[patch]) : {s}", .{@errorName(err)});
    }

    exe.root_module.addImport("buildOptions", options.createModule());
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
