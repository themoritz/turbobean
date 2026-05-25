const std = @import("std");
const Io = std.Io;
const Self = @This();

mutex: Io.Mutex = .init,
cond: Io.Condition = .init,
gen: u64 = 0,
stopped: bool = false,

pub fn publishVersion(self: *Self, io: Io) void {
    {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.gen += 1;
    }
    self.cond.broadcast(io);
}

pub fn stop(self: *Self, io: Io) void {
    {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.stopped = true;
    }
    self.cond.broadcast(io);
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
    pub fn waitForNewVersion(self: *Listener, io: Io) bool {
        self.inner.mutex.lockUncancelable(io);
        defer self.inner.mutex.unlock(io);

        while (true) {
            if (self.inner.stopped) {
                return false;
            }
            if (self.inner.gen > self.last_gen) {
                self.last_gen = self.inner.gen;
                return true;
            }
            self.inner.cond.waitUncancelable(io, &self.inner.mutex);
        }
    }
};
