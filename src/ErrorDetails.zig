const std = @import("std");
const Allocator = std.mem.Allocator;
const Lexer = @import("lexer.zig").Lexer;
const Uri = @import("Uri.zig");
const Self = @This();
const Number = @import("number.zig").Number;
const Solver = @import("solver.zig").Solver;

tag: Tag,
severity: Severity = .err,
token: Lexer.Token,
uri: Uri,
source: [:0]const u8,

pub const Severity = enum {
    err,
    warn,
};

pub const Tag = union(enum) {
    expected_declaration,
    invalid_number,
    invalid_date,
    invalid_booking_method,
    expected_token: Lexer.Token.Tag,
    expected_entry,
    expected_key_value,
    expected_value,
    expected_amount,
    duplicate_lot_spec,
    tag_already_pushed,
    meta_already_pushed,
    tag_not_pushed,
    meta_not_pushed,

    tx_balance_no_currency,
    tx_does_not_balance: Solver.CurrencyImbalance,
    tx_no_solution,
    tx_too_many_variables,
    tx_division_by_zero,
    tx_multiple_solutions,
    cannot_infer_amount_currency_when_price_set,

    account_not_open,
    account_already_open,
    multiple_pads,
    balance_assertion_failed: struct {
        expected: Number,
        accumulated: Number,
    },

    account_does_not_hold_currency,
    account_is_booked,
    account_does_not_support_lot_spec,

    lot_spec_ambiguous_match,
    lot_spec_match_too_small,
    lot_spec_no_match,
    ambiguous_strict_booking,

    flagged,
    inferred_price,
};

pub fn print(e: Self, alloc: Allocator) !void {
    const rendered = try dump(e, alloc, true);
    defer alloc.free(rendered);
    std.debug.print("{s}\n", .{rendered});
}

pub fn dump(e: Self, alloc: Allocator, color: bool) ![]const u8 {
    var allocating = std.Io.Writer.Allocating.init(alloc);
    defer allocating.deinit();
    const writer = &allocating.writer;

    try e.format(writer, alloc, color);
    return allocating.toOwnedSlice();
}

pub fn message(e: Self, alloc: Allocator) ![]const u8 {
    var allocating = std.Io.Writer.Allocating.init(alloc);
    defer allocating.deinit();
    const writer = &allocating.writer;

    try e.formatMessage(writer);
    try writer.writeByte('\n');
    return allocating.toOwnedSlice();
}

