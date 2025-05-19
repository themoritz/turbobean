const std = @import("std");
const ParseFloatError = std.fmt.ParseFloatError;

const SCALE_FACTOR = 10000; // 4 decimal places (e.g., 1.2345 stored as 12345)

pub const Number = struct {
    value: i64,

    pub fn fromFloat(f: f64) Number {
        const scaled: i64 = @intFromFloat(f * SCALE_FACTOR);
        return Number{ .value = scaled };
    }

    pub fn fromInt(i: i64) Number {
        return Number{ .value = i * SCALE_FACTOR };
    }

    pub fn fromSlice(bytes: []const u8) ParseFloatError!Number {
        std.debug.assert(bytes.len <= 64);
        var buf: [64]u8 = undefined;
        var j: usize = 0;
        for (bytes) |b| {
            if (b != ',') {
                buf[j] = b;
                j += 1;
            }
        }
        const cleaned_bytes = buf[0..j];
        return fromFloat(try std.fmt.parseFloat(f64, cleaned_bytes));
    }

    pub fn toFloat(self: Number) f64 {
        const scaled: f64 = @floatFromInt(self.value);
        return scaled / SCALE_FACTOR;
    }

    pub fn add(self: Number, other: Number) Number {
        return Number{ .value = self.value + other.value };
    }

    pub fn sub(self: Number, other: Number) Number {
        return Number{ .value = self.value - other.value };
    }

    pub fn mul(self: Number, other: Number) Number {
        const result = @divFloor(self.value * other.value, SCALE_FACTOR);
        return Number{ .value = result };
    }

    pub fn negate(self: Number) Number {
        return Number{ .value = -self.value };
    }

    pub fn div(self: Number, other: Number) !Number {
        if (other.value == 0) return error.DivisionByZero;
        const result = @divFloor(self.value * SCALE_FACTOR, other.value);
        return Number{ .value = result };
    }

    pub fn toString(self: Number, allocator: std.mem.Allocator) ![]u8 {
        const float_val = self.toFloat();
        return std.fmt.allocPrint(allocator, "{d:.4}", .{float_val});
    }

    pub fn format(self: Number, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        _ = fmt;
        _ = options;
        try std.fmt.format(writer, "{d:.4}", .{self.toFloat()});
    }
};

test Number {
    try std.testing.expectEqual(Number.fromFloat(1.13), try Number.fromSlice("1.13"));

    const a = Number.fromFloat(1.2345);
    const b = Number.fromFloat(2.3456);

    try std.testing.expectEqual(Number.fromFloat(3.5801), a.add(b));
    try std.testing.expectEqual(Number.fromFloat(-1.1111), a.sub(b));

    try std.testing.expectEqual(Number.fromFloat(2.25), Number.fromFloat(1.5).mul(Number.fromFloat(1.5)));
    try std.testing.expectEqual(Number.fromFloat(0.1428), Number.fromInt(1).div(Number.fromInt(7)));

    try std.testing.expectEqual(Number.fromFloat(123456.4), try Number.fromSlice("123,456.4"));
}
