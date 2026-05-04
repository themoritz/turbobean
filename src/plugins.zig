//! Lua plugin runner.
//!
//! Discovers plugins from `data.config.plugins`, resolves each to `<name>.lua`
//! next to the root .bean file, executes the script, and invokes its returned
//! function with a Lua list of entries. The function returns
//! `(new_entries, errors)`:
//!   - `new_entries` (optional): if a table is returned, replaces the project's
//!     entries entirely. Plugin-emitted token text lives in a synthetic file
//!     allocated per pipeline run.
//!   - `errors` (optional): a list of `{ message = "..." }` tables (or bare
//!     strings) appended to `project.errors`.
//!
//! Plugin script contract:
//!     return function(entries)
//!         return new_entries, errors
//!     end

const std = @import("std");
const Allocator = std.mem.Allocator;
const zlua = @import("zlua");
const Lua = zlua.Lua;

const Project = @import("project.zig");
const Data = @import("data.zig");
const ErrorDetails = @import("ErrorDetails.zig");
const File = @import("file.zig");
const Ast = @import("Ast.zig");
const Number = @import("number.zig").Number;
const Date = @import("date.zig").Date;
const Inventory = @import("inventory.zig");
const Uri = @import("Uri.zig");
const Lexer = @import("lexer.zig").Lexer;

pub fn run(project: *Project) !void {
    const plugins = project.data.config.plugins.items;
    if (plugins.len == 0) return;
    if (project.data.files.items.len == 0) return;

    for (plugins) |ref| {
        try runOne(project, ref);
    }
}

fn runOne(project: *Project, ref: Data.Config.PluginRef) !void {
    const arena = project.plugin_arena.allocator();

    const name = stripQuotes(ref.name);
    const root_dir = std.fs.path.dirname(project.rootUri().absolute()) orelse ".";
    const abs_path = try std.fmt.allocPrint(arena, "{s}/{s}.lua", .{ root_dir, name });

    const loc: Data.TokenLoc = .{ .file_id = ref.file_id, .index = ref.token };

    // Read the source ourselves so error messages don't leak the absolute path.
    const source = std.fs.cwd().readFileAlloc(arena, abs_path, 1 << 24) catch |err| switch (err) {
        error.FileNotFound => {
            try appendPluginError(project, loc, .{ .plugin_load_failed = .{
                .plugin = try arena.dupe(u8, name),
                .message = try std.fmt.allocPrint(arena, "{s}.lua not found", .{name}),
            } });
            return;
        },
        else => |e| {
            try appendPluginError(project, loc, .{ .plugin_load_failed = .{
                .plugin = try arena.dupe(u8, name),
                .message = try std.fmt.allocPrint(arena, "could not read {s}.lua: {s}", .{ name, @errorName(e) }),
            } });
            return;
        },
    };
    const chunkname = try std.fmt.allocPrintSentinel(arena, "[plugin: {s}]", .{name}, 0);

    var lua = try Lua.init(project.alloc);
    defer lua.deinit();
    lua.openLibs();

    // Load + run the chunk; expect it to return the plugin function.
    lua.loadBuffer(source, chunkname, .text) catch |err| {
        try addLoadError(project, loc, name, lua, err);
        return;
    };
    lua.protectedCall(.{ .results = 1 }) catch |err| {
        try addLoadError(project, loc, name, lua, err);
        return;
    };
    if (!lua.isFunction(-1)) {
        try addLoadError(project, loc, name, null, error.PluginScriptDidNotReturnFunction);
        return;
    }

    // Push entries arg.
    try pushEntries(lua, project);

    // Call: plugin(entries) -> (new_entries, errors). Ask for 2 results so the
    // stack has both slots (nil-padded if the plugin returned fewer).
    lua.protectedCall(.{ .args = 1, .results = 2 }) catch |err| {
        try addRuntimeError(project, loc, name, lua, err);
        return;
    };

    // Stack: [-2] new_entries, [-1] errors.
    try readErrors(project, loc, name, lua, -1);
    try applyEntries(project, loc, name, lua, -2);

    lua.pop(2);
}

fn stripQuotes(s: []const u8) []const u8 {
    if (s.len >= 2 and s[0] == '"' and s[s.len - 1] == '"') return s[1 .. s.len - 1];
    return s;
}

// --- error reporting --------------------------------------------------------

fn addLoadError(project: *Project, loc: Data.TokenLoc, name: []const u8, lua: ?*Lua, err: anyerror) !void {
    const msg = try formatLuaError(project, lua, err);
    try appendPluginError(project, loc, .{ .plugin_load_failed = .{
        .plugin = try project.plugin_arena.allocator().dupe(u8, name),
        .message = msg,
    } });
}

fn addRuntimeError(project: *Project, loc: Data.TokenLoc, name: []const u8, lua: *Lua, err: anyerror) !void {
    const msg = try formatLuaError(project, lua, err);
    try appendPluginError(project, loc, .{ .plugin_error = .{
        .plugin = try project.plugin_arena.allocator().dupe(u8, name),
        .message = msg,
    } });
}

fn formatLuaError(project: *Project, lua: ?*Lua, err: anyerror) ![]const u8 {
    const arena = project.plugin_arena.allocator();
    if (lua) |l| {
        if (l.getTop() > 0 and l.isString(-1)) {
            const s = l.toString(-1) catch null;
            if (s) |slice| return try std.fmt.allocPrint(arena, "{s} ({s})", .{ slice, @errorName(err) });
        }
    }
    return try std.fmt.allocPrint(arena, "{s}", .{@errorName(err)});
}

/// Append an error pinned to the source token at `loc` — typically the
/// `plugin "..."` directive that triggered the run.
fn appendPluginError(project: *Project, loc: Data.TokenLoc, tag: ErrorDetails.Tag) !void {
    try appendPluginDiag(project, loc, tag, .err);
}

fn appendPluginDiag(project: *Project, loc: Data.TokenLoc, tag: ErrorDetails.Tag, severity: ErrorDetails.Severity) !void {
    const f = &project.data.files.items[loc.file_id];
    try project.errors.append(project.alloc, .{
        .tag = tag,
        .severity = severity,
        .token = f.token(loc.index),
        .uri = f.uri,
        .source = f.source,
    });
}

