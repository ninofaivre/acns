const std = @import("std");
const posix = std.posix;

const c = @cImport({
    @cInclude("libnftnl/set.h");
});

pub const SET_ELEM_KEY = c.NFTNL_SET_ELEM_KEY;
pub const SET_ELEM_TIMEOUT = c.NFTNL_SET_ELEM_TIMEOUT;
pub const SET_TABLE = c.NFTNL_SET_TABLE;
pub const SET_NAME = c.NFTNL_SET_NAME;

pub const Set = c.nftnl_set;

pub fn setAlloc() !*c.nftnl_set {
    return c.nftnl_set_alloc() orelse error.OutOfMemory;
}

pub fn setFree(set: *const c.nftnl_set) void {
    c.nftnl_set_free(set);
}

pub fn setSetStr(set: *c.nftnl_set, attr: u16, str: [*c]const u8) !void {
    // mostly malloc failure but also wrong size on some members
    if (c.nftnl_set_set_str(set, attr, str) == -1) return error.TODO_setSetStr;
}

pub fn setElemAlloc() !*c.nftnl_set_elem {
    return c.nftnl_set_elem_alloc() orelse error.OutOfMemory;
}

pub fn setElemFree(elem: *const c.nftnl_set_elem) void {
    c.nftnl_set_elem_free(elem);
}

pub fn setElemAdd(set: *c.nftnl_set, elem: *c.nftnl_set_elem) void {
    c.nftnl_set_elem_add(set, elem);
}

pub fn setElemSet(elem: *c.nftnl_set_elem, attr: u16, data: *const anyopaque, dataLen: u32) !void {
    // mostly malloc failure but also fails if dataLen > attrLen on nftnl side
    // could probably do generation here for every attr possible, would eliminate one error
    // (only OutOfMemory left), and would allow better auto-completion and no need for dataLen
    if (c.nftnl_set_elem_set(elem, attr, data, dataLen) == -1) return error.TODO_setElemSet;
}

pub fn batchBegin(buff: *u8, seq: u32) *c.nlmsghdr {
    return @ptrCast(c.nftnl_batch_begin(buff, seq));
}

pub fn batchEnd(buff: *u8, seq: u32) *c.nlmsghdr {
    return @ptrCast(c.nftnl_batch_end(buff, seq));
}

pub fn nlmsgBuildHdr(buff: *u8, attr: u16, family: u16, flags: u16, seq: u32) *c.nlmsghdr {
    return @ptrCast(c.nftnl_nlmsg_build_hdr(buff, attr, family, flags, seq));
}

pub fn setElemsNlmsgBuildPayload(nlh: *c.nlmsghdr, s: *c.nftnl_set) void {
    return c.nftnl_set_elems_nlmsg_build_payload(nlh, s);
}
