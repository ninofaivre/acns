const std = @import("std");
const posix = std.posix;

const nftnl = @import("wrappers/libnftnl.zig");
const mnl = @import("wrappers/libmnl.zig");
const mynft = @import("./nft.zig");
const config = @import("./config.zig");

const c = @cImport({
    @cInclude("linux/netlink.h");
    @cInclude("linux/netfilter/nf_tables.h");
});

const IPv4 = struct {
    value: u32,
    pub fn format(self: IPv4, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        _ = fmt;
        _ = options;
        const o1: u8 = @truncate(self.value);
        const o2: u8 = @truncate(self.value >> 8);
        const o3: u8 = @truncate(self.value >> 16);
        const o4: u8 = @truncate(self.value >> 24);
        try writer.print("{}.{}.{}.{}", .{ o1, o2, o3, o4 });
    }
};

const Message = struct {
    tableName: [*c]const u8,
    setName: [*c]const u8,
    ip: IPv4,
    familyType: u16,
    pub fn format(self: Message, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        _ = fmt;
        _ = options;
        try writer.print("ip4/6[{d}] in family[{d}] -> tableName[{s}] -> setName[{s}]", .{ self.ip, self.familyType, self.tableName, self.setName });
    }
};

fn parseMessage(message: []const u8) error{ FamilyTypeNotFound, FamilyTypeTooShort, TableNameNotFound, TableNameTooShort, TableNameTooLong, SetNameNotFound, SetNameTooShort, SetNameTooLong, IpNotFound, IpTooShort, IpTooLong }!Message {
    var tail = message;

    if (tail.len < 0) return error.FamilyTypeNotFound;
    if (tail.len < 2) return error.FamilyTypeTooShort;
    const familyType: u16 = std.mem.readInt(u16, tail[0..2], std.builtin.Endian.little);
    tail = tail[2..];

    const endTableNameIdx = std.mem.indexOf(u8, tail, "\x00") orelse return error.TableNameNotFound;
    const tableName = tail[0..endTableNameIdx];
    if (tableName.len == 0) return error.TableNameTooShort;
    if (tableName.len >= c.NFT_TABLE_MAXNAMELEN) return error.TableNameTooLong;
    tail = tail[(endTableNameIdx + 1)..];

    const endSetNameIdx = std.mem.indexOf(u8, tail, "\x00") orelse return error.SetNameNotFound;
    const setName = tail[0..endSetNameIdx];
    if (setName.len == 0) return error.SetNameTooShort;
    if (setName.len >= c.NFT_SET_MAXNAMELEN) return error.SetNameTooLong;
    tail = tail[(endSetNameIdx + 1)..];

    if (tail.len == 0) return error.IpNotFound;
    if (tail.len > 4 and tail[tail.len - 1] == '\x00') tail = tail[0 .. tail.len - 1]; // remove trailing \0
    // TODO handle ipv6 (can be discriminated by size)
    if (tail.len < 4) return error.IpTooShort;
    if (tail.len > 4) return error.IpTooLong;
    const ip: u32 = std.mem.readInt(u32, tail[0..4], std.builtin.Endian.little);

    return .{ .familyType = familyType, .tableName = @ptrCast(tableName), .setName = @ptrCast(setName), .ip = .{ .value = ip } };
}

fn sendAck(sockFd: i32, buf: []const u8, destAddr: ?*const posix.sockaddr, addrlen: posix.socklen_t) void {
    if (addrlen == 0) return; // check if addrlen 0 cause sendto to fail
    _ = posix.sendto(sockFd, buf, 0, destAddr, addrlen) catch |err| {
        std.log.warn("while trying to send ack : {s}", .{@errorName(err)});
    };
}

fn isNftablesPathAuthorized(message: Message) bool {
    if (config.conf.accessControl == .Disabled)
        return true;
    const accessControl = config.conf.accessControl.Enabled;
    const tables = blk: {
        switch (message.familyType) {
            1 => break :blk accessControl.inet,
            2 => break :blk accessControl.ip,
            3 => break :blk accessControl.arp,
            5 => break :blk accessControl.netdev,
            7 => break :blk accessControl.bridge,
            10 => break :blk accessControl.ip6,
            else => {
                std.log.warn("{} : family type unknown (not one of [1,2,3,5,7,10] : {}\n", .{message, message.familyType});
                return false;
            },
        }
    };
    if (tables) |ts| {
        const table = ts.get(std.mem.span(message.tableName));
        if (table) |t| {
            return t.contains(std.mem.span(message.setName));
        }
    }
    return false;
}

var testob: bool = false;

