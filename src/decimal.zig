const std = @import("std");

const SCALE_FACTOR = 10000; // 4 decimal places (e.g., 1.2345 stored as 12345)
const MAX_DIGITS = 18; // Maximum digits before decimal point to prevent overflow

// Decimal struct to hold the value
const Decimal = struct {
    value: i64,

    pub fn fromFloat(f: f64) Decimal {
        const scaled: i64 = @intFromFloat(f * SCALE_FACTOR);
        return Decimal{ .value = scaled };
    }

    pub fn fromInt(i: i64) Decimal {
        return Decimal{ .value = i * SCALE_FACTOR };
    }

    pub fn toFloat(self: Decimal) f64 {
        const scaled: f64 = @floatFromInt(self.value);
        return scaled / SCALE_FACTOR;
    }

    pub fn add(self: Decimal, other: Decimal) Decimal {
        return Decimal{ .value = self.value + other.value };
    }

    pub fn sub(self: Decimal, other: Decimal) Decimal {
        return Decimal{ .value = self.value - other.value };
    }

    pub fn mul(self: Decimal, other: Decimal) Decimal {
        const result = @divFloor(self.value * other.value, SCALE_FACTOR);
        return Decimal{ .value = result };
    }

    pub fn div(self: Decimal, other: Decimal) !Decimal {
        if (other.value == 0) return error.DivisionByZero;
        const result = @divFloor(self.value * SCALE_FACTOR, other.value);
        return Decimal{ .value = result };
    }

    pub fn toString(self: Decimal, allocator: std.mem.Allocator) ![]u8 {
        const float_val = self.toFloat();
        return std.fmt.allocPrint(allocator, "{d:.4}", .{float_val});
    }
};

test Decimal {
    const a = Decimal.fromFloat(1.2345);
    const b = Decimal.fromFloat(2.3456);

    try std.testing.expectEqual(Decimal.fromFloat(3.5801), a.add(b));
    try std.testing.expectEqual(Decimal.fromFloat(-1.1111), a.sub(b));

    try std.testing.expectEqual(Decimal.fromFloat(2.25), Decimal.fromFloat(1.5).mul(Decimal.fromFloat(1.5)));
    try std.testing.expectEqual(Decimal.fromFloat(0.1428), Decimal.fromInt(1).div(Decimal.fromInt(7)));
}
