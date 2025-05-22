const std = @import("std");
const Allocator = std.mem.Allocator;
const Number = @import("number.zig").Number;

const Variable = usize;

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
    num_number_vars: Variable = 0,

    currencies: [8][]const u8 = undefined,
    num_currencies: usize = 0,
    num_currency_vars: usize = 0,

    /// An assignment: for currency var i, currencies_assignment[i] tells which currency was chosen
    currencies_assignment: [8]usize = .{0} ** 8,

    pub fn init(alloc: Allocator) Problem {
        return Problem{
            .alloc = alloc,
            .pairs = std.ArrayList(Pair).init(alloc),
        };
    }

    fn nextNumberVar(p: *Problem) Variable {
        p.num_number_vars += 1;
        return p.num_number_vars - 1;
    }

    pub fn addPair(p: *Problem, coeff: ?Number, number: ?Number, currency: ?[]const u8) !void {
        const m_coeff = if (coeff) |c| MaybeNumber{ .value = c } else MaybeNumber{ .variable = p.nextNumberVar() };
        const m_number = if (number) |c| MaybeNumber{ .value = c } else MaybeNumber{ .variable = p.nextNumberVar() };

        var m_currency: MaybeCurrency = undefined;
        if (currency) |c| {
            m_currency = MaybeCurrency{ .currency = c };
            var currency_exists = false;
            for (0..p.num_currencies) |i| {
                if (std.mem.eql(u8, c, p.currencies[i])) {
                    currency_exists = true;
                    break;
                }
            }
            if (!currency_exists) {
                if (p.num_currencies >= 8) return error.TooManyCurrencies;
                p.currencies[p.num_currencies] = c;
                p.num_currencies += 1;
            }
        } else {
            m_currency = MaybeCurrency{ .variable = p.num_currency_vars };
            if (p.num_currency_vars >= 8) return error.TooManyCurrencyVars;
            p.num_currency_vars += 1;
        }

        try p.pairs.append(Pair{ .coeff = m_coeff, .number = m_number, .currency = m_currency });
    }

    pub fn deinit(p: *Problem) void {
        p.pairs.deinit();
    }

    /// Upper bound on number of currencies and currency variables: 8
    pub fn solve(p: *Problem) !void {
        while (true) {
            try p.try_assignment();

            // Increment indices as if it were a number in fixed_len-base
            var carry: usize = 1;
            for (0..p.num_currency_vars) |var_i| {
                if (carry == 0) break;
                p.currencies_assignment[var_i] += carry;
                if (p.currencies_assignment[var_i] >= p.num_currencies) {
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
        for (0..p.num_currency_vars) |var_i| {
            const idx = p.currencies_assignment[var_i];
            const currency = p.currencies[idx];
            std.debug.print("{d} -> {s}\n", .{ var_i, currency });
        }

        const Accum = struct {
            constant: Number,
            mixed: ?Mixed,

            const Mixed = struct {
                variable: Variable,
                coeff: Number,
            };
        };

        var accum_by_currency = std.StringHashMap(Accum).init(p.alloc);
        defer accum_by_currency.deinit();

        for (p.pairs.items) |pair| {
            // Substitute currency assignment into currency vars
            var currency: []const u8 = undefined;
            switch (pair.currency) {
                .currency => |c| currency = c,
                .variable => |v| currency = p.currencies[p.currencies_assignment[v]],
            }
            var variable: ?Variable = undefined;
            var number: Number = undefined;
            switch (pair.coeff) {
                .value => |n1| {
                    switch (pair.number) {
                        .value => |n2| {
                            number = n1.mul(n2);
                            variable = null;
                        },
                        .variable => |v1| {
                            number = n1;
                            variable = v1;
                        },
                    }
                },
                .variable => |v1| {
                    switch (pair.number) {
                        .value => |n2| {
                            number = n2;
                            variable = v1;
                        },
                        .variable => |_| {
                            return error.TooManyVariables;
                        },
                    }
                },
            }
            const result = try accum_by_currency.getOrPut(currency);
            if (result.found_existing) {
                var accum = result.value_ptr;
                if (variable) |v| {
                    if (accum.*.mixed) |mixed| {
                        if (mixed.variable == v) {
                            accum.*.mixed.?.coeff = mixed.coeff.add(number);
                        } else {
                            return error.TooManyVariables;
                        }
                    } else {
                        accum.*.mixed = Accum.Mixed{
                            .variable = v,
                            .coeff = number,
                        };
                    }
                } else {
                    accum.constant = accum.constant.add(number);
                }
            } else {
                var new: Accum = undefined;
                if (variable) |v| {
                    new = Accum{
                        .constant = Number.zero(),
                        .mixed = Accum.Mixed{
                            .variable = v,
                            .coeff = number,
                        },
                    };
                } else {
                    new = Accum{
                        .constant = number,
                        .mixed = null,
                    };
                }

                result.value_ptr.* = new;
            }
        }

        var it = accum_by_currency.iterator();
        while (it.next()) |kv| {
            if (kv.value_ptr.mixed) |mixed| {
                if (mixed.coeff.is_zero()) {
                    std.debug.print("{s}: Division by zero\n", .{kv.key_ptr.*});
                } else {
                    const divided = try kv.value_ptr.constant.div(mixed.coeff);
                    const result = divided.negate();
                    std.debug.print("{s}: {}\n", .{ kv.key_ptr.*, result });
                }
            } else {
                // TODO: Take tolerance into account
                std.debug.print("{s}: {}\n", .{ kv.key_ptr.*, kv.value_ptr.constant });
            }
        }
    }
};

test "solver" {
    var p = Problem.init(std.testing.allocator);
    defer p.deinit();

    const one = Number.fromFloat(1);

    try p.addPair(one, Number.fromFloat(5), "EUR");
    try p.addPair(one, null, "USD");
    try p.addPair(one, Number.fromFloat(3), null);

    try p.solve();
}