fn parseSeverity(s: []const u8) ?ErrorDetails.Severity {
    if (std.ascii.eqlIgnoreCase(s, "error") or
        std.ascii.eqlIgnoreCase(s, "err"))
        return .err;
    if (std.ascii.eqlIgnoreCase(s, "warning") or
        std.ascii.eqlIgnoreCase(s, "warn"))
        return .warn;
    return null;
}

fn readErrors(project: *Project, loc: Data.TokenLoc, name: []const u8, lua: *Lua, idx: i32) !void {
    if (lua.isNil(idx)) return;
    if (!lua.isTable(idx)) {
        try addRuntimeError(project, loc, name, lua, error.PluginErrorsReturnIsNotTable);
        return;
    }
    const arena = project.plugin_arena.allocator();
    const len = lua.rawLen(idx);
    var i: u32 = 1;
    while (i <= len) : (i += 1) {
        _ = lua.rawGetIndex(idx, @intCast(i));
        defer lua.pop(1);

        var msg: []const u8 = "(no message)";
        var attached: ?Data.TokenLoc = null;
        var severity: ErrorDetails.Severity = .err;

        if (lua.isTable(-1)) {
            // message
            _ = lua.getField(-1, "message");
            if (lua.isString(-1)) {
                if (lua.toString(-1) catch null) |s| msg = s;
            }
            lua.pop(1);

            // severity (optional, default error)
            _ = lua.getField(-1, "severity");
            if (lua.isString(-1)) {
                if (lua.toString(-1) catch null) |s| {
                    if (parseSeverity(s)) |sev| severity = sev;
                }
            }
            lua.pop(1);

            // posting takes precedence over entry — more specific.
            _ = lua.getField(-1, "posting");
            if (lua.isTable(-1)) attached = readLoc(project, lua, -1);
            lua.pop(1);

            if (attached == null) {
                _ = lua.getField(-1, "entry");
                if (lua.isTable(-1)) attached = readLoc(project, lua, -1);
                lua.pop(1);
            }
        } else if (lua.isString(-1)) {
            if (lua.toString(-1) catch null) |s| msg = s;
        }

        try appendPluginDiag(project, attached orelse loc, .{ .plugin_error = .{
            .plugin = try arena.dupe(u8, name),
            .message = try arena.dupe(u8, msg),
        } }, severity);
    }
}

// --- Data -> Lua serialization ---------------------------------------------

fn pushEntries(lua: *Lua, project: *Project) !void {
    const data = &project.data;
    lua.createTable(@intCast(data.entries.len), 0);

    var iter = data.iterEntries();
    var i: i32 = 1;
    while (iter.next()) |entry| : (i += 1) {
        try pushEntry(lua, project, entry);
        lua.rawSetIndex(-2, i);
    }
}

fn pushEntry(lua: *Lua, project: *Project, entry: Data.EntryView) !void {
    lua.createTable(0, 9);

    pushTypeStr(lua, entry.tag());
    lua.setField(-2, "type");

    pushDate(lua, entry.date());
    lua.setField(-2, "date");

    pushLoc(lua, entry.file(), entry.mainToken());
    lua.setField(-2, "_loc");

    try pushTagsLinks(lua, entry);
    try pushEntryMeta(lua, entry);

    switch (entry.payload()) {
        .transaction => |tx| try pushTransaction(lua, project, tx),
        .open => |o| try pushOpen(lua, project, o),
        .close => |c| try pushAccount(lua, project, c.accountText()),
        .balance => |b| try pushBalance(lua, b),
        .pad => |p| try pushPad(lua, project, p),
        .pnl => |pnl| try pushPnl(lua, project, entry, pnl),
        .commodity => |c| try pushCommodity(lua, project, c),
        .price => |p| try pushPriceDecl(lua, p),
        .event => |e| try pushEvent(lua, project, entry, e),
        .query => |q| try pushQuery(lua, project, entry, q),
        .note => |n| try pushNote(lua, project, entry, n),
        .document => |d| try pushDocument(lua, project, entry, d),
    }
}

fn pushTypeStr(lua: *Lua, tag: Data.Entry.Tag) void {
    _ = lua.pushString(@tagName(tag));
}

fn pushDate(lua: *Lua, date: anytype) void {
    var buf: [16]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    date.format(&w) catch unreachable;
    _ = lua.pushString(w.buffered());
}

fn pushAccount(lua: *Lua, project: *Project, account_text: []const u8) !void {
    _ = project;
    _ = lua.pushString(account_text);
    lua.setField(-2, "account");
}

fn pushTransaction(lua: *Lua, project: *Project, tx: Data.TransactionView) !void {
    _ = lua.pushString(tx.flagSlice());
    lua.setField(-2, "flag");
    if (tx.payeeText()) |p| {
        _ = lua.pushString(stripQuotes(p));
        lua.setField(-2, "payee");
    }
    if (tx.narrationText()) |n| {
        _ = lua.pushString(stripQuotes(n));
        lua.setField(-2, "narration");
    }

    var it = tx.postings();
    lua.createTable(@intCast(it.remaining()), 0);
    var i: i32 = 1;
    while (it.next()) |p| : (i += 1) {
        try pushPosting(lua, project, p);
        lua.rawSetIndex(-2, i);
    }
    lua.setField(-2, "postings");
}

fn pushPosting(lua: *Lua, project: *Project, p: Data.PostingView) !void {
    lua.createTable(0, 8);

    pushLoc(lua, p.file, p.accountToken());
    lua.setField(-2, "_loc");

    _ = lua.pushString(p.accountText());
    lua.setField(-2, "account");

    if (p.amountNumber()) |n| {
        try pushNumberStr(lua,n);
        lua.setField(-2, "amount");
    }
    if (p.amountCurrencyText()) |c| {
        _ = lua.pushString(c);
        lua.setField(-2, "currency");
    }
    if (p.flag().unwrap()) |f| {
        const fdata = &project.data.files.items[p.file];
        _ = lua.pushString(fdata.tokenSlice(f));
        lua.setField(-2, "flag");
    }
    if (p.price()) |pr| {
        try pushPostingPrice(lua, pr);
        lua.setField(-2, "price");
    }
    if (p.lotSpec()) |ls| {
        try pushLotSpec(lua, ls);
        lua.setField(-2, "lot_spec");
    }
    try pushPostingMeta(lua, project, p);
}