pub fn formatMessage(self: Self, writer: *std.Io.Writer) !void {
    switch (self.tag) {
        .expected_declaration => try writer.writeAll("Expected declaration"),
        .invalid_number => try writer.writeAll("Invalid number"),
        .invalid_date => try writer.writeAll("Invalid date"),
        .invalid_booking_method => try writer.writeAll("Invalid booking method. Choose from FIFO, LIFO, STRICT"),
        .expected_token => |t| try writer.print("Expected {s}, found {s}", .{ @tagName(t), @tagName(self.token.tag) }),
        .expected_entry => try writer.writeAll("Expected entry"),
        .expected_key_value => try writer.writeAll("Expected key: value"),
        .expected_value => try writer.writeAll("Expected value"),
        .expected_amount => try writer.writeAll("Expected amount"),
        .duplicate_lot_spec => try writer.writeAll("Duplicate lot spec"),
        .tag_already_pushed => try writer.writeAll("Tag already pushed"),
        .meta_already_pushed => try writer.writeAll("Key already pushed"),
        .tag_not_pushed => try writer.writeAll("Tag has not been pushed before"),
        .meta_not_pushed => try writer.writeAll("Key has not been pushed before"),
        .tx_balance_no_currency => try writer.writeAll("No currency to pick to balance transaction"),
        .tx_does_not_balance => |imbalance| {
            try writer.print("Transaction does not balance: Total of {f} for {s}", .{
                imbalance.sum,
                imbalance.currency,
            });
        },
        .tx_no_solution => try writer.writeAll("Transaction can't be balanced"),
        .tx_too_many_variables => try writer.writeAll("Transaction can't be balanced unambiguously"),
        .tx_division_by_zero => try writer.writeAll("Division by zero while balancing transaction"),
        .tx_multiple_solutions => try writer.writeAll("Transaction can't be balanced unambiguously"),
        .cannot_infer_amount_currency_when_price_set => try writer.writeAll("Cannot infer amount currency when price is set. Please specify what currency is bought/sold"),
        .account_not_open => try writer.writeAll("Account is not open or has been closed. Open it with an open entry"),
        .account_already_open => try writer.writeAll("Account has already been opened"),
        .multiple_pads => try writer.writeAll("Multiple pads of the same account. You need to have a balance assertion between pads"),
        .balance_assertion_failed => |body| {
            try writer.print("Balance assertion failed. Expected {f}, but accumulated {f}", .{
                body.expected,
                body.accumulated,
            });
            const diff = body.accumulated.sub(body.expected);
            std.debug.assert(!diff.is_zero());
            if (diff.is_positive()) try writer.print(" ({f} too much).", .{diff});
            if (diff.is_negative()) try writer.print(" ({f} too little).", .{diff.negate()});
        },
        .account_does_not_hold_currency => try writer.writeAll("The account does not hold this currency. Check open declaration."),
        .account_is_booked => try writer.writeAll("Account only supports positions held at cost. Can only buy or sell."),
        .account_does_not_support_lot_spec => try writer.writeAll("Can't use lot spec on an account that doesn't support positions held at cost."),
        .lot_spec_ambiguous_match => try writer.writeAll("Ambiguous match. Lot spec needs to match exactly one lot."),
        .lot_spec_match_too_small => try writer.writeAll("Matched lot too small. You can cancel at most one lot."),
        .lot_spec_no_match => try writer.writeAll("No matching lot found for lot spec."),
        .ambiguous_strict_booking => try writer.writeAll("Strict booking requires explicit lot selection, or new lot needs to cancel all existing lots exactly."),
        .flagged => try writer.writeAll("Flagged"),
        .inferred_price => try writer.writeAll("Price inferred from cost spec. Please consider using @ syntax."),
    }
}

pub fn format(e: Self, writer: *std.Io.Writer, alloc: Allocator, color: bool) !void {
    const color_on = if (color) switch (e.severity) {
        .err => "\x1b[31m",
        .warn => "\x1b[33m",
    } else "";
    const color_off = if (color) "\x1b[0m" else "";

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

    if (line_end > line_start) {
        line_end = line_start;
        col_start = col_end;
    }

    // std.debug.print("{s}\n", .{e.uri.value});
    // std.debug.print("{d} {d} {d} {d}\n", .{ line_start, col_start, line_end, col_end });
    std.debug.assert(line_start == line_end);
    std.debug.assert(col_start <= col_end);

    var line_pos_end = e.source.len;
    for (end..e.source.len) |i| {
        if (e.source[i] == '\n') {
            line_pos_end = i;
            break;
        }
    }

    const severity = switch (e.severity) {
        .err => "Error",
        .warn => "Warning",
    };

    const relative = try e.uri.relative(alloc);
    defer alloc.free(relative);

    try writer.print(
        "{s}: [{s}{s}{s}] ",
        .{ relative, color_on, severity, color_off },
    );

    try e.formatMessage(writer);
    try writer.writeAll("\n\n");

    try writer.print(
        "{d:>5} | {s}\n",
        .{ line_start + 1, e.source[line_pos..line_pos_end] },
    );
    for (0..col_start + 8) |_| try writer.writeByte(' ');
    try writer.writeAll(color_on);
    try writer.splatByteAll('^', col_end - col_start);
    try writer.writeAll(color_off);

    try writer.writeByte('\n');
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
        .tag = .{ .expected_token = .string },
        .token = Lexer.Token{
            .tag = .number,
            .slice = source[start .. start + len],
            .start_line = 0,
            .end_line = 0,
            .start_col = @intCast(start),
            .end_col = @intCast(start + len),
        },
        .uri = uri,
        .source = source,
    };
    const rendered = try e.dump(alloc, false);
    defer alloc.free(rendered);

    try std.testing.expectEqualStrings(expected, rendered);
}
