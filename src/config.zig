// TODO: refactoring to accept regex, need to work out an order of priority
// note : possible regex lib : mnemnion/mvzr
const std = @import("std");

pub const Config = struct {
    // using array hash map to retain order for future regex support
    const Tables = std.StringArrayHashMap(std.StringArrayHashMap(void));
    socketPath: []const u8,
    socketGroupName: ?[]const u8,
    resetTimeout: bool,
    timeoutKernelAcksInMs: u6,
    accessControl: union (enum) {
        Disabled: void,
        Enabled: struct {
            inet: ?Tables,
            ip: ?Tables,
            ip6: ?Tables,
            arp: ?Tables,
            bridge: ?Tables,
            netdev: ?Tables,
        },
    },
};

const ZonConfig = struct {
    socketPath: []const u8,
    socketGroupName: ?[]const u8 = null,
    resetTimeout: bool = true,
    timeoutKernelAcksInMs: u6 = 0,
    accessControl: struct {
        const Tables = std.zig.Zoir.Node.Index;
        enabled: bool = true,
        inet: ?Tables = null,
        ip: ?Tables = null,
        ip6: ?Tables = null,
        arp: ?Tables = null,
        bridge: ?Tables = null,
        netdev: ?Tables = null,
    },
};


pub var state: union(enum) {
    Loaded: struct {
        configPath: []const u8,
        allocator: std.mem.Allocator
    },
    NotLoaded: void,
} = .{ .NotLoaded = {} };
pub var conf: Config = undefined;

fn parseTables(familyName: []const u8, familyNodeIndex: ?std.zig.Zoir.Node.Index,ast: std.zig.Ast, zoir: std.zig.Zoir, configPath: []const u8, allocator: std.mem.Allocator) !?Config.Tables {
    const familyNode = if (familyNodeIndex) |index| 
            index.get(zoir)
        else return null;
    if (familyNode == .empty_literal) return null;
    if (familyNode != .struct_literal) {
        std.log.err("in configFile {s} : accessControl.{s} must be a struct"    , .{ configPath, familyName, });
        return error.Parse;
    }
    const familyNodeStruct = familyNode.struct_literal;

    var tables = Config.Tables.init(allocator);
    for (familyNodeStruct.names, 0..familyNodeStruct.vals.len) |nameNode, index| {
        const name = nameNode.get(zoir);
        const setNamesNode = familyNodeStruct.vals.at(@intCast(index));
        var diagnostics: std.zon.parse.Diagnostics = .{};
        const setNames = std.zon.parse.fromZoirNode([][]const u8, allocator, ast, zoir, setNamesNode, &diagnostics, .{}) catch |err| {
            if (err == error.ParseZon)
                std.log.err("in configFile {s} : {f}", .{configPath, diagnostics});
            return err;
        };
        var setNamesHashMap = std.StringArrayHashMap(void).init(allocator);
        for (setNames) |setName| {
            try setNamesHashMap.put(setName, {});
        }
        try tables.put(name, setNamesHashMap);
    }
    return tables;
}

fn _load(configPath: []const u8, allocator: std.mem.Allocator) !void {
    const configFile = try std.fs.cwd().openFile(configPath, .{});
    defer configFile.close();

    const configFileSize = try configFile.getEndPos();
    const buffer = try allocator.alloc(u8, configFileSize + 1);
    defer allocator.free(buffer);
    buffer[try configFile.readAll(buffer[0..configFileSize])] = 0;
    const terminatedBuffer = buffer[0..configFileSize:0];

    const ast = try std.zig.Ast.parse(allocator, terminatedBuffer, .zon);
    const zoir = try std.zig.ZonGen.generate(allocator, ast, .{});

    var diagnostics: std.zon.parse.Diagnostics = .{};
    const zonConfig = std.zon.parse.fromZoir(ZonConfig, allocator, ast, zoir, &diagnostics, .{}) catch |err| {
        if (err == error.ParseZon)
            std.log.err("in configFile \"{s}\" : {f}", .{configPath, diagnostics});
        return err;
    };

    conf = .{
        .socketPath = zonConfig.socketPath,
        .socketGroupName = zonConfig.socketGroupName,
        .resetTimeout = zonConfig.resetTimeout,
        .timeoutKernelAcksInMs = zonConfig.timeoutKernelAcksInMs,
        .accessControl = if(zonConfig.accessControl.enabled) .{
            .Enabled = .{
                .inet = try parseTables("inet", zonConfig.accessControl.inet,
                    ast, zoir, configPath, allocator),
                .ip = try parseTables("ip", zonConfig.accessControl.ip,
                    ast, zoir, configPath, allocator),
                .ip6 = try parseTables("ip6", zonConfig.accessControl.ip6,
                    ast, zoir, configPath, allocator),
                .arp = try parseTables("arp", zonConfig.accessControl.arp,
                    ast, zoir, configPath, allocator),
                .bridge = try parseTables("bridge", zonConfig.accessControl.bridge,
                    ast, zoir, configPath, allocator),
                .netdev = try parseTables("netdev", zonConfig.accessControl.netdev,
                    ast, zoir, configPath, allocator),
            },
        } else .{ .Disabled = {}, }
    };
}

pub fn reload() !void {
    if (state == .NotLoaded) return error.ConfigReloadedBeforeLoad;
    try _load(state.Loaded.configPath, state.Loaded.allocator);
}

pub fn load(configPath: []const u8, allocator: std.mem.Allocator) !void {
    if (state == .Loaded) return error.ConfigAlreadyLoaded;
    state = .{
        .Loaded = .{
            .configPath = configPath,
            .allocator = allocator,
        },
    };
    try _load(configPath, allocator);
}