fn pushPostingPrice(lua: *Lua, pr: Data.PriceView) !void {
    lua.createTable(0, 3);
    if (pr.amount) |n| {
        try pushNumberStr(lua,n);
        lua.setField(-2, "amount");
    }
    if (pr.amountCurrencyText()) |c| {
        _ = lua.pushString(c);
        lua.setField(-2, "currency");
    }
    lua.pushBoolean(pr.total);
    lua.setField(-2, "total");
}

fn pushLotSpec(lua: *Lua, ls: Data.LotSpecView) !void {
    lua.createTable(0, 4);
    if (ls.price) |n| {
        try pushNumberStr(lua, n);
        lua.setField(-2, "price");
    }
    if (ls.priceCurrencyText()) |c| {
        _ = lua.pushString(c);
        lua.setField(-2, "currency");
    }
    if (ls.date) |d| {
        pushDate(lua, d);
        lua.setField(-2, "date");
    }
    if (ls.labelText()) |label| {
        _ = lua.pushString(stripQuotes(label));
        lua.setField(-2, "label");
    }
}

fn pushOpen(lua: *Lua, project: *Project, open: Data.OpenView) !void {
    _ = lua.pushString(open.accountText());
    lua.setField(-2, "account");

    if (open.currencies()) |cs| {
        lua.createTable(@intCast(cs.len), 0);
        for (cs, 0..) |c, k| {
            _ = lua.pushString(project.data.currencyText(c));
            lua.rawSetIndex(-2, @intCast(k + 1));
        }
        lua.setField(-2, "currencies");
    }
    if (open.bookingMethod()) |bm| {
        // Lower-case in Zig, but Beancount source convention is upper-case.
        var buf: [16]u8 = undefined;
        const upper = std.ascii.upperString(&buf, @tagName(bm));
        _ = lua.pushString(upper);
        lua.setField(-2, "booking_method");
    }
}

fn pushBalance(lua: *Lua, b: Data.BalanceView) !void {
    _ = lua.pushString(b.accountText());
    lua.setField(-2, "account");
    try pushNumberStr(lua, b.amount);
    lua.setField(-2, "amount");
    _ = lua.pushString(b.amountCurrencyText());
    lua.setField(-2, "currency");
    if (b.tolerance) |t| {
        try pushNumberStr(lua, t);
        lua.setField(-2, "tolerance");
    }
}

fn pushPad(lua: *Lua, project: *Project, p: Data.PadView) !void {
    const fdata = &project.data.files.items[p.file];
    _ = lua.pushString(fdata.tokenSlice(p.pad.account));
    lua.setField(-2, "account");
    _ = lua.pushString(fdata.tokenSlice(p.pad.pad_to));
    lua.setField(-2, "pad_to");
}

fn pushPnl(lua: *Lua, project: *Project, entry: Data.EntryView, pnl: Data.Pnl) !void {
    _ = project;
    _ = lua.pushString(entry.tokenSlice(pnl.account));
    lua.setField(-2, "account");
    _ = lua.pushString(entry.tokenSlice(pnl.income_account));
    lua.setField(-2, "income_account");
}

fn pushCommodity(lua: *Lua, project: *Project, c: Data.Commodity) !void {
    _ = lua.pushString(project.data.currencyText(c.currency));
    lua.setField(-2, "currency");
}

fn pushPriceDecl(lua: *Lua, p: Data.PriceDeclView) !void {
    _ = lua.pushString(p.currencyText());
    lua.setField(-2, "currency");
    try pushNumberStr(lua, p.amount);
    lua.setField(-2, "amount");
    _ = lua.pushString(p.amountCurrencyText());
    lua.setField(-2, "amount_currency");
}

fn pushEvent(lua: *Lua, project: *Project, entry: Data.EntryView, e: Data.Event) !void {
    _ = project;
    _ = lua.pushString(stripQuotes(entry.tokenSlice(e.variable)));
    lua.setField(-2, "variable");
    _ = lua.pushString(stripQuotes(entry.tokenSlice(e.value)));
    lua.setField(-2, "value");
}

fn pushQuery(lua: *Lua, project: *Project, entry: Data.EntryView, q: Data.Query) !void {
    _ = project;
    _ = lua.pushString(stripQuotes(entry.tokenSlice(q.name)));
    lua.setField(-2, "name");
    _ = lua.pushString(stripQuotes(entry.tokenSlice(q.sql)));
    lua.setField(-2, "sql");
}

fn pushNote(lua: *Lua, project: *Project, entry: Data.EntryView, n: Data.Note) !void {
    _ = project;
    _ = lua.pushString(entry.tokenSlice(n.account));
    lua.setField(-2, "account");
    _ = lua.pushString(stripQuotes(entry.tokenSlice(n.note)));
    lua.setField(-2, "note");
}

fn pushDocument(lua: *Lua, project: *Project, entry: Data.EntryView, d: Data.Document) !void {
    _ = project;
    _ = lua.pushString(entry.tokenSlice(d.account));
    lua.setField(-2, "account");
    _ = lua.pushString(stripQuotes(entry.tokenSlice(d.filename)));
    lua.setField(-2, "filename");
}

fn pushNumberStr(lua: *Lua, n: Number) !void {
    var buf: [64]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try n.format(&w);
    _ = lua.pushString(w.buffered());
}

