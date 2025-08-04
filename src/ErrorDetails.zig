const std = @import("std");
const Allocator = std.mem.Allocator;
const Lexer = @import("lexer.zig").Lexer;
const Uri = @import("Uri.zig");
const Self = @This();

tag: Tag,
severity: Severity = .err,
token: Lexer.Token,
uri: Uri,
source: [:0]const u8,
expected: ?Lexer.Token.Tag,

pub const Severity = enum {
    err,
    warn,
};

pub const Tag = enum {
    expected_declaration,
    invalid_number,
    invalid_date,
    invalid_booking_method,
    expected_token,
    expected_entry,
    expected_key_value,
    expected_value,
    expected_amount,
    duplicate_lot_spec,
    tag_already_pushed,
    meta_already_pushed,
    tag_not_pushed,
    meta_not_pushed,

    tx_does_not_balance,
    tx_no_solution,
    tx_too_many_variables,
    tx_division_by_zero,
    tx_multiple_solutions,

    account_not_open,
    multiple_pads,
    balance_assertion_failed,

    account_does_not_hold_currency,
    account_is_booked,
    account_is_not_booked,
    cost_currency_does_not_match,

    lot_spec_ambiguous_match,
    lot_spec_match_too_small,
    lot_spec_no_match,
    ambiguous_strict_booking,

    flagged,

    pub fn message(self: Tag) []const u8 {
        return switch (self) {
            .expected_declaration => "Expected declaration",
            .invalid_number => "Invalid number",
            .invalid_date => "Invalid date",
            .invalid_booking_method => "Invalid booking method. Choose from FIFO, LIFO, STRICT",
            .expected_token => unreachable,
            .expected_entry => "Expected entry",
            .expected_key_value => "Expected key: value",
            .expected_value => "Expected value",
            .expected_amount => "Expected amount",
            .duplicate_lot_spec => "Duplicate lot spec",
            .tag_already_pushed => "Tag already pushed",
            .meta_already_pushed => "Key already pushed",
            .tag_not_pushed => "Tag has not been pushed before",
            .meta_not_pushed => "Key has not been pushed before",
            .tx_does_not_balance => "Transaction does not balance",
            .tx_no_solution => "Transaction can't be balanced",
            .tx_too_many_variables => "Transaction can't be balanced unambiguously",
            .tx_division_by_zero => "Division by zero while balancing transaction",
            .tx_multiple_solutions => "Transaction can't be balanced unambiguously",
            .account_not_open => "Account is not open or has been closed. Open it with an open entry",
            .multiple_pads => "Multiple pads of the same account. You need to have a balance assertion between pads",
            .balance_assertion_failed => "Balance assertion failed",
            .account_does_not_hold_currency => "Cannot post this currency to this account. Check open declaration.",
            .account_is_booked => "Booked account. Can only buy or sell.",
            .account_is_not_booked => "Unbooked account. Can't buy or sell",
            .cost_currency_does_not_match => "Cost currency does not match.",
            .lot_spec_ambiguous_match => "Ambiguous match. Lot spec needs to match exactly one lot.",
            .lot_spec_match_too_small => "Matched lot too small. You can cancel at most one lot.",
            .lot_spec_no_match => "No matching lot found for lot spec.",
            .ambiguous_strict_booking => "Strict booking requires explicit lot selection, or new lot needs to cancel all existing lots exactly.",
            .flagged => "Flagged",
        };
    }
};

pub fn message(e: Self, alloc: Allocator) ![]const u8 {
    var buffer = std.ArrayList(u8).init(alloc);
    switch (e.tag) {
        .expected_token => {
            try std.fmt.format(
                buffer.writer(),
                "Expected {s}, found {s}\n",
                .{ @tagName(e.expected.?), @tagName(e.token.tag) },
            );
        },
        else => {
            try std.fmt.format(buffer.writer(), "{s}\n", .{e.tag.message()});
        },
    }
    return buffer.toOwnedSlice();
}

pub fn print(e: Self, alloc: Allocator, colors: bool) !void {
    const rendered = try dump(e, alloc, colors);
    defer alloc.free(rendered);
    std.debug.print("{s}\n", .{rendered});
}

pub fn dump(e: Self, alloc: Allocator, colors: bool) ![]const u8 {
    const color_on = if (colors) switch (e.severity) {
        .err => "\x1b[31m",
        .warn => "\x1b[33m",
    } else "";
    const color_off = if (colors) "\x1b[0m" else "";

    var buffer = std.ArrayList(u8).init(alloc);
    defer buffer.deinit();

    // Calculate line and col from token.loc
    const loc = e.token.slice;
    var line_start: u32 = 0;
    var col_start: u32 = 0;
    const start = @intFromPtr(loc.ptr) - @intFromPtr(e.source.ptr);
    const end = start + loc.len;
    var line_pos: usize = 0;
    for (0..start) |i| {
        if (e.source[i] == '\n') {
            line_start += 1;
            col_start = 0;
            line_pos = i + 1;
        } else {
            col_start += 1;
        }
    }
    var line_end = line_start;
    var col_end = col_start;
    for (start..end) |i| {
        if (e.source[i] == '\n') {
            line_end += 1;
            col_end = 0;
        } else {
            col_end += 1;
        }
    }

    std.debug.assert(line_start == line_end);
    std.debug.assert(col_start < col_end);

    var line_pos_end = e.source.len;
    for (end..e.source.len) |i| {
        if (e.source[i] == '\n') {
            line_pos_end = i;
            break;
        }
    }

    const msg = try e.message(alloc);
    defer alloc.free(msg);

    const severity = switch (e.severity) {
        .err => "Error",
        .warn => "Warning",
    };

    const relative = try e.uri.relative(alloc);
    defer alloc.free(relative);

    try std.fmt.format(
        buffer.writer(),
        "{s}: [{s}{s}{s}] {s}\n",
        .{ relative, color_on, severity, color_off, msg },
    );

    try std.fmt.format(
        buffer.writer(),
        "{d:>5} | {s}\n",
        .{ line_start + 1, e.source[line_pos..line_pos_end] },
    );
    for (0..col_start + 8) |_| try buffer.append(' ');
    try buffer.appendSlice(color_on);
    try buffer.appendNTimes('^', col_end - col_start);
    try buffer.appendSlice(color_off);

    try buffer.append('\n');

    return buffer.toOwnedSlice();
}

test "render" {
    try testLoc(0, 1,
        \\Hello Foo
    ,
        \\dummy.bean: [Error] Expected string, found number
        \\
        \\    1 | Hello Foo
        \\        ^
        \\
    );

    try testLoc(6, 3,
        \\Hello Foo
    ,
        \\dummy.bean: [Error] Expected string, found number
        \\
        \\    1 | Hello Foo
        \\              ^^^
        \\
    );
}

fn testLoc(start: u32, len: u32, source: [:0]const u8, expected: []const u8) !void {
    const alloc = std.testing.allocator;
    var uri = try Uri.from_relative_to_cwd(alloc, "dummy.bean");
    defer uri.deinit(alloc);
    const e = Self{
        .tag = .expected_token,
        .token = Lexer.Token{
            .tag = .number,
            .slice = source[start .. start + len],
            .line = 0,
            .start_col = @intCast(start),
            .end_col = @intCast(start + len),
        },
        .uri = uri,
        .source = source,
        .expected = .string,
    };
    const rendered = try e.dump(alloc, false);
    defer alloc.free(rendered);

    try std.testing.expectEqualSlices(u8, expected, rendered);
}
