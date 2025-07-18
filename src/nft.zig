const std = @import("std");
const posix = std.posix;

const nftnl = @import("wrappers/libnftnl.zig");
const mnl = @import("wrappers/libmnl.zig");
const config = @import("config.zig");
const message = @import("message.zig");

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

fn sendBatch(nl: *mnl.Socket, batch: *mnl.NlmsgBatch, buff: *[2 * mnl.SOCKET_BUFFER_SIZE]u8, seq: u32, expectedNMsgAck: u8) !void {
    _ = try mnl.socketSendto(nl, mnl.nlmsgBatchHead(batch), mnl.nlmsgBatchSize(batch));

    var fds: [1]posix.pollfd = .{
        .{
            .fd = mnl.socketGetFd(nl),
            .events = posix.POLL.IN,
            .revents = 0,
        },
    };

    var retErr: ?anyerror = null;
    var nAck: u8 = 0;
    // The second condition is not strictly needed as poll is only watching
    // for posix.POLL.IN event and only for one fd but I think it is best
    // practice to check anyway, it could avoir future footgun.
    while (nAck != expectedNMsgAck and
        (try posix.poll(&fds, config.conf.timeoutKernelAcksInMs) > 0) and
        (fds[0].revents & posix.POLL.IN) != 0
    ) {
        const retRecv = try mnl.socketRecvfrom(nl, &buff[0], @sizeOf(@TypeOf(buff.*)));
        _ = mnl.cbRun(@ptrCast(&buff[0]), retRecv, seq, mnl.socketGetPortid(nl), null, null) catch |e| {
            if (e == error.WrongSeq) {
                continue ;
            } else if (retErr == null) {
                retErr = e;
            }
        };
        nAck += 1;
    }
    if (retErr) |e| return e;
    if (nAck != expectedNMsgAck) return error.TooFewAck;
}

pub fn addIpToSetFromMessage(msg: message.Message, resources: Resources) !void {
    resources.seq.* += 1;

    const seq = resources.seq.*;
    const buff = resources.buff;
    const nl = resources.nl;
    const batch = resources.batch;

    const s = try nftnl.setAlloc();
    defer nftnl.setFree(s);

    try nftnl.setSetStr(s, nftnl.SET_TABLE, msg.tableName);
    try nftnl.setSetStr(s, nftnl.SET_NAME, msg.setName);

    const e = try nftnl.setElemAlloc();
    nftnl.setElemAdd(s, e);
    if (msg.ip == .v4) {
        try nftnl.setElemSet(e, nftnl.SET_ELEM_KEY,
            &msg.ip.v4.value, @sizeOf(message.Message.IP.IPv4.Value));
    } else {
        try nftnl.setElemSet(e, nftnl.SET_ELEM_KEY,
            &msg.ip.v6.value, @sizeOf(message.Message.IP.IPv6.Value));
    }

    mnl.nlmsgBatchReset(batch);

    _ = nftnl.batchBegin(@ptrCast(mnl.nlmsgBatchCurrent(batch)), seq);
    try mnl.nlmsgBatchNext(batch);

    var expectedNMsgAck: u8 = 1;
    try addSetElemNlmsgToBatch(batch, s, c.NFT_MSG_NEWSETELEM, msg.familyType, c.NLM_F_CREATE | c.NLM_F_REPLACE | c.NLM_F_ACK, seq);
    if (config.conf.resetTimeout)  {
        expectedNMsgAck += 2;
        try addSetElemNlmsgToBatch(batch, s, c.NFT_MSG_DELSETELEM, msg.familyType, c.NLM_F_ACK, seq);
        try addSetElemNlmsgToBatch(batch, s, c.NFT_MSG_NEWSETELEM, msg.familyType, c.NLM_F_CREATE | c.NLM_F_REPLACE | c.NLM_F_ACK, seq);
    }

    _ = nftnl.batchEnd(@ptrCast(mnl.nlmsgBatchCurrent(batch)), seq);
    try mnl.nlmsgBatchNext(batch);

    sendBatch(nl, batch, buff, seq, expectedNMsgAck) catch |err| {
        return switch (err) {
            error.PathNotFound => error.SetPathNotFound,
            else => err,
        };
    };
}
