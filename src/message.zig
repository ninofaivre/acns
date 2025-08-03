const std = @import("std");
const io = std.io;
const c = @cImport({
    @cInclude("linux/netlink.h");
    @cInclude("linux/netfilter/nf_tables.h");
});

pub const Message = struct {
    pub const IP = union(enum) {
        pub fn format(self: IP, writer: anytype) !void {
            switch (self) {
                .v4 => try writer.print("v4[{f}]", .{self.v4}),
                .v6 => try writer.print("v6[{f}]", .{self.v6}),
            }
        }
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
    };
    tableName: [*c]const u8,
    setName: [*c]const u8,
    ip: IP, 
    familyType: u16,

    pub fn format(self: Message, writer: anytype) !void {
        try writer.print("ip{f} in family[{d}] -> tableName[{s}] -> setName[{s}]", .{ self.ip, self.familyType, self.tableName, self.setName });
    }
};

const parseErrors = error{
    FamilyTypeNotFound, FamilyTypeTooShort,
    TableNameNotFound, TableNameTooShort, TableNameTooLong,
    SetNameNotFound, SetNameTooShort, SetNameTooLong,
    IpNotFound, WrongIpSize
};

pub fn parse(message: []const u8) parseErrors!Message {
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
    if ((tail.len == 5 or tail.len == 17) and tail[tail.len - 1] == '\x00')
        tail = tail[0 .. tail.len - 1]; // remove optionnal trailing \0
    if (tail.len != 4 and tail.len != 16) return error.WrongIpSize;
    var ip: Message.IP = undefined;
    if (tail.len == 4) {
        ip = .{
            .v4 = .{
                .value = std.mem.readInt(u32, tail[0..(32/8)], std.builtin.Endian.little),
            }
        };
    } else {
        ip = .{
            .v6 = .{
                .value = std.mem.readInt(u128, tail[0..(128/8)], std.builtin.Endian.little),
            }
        };
    }

    return .{ .familyType = familyType, .tableName = @ptrCast(tableName), .setName = @ptrCast(setName), .ip = ip };
}