fn pushTagsLinks(lua: *Lua, entry: Data.EntryView) !void {
    var tags_count: u32 = 0;
    var links_count: u32 = 0;
    {
        var it = entry.tagslinks();
        while (it.next()) |tl| {
            if (!tl.explicit) continue;
            switch (tl.kind) {
                .tag => tags_count += 1,
                .link => links_count += 1,
            }
        }
    }
    lua.createTable(@intCast(tags_count), 0);
    lua.createTable(@intCast(links_count), 0);

    var ti: i32 = 1;
    var li: i32 = 1;
    var it = entry.tagslinks();
    while (it.next()) |tl| {
        if (!tl.explicit) continue;
        const slice = tl.slice();
        // slice includes the leading # or ^ — strip it
        const text = if (slice.len > 0) slice[1..] else slice;
        _ = lua.pushString(text);
        switch (tl.kind) {
            .tag => {
                lua.rawSetIndex(-3, ti);
                ti += 1;
            },
            .link => {
                lua.rawSetIndex(-2, li);
                li += 1;
            },
        }
    }
    lua.setField(-3, "links");
    lua.setField(-2, "tags");
}

fn pushEntryMeta(lua: *Lua, entry: Data.EntryView) !void {
    lua.createTable(0, 0);
    var it = entry.metaKVs();
    const fdata = &entry.data.files.items[entry.file()];
    while (it.next()) |kv| {
        pushMetaKV(lua, fdata, kv);
    }
    lua.setField(-2, "meta");
}

fn pushPostingMeta(lua: *Lua, project: *Project, p: Data.PostingView) !void {
    lua.createTable(0, 0);
    var it = p.metaKVs();
    const fdata = &project.data.files.items[p.file];
    while (it.next()) |kv| {
        pushMetaKV(lua, fdata, kv);
    }
    lua.setField(-2, "meta");
}

/// Encode a source-token reference as a small Lua table `{ file, token }`.
/// Plugins receive this as a hidden `_loc` field on every entry and posting;
/// they don't need to read it directly — passing the entry/posting table
/// back via `error.entry` / `error.posting` is enough for the runner to
/// recover the original source location.
fn pushLoc(lua: *Lua, file_id: u8, tok: Ast.TokenIndex) void {
    lua.createTable(0, 2);
    lua.pushInteger(@intCast(file_id));
    lua.setField(-2, "file");
    lua.pushInteger(@intCast(@intFromEnum(tok)));
    lua.setField(-2, "token");
}

/// Inverse of `pushLoc`. Reads `_loc` off the table at `table_idx` and
/// validates that file_id/token_index are in range — plugins are not
/// trusted to keep `_loc` well-formed.
fn readLoc(project: *const Project, lua: *Lua, table_idx: i32) ?Data.TokenLoc {
    if (!lua.isTable(table_idx)) return null;

    _ = lua.getField(table_idx, "_loc");
    defer lua.pop(1);
    if (!lua.isTable(-1)) return null;

    _ = lua.getField(-1, "file");
    const file_n = lua.toInteger(-1) catch {
        lua.pop(1);
        return null;
    };
    lua.pop(1);

    _ = lua.getField(-1, "token");
    const token_n = lua.toInteger(-1) catch {
        lua.pop(1);
        return null;
    };
    lua.pop(1);

    if (file_n < 0 or token_n < 0) return null;
    if (file_n >= project.data.files.items.len) return null;
    const file_id: u8 = @intCast(file_n);
    const f = &project.data.files.items[file_id];
    if (token_n >= f.ast.tokens.items.len) return null;
    return .{ .file_id = file_id, .index = @enumFromInt(@as(u32, @intCast(token_n))) };
}

fn pushMetaKV(lua: *Lua, fdata: *const File, kv: Data.KeyValueView) void {
    // Meta key tokens carry the trailing ':'; drop it before exposing to Lua.
    const key_raw = fdata.tokenSlice(kv.key);
    const key = if (key_raw.len > 0 and key_raw[key_raw.len - 1] == ':') key_raw[0 .. key_raw.len - 1] else key_raw;
    _ = lua.pushString(key);
    _ = lua.pushString(stripQuotes(fdata.tokenSlice(kv.value)));
    lua.setTable(-3);
}

// --- Lua -> Data write-back -------------------------------------------------

const PendingToken = struct {
    tag: Lexer.Token.Tag,
    /// Byte offset into Rebuild.source_buf.
    start: u32,
    len: u32,
    /// For account/currency tokens: the interned index. `maxInt` for others.
    interned: u32 = std.math.maxInt(u32),
};

