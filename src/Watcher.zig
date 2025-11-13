const builtin = @import("builtin");

pub const Platform = switch (builtin.target.os.tag) {
    .macos => @import("watcher/MacOS.zig"),
    else => @import("watcher/Unsupported.zig"),
};
