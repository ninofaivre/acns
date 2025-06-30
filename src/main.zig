const std = @import("std");
const posix = std.posix;

const nftnl = @import("wrappers/libnftnl.zig");
const mnl = @import("wrappers/libmnl.zig");
const mynft = @import("nft.zig");
const config = @import("config.zig");
const message = @import("message.zig");

const c = @cImport({
    @cInclude("linux/netlink.h");
    @cInclude("linux/netfilter/nf_tables.h");
});

fn sendAck(sockFd: i32, buf: []const u8, destAddr: ?*const posix.sockaddr, addrlen: posix.socklen_t) void {
    if (addrlen == 0) return; // check if addrlen 0 cause sendto to fail
    _ = posix.sendto(sockFd, buf, 0, destAddr, addrlen) catch |err| {
        std.log.warn("while trying to send ack : {s}", .{@errorName(err)});
    };
}

fn isNftablesPathAuthorized(msg: message.Message) bool {
    if (config.conf.accessControl == .Disabled)
        return true;
    const accessControl = config.conf.accessControl.Enabled;
    const tables = blk: {
        switch (msg.familyType) {
            1 => break :blk accessControl.inet,
            2 => break :blk accessControl.ip,
            3 => break :blk accessControl.arp,
            5 => break :blk accessControl.netdev,
            7 => break :blk accessControl.bridge,
            10 => break :blk accessControl.ip6,
            else => {
                std.log.warn("{} : family type unknown (not one of [1,2,3,5,7,10] : {}\n", .{msg, msg.familyType});
                return false;
            },
        }
    };
    if (tables) |ts| {
        const table = ts.get(std.mem.span(msg.tableName));
        if (table) |t| {
            return t.contains(std.mem.span(msg.setName));
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
        const msg = message.parse(buff[0..len]) catch |err| {
            buff[0] = 1;
            sendAck(sockFd, buff[0..1], @ptrCast(&clientAddr), clientAddrLen);
            std.log.warn("received malformed message : {s}", .{@errorName(err)});
            continue;
        };
        if (!isNftablesPathAuthorized(msg)) {
            buff[0] = 1;
            sendAck(sockFd, buff[0..1], @ptrCast(&clientAddr), clientAddrLen);
            std.log.warn("{s} : nft path not authorized", .{ msg });
            continue;
        }
        mynft.addIpToSetFromMessage(msg, resources) catch |e| {
            buff[0] = 1;
            sendAck(sockFd, buff[0..1],
                @ptrCast(&clientAddr), clientAddrLen);
            if (e == error.Permission) return e;
            std.log.warn("while inserting {s} : {s}", .{
                msg,
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
        std.log.debug("inserted {s}", .{msg});
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
