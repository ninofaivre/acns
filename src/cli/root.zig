const std = @import("std");
const zli = @import("zli");
const config = @import("../config.zig");

const buildOptions = @import("buildOptions");

pub const Data = struct {
    needToServe: bool = false,
};

var stderr_writer = std.fs.File.stdout().writerStreaming(&.{});
const stderr = &stderr_writer.interface;

pub fn build(
    writer: *std.Io.Writer,
    reader: *std.Io.Reader,
    allocator: std.mem.Allocator
) !*zli.Command {
    const root = try zli.Command.init(writer, reader, allocator, .{
        .name = buildOptions.name,
        .description = "Access Controlled Nftables Sets",
        .version = buildOptions.version,
    }, base);

    try root.addFlags(&[_]zli.Flag{
        zli.Flag{
            .name = "validate",
            .description = "just validate the config without attempting to run it",
            .type = .Bool,
            .default_value = .{ .Bool = false },
        },
        zli.Flag{
            .name = "config",
            .shortcut = "c",
            .description = "config file path",
            .type = .String,
            .default_value = .{ .String = "" },
        },
        zli.Flag{
            .name = "version",
            .shortcut = "v",
            .description = "show version",
            .type = .Bool,
            .default_value = .{ .Bool = false },
        },
    });

    return root;
}

fn base(ctx: zli.CommandContext) !void {
    const fVersion = ctx.flag("version", bool);
    const fValidate = ctx.flag("validate", bool);
    const fConfig = ctx.flag("config", []const u8);
    const nFlags: u2 = @as(u2, @intFromBool(fValidate)) + @as(u2, @intFromBool(fVersion)) + @as(u2, @intFromBool(fConfig.len > 0));

    const data = ctx.getContextData(Data);
    if (fVersion and nFlags > 1) {
        try stderr.writeAll("Flag 'version' cannot be combined with others flags.\n");
        return error.InvalidCommand;
    }
    if (fVersion)
        try ctx.root.printVersion();
    if (fConfig.len > 0) {
        data.*.needToServe = true;
        try config.load(fConfig, ctx.allocator);
    }
    if (fValidate) {
        if (fConfig.len == 0) {
            try stderr.writeAll("There is no config to validate.\n");
            return error.InvalidCommand;
        }
        try ctx.command.writer.writeAll("Config passed !\n");
        data.*.needToServe = false;
    }
    if (nFlags == 0)
        try ctx.command.printHelp();
}