/// Builds a fresh synth file plus replacement Data tables from the Lua entries
/// list returned by the plugin. Commits atomically at the end so a partial
/// failure leaves the original Data intact (caller signals via plugin error).
const Rebuild = struct {
    project: *Project,
    plugin: []const u8,
    /// Slot in `data.files` where the synth file is being constructed.
    synth_id: u8,

    source_buf: std.ArrayList(u8) = .empty,
    pending: std.ArrayList(PendingToken) = .empty,

    entries: Data.Entries = .{},
    postings: Data.Postings = .{},
    prices: std.ArrayList(Data.Price) = .empty,
    lot_specs: std.ArrayList(Data.LotSpec) = .empty,
    open_currencies: std.ArrayList(Data.CurrencyIndex) = .empty,
    tagslinks: Data.TagsLinks = .{},
    meta: Data.Meta = .{},

    fn alloc(self: *Rebuild) Allocator {
        return self.project.alloc;
    }

    fn deinit(self: *Rebuild) void {
        self.source_buf.deinit(self.alloc());
        self.pending.deinit(self.alloc());
        self.entries.deinit(self.alloc());
        self.postings.deinit(self.alloc());
        self.prices.deinit(self.alloc());
        self.lot_specs.deinit(self.alloc());
        self.open_currencies.deinit(self.alloc());
        self.tagslinks.deinit(self.alloc());
        self.meta.deinit(self.alloc());
    }

    fn emitTok(self: *Rebuild, text: []const u8, tag: Lexer.Token.Tag) !Ast.TokenIndex {
        // Replace any embedded newlines so each token sits on its own source
        // line — `ErrorDetails.format` asserts single-line tokens.
        const start = self.source_buf.items.len;
        try self.source_buf.ensureUnusedCapacity(self.alloc(), text.len + 1);
        for (text) |b| {
            self.source_buf.appendAssumeCapacity(if (b == '\n' or b == '\r') ' ' else b);
        }
        self.source_buf.appendAssumeCapacity('\n');
        const idx: Ast.TokenIndex = @enumFromInt(self.pending.items.len);
        try self.pending.append(self.alloc(), .{
            .tag = tag,
            .start = @intCast(start),
            .len = @intCast(text.len),
        });
        return idx;
    }

    fn emitAccount(self: *Rebuild, text: []const u8) !Ast.TokenIndex {
        const tok_idx = try self.emitTok(text, .account);
        const acc_idx = try self.project.data.accounts.intern(self.alloc(), text);
        self.pending.items[@intFromEnum(tok_idx)].interned = @intFromEnum(acc_idx);
        return tok_idx;
    }

    fn emitCurrency(self: *Rebuild, text: []const u8) !Ast.TokenIndex {
        const tok_idx = try self.emitTok(text, .currency);
        const cur_idx = try self.project.data.currencies.intern(self.alloc(), text);
        self.pending.items[@intFromEnum(tok_idx)].interned = @intFromEnum(cur_idx);
        return tok_idx;
    }

    fn emitNumberLiteral(self: *Rebuild, text: []const u8) !Ast.TokenIndex {
        return try self.emitTok(text, .number);
    }

    fn emitFlag(self: *Rebuild, text: []const u8) !Ast.TokenIndex {
        return try self.emitTok(text, .flag);
    }

    fn emitString(self: *Rebuild, body: []const u8) !Ast.TokenIndex {
        // Source convention: surround with quotes, no escaping in v1.
        var buf = try self.alloc().alloc(u8, body.len + 2);
        defer self.alloc().free(buf);
        buf[0] = '"';
        @memcpy(buf[1 .. 1 + body.len], body);
        buf[buf.len - 1] = '"';
        return try self.emitTok(buf, .string);
    }

    fn emitDate(self: *Rebuild, date: Date) !Ast.TokenIndex {
        var buf: [16]u8 = undefined;
        var w = std.Io.Writer.fixed(&buf);
        date.format(&w) catch unreachable; // YYYY-MM-DD always fits.
        return try self.emitTok(w.buffered(), .date);
    }

    fn emitTag(self: *Rebuild, body: []const u8) !Ast.TokenIndex {
        // Real source includes the leading '#'; mirror that.
        var buf = try self.alloc().alloc(u8, body.len + 1);
        defer self.alloc().free(buf);
        buf[0] = '#';
        @memcpy(buf[1..], body);
        return try self.emitTok(buf, .tag);
    }

    fn emitLink(self: *Rebuild, body: []const u8) !Ast.TokenIndex {
        var buf = try self.alloc().alloc(u8, body.len + 1);
        defer self.alloc().free(buf);
        buf[0] = '^';
        @memcpy(buf[1..], body);
        return try self.emitTok(buf, .link);
    }

    fn emitMetaKey(self: *Rebuild, key: []const u8) !Ast.TokenIndex {
        var buf = try self.alloc().alloc(u8, key.len + 1);
        defer self.alloc().free(buf);
        @memcpy(buf[0..key.len], key);
        buf[buf.len - 1] = ':';
        return try self.emitTok(buf, .key);
    }

    /// Finalize the synth file and replace project.data with new tables.
    fn commit(self: *Rebuild) !void {
        const a = self.alloc();
        const data = &self.project.data;

        // Take ownership of the source buffer as a sentinel-terminated slice.
        const owned_source = try self.source_buf.toOwnedSliceSentinel(a, 0);
        errdefer a.free(owned_source);

        // Build tokens slice with patched .slice fields.
        var tokens: std.ArrayList(Lexer.Token) = .empty;
        errdefer tokens.deinit(a);
        try tokens.ensureTotalCapacityPrecise(a, self.pending.items.len);
        for (self.pending.items) |p| {
            tokens.appendAssumeCapacity(.{
                .tag = p.tag,
                .slice = owned_source[p.start .. p.start + p.len],
                .start_line = 0,
                .end_line = 0,
                .start_col = 0,
                .end_col = 0,
            });
        }

        // Build token_interned parallel to tokens.
        var token_interned: std.ArrayList(u32) = .empty;
        errdefer token_interned.deinit(a);
        try token_interned.ensureTotalCapacityPrecise(a, self.pending.items.len);
        for (self.pending.items) |p| token_interned.appendAssumeCapacity(p.interned);

        const ast = Ast{
            .alloc = a,
            .source = owned_source,
            .tokens = tokens,
            .nodes = .{},
            .extra_data = .{},
            .errors = .{},
        };

        const uri = try Uri.from_raw(a, "file:///__plugin_synth__");

        const new_file = File{
            .uri = uri,
            .source = owned_source,
            .ast = ast,
            .token_interned = token_interned,
            .errors = .{},
        };

        // Install the new synth file. After this, `owned_source`/tokens/etc.
        // are owned by `data.files`; clear our handles to avoid double-free
        // via Rebuild.deinit.
        try data.replaceSynthFile(new_file);

        // Swap data tables. Old contents get freed.
        std.mem.swap(Data.Entries, &data.entries, &self.entries);
        std.mem.swap(Data.Postings, &data.postings, &self.postings);
        std.mem.swap(std.ArrayList(Data.Price), &data.prices, &self.prices);
        std.mem.swap(std.ArrayList(Data.LotSpec), &data.lot_specs, &self.lot_specs);
        std.mem.swap(std.ArrayList(Data.CurrencyIndex), &data.open_currencies, &self.open_currencies);
        std.mem.swap(Data.TagsLinks, &data.tagslinks, &self.tagslinks);
        std.mem.swap(Data.Meta, &data.meta, &self.meta);
    }
};

