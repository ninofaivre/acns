const std = @import("std");
//const builtin = @import("builtin");
const posix = std.posix;

const nftnl = @import("wrappers/libnftnl.zig");
const mnl = @import("wrappers/libmnl.zig");

const c = @cImport({
    @cInclude("netinet/in.h");

    @cInclude("linux/netlink.h");
    @cInclude("linux/netfilter.h");
    @cInclude("linux/netfilter/nf_tables.h");
    @cInclude("stdio.h");
});

const NftnlError = error{SetElemSet};
const MnlError = error{ SocketSend, SocketRecv, SocketOpen, SocketBind, BatchNextNoSpace };

const Resources = struct { seq: *u32, buff: *[2 * mnl.SOCKET_BUFFER_SIZE]u8, nl: *mnl.Socket, portid: u32, batch: *mnl.NlmsgBatch };

fn addIpToSet(set: struct { family: u16, tableName: [*c]const u8, name: [*c]const u8 }, ip: u32, resources: Resources) !void {
    const s = try nftnl.setAlloc();
    defer nftnl.setFree(s);

    try nftnl.setSetStr(s, nftnl.SET_TABLE, set.tableName);
    try nftnl.setSetStr(s, nftnl.SET_NAME, set.name);

    const e = try nftnl.setElemAlloc();
    // no need to free elem added to set

    nftnl.setElemAdd(s, e);
    try nftnl.setElemSet(e, nftnl.SET_ELEM_KEY, &ip, @sizeOf(@TypeOf(ip)));

    defer mnl.nlmsgBatchReset(resources.batch);
    _ = nftnl.batchBegin(@ptrCast(mnl.nlmsgBatchCurrent(resources.batch)), resources.seq.*);
    resources.seq.* += 1;
    try mnl.nlmsgBatchNext(resources.batch);

    const nlh = nftnl.nlmsgBuildHdr(@ptrCast(mnl.nlmsgBatchCurrent(resources.batch)), c.NFT_MSG_NEWSETELEM, set.family, c.NLM_F_CREATE | c.NLM_F_EXCL | c.NLM_F_ACK, resources.seq.*);
    resources.seq.* += 1;
    nftnl.setElemsNlmsgBuildPayload(nlh, s);
    try mnl.nlmsgBatchNext(resources.batch);

    _ = nftnl.batchEnd(@ptrCast(mnl.nlmsgBatchCurrent(resources.batch)), resources.seq.*);
    resources.seq.* += 1;
    try mnl.nlmsgBatchNext(resources.batch);

    _ = try mnl.socketSendto(resources.nl, mnl.nlmsgBatchHead(resources.batch), mnl.nlmsgBatchSize(resources.batch));
    var ret = try mnl.socketRecvfrom(resources.nl, &resources.buff[0], @sizeOf(@TypeOf(resources.buff.*)));
    while (ret != 0) {
        if (try mnl.cbRun(@ptrCast(&resources.buff[0]), @intCast(ret), 0, resources.portid, null, null) == 0)
            break;
        ret = try mnl.socketRecvfrom(resources.nl, &resources.buff[0], @sizeOf(@TypeOf(resources.buff.*)));
    }
}

const IPv4 = struct {
    value: u32,
    pub fn format(self: IPv4, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        _ = fmt;
        _ = options;
        const o1: u8 = @truncate(self.value >> 24);
        const o2: u8 = @truncate(self.value >> 16);
        const o3: u8 = @truncate(self.value >> 8);
        const o4: u8 = @truncate(self.value);
        try writer.print("{}.{}.{}.{}", .{ o1, o2, o3, o4 });
    }
};

const Message = struct {
    tableName: [*c]const u8,
    setName: [*c]const u8,
    ip: IPv4,
    pub fn format(self: Message, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        _ = fmt;
        _ = options;
        try writer.print("inserting {} in inet -> {s} -> {s}", .{ self.ip, self.tableName, self.setName });
    }
};

fn parseMessage(message: []const u8) !Message {
    var tail = message;
    const endTableNameIdx = std.mem.indexOf(u8, tail, "\x00") orelse return error.WrongMessage;
    const tableName = tail[0..endTableNameIdx];
    tail = tail[(endTableNameIdx + 1)..];
    const endSetNameIdx = std.mem.indexOf(u8, tail, "\x00") orelse return error.WrongMessage;
    const setName = tail[0..endSetNameIdx];
    tail = tail[(endTableNameIdx + 1)..];
    if (tail.len != 5 and tail.len != 4) return error.WrongMessage;
    const ip: u32 = std.mem.readInt(u32, tail[0..4], std.builtin.Endian.little);

    return .{ .tableName = @ptrCast(tableName), .setName = @ptrCast(setName), .ip = .{ .value = ip } };
}

fn serve(resources: Resources) !void {
    const sockFd = try posix.socket(posix.AF.UNIX, posix.SOCK.DGRAM, 0);
    defer posix.close(sockFd);

    const sockPath = "/tmp/testSock";
    const addr = try std.net.Address.initUnix(sockPath);
    posix.unlinkZ(sockPath) catch {};
    try posix.bind(sockFd, &addr.any, addr.getOsSockLen());
    defer posix.unlinkZ(sockPath) catch {};
    var buff: [64 + 64 + 5]u8 = undefined;
    while (true) {
        const len = try posix.recvfrom(sockFd, &buff, 0, null, null);
        if (len <= 0)
            continue;
        const message = try parseMessage(buff[0..len]);
        addIpToSet(.{ .tableName = message.tableName, .family = c.NFPROTO_INET, .name = message.setName }, message.ip.value, resources) catch |err| {
            // TODO when ack will be implemented, send error ack here before any logging
            switch (err) {
                error.Permission => return err,
                else => std.log.err("while {} : {s}", .{ message, @errorName(err) }),
            }
        };
    }
}

//fn initResources() !Resources {}

pub fn main() !u8 {
    var buff: [2 * mnl.SOCKET_BUFFER_SIZE]u8 = undefined;

    // should be safe if just using current time
    var seq: u32 = @intCast(std.time.timestamp());

    const nl = try mnl.socketOpen(c.NETLINK_NETFILTER);
    defer mnl.socketClose(nl) catch {};

    try mnl.socketBind(nl, 0, mnl.SOCKET_AUTOPID);
    const portid = mnl.socketGetPortid(nl);

    const batch = try mnl.nlmsgBatchStart(&buff);
    defer mnl.nlmsgBatchStop(batch);

    const resources: Resources = .{ .seq = &seq, .buff = &buff, .nl = @ptrCast(nl), .portid = portid, .batch = @ptrCast(batch) };

    serve(resources) catch |err| {
        switch (err) {
            error.Permission => {
                std.log.err("lack permissions !", .{});
            },
            else => return err,
        }
        return 1;
    };
    return 0;
}
