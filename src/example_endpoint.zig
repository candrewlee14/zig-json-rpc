const std = @import("std");
pub const MethodMapping = enum {
    const Self = @This();

    subtract,
    add,
    ping,

    pub fn Params(comptime self: Self) type {
        return switch (self) {
            .subtract => []const i32,
            .add => []const i32,
            .ping => void,
        };
    }
    pub fn Result(comptime self: Self) type {
        return switch (self) {
            .subtract => i32,
            .add => i32,
            .ping => []const u8,
        };
    }
    pub fn route(comptime method: Self, params: method.Params()) !method.Result() {
        return switch (method) {
            .subtract => subtract(params),
            .add => add(params),
            .ping => "pong",
        };
    }
    pub fn fromString(str: []const u8) ?Self {
        inline for (@typeInfo(Self).Enum.fields) |field| {
            if (std.mem.eql(u8, field.name, str)) return @field(Self, field.name);
        }
        return null;
    }

    pub fn toString(self: Self) []const u8 {
        inline for (@typeInfo(Self).Enum.fields) |field| {
            if (field.value == @intFromEnum(self)) return field.name;
        }
        unreachable;
    }
};

fn subtract(params: []const i32) i32 {
    return params[0] - params[1];
}

fn add(params: []const i32) i32 {
    return params[0] + params[1];
}

test MethodMapping {
    const params: []const i32 = &.{ 15, 7 };
    const res: i32 = try MethodMapping.route(.subtract, params);
    const res2: i32 = try MethodMapping.route(.add, params);
    try std.testing.expectEqual(@as(i32, 8), res);
    try std.testing.expectEqual(@as(i32, 22), res2);
}