fn applyEntries(project: *Project, loc: Data.TokenLoc, plugin_name: []const u8, lua: *Lua, idx: i32) !void {
    if (lua.isNil(idx)) return;
    if (!lua.isTable(idx)) {
        try addRuntimeError(project, loc, plugin_name, lua, error.PluginEntriesReturnIsNotTable);
        return;
    }

    const synth_id = try project.data.ensureSynthFile();
    var rb = Rebuild{
        .project = project,
        .plugin = plugin_name,
        .synth_id = synth_id,
    };
    defer rb.deinit();

    const len = lua.rawLen(idx);
    var i: u32 = 1;
    while (i <= len) : (i += 1) {
        _ = lua.rawGetIndex(idx, @intCast(i));
        defer lua.pop(1);
        readEntry(&rb, lua, i) catch |err| {
            const msg = try std.fmt.allocPrint(
                project.plugin_arena.allocator(),
                "entry #{d}: {s}",
                .{ i, @errorName(err) },
            );
            try appendPluginError(project, loc, .{ .plugin_error = .{
                .plugin = try project.plugin_arena.allocator().dupe(u8, plugin_name),
                .message = msg,
            } });
        };
    }

    try rb.commit();
}

const ReadEntryError = error{
    PluginEntryNotTable,
    PluginEntryMissingType,
    PluginEntryUnknownType,
    PluginEntryMissingDate,
    PluginEntryInvalidDate,
    PluginEntryMissingField,
    PluginEntryFieldWrongType,
    PluginEntryInvalidNumber,
    PluginEntryInvalidBookingMethod,
} || Allocator.Error;

fn readEntry(rb: *Rebuild, lua: *Lua, ord: u32) ReadEntryError!void {
    _ = ord;
    if (!lua.isTable(-1)) return error.PluginEntryNotTable;

    const type_str = (try getStringField(lua, -1, "type")) orelse return error.PluginEntryMissingType;
    const date_str = (try getStringField(lua, -1, "date")) orelse return error.PluginEntryMissingDate;
    const date = Date.fromSlice(date_str) catch return error.PluginEntryInvalidDate;

    const tagslinks_range = try readTagsLinks(rb, lua, -1);
    const meta_range = try readEntryMeta(rb, lua, -1);

    const tag = parseEntryTag(type_str) orelse return error.PluginEntryUnknownType;
    const main_token: Ast.TokenIndex = try rb.emitDate(date);

    const payload: Data.Entry.Payload = switch (tag) {
        .transaction => .{ .transaction = try readTransaction(rb, lua, -1) },
        .open => .{ .open = try readOpen(rb, lua, -1) },
        .close => .{ .close = .{ .account = try readAccountField(rb, lua, -1, "account") } },
        .commodity => .{ .commodity = .{ .currency = try readCurrencyField(rb, lua, -1, "currency") } },
        .pad => .{ .pad = .{
            .account = try readAccountField(rb, lua, -1, "account"),
            .pad_to = try readAccountField(rb, lua, -1, "pad_to"),
        } },
        .pnl => .{ .pnl = .{
            .account = try readAccountField(rb, lua, -1, "account"),
            .income_account = try readAccountField(rb, lua, -1, "income_account"),
        } },
        .balance => .{ .balance = try readBalance(rb, lua, -1) },
        .price => .{ .price = try readPriceDecl(rb, lua, -1) },
        .event => .{ .event = .{
            .variable = try readStringField(rb, lua, -1, "variable"),
            .value = try readStringField(rb, lua, -1, "value"),
        } },
        .query => .{ .query = .{
            .name = try readStringField(rb, lua, -1, "name"),
            .sql = try readStringField(rb, lua, -1, "sql"),
        } },
        .note => .{ .note = .{
            .account = try readAccountField(rb, lua, -1, "account"),
            .note = try readStringField(rb, lua, -1, "note"),
        } },
        .document => .{ .document = .{
            .account = try readAccountField(rb, lua, -1, "account"),
            .filename = try readStringField(rb, lua, -1, "filename"),
        } },
    };

    try rb.entries.append(rb.alloc(), .{
        .file = rb.synth_id,
        .date = date,
        .main_token = main_token,
        .tagslinks = tagslinks_range,
        .meta = meta_range,
        .payload = payload,
    });
}

fn parseEntryTag(s: []const u8) ?Data.Entry.Tag {
    inline for (@typeInfo(Data.Entry.Tag).@"enum".fields) |f| {
        if (std.mem.eql(u8, f.name, s)) return @enumFromInt(f.value);
    }
    return null;
}

fn readTransaction(rb: *Rebuild, lua: *Lua, idx: i32) ReadEntryError!Data.Transaction {
    const flag_text = (try getStringField(lua, idx, "flag")) orelse "*";
    const flag_tok = try rb.emitFlag(flag_text);

    var payee: Ast.OptionalTokenIndex = .none;
    if (try getStringField(lua, idx, "payee")) |p| {
        payee = (try rb.emitString(p)).toOptional();
    }
    var narration: Ast.OptionalTokenIndex = .none;
    if (try getStringField(lua, idx, "narration")) |n| {
        narration = (try rb.emitString(n)).toOptional();
    }

    // Postings.
    const start: u32 = @intCast(rb.postings.len);
    _ = lua.getField(idx, "postings");
    defer lua.pop(1);
    if (lua.isTable(-1)) {
        const len = lua.rawLen(-1);
        var i: u32 = 1;
        while (i <= len) : (i += 1) {
            _ = lua.rawGetIndex(-1, @intCast(i));
            defer lua.pop(1);
            try readPosting(rb, lua);
        }
    } else if (!lua.isNil(-1)) {
        return error.PluginEntryFieldWrongType;
    }
    const end: u32 = @intCast(rb.postings.len);

    return .{
        .flag = flag_tok,
        .payee = payee,
        .narration = narration,
        .postings = .{ .start = start, .end = end },
    };
}

