const std = @import("std");
const posix = std.posix;

const c = @cImport({
    @cInclude("libmnl/libmnl.h");
    @cInclude("errno.h");
});

const MnlSocketError = error{ AccessDenied, AddressFamilyNotSupported, ProtocolFamilyNotAvailable, ProcessFdQuotaExceeded, SystemFdQuotaExceeded, SystemResources, ProtocolNotSupported, SocketTypeNotSupported, OutOfMemory, Unexpected };

pub const SOCKET_AUTOPID = c.MNL_SOCKET_AUTOPID;
pub const SOCKET_BUFFER_SIZE = if (std.heap.pageSize() < 8192) std.heap.pageSize() else 8192;
pub const Socket = c.mnl_socket;
pub const NlmsgBatch = c.mnl_nlmsg_batch;

pub fn socketOpen(bus: i32) MnlSocketError!*c.mnl_socket {
    std.c._errno().* = 0;
    return c.mnl_socket_open(bus) orelse switch (posix.errno(-1)) {
        .SUCCESS => error.OutOfMemory,
        .ACCES => error.AccessDenied,
        .AFNOSUPPORT => error.AddressFamilyNotSupported,
        .INVAL => error.ProtocolFamilyNotAvailable,
        .MFILE => error.ProcessFdQuotaExceeded,
        .NFILE => error.SystemFdQuotaExceeded,
        .NOBUFS => error.SystemResources,
        .NOMEM => error.SystemResources,
        .PROTONOSUPPORT => error.ProtocolNotSupported,
        .PROTOTYPE => error.SocketTypeNotSupported,
        else => |errno| return posix.unexpectedErrno(errno),
    };
}

pub fn socketClose(nl: *c.mnl_socket) !void {
    if (c.mnl_socket_close(nl) == -1) return error.TODO_SocketClose;
}

pub fn socketBind(nl: *c.mnl_socket, groups: u32, pid: c.pid_t) !void {
    if (c.mnl_socket_bind(nl, groups, pid) == -1) return error.TODO_socketBind;
}

pub fn socketSendto(nl: *const c.mnl_socket, buff: *anyopaque, len: usize) !usize {
    const ret: isize = c.mnl_socket_sendto(nl, buff, len);
    if (ret < 0) return error.TODO_socketSendto;
    return @intCast(ret);
}

pub fn socketRecvfrom(nl: *const c.mnl_socket, buff: *anyopaque, buffSize: usize) !usize {
    const ret: isize = c.mnl_socket_recvfrom(nl, buff, buffSize);
    if (ret < 0) return error.TODO_socketRecvfrom;
    return @intCast(ret);
}

pub fn socketGetPortid(nl: *c.mnl_socket) u32 {
    return c.mnl_socket_get_portid(nl);
}

pub fn nlmsgBatchStart(buff: *[2 * SOCKET_BUFFER_SIZE]u8) !*c.mnl_nlmsg_batch {
    return c.mnl_nlmsg_batch_start(&buff[0], SOCKET_BUFFER_SIZE) orelse error.OutOfMemory;
}

pub fn nlmsgBatchStop(batch: *c.mnl_nlmsg_batch) void {
    c.mnl_nlmsg_batch_stop(batch);
}

pub fn nlmsgBatchReset(batch: *c.mnl_nlmsg_batch) void {
    c.mnl_nlmsg_batch_reset(batch);
}

pub fn nlmsgBatchCurrent(batch: *c.mnl_nlmsg_batch) *anyopaque {
    return @ptrCast(c.mnl_nlmsg_batch_current(batch));
}

pub fn nlmsgBatchNext(batch: *c.mnl_nlmsg_batch) !void {
    if (c.mnl_nlmsg_batch_next(batch) == false) return error.Overflow;
}

pub fn nlmsgBatchHead(batch: *c.mnl_nlmsg_batch) *anyopaque {
    return @ptrCast(c.mnl_nlmsg_batch_head(batch));
}

pub fn nlmsgBatchSize(batch: *c.mnl_nlmsg_batch) usize {
    return c.mnl_nlmsg_batch_size(batch);
}

pub fn cbRun(buff: *anyopaque, numbytes: usize, seq: u32, portid: u32, cbData: c.mnl_cb_t, data: ?*anyopaque) !u32 {
    const ret = c.mnl_cb_run(buff, numbytes, seq, portid, cbData, data);
    return switch (posix.errno(ret)) {
        .SUCCESS => @intCast(ret),
        .PERM => error.Permission,
        else => error.TODO_cbRun,
    };
}
