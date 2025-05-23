const std = @import("std");
const Allocator = std.mem.Allocator;
const Number = @import("number.zig").Number;

const Variable = usize;

/// Upper bound on number of currencies and currency variables.
const MAX_UNKNOWNS = 8;

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

const Solution = struct {
    currencies: [MAX_UNKNOWNS][]const u8,
    numbers: [MAX_UNKNOWNS]Number,
    num_number_vars: usize,
    num_currency_vars: usize,

    pub fn format(self: Solution, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        _ = fmt;
        _ = options;
        for (0..self.num_number_vars) |i| {
            try std.fmt.format(writer, "{d} -> {any}, ", .{ i, self.numbers[i] });
        }
        for (0..self.num_currency_vars) |i| {
            try std.fmt.format(writer, "{d} -> {s}, ", .{ i, self.currencies[i] });
        }
    }
};

pub const Problem = struct {
    alloc: Allocator,
    pairs: std.ArrayList(Pair),
    num_number_vars: Variable = 0,

    currencies: [MAX_UNKNOWNS][]const u8 = undefined,
    num_currencies: usize = 0,
    num_currency_vars: usize = 0,

    pub fn init(alloc: Allocator) Problem {
        return Problem{
            .alloc = alloc,
            .pairs = std.ArrayList(Pair).init(alloc),
        };
    }

    fn nextNumberVar(p: *Problem) !Variable {
        if (p.num_number_vars >= MAX_UNKNOWNS) return error.TooManyNumberVars;
        p.num_number_vars += 1;
        return p.num_number_vars - 1;
    }

    pub fn addPair(p: *Problem, coeff: ?Number, number: ?Number, currency: ?[]const u8) !Pair {
        const m_coeff = if (coeff) |c| MaybeNumber{ .value = c } else MaybeNumber{ .variable = try p.nextNumberVar() };
        const m_number = if (number) |c| MaybeNumber{ .value = c } else MaybeNumber{ .variable = try p.nextNumberVar() };

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
                if (p.num_currencies >= MAX_UNKNOWNS) return error.TooManyCurrencies;
                p.currencies[p.num_currencies] = c;
                p.num_currencies += 1;
            }
        } else {
            m_currency = MaybeCurrency{ .variable = p.num_currency_vars };
            if (p.num_currency_vars >= MAX_UNKNOWNS) return error.TooManyCurrencyVars;
            p.num_currency_vars += 1;
        }

        const pair = Pair{ .coeff = m_coeff, .number = m_number, .currency = m_currency };
        try p.pairs.append(pair);
        return pair;
    }

    pub fn deinit(p: *Problem) void {
        p.pairs.deinit();
    }

    const SolverError = error{
        NoSolution,
        MultipleSolutions,
    } || TryAssignmentError;

    pub fn solve(p: *Problem) SolverError!Solution {
        // An assignment: for currency var i, currencies_assignment[i] tells which currency was chosen
        var currencies_assignment: [MAX_UNKNOWNS]usize = .{0} ** MAX_UNKNOWNS;

        var err: ?TryAssignmentError = null;
        var solution: ?Solution = null;
        while (true) {
            const next_solution = p.try_assignment(currencies_assignment) catch |e| blk: {
                err = e;
                break :blk null;
            };
            if (next_solution) |s| {
                if (solution) |_| {
                    return error.MultipleSolutions;
                } else {
                    solution = s;
                }
            }

            // Increment indices as if it were a number in fixed_len-base
            var carry: usize = 1;
            for (0..p.num_currency_vars) |var_i| {
                if (carry == 0) break;
                currencies_assignment[var_i] += carry;
                if (currencies_assignment[var_i] >= p.num_currencies) {
                    currencies_assignment[var_i] = 0;
                    carry = 1;
                } else {
                    carry = 0;
                }
            }
            if (carry == 1) break;
        }

        return solution orelse return err orelse error.NoSolution;
    }

    const TryAssignmentError = error{
        TooManyVariables,
        DivisionByZero,
        DoesNotBalance,
        OutOfMemory,
    };

    fn try_assignment(p: *Problem, currencies_assignment: [MAX_UNKNOWNS]usize) TryAssignmentError!Solution {
        // std.debug.print("\ntry_assignment:\n", .{});
        // for (0..p.num_currency_vars) |var_i| {
        //     const idx = currencies_assignment[var_i];
        //     const currency = p.currencies[idx];
        //     std.debug.print("{d} -> {s}\n", .{ var_i, currency });
        // }

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
                .variable => |v| currency = p.currencies[currencies_assignment[v]],
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

        var currencies: [MAX_UNKNOWNS][]const u8 = undefined;
        for (0..p.num_currency_vars) |var_i| {
            const idx = currencies_assignment[var_i];
            currencies[var_i] = p.currencies[idx];
        }
        var solution = Solution{
            .currencies = currencies,
            .numbers = undefined,
            .num_currency_vars = p.num_currency_vars,
            .num_number_vars = p.num_number_vars,
        };

        var it = accum_by_currency.iterator();
        while (it.next()) |kv| {
            if (kv.value_ptr.mixed) |mixed| {
                if (mixed.coeff.is_zero()) {
                    return error.DivisionByZero;
                } else {
                    const divided = try kv.value_ptr.constant.div(mixed.coeff);
                    const result = divided.negate();
                    solution.numbers[mixed.variable] = result;
                }
            } else {
                // TODO: Take tolerance into account
                if (!kv.value_ptr.constant.is_zero()) {
                    return error.DoesNotBalance;
                }
            }
        }

        return solution;
    }
};

