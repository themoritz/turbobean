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
        self.inner.mutex.lock();
        defer self.inner.mutex.unlock();

        while (self.inner.gen <= self.last_gen) {
            self.inner.cond.wait(&self.inner.mutex);
        }
        self.last_gen = self.inner.gen;
    }
};
