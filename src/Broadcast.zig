const std = @import("std");
const Self = @This();

mutex: std.Thread.Mutex = .{},
cond: std.Thread.Condition = .{},
gen: u64 = 0,

pub fn publishVersion(self: *Self) void {
    {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.gen += 1;
    }
    self.cond.broadcast();
}

pub fn newListener(self: *Self) Listener {
    return .{
        .inner = self,
        .last_gen = self.gen,
    };
}

pub const Listener = struct {
    inner: *Self,
    last_gen: u64,

    pub fn waitForNewVersion(self: *Listener) void {
        self.shared.mutex.lock();
        defer self.shared.mutex.unlock();

        while (self.shared.gen <= self.last_gen) {
            self.shared.cond.wait(&self.shared.mutex);
        }
        self.last_gen = self.shared.gen;
    }
};
