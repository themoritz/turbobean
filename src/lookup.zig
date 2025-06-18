const std = @import("std");
const Lexer = @import("lexer.zig").Lexer;

const AccountSpan = struct {
    name: []const u8,
    start: u16,
    end: u16,
};

pub const AccountsByLine = struct {
    map: std.AutoHashMap(FileLine, std.ArrayList(AccountSpan)),

    pub fn init(alloc: std.mem.Allocator) AccountsByLine {
        return .{
            .map = std.AutoHashMap(FileLine, std.ArrayList(AccountSpan)).init(alloc),
        };
    }

    pub fn deinit(self: *AccountsByLine) void {
        var iter = self.map.valueIterator();
        while (iter.next()) |v| v.deinit();
        self.map.deinit();
        std.debug.print("AccountsByLine deinit\n", .{});
    }

    pub fn clear(self: *AccountsByLine) void {
        var iter = self.map.valueIterator();
        while (iter.next()) |v| v.deinit();
        self.map.clearRetainingCapacity();
    }

    pub fn put(self: *AccountsByLine, file: u32, token: Lexer.Token) !void {
        const file_line = FileLine{
            .file = file,
            .line = token.line,
        };
        const entry = try self.map.getOrPut(file_line);
        if (!entry.found_existing) {
            entry.value_ptr.* = std.ArrayList(AccountSpan).init(self.map.allocator);
        }
        try entry.value_ptr.append(AccountSpan{
            .name = token.slice,
            .start = token.start_col,
            .end = token.end_col,
        });
    }

    pub fn get_account_by_pos(self: *AccountsByLine, file: u32, line: u32, col: u16) ?[]const u8 {
        const file_line = FileLine{
            .file = file,
            .line = line,
        };
        const entry = self.map.get(file_line) orelse return null;
        for (entry.items) |span| {
            if (span.start <= col and col <= span.end) {
                return span.name;
            }
        }
        return null;
    }
};

pub const FileLine = struct {
    file: u32,
    line: u32,
};
