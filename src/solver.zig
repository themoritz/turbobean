//! Solver for balancing transactions.
//!
//! It takes as input a list of triples (price, number, currency), where each
//! entry can be missing, indicating that the number or currency is not known and
//! should be filled in by the solver. The solver will generate variables for the
//! unknowns. In this example, n0 and c0 are variables, and should be filled in by
//! the solver such that if all the tiples are summed up, the result is zero (i.e.
//! the transaction balances):
//!
//! (1, 6, EUR)
//! (2, n,   c)
//!
//! The unique solution in this case is n = -3, c = EUR because
//!
//! 1 * 6 EUR + 2 * -3 EUR = 0 EUR
//!
//! The solver works as follows. For the missing currencies, it tries all
//! possible combinations of other currencies that are present in the triples.
//! Then for each such combination, it tries to find numbers that balance all
//! currencies.
//!
//! This is done by simply, for each currency, adding up all the triples while
//! making sure at most one variable can exist (because otherwise the solution
//! is not unique). Then we just rearrange the sum to get the number that
//! balances the currency.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Number = @import("number.zig").Number;

pub const Variable = usize;

/// Upper bound on number of currencies and currency variables.
const MAX_UNKNOWNS = 8;

/// Assignment of currency variables to currency. The solver tries all
/// combinations. For currency var i, assignment[i] tells which currency is
/// chosen.
const Assignment = [MAX_UNKNOWNS]usize;

pub const MaybeCurrency = union(enum) {
    currency: []const u8,
    variable: Variable,
};

pub const MaybeNumber = union(enum) {
    value: Number,
    variable: Variable,
};

pub const Triple = struct {
    price: MaybeNumber,
    number: MaybeNumber,
    currency: MaybeCurrency,
};

pub const Solution = struct {
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

    pub fn currency(self: Solution, v: Variable) []const u8 {
        std.debug.assert(v < self.num_currency_vars);
        return self.currencies[v];
    }

    pub fn number(self: Solution, v: Variable) Number {
        std.debug.assert(v < self.num_number_vars);
        return self.numbers[v];
    }
};

