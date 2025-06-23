const std = @import("std");
const posix = std.posix;

const nftnl = @import("wrappers/libnftnl.zig");
const mnl = @import("wrappers/libmnl.zig");
const config = @import("config.zig");

pub const Resources = struct { seq: *u32, buff: *[2 * mnl.SOCKET_BUFFER_SIZE]u8, nl: *mnl.Socket, batch: *mnl.NlmsgBatch };

const c = @cImport({
    @cInclude("linux/netlink.h");
    @cInclude("linux/netfilter/nf_tables.h");
});

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

    var pollRet: usize = 0;
    while (blk: {
        pollRet = try posix.poll(&fds, 0);
        break :blk pollRet > 0;
    } and (fds[0].revents & posix.POLL.IN) != 0) : (nMsgAck += 1) {
        const retRecv = try mnl.socketRecvfrom(nl, &buff[0], @sizeOf(@TypeOf(buff.*)));
        // TODO patch this ugly shit
        const cbR = mnl.cbRun(@ptrCast(&buff[0]), retRecv, seq, mnl.socketGetPortid(nl), null, null) catch |e| blk: {
            if (err) |errr| {
                if (errr == error.WrongSeq) err = e;
            } else {
                err = e;
            }
            break :blk null;
        };
        if (cbR != null) {
            if (err) |errr| {
                if (errr == error.WrongSeq)
                    err = null;
            }
        }
    }
    if (err) |e| return e;
    return nMsgAck;
}

pub fn addIpToSet(set: struct { family: u16, tableName: [*c]const u8, name: [*c]const u8 }, ip: u32, resources: Resources, conf: config.Config) !void {
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
    if (conf.resetTimeout)  {
        expectedNMsgAck += 2;
        try addSetElemNlmsgToBatch(batch, s, c.NFT_MSG_DELSETELEM, set.family, c.NLM_F_ACK, seq);
        try addSetElemNlmsgToBatch(batch, s, c.NFT_MSG_NEWSETELEM, set.family, c.NLM_F_CREATE | c.NLM_F_REPLACE | c.NLM_F_ACK, seq);
    }

    _ = nftnl.batchEnd(@ptrCast(mnl.nlmsgBatchCurrent(batch)), seq);
    try mnl.nlmsgBatchNext(batch);

    const nMsgAck = sendBatch(nl, batch, buff, seq) catch |err| {
        return switch (err) {
            error.PathNotFound => error.SetPathNotFound,
            else => err,
        };
    };
    if (nMsgAck < expectedNMsgAck) {
        return error.ReceivedTooFewAck;
    } else if (nMsgAck > expectedNMsgAck) {
        return error.ReceivedTooManyAck;
    }
}
