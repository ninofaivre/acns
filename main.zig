const std = @import("std");

const c = @cImport({
    @cInclude("netinet/in.h");

    @cInclude("linux/netfilter.h");
    @cInclude("linux/netfilter/nf_tables.h");

    @cInclude("libmnl/libmnl.h");
    @cInclude("libnftnl/set.h");
});

const MNL_SOCKET_BUFFER_SIZE = if (std.heap.pageSize() < 8192) std.heap.pageSize() else 8192;

fn addIpToSet(family: u16, tableName: [*c]const u8, setName: [*c]const u8, ip: u32, seq: *u32, buff: *[2 * MNL_SOCKET_BUFFER_SIZE]u8, nl: *c.mnl_socket, portid: u32) !void {
    const s = c.nftnl_set_alloc();
    if (s == null) return error.OutOfMemory;
    defer c.nftnl_set_free(s);

    _ = c.nftnl_set_set_str(s, c.NFTNL_SET_TABLE, tableName);
    _ = c.nftnl_set_set_str(s, c.NFTNL_SET_NAME, setName);

    const e = c.nftnl_set_elem_alloc();
    if (e == null) return error.OutOfMemory;
    defer c.nftnl_set_elem_free(e);

    if (c.nftnl_set_elem_set(e, c.NFTNL_SET_ELEM_KEY, &ip, @sizeOf(@TypeOf(ip))) < 0) {
        return error.NftnlSetElemSet;
    }
    c.nftnl_set_elem_add(s, e);

    const batch = c.mnl_nlmsg_batch_start(&buff[0], MNL_SOCKET_BUFFER_SIZE);
    if (batch == null) return error.OutOfMemory;

    _ = c.nftnl_batch_begin(@ptrCast(c.mnl_nlmsg_batch_current(batch)), seq.*);
    seq.* += 1;
    _ = c.mnl_nlmsg_batch_next(batch);

    const nlh = c.nftnl_nlmsg_build_hdr(@ptrCast(c.mnl_nlmsg_batch_current(batch)), c.NFT_MSG_NEWSETELEM, family, c.NLM_F_CREATE | c.NLM_F_EXCL | c.NLM_F_ACK, seq.*);
    seq.* += 1;
    c.nftnl_set_elems_nlmsg_build_payload(nlh, s);
    _ = c.mnl_nlmsg_batch_next(batch);

    _ = c.nftnl_batch_end(@ptrCast(c.mnl_nlmsg_batch_current(batch)), seq.*);
    seq.* += 1;
    _ = c.mnl_nlmsg_batch_next(batch);

    if (c.mnl_socket_sendto(nl, c.mnl_nlmsg_batch_head(batch), c.mnl_nlmsg_batch_size(batch)) < 0) {
        return error.MnlSocketSend;
    }
    c.mnl_nlmsg_batch_stop(batch);

    var ret: i64 = c.mnl_socket_recvfrom(nl, &buff[0], @sizeOf(@TypeOf(buff)));
    while (ret > 0) {
        std.debug.print("while A, ret : {} sizeof buff : {}, portid : {}\n", .{ ret, @sizeOf(@TypeOf(buff)), portid });
        ret = c.mnl_cb_run(@ptrCast(&buff[0]), @intCast(ret), 0, portid, null, null);
        if (ret <= 0) break;
        std.debug.print("while B\n", .{});
        ret = c.mnl_socket_recvfrom(nl, &buff[0], @sizeOf(@TypeOf(buff)));
    }
    c.perror("testoa :");
    if (ret == -1) return error.MnlRecv;
}

pub fn main() !void {
    var buff: [2 * MNL_SOCKET_BUFFER_SIZE]u8 = undefined;

    // should be safe if just using current time
    var seq: u32 = @intCast(std.time.timestamp());

    const nl = c.mnl_socket_open(c.NETLINK_NETFILTER);
    if (nl == null) return error.MnlSocketOpen;
    defer _ = c.mnl_socket_close(nl);

    if (c.mnl_socket_bind(nl, 0, c.MNL_SOCKET_AUTOPID) < 0) return error.MnlSocketBind;
    const portid = c.mnl_socket_get_portid(nl);

    try addIpToSet(c.NFPROTO_INET, "filter", "monSet", 0x3, &seq, &buff, @ptrCast(nl), portid);
}