test "plain balance" {
    var p = Problem.init(std.testing.allocator);
    defer p.deinit();

    const one = Number.fromFloat(1);
    const five = Number.fromFloat(5);

    _ = try p.addPair(one, five, "EUR");
    _ = try p.addPair(one, five.negate(), "EUR");

    _ = try p.solve();
}

test "currency solution" {
    var p = Problem.init(std.testing.allocator);
    defer p.deinit();

    const one = Number.fromFloat(1);
    const five = Number.fromFloat(5);
    const three = Number.fromFloat(3);

    _ = try p.addPair(one, five, "EUR");
    const eur_pair = try p.addPair(one, five.negate(), null);
    _ = try p.addPair(one, three, "USD");
    const usd_pair = try p.addPair(one, three.negate(), null);

    const solution = try p.solve();
    try std.testing.expectEqualStrings("EUR", solution.currencies[eur_pair.currency.variable]);
    try std.testing.expectEqualStrings("USD", solution.currencies[usd_pair.currency.variable]);
}

test "number solution" {
    var p = Problem.init(std.testing.allocator);
    defer p.deinit();

    const one = Number.fromFloat(1);
    const six = Number.fromFloat(6);
    const three = Number.fromFloat(3);

    _ = try p.addPair(one, six, "EUR");
    const eur_pair = try p.addPair(one, null, "EUR");
    _ = try p.addPair(one, six, "USD");
    const usd_pair = try p.addPair(null, three, "USD");

    const solution = try p.solve();
    try std.testing.expectEqual(Number.fromFloat(-6), solution.numbers[eur_pair.number.variable]);
    try std.testing.expectEqual(Number.fromFloat(-2), solution.numbers[usd_pair.coeff.variable]);
}

test "too many variables" {
    var p = Problem.init(std.testing.allocator);
    defer p.deinit();

    const one = Number.fromFloat(1);
    const five = Number.fromFloat(5);

    _ = try p.addPair(one, five, "EUR");
    _ = try p.addPair(one, null, "EUR");
    _ = try p.addPair(one, null, "EUR");

    const solution = p.solve();
    try std.testing.expectError(error.TooManyVariables, solution);
}

test "does not balance" {
    var p = Problem.init(std.testing.allocator);
    defer p.deinit();

    const one = Number.fromFloat(1);

    _ = try p.addPair(one, Number.fromFloat(5), "EUR");
    _ = try p.addPair(one, null, "USD");
    _ = try p.addPair(one, Number.fromFloat(3), null);

    const solution = p.solve();
    try std.testing.expectError(error.DoesNotBalance, solution);
}
