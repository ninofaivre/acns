const std = @import("std");

const c = @cImport({
    @cInclude("netinet/in.h");

    @cInclude("linux/netfilter.h");
    @cInclude("linux/netfilter/nf_tables.h");

    @cInclude("libmnl/libmnl.h");
    @cInclude("libnftnl/set.h");
});

const MNL_SOCKET_BUFFER_SIZE = if (std.heap.pageSize() < 8192) std.heap.pageSize() else 8192;

fn addIpToSet() !void {}

pub fn main() !void {
    var buff: [2 * MNL_SOCKET_BUFFER_SIZE]u8 = undefined;

    const s = c.nftnl_set_alloc();
    if (s == null) return error.OutOfMemory;
    // TODO investigate segfault
    //defer c.nftnl_set_free(s);

    // should be safe if just using current time
    var seq: u32 = @intCast(std.time.timestamp());

    const family = c.NFPROTO_INET;

    _ = c.nftnl_set_set_str(s, c.NFTNL_SET_TABLE, "filter");
    _ = c.nftnl_set_set_str(s, c.NFTNL_SET_NAME, "monSet");

    const e1 = c.nftnl_set_elem_alloc();
    if (e1 == null) return error.OutOfMemory;
    //defer c.nftnl_set_elem_free(e1);

    const data1: u32 = 0x1;
    if (c.nftnl_set_elem_set(e1, c.NFTNL_SET_ELEM_KEY, &data1, @sizeOf(@TypeOf(data1))) < 0) {
        return error.NftnlSetElemSet;
    }
    c.nftnl_set_elem_add(s, e1);

    const e2 = c.nftnl_set_elem_alloc();
    if (e2 == null) return error.OutOfMemory;
    //defer c.nftnl_set_elem_free(e2);

    const data2: u32 = 0x2;
    if (c.nftnl_set_elem_set(e2, c.NFTNL_SET_ELEM_KEY, &data2, @sizeOf(@TypeOf(data2))) < 0) {
        return error.NftnlSetElemSet;
    }
    c.nftnl_set_elem_add(s, e2);

    const batch = c.mnl_nlmsg_batch_start(&buff[0], MNL_SOCKET_BUFFER_SIZE);
    if (batch == null) return error.OutOfMemory;

    _ = c.nftnl_batch_begin(@ptrCast(c.mnl_nlmsg_batch_current(batch)), seq);
    seq += 1;
    _ = c.mnl_nlmsg_batch_next(batch);

    const nlh = c.nftnl_nlmsg_build_hdr(@ptrCast(c.mnl_nlmsg_batch_current(batch)), c.NFT_MSG_NEWSETELEM, family, c.NLM_F_CREATE | c.NLM_F_EXCL | c.NLM_F_ACK, seq);
    seq += 1;
    c.nftnl_set_elems_nlmsg_build_payload(nlh, s);
    c.nftnl_set_free(s);
    _ = c.mnl_nlmsg_batch_next(batch);

    _ = c.nftnl_batch_end(@ptrCast(c.mnl_nlmsg_batch_current(batch)), seq);
    seq += 1;
    _ = c.mnl_nlmsg_batch_next(batch);

    const nl = c.mnl_socket_open(c.NETLINK_NETFILTER);
    if (nl == null) return error.MnlSocketOpen;
    defer _ = c.mnl_socket_close(nl);
    if (c.mnl_socket_bind(nl, 0, c.MNL_SOCKET_AUTOPID) < 0) return error.MnlSocketBind;
    const portid = c.mnl_socket_get_portid(nl);

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