fn readPosting(rb: *Rebuild, lua: *Lua) ReadEntryError!void {
    if (!lua.isTable(-1)) return error.PluginEntryFieldWrongType;

    const account_text = (try getStringField(lua, -1, "account")) orelse return error.PluginEntryMissingField;
    const account_tok = try rb.emitAccount(account_text);

    var amount = Data.PackedNumber.none;
    if (try getStringField(lua, -1, "amount")) |s| {
        const n = Number.fromSlice(s) catch return error.PluginEntryInvalidNumber;
        amount = Data.PackedNumber.pack(n);
    }
    var amount_currency: Data.OptionalCurrencyIndex = .none;
    if (try getStringField(lua, -1, "currency")) |s| {
        const cur_idx = try rb.project.data.currencies.intern(rb.alloc(), s);
        // Also emit a synth token so source rendering works.
        _ = try rb.emitCurrency(s);
        amount_currency = cur_idx.toOptional();
    }
    var flag: Ast.OptionalTokenIndex = .none;
    if (try getStringField(lua, -1, "flag")) |s| {
        flag = (try rb.emitFlag(s)).toOptional();
    }

    var price: Data.OptionalPriceIndex = .none;
    _ = lua.getField(-1, "price");
    if (lua.isTable(-1)) {
        const pr = try readPostingPrice(rb, lua, -1);
        const pidx: Data.PriceIndex = @enumFromInt(rb.prices.items.len);
        try rb.prices.append(rb.alloc(), pr);
        price = pidx.toOptional();
    } else if (!lua.isNil(-1)) {
        lua.pop(1);
        return error.PluginEntryFieldWrongType;
    }
    lua.pop(1);

    var lot_spec: Data.OptionalLotSpecIndex = .none;
    _ = lua.getField(-1, "lot_spec");
    if (lua.isTable(-1)) {
        const ls = try readPostingLotSpec(rb, lua, -1);
        const lidx: Data.LotSpecIndex = @enumFromInt(rb.lot_specs.items.len);
        try rb.lot_specs.append(rb.alloc(), ls);
        lot_spec = lidx.toOptional();
    } else if (!lua.isNil(-1)) {
        lua.pop(1);
        return error.PluginEntryFieldWrongType;
    }
    lua.pop(1);

    const meta_range = try readPostingMeta(rb, lua, -1);

    try rb.postings.append(rb.alloc(), .{
        .account = account_tok,
        .flag = flag,
        .amount_number = amount,
        .amount_currency = amount_currency,
        .price = price,
        .lot_spec = lot_spec,
        .meta = meta_range,
        .ast_node = .none,
    });
}

fn readPostingPrice(rb: *Rebuild, lua: *Lua, idx: i32) ReadEntryError!Data.Price {
    var amount: ?Number = null;
    if (try getStringField(lua, idx, "amount")) |s| {
        amount = Number.fromSlice(s) catch return error.PluginEntryInvalidNumber;
    }
    var amount_currency: Data.OptionalCurrencyIndex = .none;
    if (try getStringField(lua, idx, "currency")) |s| {
        const cur_idx = try rb.project.data.currencies.intern(rb.alloc(), s);
        amount_currency = cur_idx.toOptional();
    }
    const total = (try getBoolField(lua, idx, "total")) orelse false;
    return .{ .amount = amount, .amount_currency = amount_currency, .total = total };
}

fn readPostingLotSpec(rb: *Rebuild, lua: *Lua, idx: i32) ReadEntryError!Data.LotSpec {
    var price: ?Number = null;
    if (try getStringField(lua, idx, "price")) |s| {
        price = Number.fromSlice(s) catch return error.PluginEntryInvalidNumber;
    }
    var price_currency: Data.OptionalCurrencyIndex = .none;
    if (try getStringField(lua, idx, "currency")) |s| {
        const cur_idx = try rb.project.data.currencies.intern(rb.alloc(), s);
        price_currency = cur_idx.toOptional();
    }
    var date: ?Date = null;
    if (try getStringField(lua, idx, "date")) |s| {
        date = Date.fromSlice(s) catch return error.PluginEntryInvalidDate;
    }
    var label: Ast.OptionalTokenIndex = .none;
    if (try getStringField(lua, idx, "label")) |s| {
        label = (try rb.emitString(s)).toOptional();
    }
    return .{ .price = price, .price_currency = price_currency, .date = date, .label = label };
}

fn readOpen(rb: *Rebuild, lua: *Lua, idx: i32) ReadEntryError!Data.Open {
    const account_tok = try readAccountField(rb, lua, idx, "account");

    const cur_start: u32 = @intCast(rb.open_currencies.items.len);
    _ = lua.getField(idx, "currencies");
    if (lua.isTable(-1)) {
        const len = lua.rawLen(-1);
        var i: u32 = 1;
        while (i <= len) : (i += 1) {
            _ = lua.rawGetIndex(-1, @intCast(i));
            defer lua.pop(1);
            if (lua.toString(-1) catch null) |s| {
                const cur_idx = try rb.project.data.currencies.intern(rb.alloc(), s);
                _ = try rb.emitCurrency(s);
                try rb.open_currencies.append(rb.alloc(), cur_idx);
            }
        }
    }
    lua.pop(1);
    const cur_end: u32 = @intCast(rb.open_currencies.items.len);

    var booking_method: ?Inventory.BookingMethod = null;
    if (try getStringField(lua, idx, "booking_method")) |s| {
        booking_method = parseBookingMethod(s) orelse return error.PluginEntryInvalidBookingMethod;
    }

    return .{
        .account = account_tok,
        .booking_method = booking_method,
        .currencies = .{ .start = cur_start, .end = cur_end },
    };
}

fn parseBookingMethod(s: []const u8) ?Inventory.BookingMethod {
    var buf: [16]u8 = undefined;
    if (s.len > buf.len) return null;
    const lower = std.ascii.lowerString(buf[0..s.len], s);
    inline for (@typeInfo(Inventory.BookingMethod).@"enum".fields) |f| {
        if (std.mem.eql(u8, f.name, lower)) return @enumFromInt(f.value);
    }
    return null;
}

