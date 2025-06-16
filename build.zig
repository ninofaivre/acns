const std = @import("std");

pub fn missingOption(optionName: []const u8) void {
    std.debug.panic("Build option '{s}' is missing, build cannot proceed, this option is mandatory.", .{optionName});
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const absoluteLibsPathsOpt = b.option([]const u8, "absoluteLibsPaths", "List of comma separated paths to add to libs search path.") orelse "";
    var absoluteLibsPaths = std.mem.splitScalar(u8, absoluteLibsPathsOpt, ',');

    const absoluteIncludesPathsOpt = b.option([]const u8, "absoluteIncludesPaths", "List of comma separated paths to add to libs headers search path.") orelse "";
    var absoluteIncludesPaths = std.mem.splitScalar(u8, absoluteIncludesPathsOpt, ',');

    const version = std.SemanticVersion.parse(b.option(([]const u8), "version", "Version of the program (mandatory).") orelse {
        missingOption("version");
        return;
    });

    const exe = b.addExecutable(.{
        .name = "acns",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const options = b.addOptions();

    if (version) |semanticVersion| {
        options.addOption(std.SemanticVersion, "version", semanticVersion);
    } else |err| {
        std.debug.panic("Version need to be semantic ([major].[minor].[patch]) : {s}", .{@errorName(err)});
    }
    exe.root_module.addImport("buildOptions", options.createModule());

    const zliDep = b.dependency("zli", .{ .target = target });
    exe.root_module.addImport("zli", zliDep.module("zli"));

    const yamlDep = b.dependency("yaml", .{ .target = target, .optimize = optimize });
    exe.root_module.addImport("yaml", yamlDep.module("yaml"));

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
