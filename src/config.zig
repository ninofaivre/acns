const std = @import("std");

pub const Config = struct {
    socketPath: []const u8,
    resetTimeout: bool = true,
};

pub fn load(configPath: []const u8, allocator: std.mem.Allocator) !Config {
    const configFile = try std.fs.cwd().openFile(configPath, .{});
    defer configFile.close();

    const configFileSize = try configFile.getEndPos();
    const buffer = try allocator.alloc(u8, configFileSize + 1);
    defer allocator.free(buffer);
    buffer[try configFile.readAll(buffer[0..configFileSize])] = 0;

    return try std.zon.parse.fromSlice(Config, allocator, buffer[0..configFileSize:0], null, .{});
}