fn sigHupHandler(sigNum: c_int) callconv(.C) void {
    _ = sigNum;
    config.reload() catch |err| {
        switch (err) {
            error.ConfigReloadedBeforeLoad => std.log.warn("tryed to reload config before it even loaded once", .{}),
            else =>
                std.log.warn("failed to reload config at path : {s}\nKeeping old config.", .{
                    config.state.Loaded.configPath
                }),
        }
        return;
    };
    std.log.info("Config at path {s} has been successfully reloaded !", .{
        config.state.Loaded.configPath
    });
}

fn serve(sockFd: i32, resources: mynft.Resources) !void {
    var buff: [2 + c.NFT_TABLE_MAXNAMELEN + c.NFT_SET_MAXNAMELEN + 4 + 1]u8 = undefined;
    var clientAddr: posix.sockaddr.storage = undefined;
    var clientAddrLen: posix.socklen_t = @sizeOf(@TypeOf(clientAddr));
    while (true) {
        const len = try posix.recvfrom(sockFd, &buff, 0, @ptrCast(&clientAddr), &clientAddrLen);
        const message = parseMessage(buff[0..len]) catch |err| {
            buff[0] = 1;
            sendAck(sockFd, buff[0..1], @ptrCast(&clientAddr), clientAddrLen);
            std.log.warn("received malformed message : {s}", .{@errorName(err)});
            continue;
        };
        if (!isNftablesPathAuthorized(message)) {
            buff[0] = 1;
            sendAck(sockFd, buff[0..1], @ptrCast(&clientAddr), clientAddrLen);
            std.log.warn("{s} : nft path not authorized", .{ message });
            continue;
        }
        mynft.addIpToSet(.{
                .tableName = message.tableName,
                .family = message.familyType,
                .name = message.setName
            }, message.ip.value, resources
        ) catch |e| {
            buff[0] = 1;
            sendAck(sockFd, buff[0..1],
                @ptrCast(&clientAddr), clientAddrLen);
            if (e == error.Permission) return e;
            std.log.warn("while inserting {s} : {s}", .{
                message,
                switch (e) {
                    error.TooFewAck =>
                        "the kernel was too slow sending ACKs",
                    error.SetPathNotFound =>
                        "the path for this set was not found",
                    else => @errorName(e),
                }
            });
            continue;
        };
        buff[0] = 0;
        sendAck(sockFd, buff[0..1], @ptrCast(&clientAddr), clientAddrLen);
        std.log.debug("inserted {s}", .{message});
    }
}

fn init() !u8 {
    var buff: [2 * mnl.SOCKET_BUFFER_SIZE]u8 = undefined;

    // should be safe if just using current time
    var seq: u32 = @intCast(std.time.timestamp());

    const nl = try mnl.socketOpen(c.NETLINK_NETFILTER);
    defer mnl.socketClose(nl) catch {};

    try mnl.socketBind(nl, 0, mnl.SOCKET_AUTOPID);

    const batch = try mnl.nlmsgBatchStart(&buff);
    defer mnl.nlmsgBatchStop(batch);

    const resources: mynft.Resources = .{ .seq = &seq, .buff = &buff, .nl = @ptrCast(nl), .batch = @ptrCast(batch) };

    const sockFd = try posix.socket(posix.AF.UNIX, posix.SOCK.DGRAM, 0);
    defer posix.close(sockFd);

    const addr = try std.net.Address.initUnix(config.conf.socketPath);
    posix.unlink(config.conf.socketPath) catch {};
    try posix.bind(sockFd, &addr.any, addr.getOsSockLen());
    defer posix.unlink(config.conf.socketPath) catch {};

    std.log.info("listening on unix dgram sock {s}", .{config.conf.socketPath});
    serve(sockFd, resources) catch |err| {
        switch (err) {
            error.Permission => std.log.err("lack permission : CAP_NET_ADMIN", .{}),
            error.WrongSeq => std.log.err("wrong sequence number as last error for sendBatch, either there is a bug in the code, either the kernel was late sending ACKs twice in a row", .{}),
            else => std.log.err("unhandled error during serve : {s}", .{@errorName(err)}),
        }
        return 1;
    };
    return 0;
}

const cli = @import("cli/root.zig");

pub fn main() !u8 {
    // try to reload config on sighup
    posix.sigaction(posix.SIG.HUP, &.{
        .handler = .{ .handler = sigHupHandler, },
        .mask = posix.sigemptyset(),
        .flags = 0,
    }, null);

    // use std.heap.c_allocator to see memory usage in valgrind
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var root = try cli.build(allocator);
    defer root.deinit();

    var data: cli.Data = .{};
    root.execute(.{
        .data = &data,
    }) catch |err| {
        switch (err) {
            error.ParseZon, error.Parse => return 1,
            else => return err,
        }
    };

    if (data.needToServe) {
        if (config.state == .NotLoaded) unreachable;
        return init() catch |err| {
            std.log.err("init failed : {s}", .{@errorName(err)});
            return 1;
        };
    }
    return 0;
}
