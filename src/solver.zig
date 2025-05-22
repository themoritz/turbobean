const std = @import("std");
const Allocator = std.mem.Allocator;
const Number = @import("number.zig").Number;

const Variable = u32;

pub const MaybeCurrency = union(enum) {
    currency: []const u8,
    variable: Variable,
};

pub const MaybeNumber = union(enum) {
    value: Number,
    variable: Variable,
};

pub const Pair = struct {
    coeff: MaybeNumber,
    number: MaybeNumber,
    currency: MaybeCurrency,
};

pub const Problem = struct {
    alloc: Allocator,
    pairs: std.ArrayList(Pair),
    next_var: Variable = 0,

    // For the solver:

    currencies_fix: [8][]const u8 = undefined,
    currencies_fix_n: usize = 0,
    currencies_var: [8]Variable = undefined,
    currencies_var_n: usize = 0,
    /// An assignment: for variables i, currencies_assignment[i] tells which currency was chosen
    currencies_assignment: [8]usize = .{0} ** 8,

    pub fn init(alloc: Allocator) Problem {
        return Problem{
            .alloc = alloc,
            .pairs = std.ArrayList(Pair).init(alloc),
        };
    }

    pub fn nextVar(p: *Problem) Variable {
        p.next_var += 1;
        return p.next_var;
    }

    pub fn addPair(p: *Problem, coeff: ?Number, number: ?Number, currency: ?[]const u8) !void {
        const m_coeff = if (coeff) |c| MaybeNumber{ .value = c } else MaybeNumber{ .variable = p.nextVar() };
        const m_number = if (number) |c| MaybeNumber{ .value = c } else MaybeNumber{ .variable = p.nextVar() };
        const m_currency = if (currency) |c| MaybeCurrency{ .currency = c } else MaybeCurrency{ .variable = p.nextVar() };
        try p.pairs.append(Pair{ .coeff = m_coeff, .number = m_number, .currency = m_currency });
    }

    pub fn deinit(p: *Problem) void {
        p.pairs.deinit();
    }

    /// Upper bound on number of currencies and currency variables: 8
    pub fn solve(p: *Problem) !void {
        pairs: for (p.pairs.items) |pair| {
            switch (pair.currency) {
                .currency => |c| {
                    for (0..p.currencies_fix_n) |i| {
                        if (std.mem.eql(u8, c, p.currencies_fix[i])) continue :pairs;
                    }
                    p.currencies_fix[p.currencies_fix_n] = c;
                    p.currencies_fix_n += 1;
                    std.debug.assert(p.currencies_fix_n <= 8);
                },
                .variable => |v| {
                    p.currencies_var[p.currencies_var_n] = v;
                    p.currencies_var_n += 1;
                    std.debug.assert(p.currencies_var_n <= 8);
                },
            }
        }

        while (true) {
            try p.try_assignment();

            // Increment indices as if it were a number in fixed_len-base
            var carry: usize = 1;
            for (0..p.currencies_var_n) |var_i| {
                if (carry == 0) break;
                p.currencies_assignment[var_i] += carry;
                if (p.currencies_assignment[var_i] >= p.currencies_fix_n) {
                    p.currencies_assignment[var_i] = 0;
                    carry = 1;
                } else {
                    carry = 0;
                }
            }
            if (carry == 1) break;
        }
    }

    fn try_assignment(p: *Problem) !void {
        std.debug.print("\ntry_assignment:\n", .{});
        for (0..p.currencies_var_n) |var_i| {
            const idx = p.currencies_assignment[var_i];
            const currency = p.currencies_fix[idx];
            std.debug.print("{d} -> {s}\n", .{ p.currencies_var[var_i], currency });
        }
    }
};

test "solver" {
    var p = Problem.init(std.testing.allocator);
    defer p.deinit();

    try p.addPair(null, Number.fromFloat(1), "USD");
    try p.addPair(null, Number.fromFloat(1), "EUR");
    try p.addPair(null, Number.fromFloat(1), "GBP");
    try p.addPair(null, Number.fromFloat(1), null);
    try p.addPair(null, Number.fromFloat(1), null);

    try p.solve();
}
