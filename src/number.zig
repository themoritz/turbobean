const std = @import("std");

const MAX_PRECISION = 9;

pub const Number = struct {
    value: i64,
    /// Number of decimal places
    precision: u32,

    pub fn fromFloat(f: f64) Number {
        if (f == 0.0) {
            return Number{ .value = 0, .precision = 0 };
        }
        var precision: u32 = 0;
        var scaled = f;
        var rounded = std.math.round(scaled);
        while (precision < MAX_PRECISION) {
            if (std.math.approxEqAbs(f64, scaled, rounded, 1e-9)) break;
            scaled *= 10;
            precision += 1;
            rounded = std.math.round(scaled);
        }
        return Number{
            .value = @intFromFloat(rounded),
            .precision = precision,
        };
    }

    pub fn fromInt(i: i64) Number {
        return Number{ .value = i, .precision = 0 };
    }

    pub fn fromSlice(bytes: []const u8) std.fmt.ParseIntError!Number {
        std.debug.assert(bytes.len <= 64);
        var buf: [64]u8 = undefined;
        var j: usize = 0;
        var precision: u32 = 0;
        var seen_dot = false;
        for (bytes) |b| {
            switch (b) {
                ',' => {},
                '.' => seen_dot = true,
                else => {
                    buf[j] = b;
                    j += 1;
                    if (seen_dot) precision += 1;
                    if (precision == MAX_PRECISION) break;
                },
            }
        }
        const cleaned_bytes = buf[0..j];
        return Number{
            .value = try std.fmt.parseInt(i64, cleaned_bytes, 10),
            .precision = precision,
        };
    }

    pub fn toFloat(self: Number) f64 {
        const scaled: f64 = @floatFromInt(self.value);
        const divisor: f64 = @floatFromInt(pow10(self.precision));
        return scaled / divisor;
    }

    pub fn add(self: Number, other: Number) Number {
        const p = @max(self.precision, other.precision);
        const self_factor = if (self.precision < p) pow10(p - self.precision) else 1;
        const other_factor = if (other.precision < p) pow10(p - other.precision) else 1;
        const self_scaled = self.value * self_factor;
        const other_scaled = other.value * other_factor;
        return Number{
            .value = self_scaled + other_scaled,
            .precision = p,
        };
    }

    pub fn sub(self: Number, other: Number) Number {
        const p = @max(self.precision, other.precision);
        const self_factor = if (self.precision < p) pow10(p - self.precision) else 1;
        const other_factor = if (other.precision < p) pow10(p - other.precision) else 1;
        const self_scaled = self.value * self_factor;
        const other_scaled = other.value * other_factor;
        return Number{
            .value = self_scaled - other_scaled,
            .precision = p,
        };
    }

    pub fn mul(self: Number, other: Number) Number {
        // Use float in case of too high precision to avoid overflows
        if (self.precision + other.precision > MAX_PRECISION) {
            return Number.fromFloat(self.toFloat() * other.toFloat());
        } else {
            return Number{
                .value = self.value * other.value,
                .precision = self.precision + other.precision,
            };
        }
    }

    pub fn negate(self: Number) Number {
        return Number{ .value = -self.value, .precision = self.precision };
    }

    pub fn div(self: Number, other: Number) !Number {
        if (other.value == 0) return error.DivisionByZero;
        const self_float = self.toFloat();
        const other_float = other.toFloat();
        return Number.fromFloat(self_float / other_float);
    }

    pub fn toString(self: Number, allocator: std.mem.Allocator) ![]const u8 {
        const float_val = self.toFloat();

        var buf: [64]u8 = undefined;

        const used = try std.fmt.float.render(&buf, float_val, .{
            .mode = .decimal,
            .precision = self.precision,
        });
        return try allocator.dupe(u8, used);
    }

    pub const WithPrecision = struct {
        inner: Number,
        precision: u32,

        pub fn format(self: WithPrecision, writer: *std.Io.Writer) !void {
            try self.inner.formatWithPrecision(writer, self.precision);
        }
    };

    pub fn withPrecision(self: Number, precision: u32) WithPrecision {
        return .{
            .inner = self,
            .precision = precision,
        };
    }

    pub fn format(self: Number, writer: *std.Io.Writer) !void {
        try self.formatWithPrecision(writer, self.precision);
    }

    pub fn formatWithPrecision(self: Number, writer: *std.Io.Writer, precision: u32) !void {
        const rounded = self.roundTo(@intCast(precision));

        const abs_value: i64 = @intCast(@abs(rounded.value));
        const negative = rounded.value < 0;

        // Calculate integer and decimal parts
        const divisor = pow10(rounded.precision);
        const integer_part = @divFloor(abs_value, divisor);
        const decimal_part = @rem(abs_value, divisor);

        if (negative) try writer.writeByte('-');

        if (integer_part == 0) {
            try writer.writeByte('0');
        } else {
            var digits: [64]u8 = undefined;
            var temp_int = integer_part;
            var i: usize = 0;

            while (temp_int > 0) {
                digits[i] = @intCast(@rem(temp_int, 10) + '0');
                temp_int = @divFloor(temp_int, 10);
                i += 1;
            }

            var digit_count: usize = 0;
            while (i > 0) {
                if (digit_count > 0 and i % 3 == 0) {
                    try writer.writeByte(',');
                }
                i -= 1;
                try writer.writeByte(digits[i]);
                digit_count += 1;
            }
        }

        if (precision > 0) {
            try writer.writeByte('.');

            // Scale decimal_part to match the requested precision
            const scaled_decimal_part = decimal_part * pow10(@intCast(precision - rounded.precision));

            // Write decimal digits from most to least significant
            for (0..precision) |digit_pos| {
                const place_value = pow10(@intCast(precision - 1 - digit_pos));
                const digit = @rem(@divFloor(scaled_decimal_part, place_value), 10);
                try writer.writeByte(@intCast(digit + '0'));
            }
        }
    }

    pub fn zero() Number {
        return Number{
            .value = 0,
            .precision = 0,
        };
    }

    pub fn is_zero(self: Number) bool {
        return self.value == 0;
    }

    pub fn is_positive(self: Number) bool {
        return self.value > 0;
    }

    pub fn is_negative(self: Number) bool {
        return self.value < 0;
    }

    /// For precision of self is 2, checks whether |self - other| <= 0.01
    pub fn is_within_tolerance(self: Number, other: Number) bool {
        const diff = self.sub(other).abs();
        const tolerance = Number{
            .value = 1,
            .precision = self.precision,
        };

        // Compare diff <= tolerance by scaling both to same precision
        const p = @max(diff.precision, tolerance.precision);
        const diff_factor = pow10(p - diff.precision);
        const tolerance_factor = pow10(p - tolerance.precision);
        const diff_scaled = diff.value * diff_factor;
        const tolerance_scaled = tolerance.value * tolerance_factor;

        return diff_scaled <= tolerance_scaled;
    }

    pub fn min(self: Number, other: Number) Number {
        const p = @max(self.precision, other.precision);
        const self_factor = pow10(p - self.precision);
        const other_factor = pow10(p - other.precision);
        const self_scaled = self.value * self_factor;
        const other_scaled = other.value * other_factor;

        if (self_scaled <= other_scaled) {
            return self;
        } else {
            return other;
        }
    }

    pub fn abs(self: Number) Number {
        return Number{
            .value = @intCast(@abs(self.value)),
            .precision = self.precision,
        };
    }

    pub fn roundTo(self: Number, target_precision: u32) Number {
        if (target_precision >= self.precision) {
            return self;
        }

        const factor = pow10(self.precision - target_precision);
        const half = @divTrunc(factor, 2);

        const rounded_value = if (self.value >= 0)
            @divTrunc(self.value + half, factor)
        else
            @divTrunc(self.value - half, factor);

        const result = Number{
            .value = rounded_value,
            .precision = target_precision,
        };
        return result.normalize();
    }

    pub fn normalize(self: Number) Number {
        if (self.precision == 0 or self.value == 0) {
            return self;
        }

        var value = self.value;
        var precision = self.precision;

        while (precision > 0 and @rem(value, 10) == 0) {
            value = @divTrunc(value, 10);
            precision -= 1;
        }

        return Number{
            .value = value,
            .precision = precision,
        };
    }
};

