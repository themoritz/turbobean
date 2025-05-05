const std = @import("std");
const Allocator = std.mem.Allocator;
const Data = @import("data.zig");
const Date = @import("date.zig").Date;
const Self = @This();
const Lexer = @import("lexer.zig").Lexer;
const Decimal = @import("decimal.zig").Decimal;

pub const Error = error{ ParseError, InvalidCharacter } || Allocator.Error;

gpa: Allocator,
lexer: *Lexer,
directives: Data.Directives,
legs: Data.Legs,
err: ?ErrorDetails,
current_token: Lexer.Token,

pub const ErrorDetails = struct {
    tag: Tag,
    token: Lexer.Token,
    expected: ?Lexer.Token.Tag,

    pub const Tag = enum {
        expected_token,
    };
};

fn addLeg(p: *Self, leg: Data.Leg) !usize {
    const result = p.legs.len;
    try p.legs.append(p.gpa, leg);
    return result;
}

fn addDirective(p: *Self, directive: Data.Directive) !usize {
    const result = p.directives.items.len;
    try p.directives.append(directive);
    return result;
}

/// Advances the lexer and stores the next token in `current_token`.
/// Returns the previous token.
fn advanceToken(p: *Self) Lexer.Token {
    const result = p.current_token;
    p.current_token = p.lexer.next();
    return result;
}

fn currentToken(p: *Self) Lexer.Token {
    return p.current_token;
}

/// If successful, returns the token looked for and advances
/// the lexer.
fn expectToken(p: *Self, tag: Lexer.Token.Tag) Error!Lexer.Token {
    const current = p.currentToken();
    if (current.tag != tag) {
        p.err = .{
            .tag = .expected_token,
            .token = current,
            .expected = tag,
        };
        return error.ParseError;
    } else {
        return p.advanceToken();
    }
}

fn expectTokenSlice(p: *Self, tag: Lexer.Token.Tag) Error![]const u8 {
    const token = try p.expectToken(tag);
    return p.lexer.token_slice(&token);
}

/// If successful, returns the token looked for and advances the
/// lexer.
fn tryToken(p: *Self, tag: Lexer.Token.Tag) ?Lexer.Token {
    if (p.currentToken().tag == tag) {
        return p.advanceToken();
    } else {
        return null;
    }
}

pub fn parse(p: *Self) !void {
    while (true) {
        _ = p.parseDirective() catch |err| switch (err) {
            error.ParseError => {
                // std.debug.print("{any}\n", .{p.err});
                break;
            },
            else => return err,
        };
    }
}

/// Returns index of newly parsed directive in directives array.
fn parseDirective(p: *Self) !usize {
    const date_slice = try p.expectTokenSlice(.date);
    const date = try Date.fromSlice(date_slice);
    const flag = try p.parseFlag();
    const msg = try p.expectTokenSlice(.string);
    _ = p.tryToken(.eol);

    const legs_top = p.legs.len;
    while (true) {
        _ = p.parseLeg() catch |err| switch (err) {
            error.ParseError => break,
            else => return err,
        };
    }
    const directive = Data.Directive{ .transaction = .{ .date = date, .flag = flag, .message = msg, .legs = .{
        .start = legs_top,
        .end = p.legs.len,
    } } };

    _ = p.tryToken(.eol);

    return p.addDirective(directive);
}

fn parseFlag(p: *Self) !Data.Flag {
    if (p.tryToken(.asterisk)) |_| {
        return .star;
    } else {
        _ = try p.expectToken(.flag);
        return .bang;
    }
}

fn parseLeg(p: *Self) Error!usize {
    _ = try p.expectToken(.indent);
    const account = try p.expectTokenSlice(.account);
    const amount_slice = try p.expectTokenSlice(.number);
    const amount = try Decimal.fromSlice(amount_slice);
    const currency = try p.expectTokenSlice(.currency);
    _ = p.tryToken(.eol);

    const leg = Data.Leg{
        .account = account,
        .amount = amount,
        .currency = currency,
    };

    return p.addLeg(leg);
}

test "parser" {
    try testParse(
        \\2015-11-01 * "Test"
        \\  Foo 100.0000 USD
        \\  Bar -2.0000 EUR
    );

    try testParse(
        \\2024-12-01 * "Foo"
    );

    try testParse(
        \\2015-01-01 * ""
        \\  Aa 10.0000 USD
        \\  Ba 30.0000 USD
        \\
        \\2016-01-01 * ""
        \\  Ca 10.0000 USD
        \\  Da 20.0000 USD
    );
}

fn testParse(source: [:0]const u8) !void {
    const alloc = std.testing.allocator;

    var data = try Data.parse(alloc, source);
    defer data.deinit(alloc);

    // const pretty = @import("pretty.zig");
    // try pretty.print(alloc, data.directives, .{});
    // try pretty.print(alloc, data.legs.items(.amount), .{});

    const Render = @import("render.zig");
    const rendered = try Render.dump(alloc, &data);
    defer alloc.free(rendered);

    try std.testing.expectEqualSlices(u8, source, rendered);
}
