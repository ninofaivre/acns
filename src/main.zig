pub const std_options = std.Options{
    // TODO setting option for log_level
    .log_level = .debug,
};

const std = @import("std");
const posix = std.posix;

const nftnl = @import("wrappers/libnftnl.zig");
const mnl = @import("wrappers/libmnl.zig");

const c = @cImport({
    // TODO see what's necessary
    @cInclude("linux/netlink.h");
    @cInclude("linux/netfilter.h");
    @cInclude("linux/netfilter/nf_tables.h");
    @cInclude("stdio.h");
});

const NftnlError = error{SetElemSet};
const MnlError = error{ SocketSend, SocketRecv, SocketOpen, SocketBind, BatchNextNoSpace };

const Resources = struct { seq: *u32, buff: *[2 * mnl.SOCKET_BUFFER_SIZE]u8, nl: *mnl.Socket, batch: *mnl.NlmsgBatch };

fn addSetElemNlmsgToBatch(batch: *mnl.NlmsgBatch, set: *nftnl.Set, attr: u16, family: u16, flags: u16, seq: u32) !void {
    const nlh = nftnl.nlmsgBuildHdr(@ptrCast(mnl.nlmsgBatchCurrent(batch)), attr, family, flags, seq);
    nftnl.setElemsNlmsgBuildPayload(nlh, set);
    try mnl.nlmsgBatchNext(batch);
}

fn sendBatch(nl: *mnl.Socket, batch: *mnl.NlmsgBatch, buff: *[2 * mnl.SOCKET_BUFFER_SIZE]u8, seq: u32) !usize {
    _ = try mnl.socketSendto(nl, mnl.nlmsgBatchHead(batch), mnl.nlmsgBatchSize(batch));

    var fds: [1]posix.pollfd = .{
        .{
            .fd = mnl.socketGetFd(nl),
            .events = posix.POLL.IN,
            .revents = 0,
        },
    };

    var err: ?anyerror = null;
    var nMsgAck: usize = 0;

    var pollRet = try posix.poll(&fds, 0);
    while (pollRet > 0 and (fds[0].revents & posix.POLL.IN) != 0) {
        const retRecv = try mnl.socketRecvfrom(nl, &buff[0], @sizeOf(@TypeOf(buff.*)));
        const cbR = mnl.cbRun(@ptrCast(&buff[0]), retRecv, seq, mnl.socketGetPortid(nl), null, null) catch |e| {
            if (err) |errr| {
                if (errr == error.WrongSeq) err = e;
            } else {
                err = e;
            }
            null;
        };
        if (cbR != null and err == error.WrongSeq)
            err = null;
        nMsgAck += 1;
        pollRet = try posix.poll(&fds, 0);
    }
    if (err) |e| return e;
    return nMsgAck;
}

fn addIpToSet(set: struct { family: u16, tableName: [*c]const u8, name: [*c]const u8 }, ip: u32, resources: Resources) !void {
    resources.seq.* += 1;

    const seq = resources.seq.*;
    const buff = resources.buff;
    const nl = resources.nl;
    const batch = resources.batch;

    const s = try nftnl.setAlloc();
    defer nftnl.setFree(s);

    try nftnl.setSetStr(s, nftnl.SET_TABLE, set.tableName);
    try nftnl.setSetStr(s, nftnl.SET_NAME, set.name);

    const e = try nftnl.setElemAlloc();
    nftnl.setElemAdd(s, e);
    try nftnl.setElemSet(e, nftnl.SET_ELEM_KEY, &ip, @sizeOf(@TypeOf(ip)));

    mnl.nlmsgBatchReset(batch);

    _ = nftnl.batchBegin(@ptrCast(mnl.nlmsgBatchCurrent(batch)), seq);
    try mnl.nlmsgBatchNext(batch);

    var expectedNMsgAck: usize = 1;
    try addSetElemNlmsgToBatch(batch, s, c.NFT_MSG_NEWSETELEM, set.family, c.NLM_F_CREATE | c.NLM_F_REPLACE | c.NLM_F_ACK, seq);
    // if reset timeout enabled in settings
    expectedNMsgAck += 2;
    try addSetElemNlmsgToBatch(batch, s, c.NFT_MSG_DELSETELEM, set.family, c.NLM_F_ACK, seq);
    try addSetElemNlmsgToBatch(batch, s, c.NFT_MSG_NEWSETELEM, set.family, c.NLM_F_CREATE | c.NLM_F_REPLACE | c.NLM_F_ACK, seq);
    // if reset timeout enabled in settings

    _ = nftnl.batchEnd(@ptrCast(mnl.nlmsgBatchCurrent(batch)), seq);
    try mnl.nlmsgBatchNext(batch);

    const nMsgAck = sendBatch(nl, batch, buff, seq) catch |err| {
        return switch (err) {
            error.PathNotFound => error.SetPathNotFound,
            else => err,
        };
    };
    if (nMsgAck <= expectedNMsgAck) {
        return error.ReceivedTooFewAck;
    } else if (nMsgAck >= expectedNMsgAck) {
        return error.ReceivedTooManyAck;
    }
}

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

fn serve(sockFd: i32, resources: Resources) !void {
    var buff: [2 + c.NFT_TABLE_MAXNAMELEN + c.NFT_SET_MAXNAMELEN + 4 + 1]u8 = undefined;
    while (true) {
        const len = try posix.recvfrom(sockFd, &buff, 0, null, null);
        const message = parseMessage(buff[0..len]) catch |err| {
            // TODO ERROR ACK
            std.log.warn("received malformed message : {s}", .{@errorName(err)});
            continue;
        };
        addIpToSet(.{ .tableName = message.tableName, .family = message.familyType, .name = message.setName }, message.ip.value, resources) catch |err| {
            // TODO ERROR ACK
            switch (err) {
                error.Permission, error.WrongSeq => return err,
            }
            std.log.warn("while inserting {} : {s}", .{ message, @errorName(err) });
            continue;
        };
        // TODO SUCCESS ACK
        std.log.debug("inserted {}", .{message});
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

    const resources: Resources = .{ .seq = &seq, .buff = &buff, .nl = @ptrCast(nl), .batch = @ptrCast(batch) };

    const sockFd = try posix.socket(posix.AF.UNIX, posix.SOCK.DGRAM, 0);
    defer posix.close(sockFd);

    const sockPath = "/tmp/testSock";
    const addr = try std.net.Address.initUnix(sockPath);
    posix.unlinkZ(sockPath) catch {};
    try posix.bind(sockFd, &addr.any, addr.getOsSockLen());
    defer posix.unlinkZ(sockPath) catch {};

    std.log.info("listening on unix dgram sock {}", .{sockPath});
    return serve(sockFd, resources) catch |err| {
        switch (err) {
            error.Permission => std.log.err("lack permission : CAP_NET_ADMIN", .{}),
            error.WrongSeq => std.log.err("wrong sequence number as last error for sendBatch, either there is a bug in the code, either the kernel was late sending ACKs twice in a row", .{}),
            else => std.log.err("unhandled error during serve : {s}", .{@errorName(err)}),
        }
        return 1;
    } orelse 0;
}

pub fn main() !u8 {
    return init() catch |err| {
        std.log.err("init failed : {s}", .{@errorName(err)});
        return 1;
    };
}