pub const Problem = struct {
    alloc: Allocator,
    triples: std.ArrayList(Triple),

    num_number_vars: Variable = 0,
    num_currency_vars: Variable = 0,

    currencies: [MAX_UNKNOWNS][]const u8 = undefined,
    num_currencies: usize = 0,

    pub fn init(alloc: Allocator) Problem {
        return Problem{
            .alloc = alloc,
            .triples = std.ArrayList(Triple).init(alloc),
        };
    }

    pub fn deinit(p: *Problem) void {
        p.triples.deinit();
    }

    fn nextNumberVar(p: *Problem) !Variable {
        if (p.num_number_vars >= MAX_UNKNOWNS) return error.TooManyNumberVars;
        p.num_number_vars += 1;
        return p.num_number_vars - 1;
    }

    /// Add a triple to the problem.
    pub fn addTriple(p: *Problem, price: ?Number, number: ?Number, currency: ?[]const u8) !Triple {
        const m_price = if (price) |c| MaybeNumber{ .value = c } else MaybeNumber{ .variable = try p.nextNumberVar() };
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

        const triple = Triple{ .price = m_price, .number = m_number, .currency = m_currency };
        try p.triples.append(triple);
        return triple;
    }

    pub const SolverError = error{
        NoSolution,
        MultipleSolutions,
    } || TryAssignmentError;

    pub fn solve(p: *Problem) SolverError!Solution {
        var assignment: Assignment = .{0} ** MAX_UNKNOWNS;

        var err: ?TryAssignmentError = null;
        var prev_solution: ?Solution = null;
        while (true) {
            const solution = p.try_assignment(assignment) catch |e| blk: {
                err = e;
                break :blk null;
            };
            if (solution) |s| {
                if (prev_solution) |_| {
                    return error.MultipleSolutions;
                } else {
                    prev_solution = s;
                }
            }

            // Increment indices as if it were a number in num_currencies base
            var carry: usize = 1;
            for (0..p.num_currency_vars) |var_i| {
                if (carry == 0) break;
                assignment[var_i] += carry;
                if (assignment[var_i] >= p.num_currencies) {
                    assignment[var_i] = 0;
                    carry = 1;
                } else {
                    carry = 0;
                }
            }
            if (carry == 1) break;
        }

        return prev_solution orelse return err orelse error.NoSolution;
    }

    pub const TryAssignmentError = error{
        TooManyVariables,
        DivisionByZero,
        DoesNotBalance,
        OutOfMemory,
    };

    fn try_assignment(p: *Problem, assignment: Assignment) TryAssignmentError!Solution {
        const Sum = struct {
            constant: Number,
            mixed: ?Mixed,

            const Mixed = struct {
                variable: Variable,
                coeff: Number,
            };
        };

        var sum_by_currency = std.StringHashMap(Sum).init(p.alloc);
        defer sum_by_currency.deinit();

        for (p.triples.items) |triple| {
            // Substitute currency assignment into currency var
            const currency = switch (triple.currency) {
                .currency => |c| c,
                .variable => |v| p.currencies[assignment[v]],
            };

            var variable: ?Variable = undefined;
            var coeff: Number = undefined;
            switch (triple.price) {
                .value => |val_p| {
                    switch (triple.number) {
                        .value => |val_n| {
                            coeff = val_p.mul(val_n);
                            variable = null;
                        },
                        .variable => |var_n| {
                            coeff = val_p;
                            variable = var_n;
                        },
                    }
                },
                .variable => |var_p| {
                    switch (triple.number) {
                        .value => |val_n| {
                            coeff = val_n;
                            variable = var_p;
                        },
                        .variable => |_| {
                            return error.TooManyVariables;
                        },
                    }
                },
            }

            const result = try sum_by_currency.getOrPut(currency);
            if (result.found_existing) {
                var sum = result.value_ptr;
                if (variable) |v| {
                    if (sum.*.mixed) |mixed| {
                        if (mixed.variable == v) {
                            sum.*.mixed.?.coeff = mixed.coeff.add(coeff);
                        } else {
                            return error.TooManyVariables;
                        }
                    } else {
                        sum.*.mixed = Sum.Mixed{
                            .variable = v,
                            .coeff = coeff,
                        };
                    }
                } else {
                    sum.constant = sum.constant.add(coeff);
                }
            } else {
                var new: Sum = undefined;
                if (variable) |v| {
                    new = Sum{
                        .constant = Number.zero(),
                        .mixed = Sum.Mixed{
                            .variable = v,
                            .coeff = coeff,
                        },
                    };
                } else {
                    new = Sum{
                        .constant = coeff,
                        .mixed = null,
                    };
                }

                result.value_ptr.* = new;
            }
        }

        var currencies: [MAX_UNKNOWNS][]const u8 = undefined;
        for (0..p.num_currency_vars) |var_i| {
            const idx = assignment[var_i];
            currencies[var_i] = p.currencies[idx];
        }
        var solution = Solution{
            .currencies = currencies,
            .numbers = undefined,
            .num_currency_vars = p.num_currency_vars,
            .num_number_vars = p.num_number_vars,
        };

        var it = sum_by_currency.iterator();
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

    _ = try p.addTriple(one, five, "EUR");
    _ = try p.addTriple(one, five.negate(), "EUR");

    _ = try p.solve();
}

test "currency solution" {
    var p = Problem.init(std.testing.allocator);
    defer p.deinit();

    const one = Number.fromFloat(1);
    const five = Number.fromFloat(5);
    const three = Number.fromFloat(3);

    _ = try p.addTriple(one, five, "EUR");
    const eur = try p.addTriple(one, five.negate(), null);
    _ = try p.addTriple(one, three, "USD");
    const usd = try p.addTriple(one, three.negate(), null);

    const s = try p.solve();
    try std.testing.expectEqualStrings("EUR", s.currency(eur.currency.variable));
    try std.testing.expectEqualStrings("USD", s.currency(usd.currency.variable));
}

test "number solution" {
    var p = Problem.init(std.testing.allocator);
    defer p.deinit();

    const one = Number.fromFloat(1);
    const six = Number.fromFloat(6);
    const three = Number.fromFloat(3);

    _ = try p.addTriple(one, six, "EUR");
    const eur = try p.addTriple(one, null, "EUR");
    _ = try p.addTriple(one, six, "USD");
    const usd = try p.addTriple(null, three, "USD");

    const s = try p.solve();
    try std.testing.expectEqual(Number.fromFloat(-6), s.number(eur.number.variable));
    try std.testing.expectEqual(Number.fromFloat(-2), s.number(usd.price.variable));
}

test "currency + number solution" {
    var p = Problem.init(std.testing.allocator);
    defer p.deinit();

    const one = Number.fromFloat(1);
    const six = Number.fromFloat(6);

    _ = try p.addTriple(one, six, "EUR");
    const eur = try p.addTriple(one, null, null);

    const s = try p.solve();
    try std.testing.expectEqualStrings("EUR", s.currency(eur.currency.variable));
    try std.testing.expectEqual(six.negate(), s.number(eur.number.variable));
}

test "too many variables" {
    var p = Problem.init(std.testing.allocator);
    defer p.deinit();

    const one = Number.fromFloat(1);
    const five = Number.fromFloat(5);

    _ = try p.addTriple(one, five, "EUR");
    _ = try p.addTriple(one, null, "EUR");
    _ = try p.addTriple(one, null, "EUR");

    const s = p.solve();
    try std.testing.expectError(error.TooManyVariables, s);
}

test "too many variables price" {
    var p = Problem.init(std.testing.allocator);
    defer p.deinit();

    _ = try p.addTriple(null, null, "EUR");

    const s = p.solve();
    try std.testing.expectError(error.TooManyVariables, s);
}

test "does not balance" {
    var p = Problem.init(std.testing.allocator);
    defer p.deinit();

    const one = Number.fromFloat(1);

    _ = try p.addTriple(one, Number.fromFloat(5), "EUR");
    _ = try p.addTriple(one, null, "USD");
    _ = try p.addTriple(one, Number.fromFloat(3), null);

    const s = p.solve();
    try std.testing.expectError(error.DoesNotBalance, s);
}
