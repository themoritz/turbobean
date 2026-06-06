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
};
