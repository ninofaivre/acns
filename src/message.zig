const std = @import("std");
const io = std.io;
const c = @cImport({
    @cInclude("linux/netlink.h");
    @cInclude("linux/netfilter/nf_tables.h");
});

pub const Message = struct {
    pub const IP = union(enum) {
        pub const IPv4 = struct {
            pub const Value = u32;
            value: Value,
            pub fn format(self: IPv4, writer: anytype) !void {

                try writer.print("{d}.{d}.{d}.{d}", .{
                    @as(u8, @truncate(self.value)),
                    @as(u8, @truncate(self.value >> 8)),
                    @as(u8, @truncate(self.value >> 16)),
                    @as(u8, @truncate(self.value >> 24)),
                });
            }
        };

        pub const IPv6 = struct {
            pub const Value = u128;
            value: Value,
            pub fn format(self: IPv6, writer: anytype) !void {
                var buffer: [8-1+4*8]u8 = undefined;
                writer.buffer = &buffer;

                var nProcessedBits: u8 = 0;
                var doubleColonUsed = false;
                var doubleColonInUse = false;
                while (nProcessedBits < 128) : (nProcessedBits += 16) {
                    const hexNumber: u16 = std.mem.nativeToBig(u16, @truncate(self.value >> @intCast(nProcessedBits)));

                    if (hexNumber == 0) {
                        if (doubleColonUsed == false) {
                            doubleColonUsed = true;
                            doubleColonInUse = true;
                            try writer.print("::", .{});
                        }
                        if (doubleColonInUse) continue;
                    }
                    try writer.print("{s}{x}", .{
                        if (nProcessedBits == 0 or doubleColonInUse)
                            ""
                        else
                            ":",
                        hexNumber,
                    });
                    doubleColonInUse = false;
                }
                try writer.flush();
            }
        };
        v4: IPv4,
        v6: IPv6,

        pub fn format(self: *const IP, writer: anytype) !void {
            switch (self.*) {
                .v4 => try writer.print("v4[{f}]", .{self.v4}),
                .v6 => try writer.print("v6[{f}]", .{self.v6}),
            }
        }

        pub fn getDataPtr(self: *const IP) *const anyopaque {
            return switch (self.*) {
                .v4 => &self.v4.value,
                .v6 => &self.v6.value,
            };
        }

        pub fn getDataLen(self: *const IP) u32 {
            return switch (self.*) {
                .v4 => @sizeOf(IPv4.Value),
                .v6 => @sizeOf(IPv6.Value),
            };
        }
    };

    pub const TTL = u32;
    pub const FamilyType = u16;

    familyType: FamilyType,
    tableName: [*c]const u8,
    setName: [*c]const u8,
    ip: IP, 
    ttl: ?TTL = null,

    pub fn format(self: Message, writer: anytype) !void {
        var buff: [16]u8 = undefined;
        var formattedTTL: []const u8 = buff[0..0];
        if (self.ttl) |ttl| {
            formattedTTL = std.fmt.bufPrint(&buff,
                "wTTL[{d}]", .{ttl}) catch buff[0..0];
        }
        try writer.print(
            "ip{f}{s} in family[{d}] -> tableName[{s}] -> setName[{s}]", 
            .{
                self.ip,
                formattedTTL,
                self.familyType,
                self.tableName,
                self.setName
            });
    }
};

const parseErrors = error{
    FamilyTypeNotFound, FamilyTypeTooShort,
    TableNameNotFound, TableNameTooShort, TableNameTooLong,
    SetNameNotFound, SetNameTooShort, SetNameTooLong,
    IpNotFound, IpTooShort, TTLTooShort, TTLTooLong
};

pub fn parse(message: []const u8) parseErrors!Message {
    var tail = message;

    if (tail.len == 0) return error.FamilyTypeNotFound;
    if (tail.len < @sizeOf(Message.FamilyType))
        return error.FamilyTypeTooShort;
    const familyType = std.mem.readInt(Message.FamilyType, tail[0..@sizeOf(Message.FamilyType)], std.builtin.Endian.little);
    tail = tail[@sizeOf(Message.FamilyType)..];

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

    var ip: Message.IP = undefined;
    const IPv4Size = @sizeOf(Message.IP.IPv4.Value);
    const IPv6Size = @sizeOf(Message.IP.IPv6.Value);
    const TTLSize = @sizeOf(Message.TTL);

    switch (tail.len) {
        0 => return error.IpNotFound,
        IPv4Size, IPv4Size + 1,
        IPv4Size + TTLSize, IPv4Size + TTLSize + 1 => {
            ip = .{
                .v4 = .{
                    .value = std.mem.readInt(u32, tail[0..@sizeOf(u32)],
                        std.builtin.Endian.little),
                }
            };
            tail = tail[@sizeOf(u32)..];
        },
        IPv6Size, IPv6Size + 1,
        IPv6Size + TTLSize, IPv6Size + TTLSize + 1 => {
            ip = .{
                .v6 = .{
                    .value = std.mem.readInt(u128, tail[0..@sizeOf(u128)],
                        std.builtin.Endian.little),
                }
            };
            tail = tail[@sizeOf(u128)..];
        },
        else => |len| {
            if (len < IPv4Size) { return error.IpTooShort; }
            else if (len < IPv6Size + TTLSize) { return error.TTLTooShort; }
            else { return error.TTLTooLong; }
        }
    }

    return .{
        .familyType = familyType,
        .tableName = @ptrCast(tableName),
        .setName = @ptrCast(setName),
        .ip = ip,
        .ttl = if (tail.len <= 1) null
            else std.mem.readInt(u32, tail[0..4], std.builtin.Endian.little),
    };
}
