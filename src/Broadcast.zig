const std = @import("std");
const Self = @This();

mutex: std.Thread.Mutex = .{},
cond: std.Thread.Condition = .{},
gen: u64 = 0,
stopped: bool = false,

pub fn publishVersion(self: *Self) void {
    {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.gen += 1;
    }
    self.cond.broadcast();
}

pub fn stop(self: *Self) void {
    {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.stopped = true;
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

    /// Blocks until a new version is available or the program
    /// has been stopped. Returns true if the program can continue.
    pub fn waitForNewVersion(self: *Listener) bool {
        self.inner.mutex.lock();
        defer self.inner.mutex.unlock();

        while (true) {
            if (self.inner.stopped) {
                return false;
            }
            if (self.inner.gen > self.last_gen) {
                self.last_gen = self.inner.gen;
                return true;
            }
            self.inner.cond.wait(&self.inner.mutex);
        }
    }
};
