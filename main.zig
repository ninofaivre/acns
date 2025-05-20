const std = @import("std");
//const builtin = @import("builtin");
const posix = std.posix;

const c = @cImport({
    @cInclude("netinet/in.h");

    @cInclude("linux/netfilter.h");
    @cInclude("linux/netfilter/nf_tables.h");

    @cInclude("libmnl/libmnl.h");
    @cInclude("libnftnl/set.h");
});

const NftnlError = error{SetElemSet};
const MnlError = error{ SocketSend, SocketRecv, SocketOpen, SocketBind, BatchNextNoSpace };

const MNL_SOCKET_BUFFER_SIZE = if (std.heap.pageSize() < 8192) std.heap.pageSize() else 8192;

const Resources = struct { seq: *u32, buff: *[2 * MNL_SOCKET_BUFFER_SIZE]u8, nl: *c.mnl_socket, portid: u32, batch: *c.mnl_nlmsg_batch };

fn addIpToSet(set: struct { family: u16, tableName: [*c]const u8, name: [*c]const u8 }, ip: u32, resources: Resources) !void {
    const s = c.nftnl_set_alloc();
    if (s == null) return error.OutOfMemory;
    defer c.nftnl_set_free(s);

    _ = c.nftnl_set_set_str(s, c.NFTNL_SET_TABLE, set.tableName);
    _ = c.nftnl_set_set_str(s, c.NFTNL_SET_NAME, set.name);

    const e = c.nftnl_set_elem_alloc();
    if (e == null) return error.OutOfMemory;
    // no need to free elem added to set

    c.nftnl_set_elem_add(s, e);
    if (c.nftnl_set_elem_set(e, c.NFTNL_SET_ELEM_KEY, &ip, @sizeOf(@TypeOf(ip))) < 0) {
        return NftnlError.SetElemSet;
    }

    defer c.mnl_nlmsg_batch_reset(resources.batch);
    _ = c.nftnl_batch_begin(@ptrCast(c.mnl_nlmsg_batch_current(resources.batch)), resources.seq.*);
    resources.seq.* += 1;
    if (c.mnl_nlmsg_batch_next(resources.batch) == false) return MnlError.BatchNextNoSpace;

    const nlh = c.nftnl_nlmsg_build_hdr(@ptrCast(c.mnl_nlmsg_batch_current(resources.batch)), c.NFT_MSG_NEWSETELEM, set.family, c.NLM_F_CREATE | c.NLM_F_EXCL | c.NLM_F_ACK, resources.seq.*);
    resources.seq.* += 1;
    c.nftnl_set_elems_nlmsg_build_payload(nlh, s);
    if (c.mnl_nlmsg_batch_next(resources.batch) == false) return MnlError.BatchNextNoSpace;

    _ = c.nftnl_batch_end(@ptrCast(c.mnl_nlmsg_batch_current(resources.batch)), resources.seq.*);
    resources.seq.* += 1;
    if (c.mnl_nlmsg_batch_next(resources.batch) == false) return MnlError.BatchNextNoSpace;

    if (c.mnl_socket_sendto(resources.nl, c.mnl_nlmsg_batch_head(resources.batch), c.mnl_nlmsg_batch_size(resources.batch)) < 0) {
        return MnlError.SocketSend;
    }

    var ret: i64 = c.mnl_socket_recvfrom(resources.nl, &resources.buff[0], @sizeOf(@TypeOf(resources.buff.*)));
    while (ret > 0) {
        ret = c.mnl_cb_run(@ptrCast(&resources.buff[0]), @intCast(ret), 0, resources.portid, null, null);
        if (ret <= 0) break;
        ret = c.mnl_socket_recvfrom(resources.nl, &resources.buff[0], @sizeOf(@TypeOf(resources.buff.*)));
    }
    if (ret == -1) {
        c.perror("testoa :");
        return MnlError.SocketRecv;
    }
}

const Message = struct {
    tableName: [*c]const u8,
    setName: [*c]const u8,
    ip: u32,
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

    return .{ .tableName = @ptrCast(tableName), .setName = @ptrCast(setName), .ip = ip };
}

fn serve(resources: Resources) !void {
    const sockFd = try posix.socket(posix.AF.UNIX, posix.SOCK.DGRAM, 0);
    defer posix.close(sockFd);

    const addr = try std.net.Address.initUnix("/tmp/testSock");
    try posix.bind(sockFd, &addr.any, addr.getOsSockLen());
    defer posix.unlinkZ("/tmp/testSock") catch {};
    var buff: [64 + 64 + 5]u8 = undefined;
    while (true) {
        const len = try posix.recvfrom(sockFd, &buff, 0, null, null);
        if (len <= 0)
            continue;
        const message = try parseMessage(buff[0..len]);
        try addIpToSet(.{ .tableName = message.tableName, .family = c.NFPROTO_INET, .name = message.setName }, message.ip, resources);
    }
}

pub fn main() !void {
    var buff: [2 * MNL_SOCKET_BUFFER_SIZE]u8 = undefined;

    // should be safe if just using current time
    var seq: u32 = @intCast(std.time.timestamp());

    const nl = c.mnl_socket_open(c.NETLINK_NETFILTER);
    if (nl == null) return MnlError.SocketOpen;
    defer _ = c.mnl_socket_close(nl);

    if (c.mnl_socket_bind(nl, 0, c.MNL_SOCKET_AUTOPID) < 0) return MnlError.SocketBind;
    const portid = c.mnl_socket_get_portid(nl);

    const batch = c.mnl_nlmsg_batch_start(&buff[0], MNL_SOCKET_BUFFER_SIZE);
    if (batch == null) return error.OutOfMemory;
    defer c.mnl_nlmsg_batch_stop(batch);

    const resources: Resources = .{ .seq = &seq, .buff = &buff, .nl = @ptrCast(nl), .portid = portid, .batch = @ptrCast(batch) };

    try serve(resources);
}