fn pow10(n: u32) i64 {
    var result: i64 = 1;
    for (0..n) |_| {
        result *= 10;
    }
    return result;
}

test Number {
    const alloc = std.testing.allocator;

    try std.testing.expectEqual(Number.fromFloat(1.13), try Number.fromSlice("1.13"));

    const a = Number.fromFloat(1.2345);
    const b = Number.fromFloat(2);

    const a_str = try a.toString(alloc);
    const b_str = try b.toString(alloc);
    defer alloc.free(a_str);
    defer alloc.free(b_str);

    try std.testing.expectEqualStrings("1.2345", a_str);
    try std.testing.expectEqualStrings("2", b_str);

    try std.testing.expectEqual(Number.fromFloat(3.2345), a.add(b));
    try std.testing.expectEqual(Number.fromFloat(-0.7655), a.sub(b));

    try std.testing.expectEqual(Number.fromFloat(2.25), Number.fromFloat(1.5).mul(Number.fromFloat(1.5)));
    try std.testing.expectEqual(Number.fromFloat(0.142857143), Number.fromInt(1).div(Number.fromInt(7)));

    try std.testing.expectEqual(Number.fromFloat(123456.4), try Number.fromSlice("123,456.4"));

    try std.testing.expectEqual(Number.fromFloat(1.1111).min(Number.fromFloat(2.222)), Number.fromFloat(1.1111));

    try std.testing.expectEqual(Number.fromInt(2).abs(), Number.fromInt(2));
    try std.testing.expectEqual(Number.fromInt(-4).abs(), Number.fromInt(4));

    try std.testing.expect(Number.fromFloat(1.15).is_within_tolerance(Number.fromFloat(1.16)));
    try std.testing.expect(Number.fromFloat(1.15).is_within_tolerance(Number.fromFloat(1.145)));
    try std.testing.expect(!Number.fromFloat(1.15).is_within_tolerance(Number.fromFloat(1.135)));
}

test "rounding" {
    try std.testing.expectEqual(Number.fromFloat(1.123).roundTo(2), Number.fromFloat(1.12));
    try std.testing.expectEqual(Number.fromFloat(1.99).roundTo(1), Number.fromFloat(2.0));
}

test "format" {
    try testFormat(Number.fromFloat(1234567.89), "1,234,567.89");
    try testFormat(Number.fromFloat(42.5), "42.50");
    try testFormat(Number.fromInt(1000), "1,000.00");
    try testFormat(Number.fromInt(0), "0.00");
    try testFormat(Number.fromInt(-10), "-10.00");
    try testFormat(Number.fromFloat(3.199), "3.20");
    try testFormat(Number.fromFloat(-4.999), "-5.00");
    try testFormat(Number.fromFloat(1.01), "1.01");
    try testFormat(Number.fromFloat(0.01), "0.01");
}

fn testFormat(num: Number, expected: []const u8) !void {
    const formatted = try std.fmt.allocPrint(std.testing.allocator, "{f}", .{num.withPrecision(2)});
    defer std.testing.allocator.free(formatted);
    try std.testing.expectEqualStrings(expected, formatted);
}
