const std = @import("std");

pub const Point = struct {
    x: f32,
    y: f32,
};

pub const Rect = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,

    pub fn contains(self: Rect, p: Point) bool {
        const x_contained = self.x <= p.x and p.x <= self.x + self.w;
        const y_contained = self.y <= p.y and p.y <= self.y + self.h;
        return x_contained and y_contained;
    }

    pub fn intersect(self: Rect, other: Rect) Rect {
        const x0 = @max(self.x, other.x);
        const y0 = @max(self.y, other.y);
        const x1 = @min(self.x + self.w, other.x + other.w);
        const y1 = @min(self.y + self.h, other.y + other.h);
        return .{
            .x = x0,
            .y = y0,
            .w = x1 - x0,
            .h = y1 - y0,
        };
    }

    pub fn isEmpty(self: Rect) bool {
        return self.w <= 0 or self.h <= 0;
    }

    /// Result is pixel aligned (floored)
    pub fn asArray(self: Rect) [4]f32 {
        return .{
            @floor(self.x),
            @floor(self.y),
            @floor(self.w),
            @floor(self.h),
        };
    }
};

pub fn clamp(comptime T: type, a: T, x: T, b: T) T {
    if (x < a) return a;
    if (x > b) return b;
    return x;
}

test clamp {
    const x: f32 = 0.3;
    try std.testing.expectEqual(x, clamp(f32, 0, x, 1));
    try std.testing.expectEqual(0, clamp(f32, 0, -1, 1));
    try std.testing.expectEqual(1, clamp(f32, 0, 2, 1));
}
