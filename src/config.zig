const std = @import("std");
const Yaml = @import("yaml").Yaml;

const YamlConfig = struct {
    logLevel: ?[]const u8,
};

pub const Config = struct {
    logLevel: std.log.Level,
};

// fn yamlLoad(configPath: []const u8, allocator: std.mem.Allocator) !YamlConfig {
//     const configFile = try std.fs.cwd().openFile(configPath, .{});
//     defer configFile.close();
//     const source = try configFile.readToEndAlloc(allocator, std.math.maxInt(u32));
//
//     var yaml: Yaml = .{ .source = source };
//     defer yaml.deinit(allocator);
//
//     yaml.load(allocator) catch |err| switch (err) {
//         error.ParseFailure => {
//             yaml.parse_errors.renderToStdErr(.{ .ttyconf = std.io.tty.detectConfig(std.io.getStdErr()) });
//             return error.ParseFailure;
//         },
//         else => return err,
//     };
//
//     return yaml.parse(allocator, YamlConfig);
// }
//
// pub fn load(configPath: []const u8, config: *?Config, allocator: std.mem.Allocator) !void {
//     const yamlConfig = try yamlLoad(configPath, allocator);
//     std.debug.print("-----A-----", .{});
//     std.debug.print("yamlConfig.logLevel : {any}\n", .{yamlConfig.logLevel});
//     _ = std.meta.stringToEnum(std.log.Level, yamlConfig.logLevel.?);
//     std.debug.print("-----B-----", .{});
//     _ = config;
//     _ = .{
//         .logLevel = if (yamlConfig.logLevel) |logLevel| std.meta.stringToEnum(std.log.Level, logLevel) orelse return error.InvalidLogLevel else std.log.Level.info,
//     };
//     std.debug.print("-----C-----", .{});
// }

pub fn load(configPath: []const u8, config: *?Config, allocator: std.mem.Allocator) !void {
    _ = config;
    const content = try std.fs.cwd().readFileAlloc(allocator, configPath, 10 * 1024);
    defer allocator.free(content);

    const parsed = try std.zon.parse.fromSlice(Config, allocator, content[0.. :0], null, .{});
    _ = parsed;
}