fn readBalance(rb: *Rebuild, lua: *Lua, idx: i32) ReadEntryError!Data.Balance {
    const account_tok = try readAccountField(rb, lua, idx, "account");
    const amount_str = (try getStringField(lua, idx, "amount")) orelse return error.PluginEntryMissingField;
    const amount_num = Number.fromSlice(amount_str) catch return error.PluginEntryInvalidNumber;
    const cur_str = (try getStringField(lua, idx, "currency")) orelse return error.PluginEntryMissingField;
    const cur_idx = try rb.project.data.currencies.intern(rb.alloc(), cur_str);
    _ = try rb.emitCurrency(cur_str);

    var tolerance = Data.PackedNumber.none;
    if (try getStringField(lua, idx, "tolerance")) |s| {
        const n = Number.fromSlice(s) catch return error.PluginEntryInvalidNumber;
        tolerance = Data.PackedNumber.pack(n);
    }

    return .{
        .account = account_tok,
        .amount = Data.PackedNumber.pack(amount_num),
        .amount_currency = cur_idx,
        .tolerance = tolerance,
    };
}

fn readPriceDecl(rb: *Rebuild, lua: *Lua, idx: i32) ReadEntryError!Data.PriceDecl {
    const cur_str = (try getStringField(lua, idx, "currency")) orelse return error.PluginEntryMissingField;
    const cur_idx = try rb.project.data.currencies.intern(rb.alloc(), cur_str);
    _ = try rb.emitCurrency(cur_str);

    const amount_cur_str = (try getStringField(lua, idx, "amount_currency")) orelse return error.PluginEntryMissingField;
    const amount_cur_idx = try rb.project.data.currencies.intern(rb.alloc(), amount_cur_str);
    _ = try rb.emitCurrency(amount_cur_str);

    const amount_str = (try getStringField(lua, idx, "amount")) orelse return error.PluginEntryMissingField;
    const amount_num = Number.fromSlice(amount_str) catch return error.PluginEntryInvalidNumber;

    return .{
        .currency = cur_idx,
        .amount_currency = amount_cur_idx,
        .amount_number = Data.PackedNumber.pack(amount_num),
    };
}

fn readAccountField(rb: *Rebuild, lua: *Lua, idx: i32, field: [:0]const u8) ReadEntryError!Ast.TokenIndex {
    const s = (try getStringField(lua, idx, field)) orelse return error.PluginEntryMissingField;
    return try rb.emitAccount(s);
}

fn readCurrencyField(rb: *Rebuild, lua: *Lua, idx: i32, field: [:0]const u8) ReadEntryError!Data.CurrencyIndex {
    const s = (try getStringField(lua, idx, field)) orelse return error.PluginEntryMissingField;
    const cur_idx = try rb.project.data.currencies.intern(rb.alloc(), s);
    _ = try rb.emitCurrency(s);
    return cur_idx;
}

fn readStringField(rb: *Rebuild, lua: *Lua, idx: i32, field: [:0]const u8) ReadEntryError!Ast.TokenIndex {
    const s = (try getStringField(lua, idx, field)) orelse return error.PluginEntryMissingField;
    return try rb.emitString(s);
}

fn readTagsLinks(rb: *Rebuild, lua: *Lua, idx: i32) ReadEntryError!Data.Range {
    const start: u32 = @intCast(rb.tagslinks.len);

    _ = lua.getField(idx, "tags");
    if (lua.isTable(-1)) {
        const len = lua.rawLen(-1);
        var i: u32 = 1;
        while (i <= len) : (i += 1) {
            _ = lua.rawGetIndex(-1, @intCast(i));
            defer lua.pop(1);
            if (lua.toString(-1) catch null) |s| {
                const tok = try rb.emitTag(s);
                try rb.tagslinks.append(rb.alloc(), .{ .kind = .tag, .token = tok, .explicit = true });
            }
        }
    }
    lua.pop(1);

    _ = lua.getField(idx, "links");
    if (lua.isTable(-1)) {
        const len = lua.rawLen(-1);
        var i: u32 = 1;
        while (i <= len) : (i += 1) {
            _ = lua.rawGetIndex(-1, @intCast(i));
            defer lua.pop(1);
            if (lua.toString(-1) catch null) |s| {
                const tok = try rb.emitLink(s);
                try rb.tagslinks.append(rb.alloc(), .{ .kind = .link, .token = tok, .explicit = true });
            }
        }
    }
    lua.pop(1);

    return .{ .start = start, .end = @intCast(rb.tagslinks.len) };
}

fn readEntryMeta(rb: *Rebuild, lua: *Lua, idx: i32) ReadEntryError!Data.Range {
    return try readMetaTable(rb, lua, idx, "meta");
}

fn readPostingMeta(rb: *Rebuild, lua: *Lua, idx: i32) ReadEntryError!Data.Range {
    return try readMetaTable(rb, lua, idx, "meta");
}

fn readMetaTable(rb: *Rebuild, lua: *Lua, idx: i32, field: [:0]const u8) ReadEntryError!Data.Range {
    const start: u32 = @intCast(rb.meta.len);

    _ = lua.getField(idx, field);
    defer lua.pop(1);
    if (!lua.isTable(-1)) return .{ .start = start, .end = start };

    lua.pushNil();
    while (lua.next(-2)) {
        // Stack: ..., key, value
        defer lua.pop(1); // pop value, leave key for next iteration
        const key_str = (lua.toString(-2) catch null) orelse continue;
        const val_str = (lua.toString(-1) catch null) orelse continue;
        const key_tok = try rb.emitMetaKey(key_str);
        const val_tok = try rb.emitString(val_str);
        try rb.meta.append(rb.alloc(), .{ .key = key_tok, .value = val_tok });
    }

    return .{ .start = start, .end = @intCast(rb.meta.len) };
}

fn getStringField(lua: *Lua, idx: i32, field: [:0]const u8) !?[]const u8 {
    _ = lua.getField(idx, field);
    defer lua.pop(1);
    if (lua.isNil(-1)) return null;
    if (!lua.isString(-1)) return null;
    return lua.toString(-1) catch null;
}

fn getBoolField(lua: *Lua, idx: i32, field: [:0]const u8) !?bool {
    _ = lua.getField(idx, field);
    defer lua.pop(1);
    if (lua.isNil(-1)) return null;
    if (!lua.isBoolean(-1)) return null;
    return lua.toBoolean(-1);
}
