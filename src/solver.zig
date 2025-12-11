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

const Variable = usize;

/// Upper bound on number of currencies and currency variables.
const MAX_UNKNOWNS = 8;

/// Assignment of currency variables to currency. The solver tries all
/// combinations. For currency var i, assignment[i] tells which currency is
/// chosen.
const Assignment = [MAX_UNKNOWNS]usize;

const MaybeCurrency = struct {
    currency: *?[]const u8,
    variable: ?Variable,
};

const MaybeNumber = struct {
    number: *?Number,
    variable: ?Variable,
};

const Triple = struct {
    price: MaybeNumber,
    number: MaybeNumber,
    currency: MaybeCurrency,
};

const Solution = struct {
    currencies: [MAX_UNKNOWNS][]const u8,
    numbers: [MAX_UNKNOWNS]Number,
    num_number_vars: usize,
    num_currency_vars: usize,

    pub fn format(self: Solution, writer: *std.Io.Writer) !void {
        for (0..self.num_number_vars) |i| {
            try writer.print("{d} -> {f}, ", .{ i, self.numbers[i] });
        }
        for (0..self.num_currency_vars) |i| {
            try writer.print("{d} -> {s}, ", .{ i, self.currencies[i] });
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

pub const Solver = struct {
    alloc: Allocator,
    triples: std.ArrayList(Triple),

    num_number_vars: Variable = 0,
    num_currency_vars: Variable = 0,

    currencies: [MAX_UNKNOWNS][]const u8 = undefined,
    num_currencies: usize = 0,

    sum_by_currency: std.StringHashMap(Sum),

    const Sum = struct {
        constant: Number,
        mixed: ?Mixed,

        const Mixed = struct {
            variable: Variable,
            coeff: Number,
        };
    };

    pub fn init(alloc: Allocator) Solver {
        return Solver{
            .alloc = alloc,
            .triples = .{},
            .sum_by_currency = std.StringHashMap(Sum).init(alloc),
        };
    }

    pub fn deinit(p: *Solver) void {
        p.triples.deinit(p.alloc);
        p.sum_by_currency.deinit();
    }

    fn clear(p: *Solver) void {
        p.num_number_vars = 0;
        p.num_currency_vars = 0;
        p.num_currencies = 0;
        p.triples.clearRetainingCapacity();
    }

    fn nextNumberVar(p: *Solver) !Variable {
        if (p.num_number_vars >= MAX_UNKNOWNS) return error.TooManyNumberVars;
        p.num_number_vars += 1;
        return p.num_number_vars - 1;
    }

    /// Add a triple to the problem.
    pub fn addTriple(p: *Solver, price: *?Number, number: *?Number, currency: *?[]const u8) !void {
        const price_var = if (price.*) |_| null else try p.nextNumberVar();
        const m_price = MaybeNumber{ .number = price, .variable = price_var };
        const number_var = if (number.*) |_| null else try p.nextNumberVar();
        const m_number = MaybeNumber{ .number = number, .variable = number_var };

        var currency_var: ?Variable = undefined;
        if (currency.*) |c| {
            currency_var = null;
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
            currency_var = p.num_currency_vars;
            if (p.num_currency_vars >= MAX_UNKNOWNS) return error.TooManyCurrencyVars;
            p.num_currency_vars += 1;
        }
        const m_currency = MaybeCurrency{ .currency = currency, .variable = currency_var };

        const triple = Triple{ .price = m_price, .number = m_number, .currency = m_currency };
        try p.triples.append(p.alloc, triple);
    }

    pub const SolverError = error{
        NoCurrency,
        NoSolution,
        MultipleSolutions,
    } || TryAssignmentError;

    /// The solver can be reused after this. There is no need to allocate a new one
    /// for each tx that needs balancing.
    pub fn solve(p: *Solver, diagnostics: ?*CurrencyImbalance) SolverError!Solution {
        defer p.clear();
        var assignment: Assignment = .{0} ** MAX_UNKNOWNS;

        if (p.num_currencies == 0) return error.NoCurrency;

        var err: ?TryAssignmentError = null;
        var prev_solution: ?Solution = null;
        while (true) {
            const solution = p.try_assignment(assignment, diagnostics) catch |e| blk: {
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

        if (prev_solution) |s| {
            // Apply solution to triples
            for (p.triples.items) |triple| {
                if (triple.price.variable) |v| triple.price.number.* = s.numbers[v];
                if (triple.number.variable) |v| triple.number.number.* = s.numbers[v];
                if (triple.currency.variable) |v| triple.currency.currency.* = s.currencies[v];
            }
            return s;
        } else if (err) |e| {
            return e;
        } else {
            return error.NoSolution;
        }
    }

    pub const TryAssignmentError = error{
        TooManyVariables,
        DivisionByZero,
        DoesNotBalance,
        OutOfMemory,
    };

    pub const CurrencyImbalance = struct {
        currency: []const u8,
        sum: Number,
    };

    fn try_assignment(
        p: *Solver,
        assignment: Assignment,
        diagnostics: ?*CurrencyImbalance,
    ) TryAssignmentError!Solution {
        p.sum_by_currency.clearRetainingCapacity();

        for (p.triples.items) |triple| {
            // Substitute currency assignment into currency var
            const currency = if (triple.currency.variable) |v| p.currencies[assignment[v]] else triple.currency.currency.*.?;

            var variable: ?Variable = undefined;
            var coeff: Number = undefined;
            if (triple.price.variable) |var_p| {
                if (triple.number.variable) |_| {
                    return error.TooManyVariables;
                } else {
                    coeff = triple.number.number.*.?;
                    variable = var_p;
                }
            } else {
                const val_p = triple.price.number.*.?;
                if (triple.number.variable) |var_n| {
                    coeff = val_p;
                    variable = var_n;
                } else {
                    const val_n = triple.number.number.*.?;
                    coeff = val_p.mul(val_n);
                    variable = null;
                }
            }

            const result = try p.sum_by_currency.getOrPut(currency);
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

        var it = p.sum_by_currency.iterator();
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
                    if (diagnostics) |diag| diag.* = .{ .currency = kv.key_ptr.*, .sum = kv.value_ptr.constant };
                    return error.DoesNotBalance;
                }
            }
        }

        return solution;
    }
};

test "plain balance" {
    const alloc = std.testing.allocator;
    var p = Solver.init(alloc);
    defer p.deinit();

    var one: ?Number = Number.fromFloat(1);
    var five: ?Number = Number.fromFloat(5);
    var neg_five: ?Number = Number.fromFloat(-5);

    var eur: ?[]const u8 = try alloc.dupe(u8, "EUR");
    defer alloc.free(eur.?);

    try p.addTriple(&one, &five, &eur);
    try p.addTriple(&one, &neg_five, &eur);

    _ = try p.solve(null);
}

test "currency solution" {
    const alloc = std.testing.allocator;
    var p = Solver.init(alloc);
    defer p.deinit();

    var one: ?Number = Number.fromFloat(1);
    var five: ?Number = Number.fromFloat(5);
    var three: ?Number = Number.fromFloat(3);
    var neg_five: ?Number = Number.fromFloat(-5);
    var neg_three: ?Number = Number.fromFloat(-3);

    var eur: ?[]const u8 = try alloc.dupe(u8, "EUR");
    var usd: ?[]const u8 = try alloc.dupe(u8, "USD");
    defer alloc.free(eur.?);
    defer alloc.free(usd.?);

    var c1: ?[]const u8 = null;
    var c2: ?[]const u8 = null;

    try p.addTriple(&one, &five, &eur);
    try p.addTriple(&one, &neg_five, &c1);
    try p.addTriple(&one, &three, &usd);
    try p.addTriple(&one, &neg_three, &c2);

    _ = try p.solve(null);
    try std.testing.expectEqualStrings("EUR", c1.?);
    try std.testing.expectEqualStrings("USD", c2.?);
}

test "number solution" {
    const alloc = std.testing.allocator;
    var p = Solver.init(alloc);
    defer p.deinit();

    var one: ?Number = Number.fromFloat(1);
    var six: ?Number = Number.fromFloat(6);
    var three: ?Number = Number.fromFloat(3);

    var eur: ?[]const u8 = try alloc.dupe(u8, "EUR");
    var usd: ?[]const u8 = try alloc.dupe(u8, "USD");
    defer alloc.free(eur.?);
    defer alloc.free(usd.?);

    var n1: ?Number = null;
    var n2: ?Number = null;

    try p.addTriple(&one, &six, &eur);
    try p.addTriple(&one, &n1, &eur);
    try p.addTriple(&one, &six, &usd);
    try p.addTriple(&n2, &three, &usd);

    _ = try p.solve(null);
    try std.testing.expectEqual(Number.fromFloat(-6), n1.?);
    try std.testing.expectEqual(Number.fromFloat(-2), n2.?);
}

test "combined solution" {
    const alloc = std.testing.allocator;
    var p = Solver.init(alloc);
    defer p.deinit();

    var one: ?Number = Number.fromFloat(1);
    var six: ?Number = Number.fromFloat(6);

    var eur: ?[]const u8 = try alloc.dupe(u8, "EUR");
    defer alloc.free(eur.?);

    var n1: ?Number = null;
    var c1: ?[]const u8 = null;

    try p.addTriple(&one, &six, &eur);
    try p.addTriple(&one, &n1, &c1);

    _ = try p.solve(null);
    try std.testing.expectEqualStrings("EUR", c1.?);
    try std.testing.expectEqual(Number.fromFloat(-6), n1.?);
}

test "too many variables" {
    const alloc = std.testing.allocator;
    var p = Solver.init(alloc);
    defer p.deinit();

    var one: ?Number = Number.fromFloat(1);
    var five: ?Number = Number.fromFloat(5);

    var eur: ?[]const u8 = try alloc.dupe(u8, "EUR");
    defer alloc.free(eur.?);

    var n1: ?Number = null;
    var n2: ?Number = null;

    try p.addTriple(&one, &five, &eur);
    try p.addTriple(&one, &n1, &eur);
    try p.addTriple(&one, &n2, &eur);

    const s = p.solve(null);
    try std.testing.expectError(error.TooManyVariables, s);
}

test "too many variables price" {
    const alloc = std.testing.allocator;
    var p = Solver.init(alloc);
    defer p.deinit();

    var eur: ?[]const u8 = try alloc.dupe(u8, "EUR");
    defer alloc.free(eur.?);

    var n1: ?Number = null;
    var n2: ?Number = null;

    try p.addTriple(&n1, &n2, &eur);

    const s = p.solve(null);
    try std.testing.expectError(error.TooManyVariables, s);
}

test "does not balance" {
    const alloc = std.testing.allocator;
    var p = Solver.init(alloc);
    defer p.deinit();

    var one: ?Number = Number.fromFloat(1);
    var five: ?Number = Number.fromFloat(5);
    var three: ?Number = Number.fromFloat(3);

    var eur: ?[]const u8 = try alloc.dupe(u8, "EUR");
    var usd: ?[]const u8 = try alloc.dupe(u8, "USD");
    defer alloc.free(eur.?);
    defer alloc.free(usd.?);

    var n1: ?Number = null;
    var c1: ?[]const u8 = null;

    try p.addTriple(&one, &five, &eur);
    try p.addTriple(&one, &n1, &usd);
    try p.addTriple(&one, &three, &c1);

    var diag: Solver.CurrencyImbalance = undefined;
    const s = p.solve(&diag);
    try std.testing.expectError(error.DoesNotBalance, s);
    try std.testing.expectEqualStrings("EUR", diag.currency);
    try std.testing.expectEqual(Number.fromFloat(5), diag.sum);
}

test "single no currency" {
    const alloc = std.testing.allocator;
    var p = Solver.init(alloc);
    defer p.deinit();

    var n1: ?Number = null;
    var one: ?Number = Number.fromFloat(1);
    var c1: ?[]const u8 = null;

    try p.addTriple(&n1, &one, &c1);

    const s = p.solve(null);
    try std.testing.expectError(error.NoCurrency, s);
}

test "single zero" {
    const alloc = std.testing.allocator;
    var p = Solver.init(alloc);
    defer p.deinit();

    var n1: ?Number = null;
    var one: ?Number = Number.fromFloat(1);

    var eur: ?[]const u8 = try alloc.dupe(u8, "EUR");
    defer alloc.free(eur.?);

    try p.addTriple(&n1, &one, &eur);

    _ = try p.solve(null);
    try std.testing.expectEqual(Number.zero(), n1.?);
}
