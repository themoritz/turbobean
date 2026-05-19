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

// --- entry & posting userdata ----------------------------------------------
//
// Three userdata types model the entry/posting object graph lazily.
//
// EntryUD wraps an index into `Data.entries`. Its user values:
//   uv1 — full cached entry table (set by `pushEntry` on first non-leaf read
//         or any write). When present, the userdata behaves as a thin proxy
//         around it.
//   uv2 — PostingListUD created when the plugin reads `e.postings`. Lets
//         postings be inspected/mutated without forcing the parent entry
//         to materialize.
//
// PostingListUD wraps the parent entry idx. Its uv1 is a sparse Lua array
// caching PostingUDs by 1-based index, so `postings[i]` returns the same
// identity each call.
//
// PostingUD wraps (entry_idx, offset). Its uv1 is either:
//   - a sparse overlay table (set when the plugin writes a field), or
//   - a fully-materialized posting table (set when the plugin reads a
//     non-leaf field like `price`).
// Readback treats both shapes the same: "uv1 present → this posting was
// touched". Pristine postings (uv1 nil) bubble up to entry-level passthrough.
//
// Why all this matters: a filter that reads `p.account` over 70k postings
// never triggers materialization for any of them, so all 40k parent
// entries take the passthrough path. Compare to the pre-userdata model
// which always paid the full per-entry/per-posting push cost up front.

const EntryUD = extern struct {
    /// Index into `Data.entries`. Stable for the run.
    idx: u32,
};

const PostingListUD = extern struct {
    /// Parent entry's index into `Data.entries`.
    entry_idx: u32,
};

const PostingUD = extern struct {
    entry_idx: u32,
    /// Zero-based position within the parent entry's postings range.
    offset: u32,
};

const ENTRY_MT_KEY: [:0]const u8 = "turbobean.entry_mt";
const POSTING_LIST_MT_KEY: [:0]const u8 = "turbobean.posting_list_mt";
const POSTING_MT_KEY: [:0]const u8 = "turbobean.posting_mt";

/// Install all three metatables into the registry once per run. Each
/// metamethod gets `*Origin` as a light-userdata upvalue so hot paths reach
/// project data without a registry lookup.
fn installMetatables(lua: *Lua, origin: *Origin) !void {
    lua.newMetatable(ENTRY_MT_KEY) catch {};
    lua.pushLightUserdata(@ptrCast(origin));
    lua.pushClosure(entryIndexC, 1);
    lua.setField(-2, "__index");
    lua.pushLightUserdata(@ptrCast(origin));
    lua.pushClosure(entryNewindexC, 1);
    lua.setField(-2, "__newindex");
    lua.pushLightUserdata(@ptrCast(origin));
    lua.pushClosure(entryPairsC, 1);
    lua.setField(-2, "__pairs");
    lua.pop(1);

    lua.newMetatable(POSTING_LIST_MT_KEY) catch {};
    lua.pushLightUserdata(@ptrCast(origin));
    lua.pushClosure(postingListIndexC, 1);
    lua.setField(-2, "__index");
    lua.pushLightUserdata(@ptrCast(origin));
    lua.pushClosure(postingListLenC, 1);
    lua.setField(-2, "__len");
    lua.pop(1);

    lua.newMetatable(POSTING_MT_KEY) catch {};
    lua.pushLightUserdata(@ptrCast(origin));
    lua.pushClosure(postingIndexC, 1);
    lua.setField(-2, "__index");
    lua.pushLightUserdata(@ptrCast(origin));
    lua.pushClosure(postingNewindexC, 1);
    lua.setField(-2, "__newindex");
    lua.pushLightUserdata(@ptrCast(origin));
    lua.pushClosure(postingPairsC, 1);
    lua.setField(-2, "__pairs");
    lua.pop(1);
}

/// `__index` for entry userdata. Three paths in priority order:
///   1) Cached materialized table exists → rawget from it. (Includes the
///      post-write case: any prior `__newindex` will have populated the
///      cache, so all subsequent reads route through it and see the write.)
///   2) Pristine + key is a known leaf string field → push the value
///      straight from Data. No materialization, so the entry stays pristine
///      and gets the passthrough path at readback.
///   3) Otherwise → materialize (which fills the cache with all fields),
///      then rawget.
fn entryIndexC(state: ?*zlua.LuaState) callconv(.c) c_int {
    const lua: *Lua = @ptrCast(state.?);
    // Stack: [self, key]
    const t = lua.getUserValue(1, 1) catch {
        lua.pushNil();
        return 1;
    };
    // Stack: [self, key, uvalue]

    if (t == .table) {
        lua.pushValue(2);
        _ = lua.rawGetTable(-2);
        return 1;
    }

    // No cache. Drop the nil uvalue and try the special / leaf fast paths
    // before committing to a full materialization.
    lua.pop(1);
    if (tryPostingsAccess(lua)) return 1;
    if (tryLeafIndex(lua)) return 1;

    materializeAndRawGet(lua) catch {
        lua.pushNil();
        return 1;
    };
    return 1;
}

/// Handle `e.postings` specifically: returns (and caches in entry.uv2) a
/// PostingListUD that lets the plugin walk postings without materializing
/// the parent entry. Returns true (with a value on the stack) iff the key
/// is `"postings"`.
fn tryPostingsAccess(lua: *Lua) bool {
    if (!lua.isString(2)) return false;
    const key = lua.toString(2) catch return false;
    if (!std.mem.eql(u8, key, "postings")) return false;

    const origin = lua.toUserdata(Origin, Lua.upvalueIndex(1)) catch {
        lua.pushNil();
        return true;
    };
    const ud = lua.toUserdata(EntryUD, 1) catch {
        lua.pushNil();
        return true;
    };
    if (ud.idx >= origin.project.data.entries.len) {
        lua.pushNil();
        return true;
    }
    const view = origin.project.data.entryAt(ud.idx);
    if (view.tag() != .transaction) {
        lua.pushNil();
        return true;
    }

    // Cached? uv2 holds the PostingListUD across reads for identity.
    const cached = lua.getUserValue(1, 2) catch {
        lua.pushNil();
        return true;
    };
    if (cached == .userdata) return true;
    lua.pop(1);

    const pl = lua.newUserdata(PostingListUD, 1);
    pl.entry_idx = ud.idx;
    lua.setMetatableRegistry(POSTING_LIST_MT_KEY);
    lua.pushValue(-1);
    lua.setUserValue(1, 2) catch {};
    return true;
}

/// If the key is a recognized leaf field name, push the corresponding
/// value directly from Data and return true. Otherwise leave the stack
/// untouched and return false so the caller can fall back to materializing.
fn tryLeafIndex(lua: *Lua) bool {
    // The Lua "is string" check accepts numeric keys (auto-stringifiable);
    // matching on a stringified number will simply miss our key set, so we
    // don't need to filter those out explicitly.
    if (!lua.isString(2)) return false;
    const key = lua.toString(2) catch return false;
    const origin = lua.toUserdata(Origin, Lua.upvalueIndex(1)) catch return false;
    const ud = lua.toUserdata(EntryUD, 1) catch return false;
    if (ud.idx >= origin.project.data.entries.len) return false;
    const view = origin.project.data.entryAt(ud.idx);
    return pushLeafField(lua, origin.project, view, key);
}

fn materializeAndRawGet(lua: *Lua) !void {
    try ensureEntryMaterialized(lua);
    // Stack: [self, key, cache]
    lua.pushValue(2);
    _ = lua.rawGetTable(-2);
    // Stack: [self, key, cache, value]; collapse to [..., value].
    lua.remove(-2);
}

// --- PostingListUD callbacks ----------------------------------------------

/// Range of `Data.postings` for the entry at `entry_idx`, or null if the
/// entry isn't a transaction.
fn postingRangeOf(data: *Data, entry_idx: u32) ?Data.Range {
    if (entry_idx >= data.entries.len) return null;
    const payload = data.entries.items(.payload)[entry_idx];
    return switch (payload) {
        .transaction => |tx| tx.postings,
        else => null,
    };
}

fn postingListIndexC(state: ?*zlua.LuaState) callconv(.c) c_int {
    const lua: *Lua = @ptrCast(state.?);
    // Stack: [self, key]
    if (!lua.isInteger(2)) {
        lua.pushNil();
        return 1;
    }
    const n = lua.toInteger(2) catch {
        lua.pushNil();
        return 1;
    };
    const origin = lua.toUserdata(Origin, Lua.upvalueIndex(1)) catch {
        lua.pushNil();
        return 1;
    };
    const pl = lua.toUserdata(PostingListUD, 1) catch {
        lua.pushNil();
        return 1;
    };
    const range = postingRangeOf(&origin.project.data, pl.entry_idx) orelse {
        lua.pushNil();
        return 1;
    };
    const size: u32 = range.end - range.start;
    if (n < 1 or n > size) {
        lua.pushNil();
        return 1;
    }

    // Lazy-create or fetch the identity cache (a Lua array on uv1).
    const cache_t = lua.getUserValue(1, 1) catch {
        lua.pushNil();
        return 1;
    };
    if (cache_t != .table) {
        lua.pop(1);
        lua.createTable(@intCast(size), 0);
        lua.pushValue(-1);
        lua.setUserValue(1, 1) catch {};
    }
    // Stack: [self, key, cache]

    const existing = lua.rawGetIndex(-1, @intCast(n));
    if (existing != .nil) {
        lua.remove(-2); // drop cache, leave posting userdata
        return 1;
    }
    lua.pop(1); // drop nil

    const pu = lua.newUserdata(PostingUD, 1);
    pu.entry_idx = pl.entry_idx;
    pu.offset = @intCast(n - 1);
    lua.setMetatableRegistry(POSTING_MT_KEY);
    // Cache for identity, then leave the userdata on top.
    lua.pushValue(-1);
    lua.rawSetIndex(-3, @intCast(n));
    lua.remove(-2); // drop cache
    return 1;
}

fn postingListLenC(state: ?*zlua.LuaState) callconv(.c) c_int {
    const lua: *Lua = @ptrCast(state.?);
    const origin = lua.toUserdata(Origin, Lua.upvalueIndex(1)) catch {
        lua.pushInteger(0);
        return 1;
    };
    const pl = lua.toUserdata(PostingListUD, 1) catch {
        lua.pushInteger(0);
        return 1;
    };
    const range = postingRangeOf(&origin.project.data, pl.entry_idx) orelse {
        lua.pushInteger(0);
        return 1;
    };
    lua.pushInteger(@intCast(range.end - range.start));
    return 1;
}

// --- PostingUD callbacks --------------------------------------------------

fn postingViewAt(data: *Data, entry_idx: u32, offset: u32) ?Data.PostingView {
    const range = postingRangeOf(data, entry_idx) orelse return null;
    if (offset >= range.end - range.start) return null;
    const view = data.entryAt(entry_idx);
    return Data.PostingView{ .data = data, .file = view.file(), .idx = range.start + offset };
}

fn postingIndexC(state: ?*zlua.LuaState) callconv(.c) c_int {
    const lua: *Lua = @ptrCast(state.?);
    // Stack: [self, key]
    // uv1 may hold either a sparse write-overlay or a fully-materialized
    // posting table (set by a previous non-leaf read). In either case we
    // check the table first: it wins over the leaf path because the plugin
    // might have written there.
    const t = lua.getUserValue(1, 1) catch {
        lua.pushNil();
        return 1;
    };
    if (t == .table) {
        lua.pushValue(2);
        _ = lua.rawGetTable(-2);
        if (!lua.isNil(-1)) {
            lua.remove(-2); // drop the overlay/cache table, leave value
            return 1;
        }
        lua.pop(2); // drop nil + overlay
    } else {
        lua.pop(1);
    }

    // Leaf fast path for read-only access — keeps the posting pristine
    // so its parent entry can passthrough.
    if (tryPostingLeafIndex(lua)) return 1;

    // Non-leaf (price, lot_spec, meta, etc.) → materialize the full posting
    // into uv1 as a Lua table and rawget from it.
    materializePostingAndRawGet(lua) catch {
        lua.pushNil();
        return 1;
    };
    return 1;
}

fn postingNewindexC(state: ?*zlua.LuaState) callconv(.c) c_int {
    const lua: *Lua = @ptrCast(state.?);
    // Stack: [self, key, value]
    ensurePostingOverlay(lua) catch return 0;
    // Stack: [self, key, value, overlay]
    lua.pushValue(2);
    lua.pushValue(3);
    lua.rawSetTable(-3);
    lua.pop(1);
    return 0;
}

/// `__pairs` for entries. Materializes the entry fully and returns
/// `(next, cache_table, nil)` — Lua then iterates the cache as a normal
/// table. Cost: same as today's eager push for this one entry, paid only
/// on `pairs(e)` access.
fn entryPairsC(state: ?*zlua.LuaState) callconv(.c) c_int {
    const lua: *Lua = @ptrCast(state.?);
    ensureEntryMaterialized(lua) catch {
        lua.pushNil();
        lua.pushNil();
        lua.pushNil();
        return 3;
    };
    // Stack: [self, cache]
    _ = lua.getGlobal("next") catch {
        lua.pushNil();
        lua.pushNil();
        lua.pushNil();
        return 3;
    };
    // Stack: [self, cache, next]
    lua.pushValue(-2); // cache
    lua.pushNil();
    return 3;
}

/// `__pairs` for postings. If the posting already has a cache table on uv1
/// (sparse overlay OR full materialization), iterate that. Otherwise
/// materialize fully via `pushPosting`. Plugins that only need leaf reads
/// shouldn't be using `pairs(p)` — but if they do, this falls back to the
/// safe-but-eager path.
fn postingPairsC(state: ?*zlua.LuaState) callconv(.c) c_int {
    const lua: *Lua = @ptrCast(state.?);
    const t = lua.getUserValue(1, 1) catch .nil;
    if (t != .table) {
        lua.pop(1);
        const origin = lua.toUserdata(Origin, Lua.upvalueIndex(1)) catch {
            lua.pushNil();
            lua.pushNil();
            lua.pushNil();
            return 3;
        };
        const pu = lua.toUserdata(PostingUD, 1) catch {
            lua.pushNil();
            lua.pushNil();
            lua.pushNil();
            return 3;
        };
        const pv = postingViewAt(&origin.project.data, pu.entry_idx, pu.offset) orelse {
            lua.pushNil();
            lua.pushNil();
            lua.pushNil();
            return 3;
        };
        pushPosting(lua, origin, pv) catch {
            lua.pushNil();
            lua.pushNil();
            lua.pushNil();
            return 3;
        };
        lua.pushValue(-1);
        lua.setUserValue(1, 1) catch {};
    }
    // Stack: [self, cache]
    _ = lua.getGlobal("next") catch {
        lua.pushNil();
        lua.pushNil();
        lua.pushNil();
        return 3;
    };
    lua.pushValue(-2);
    lua.pushNil();
    return 3;
}

/// Lazy-create an empty overlay table on the posting userdata's uv1 if it
/// doesn't already hold one. Leaves the table on top of the stack.
fn ensurePostingOverlay(lua: *Lua) !void {
    const t = try lua.getUserValue(1, 1);
    if (t == .table) return;
    lua.pop(1);
    // Hint for the ~6 leaf fields a plugin might write.
    lua.createTable(0, 6);
    lua.pushValue(-1);
    try lua.setUserValue(1, 1);
}

/// Materialize the posting fully via the existing `pushPosting` helper and
/// stash the result on uv1, then `rawGetTable` with the requested key.
/// Used when the plugin reads a non-leaf field.
fn materializePostingAndRawGet(lua: *Lua) !void {
    const origin = try lua.toUserdata(Origin, Lua.upvalueIndex(1));
    const pu = try lua.toUserdata(PostingUD, 1);
    const pv = postingViewAt(&origin.project.data, pu.entry_idx, pu.offset) orelse return error.PostingViewMissing;
    try pushPosting(lua, origin, pv);
    // Stack: [self, key, table]
    lua.pushValue(-1);
    try lua.setUserValue(1, 1);
    // Stack: [self, key, table]
    lua.pushValue(2);
    _ = lua.rawGetTable(-2);
    lua.remove(-2);
}

/// Leaf fast path for posting fields. Mirrors the per-posting fields in
/// `pushPosting`: account, amount, currency, flag.
fn tryPostingLeafIndex(lua: *Lua) bool {
    if (!lua.isString(2)) return false;
    const key = lua.toString(2) catch return false;
    const origin = lua.toUserdata(Origin, Lua.upvalueIndex(1)) catch return false;
    const pu = lua.toUserdata(PostingUD, 1) catch return false;
    const pv = postingViewAt(&origin.project.data, pu.entry_idx, pu.offset) orelse return false;

    if (std.mem.eql(u8, key, "account")) {
        _ = lua.pushString(pv.accountText());
        return true;
    }
    if (std.mem.eql(u8, key, "amount")) {
        if (pv.amountNumber()) |n| {
            pushNumberStr(lua, n) catch lua.pushNil();
        } else {
            lua.pushNil();
        }
        return true;
    }
    if (std.mem.eql(u8, key, "currency")) {
        if (pv.amountCurrencyText()) |c| {
            _ = lua.pushString(c);
        } else {
            lua.pushNil();
        }
        return true;
    }
    if (std.mem.eql(u8, key, "flag")) {
        if (pv.flag().unwrap()) |f| {
            const fdata = &origin.project.data.files.items[pv.file];
            _ = lua.pushString(fdata.tokenSlice(f));
        } else {
            lua.pushNil();
        }
        return true;
    }
    return false;
}

/// Push the value for a recognized leaf field directly from Data and
/// return true. Returns false if `key` isn't a leaf field on this entry
/// shape — caller then falls back to full materialization.
///
/// "Leaf" here means a single-value field: strings, dates, numbers. The
/// container-shaped fields (`postings`, `tags`, `links`, `meta`, the
/// `currencies` list on open, the `price` / `lot_spec` sub-tables on
/// postings) need a Lua table the plugin can iterate / mutate, so they
/// always fall through to materialization.
///
/// Field set mirrors the per-payload `push*` helpers below — kept in sync
/// by inspection. Adding a new payload field requires touching both.
fn pushLeafField(lua: *Lua, project: *Project, view: Data.EntryView, key: []const u8) bool {
    // Universal.
    if (std.mem.eql(u8, key, "type")) {
        pushTypeStr(lua, view.tag());
        return true;
    }
    if (std.mem.eql(u8, key, "date")) {
        pushDate(lua, view.date());
        return true;
    }

    switch (view.payload()) {
        .transaction => |tx| {
            if (std.mem.eql(u8, key, "flag")) {
                _ = lua.pushString(tx.flagSlice());
                return true;
            }
            if (std.mem.eql(u8, key, "payee")) {
                if (tx.payeeText()) |p| {
                    _ = lua.pushString(stripQuotes(p));
                } else {
                    lua.pushNil();
                }
                return true;
            }
            if (std.mem.eql(u8, key, "narration")) {
                if (tx.narrationText()) |n| {
                    _ = lua.pushString(stripQuotes(n));
                } else {
                    lua.pushNil();
                }
                return true;
            }
        },
        .open => |o| {
            if (std.mem.eql(u8, key, "account")) {
                _ = lua.pushString(o.accountText());
                return true;
            }
            if (std.mem.eql(u8, key, "booking_method")) {
                if (o.bookingMethod()) |bm| {
                    var buf: [16]u8 = undefined;
                    const upper = std.ascii.upperString(&buf, @tagName(bm));
                    _ = lua.pushString(upper);
                } else {
                    lua.pushNil();
                }
                return true;
            }
        },
        .close => |c| {
            if (std.mem.eql(u8, key, "account")) {
                _ = lua.pushString(c.accountText());
                return true;
            }
        },
        .balance => |b| {
            if (std.mem.eql(u8, key, "account")) {
                _ = lua.pushString(b.accountText());
                return true;
            }
            if (std.mem.eql(u8, key, "amount")) {
                pushNumberStr(lua, b.amount) catch lua.pushNil();
                return true;
            }
            if (std.mem.eql(u8, key, "currency")) {
                _ = lua.pushString(b.amountCurrencyText());
                return true;
            }
            if (std.mem.eql(u8, key, "tolerance")) {
                if (b.tolerance) |tol| {
                    pushNumberStr(lua, tol) catch lua.pushNil();
                } else {
                    lua.pushNil();
                }
                return true;
            }
        },
        .pad => |p| {
            const fdata = &project.data.files.items[p.file];
            if (std.mem.eql(u8, key, "account")) {
                _ = lua.pushString(fdata.tokenSlice(p.pad.account));
                return true;
            }
            if (std.mem.eql(u8, key, "pad_to")) {
                _ = lua.pushString(fdata.tokenSlice(p.pad.pad_to));
                return true;
            }
        },
        .pnl => |pnl| {
            if (std.mem.eql(u8, key, "account")) {
                _ = lua.pushString(view.tokenSlice(pnl.account));
                return true;
            }
            if (std.mem.eql(u8, key, "income_account")) {
                _ = lua.pushString(view.tokenSlice(pnl.income_account));
                return true;
            }
        },
        .commodity => |c| {
            if (std.mem.eql(u8, key, "currency")) {
                _ = lua.pushString(project.data.currencyText(c.currency));
                return true;
            }
        },
        .price => |pd| {
            if (std.mem.eql(u8, key, "currency")) {
                _ = lua.pushString(pd.currencyText());
                return true;
            }
            if (std.mem.eql(u8, key, "amount")) {
                pushNumberStr(lua, pd.amount) catch lua.pushNil();
                return true;
            }
            if (std.mem.eql(u8, key, "amount_currency")) {
                _ = lua.pushString(pd.amountCurrencyText());
                return true;
            }
        },
        .event => |e| {
            if (std.mem.eql(u8, key, "variable")) {
                _ = lua.pushString(stripQuotes(view.tokenSlice(e.variable)));
                return true;
            }
            if (std.mem.eql(u8, key, "value")) {
                _ = lua.pushString(stripQuotes(view.tokenSlice(e.value)));
                return true;
            }
        },
        .query => |q| {
            if (std.mem.eql(u8, key, "name")) {
                _ = lua.pushString(stripQuotes(view.tokenSlice(q.name)));
                return true;
            }
            if (std.mem.eql(u8, key, "sql")) {
                _ = lua.pushString(stripQuotes(view.tokenSlice(q.sql)));
                return true;
            }
        },
        .note => |n| {
            if (std.mem.eql(u8, key, "account")) {
                _ = lua.pushString(view.tokenSlice(n.account));
                return true;
            }
            if (std.mem.eql(u8, key, "note")) {
                _ = lua.pushString(stripQuotes(view.tokenSlice(n.note)));
                return true;
            }
        },
        .document => |d| {
            if (std.mem.eql(u8, key, "account")) {
                _ = lua.pushString(view.tokenSlice(d.account));
                return true;
            }
            if (std.mem.eql(u8, key, "filename")) {
                _ = lua.pushString(stripQuotes(view.tokenSlice(d.filename)));
                return true;
            }
        },
    }
    return false;
}

/// `__newindex` for entry userdata. Materializes if needed, then `rawset`s.
fn entryNewindexC(state: ?*zlua.LuaState) callconv(.c) c_int {
    const lua: *Lua = @ptrCast(state.?);
    // Stack: [self, key, value]
    ensureEntryMaterialized(lua) catch return 0;
    // Stack: [self, key, value, cached_table]
    lua.pushValue(2);
    lua.pushValue(3);
    lua.rawSetTable(-3);
    lua.pop(1);
    return 0;
}

/// Ensure user value 1 of the userdata at stack index 1 holds a table; if
/// it was nil, materialize via the regular `pushEntry` path and stash the
/// result. On return the cached table is at the top of the stack.
fn ensureEntryMaterialized(lua: *Lua) !void {
    const t = try lua.getUserValue(1, 1);
    if (t == .table) return;
    lua.pop(1);
    const origin = try lua.toUserdata(Origin, Lua.upvalueIndex(1));
    const ud = try lua.toUserdata(EntryUD, 1);
    const view = origin.project.data.entryAt(ud.idx);
    try pushEntry(lua, origin, view);
    // Stack: [..., table]
    lua.pushValue(-1);
    try lua.setUserValue(1, 1);
}

pub fn run(project: *Project) !void {
    const plugins = project.data.config.plugins.items;
    if (plugins.len == 0) return;
    if (project.data.files.items.len == 0) return;

    // One Lua state and one Origin for the whole pipeline. Entries flow in
    // Lua space across plugin calls; we only do Data <-> Lua at the ends,
    // regardless of how many plugins run.
    // Lua manages its own memory lifecycle: `lua_close` walks every
    // object and frees it. Leak detection on its internal churn is wasted
    // work, and in ReleaseSafe the per-alloc stack-trace capture in
    // DebugAllocator dominates the profile. Hand Lua the fast allocator
    // even in safe builds — everything else keeps the debug allocator.
    const lua = try Lua.init(std.heap.smp_allocator);
    defer lua.deinit();
    lua.openLibs();
    // Bulk Data <-> Lua transfer reuses tables that stay reachable from the
    // outer entries list, so there's nothing to collect. Stop the GC so
    // luaC_step doesn't fire on every allocation; the state is torn down at
    // function exit, which frees everything in one shot.
    lua.gcStop();

    var origin = Origin{
        .project = project,
        .plugin = "",
        .plugin_loc = .{ .file_id = plugins[0].file_id, .index = plugins[0].token },
        .arena = std.heap.ArenaAllocator.init(project.alloc),
    };
    defer origin.deinit();

    try installMetatables(lua, &origin);

    // Data -> Lua (once).
    try pushEntries(lua, &origin);
    // Stack: [entries]

    var any_ran = false;
    for (plugins) |ref| {
        if (try invokePlugin(lua, &origin, ref)) any_ran = true;
    }

    // Stack: [final_entries]. Apply once if at least one plugin ran; if none
    // did (e.g. all failed to load), the original Data is left untouched.
    if (any_ran) try applyEntries(&origin, lua, -1);
    lua.pop(1);
}

/// Invoke one plugin. Expects [entries] on top of the Lua stack on entry and
/// leaves [entries] on top on exit (possibly replaced by the plugin's
/// returned table). Returns true if the plugin function ran (even if it
/// raised a Lua error); false on load failures.
fn invokePlugin(lua: *Lua, origin: *Origin, ref: Data.Config.PluginRef) !bool {
    const project = origin.project;
    const arena = project.plugin_arena.allocator();

    const name = stripQuotes(ref.name);
    const loc: Data.TokenLoc = .{ .file_id = ref.file_id, .index = ref.token };
    origin.plugin = name;
    origin.plugin_loc = loc;

    const root_dir = std.fs.path.dirname(project.rootUri().absolute()) orelse ".";
    const abs_path = try std.fmt.allocPrint(arena, "{s}/{s}.lua", .{ root_dir, name });

    // Read the source ourselves so error messages don't leak the absolute path.
    const source = std.fs.cwd().readFileAlloc(arena, abs_path, 1 << 24) catch |err| switch (err) {
        error.FileNotFound => {
            try appendPluginError(project, loc, .{ .plugin_load_failed = .{
                .plugin = try arena.dupe(u8, name),
                .message = try std.fmt.allocPrint(arena, "{s}.lua not found", .{name}),
            } });
            return false;
        },
        else => |e| {
            try appendPluginError(project, loc, .{ .plugin_load_failed = .{
                .plugin = try arena.dupe(u8, name),
                .message = try std.fmt.allocPrint(arena, "could not read {s}.lua: {s}", .{ name, @errorName(e) }),
            } });
            return false;
        },
    };
    // The leading `=` tells Lua to use the rest verbatim in error messages;
    // without it Lua wraps the chunk name as `[string "..."]`. We use
    // `<name>.lua` so errors read like `foo.lua:2: <msg>`.
    const chunkname = try std.fmt.allocPrintSentinel(arena, "={s}.lua", .{name}, 0);

    // Stack: [entries]. Load the chunk and evaluate it to obtain the plugin
    // function — pushed on top of `entries`. On failure Lua leaves the error
    // message on top, which we drop after capturing.
    lua.loadBuffer(source, chunkname, .text) catch |err| {
        try addLoadError(project, loc, name, lua, err);
        lua.pop(1);
        return false;
    };
    lua.protectedCall(.{ .results = 1 }) catch |err| {
        try addLoadError(project, loc, name, lua, err);
        lua.pop(1);
        return false;
    };
    if (!lua.isFunction(-1)) {
        try addLoadError(project, loc, name, null, error.PluginScriptDidNotReturnFunction);
        lua.pop(1);
        return false;
    }
    // Stack: [entries, plugin_fn]. Duplicate `entries` as the call argument
    // so we can fall back to it if the plugin returns nil.
    lua.pushValue(-2);
    // Stack: [entries, plugin_fn, entries_arg].
    lua.protectedCall(.{ .args = 1, .results = 2 }) catch |err| {
        try addRuntimeError(project, loc, name, lua, err);
        lua.pop(1);
        // Stack: [entries] — entries unchanged for the next plugin.
        return true;
    };
    // Stack: [entries, new_entries, errors].
    try readErrors(origin, lua, -1);
    lua.pop(1);
    // Stack: [entries, new_entries].
    if (lua.isNil(-1)) {
        // Plugin returned nothing — keep the input table (which the plugin
        // may have mutated in place).
        lua.pop(1);
    } else {
        // Replace `entries` with `new_entries`.
        lua.remove(-2);
    }
    return true;
}

fn stripQuotes(s: []const u8) []const u8 {
    if (s.len >= 2 and s[0] == '"' and s[s.len - 1] == '"') return s[1 .. s.len - 1];
    return s;
}

// --- origin side-table ------------------------------------------------------
//
// Every entry/posting we hand to the plugin gets a `_origin` integer ID that
// indexes into `Origin.entries` / `Origin.postings`. All source-loc info we
// need on the way back lives in those Zig-side arrays, so the Lua tables
// stay clean (one hidden int per entity) and the plugin author never sees
// `_loc` / `_account_loc` / parallel `_tag_locs` clutter.
//
// Entries the plugin builds from scratch have no `_origin`; reads fall back
// to the plugin directive's loc.

const Origin = struct {
    project: *Project,
    plugin: []const u8,
    /// Fallback loc for entries/postings that have no recorded origin
    /// (typically: plugin-built from scratch). Points at the `plugin "..."`
    /// directive.
    plugin_loc: Data.TokenLoc,
    /// Owns slices stored in `EntryOrigin.tag_locs` / `link_locs`.
    arena: std.heap.ArenaAllocator,

    entries: std.ArrayList(EntryOrigin) = .empty,
    postings: std.ArrayList(PostingOrigin) = .empty,

    const EntryOrigin = struct {
        /// The entry-level token (date / main token of the source entry).
        entry: Data.TokenLoc,
        /// Account token for entries that have one (open/close/balance/pad/
        /// pnl/note/document). Falls back to `entry` when null.
        account: ?Data.TokenLoc = null,
        /// Second account token for `pad.pad_to` and `pnl.income_account`.
        account2: ?Data.TokenLoc = null,
        /// Per-tag origin loc, parallel to source `entry.tags` order. If the
        /// plugin reorders/inserts tags, indices past the original count
        /// fall back to `entry`.
        tag_locs: []const Data.TokenLoc = &.{},
        link_locs: []const Data.TokenLoc = &.{},
    };

    const PostingOrigin = struct {
        /// The posting's account token in the source file.
        account: Data.TokenLoc,
    };

    fn deinit(self: *Origin) void {
        self.entries.deinit(self.project.alloc);
        self.postings.deinit(self.project.alloc);
        self.arena.deinit();
    }

    /// Reserve an entry-origin slot up front so we can stamp `_origin = id`
    /// on the Lua table before populating the loc fields. Returns the new
    /// slot index. Caller fills `entries.items[id]` while pushing children.
    fn reserveEntry(self: *Origin) !u32 {
        const id: u32 = @intCast(self.entries.items.len);
        try self.entries.append(self.project.alloc, .{ .entry = self.plugin_loc });
        return id;
    }

    fn reservePosting(self: *Origin, account_loc: Data.TokenLoc) !u32 {
        const id: u32 = @intCast(self.postings.items.len);
        try self.postings.append(self.project.alloc, .{ .account = account_loc });
        return id;
    }

    /// Look up an entry origin by `_origin` field on the Lua table.
    /// For userdata entries, returns an origin derived from the userdata's
    /// `idx` (the cached materialized table's stamped `_origin` is preferred
    /// when present, since it carries account/tag locs filled by pushEntry).
    /// Returns null if neither form is recognized.
    fn entryOf(self: *const Origin, lua: *Lua, table_idx: i32) ?EntryOrigin {
        if (lua.isUserdata(table_idx)) {
            // Read idx from the userdata *before* we push anything new on
            // the stack — a negative `table_idx` would otherwise drift to
            // a different slot the moment we push the uvalue.
            const ud = lua.toUserdata(EntryUD, table_idx) catch return null;
            if (ud.idx >= self.project.data.entries.len) return null;

            // Prefer the cached materialized table when available: its
            // origin slot has account/tag_locs filled by `pushEntry`.
            const t = lua.getUserValue(table_idx, 1) catch return null;
            defer lua.pop(1);
            if (t == .table) {
                const id = readOriginId(lua, -1) orelse return null;
                if (id >= self.entries.items.len) return null;
                return self.entries.items[id];
            }
            // Pristine userdata — entry never materialized, so we only
            // have the entry-level loc (no account/tag_locs).
            const view = self.project.data.entryAt(ud.idx);
            return .{ .entry = .{ .file_id = view.file(), .index = view.mainToken() } };
        }
        const id = readOriginId(lua, table_idx) orelse return null;
        if (id >= self.entries.items.len) return null;
        return self.entries.items[id];
    }

    fn postingOf(self: *const Origin, lua: *Lua, table_idx: i32) ?PostingOrigin {
        if (lua.isUserdata(table_idx)) {
            // Read fields before pushing anything (else negative index drifts).
            const pu = lua.toUserdata(PostingUD, table_idx) catch return null;
            // Look for a stamped `_origin` on the materialized posting table
            // (set when `pushPosting` ran during a non-leaf access). That
            // gives us the populated origin slot with full loc info.
            const t = lua.getUserValue(table_idx, 1) catch return null;
            defer lua.pop(1);
            if (t == .table) {
                if (readOriginId(lua, -1)) |id| {
                    if (id < self.postings.items.len) return self.postings.items[id];
                }
            }
            // Pristine posting (no full materialization). Derive the
            // account loc straight from Data.
            const pv = postingViewAt(@constCast(&self.project.data), pu.entry_idx, pu.offset) orelse return null;
            return .{ .account = pv.accountLoc() };
        }
        const id = readOriginId(lua, table_idx) orelse return null;
        if (id >= self.postings.items.len) return null;
        return self.postings.items[id];
    }
};

/// Stamp `_origin = id` on the table at the top of the Lua stack.
fn pushOriginId(lua: *Lua, id: u32) void {
    lua.pushInteger(@intCast(id));
    lua.setField(-2, "_origin");
}

/// Read `_origin` from the table at `idx`. Returns null if missing or out of
/// range for u32.
fn readOriginId(lua: *Lua, idx: i32) ?u32 {
    if (!lua.isTable(idx)) return null;
    _ = lua.getField(idx, "_origin");
    defer lua.pop(1);
    if (lua.isNil(-1)) return null;
    const n = lua.toInteger(-1) catch return null;
    if (n < 0 or n > std.math.maxInt(u32)) return null;
    return @intCast(n);
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
            // The Lua message already includes `<chunk>:<line>: <reason>`.
            // The Zig error name (e.g. `LuaRuntime`) adds no signal — drop it.
            if (s) |slice| return try arena.dupe(u8, slice);
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

fn readErrors(origin: *Origin, lua: *Lua, idx: i32) !void {
    const project = origin.project;
    const name = origin.plugin;
    const loc = origin.plugin_loc;
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
            if (origin.postingOf(lua, -1)) |po| attached = po.account;
            lua.pop(1);

            if (attached == null) {
                _ = lua.getField(-1, "entry");
                if (origin.entryOf(lua, -1)) |eo| attached = eo.entry;
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

fn pushEntries(lua: *Lua, origin: *Origin) !void {
    const data = &origin.project.data;
    const n = data.entries.len;
    lua.createTable(@intCast(n), 0);

    // Create one userdata per entry and let lazy materialization populate
    // them on demand. Untouched entries take the passthrough path in
    // `applyEntries`.
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        // 2 user values: uv1 = cached entry table, uv2 = PostingListUD.
        // Both start nil and get populated lazily.
        const ud = lua.newUserdata(EntryUD, 2);
        ud.idx = i;
        lua.setMetatableRegistry(ENTRY_MT_KEY);
        lua.rawSetIndex(-2, @intCast(i + 1));
    }
}

fn pushEntry(lua: *Lua, origin: *Origin, entry: Data.EntryView) !void {
    const project = origin.project;

    const id = try origin.reserveEntry();
    origin.entries.items[id].entry = .{ .file_id = entry.file(), .index = entry.mainToken() };

    // Hint sized for the widest entry shapes (transaction has 10 fields:
    // _origin, type, date, tags, links, meta, flag, payee, narration,
    // postings). Lua rounds this to the next power of two, so 10 → 16
    // buckets — enough to avoid rehashing for every entry type.
    lua.createTable(0, 10);
    pushOriginId(lua, id);

    pushTypeStr(lua, entry.tag());
    lua.setField(-2, "type");

    pushDate(lua, entry.date());
    lua.setField(-2, "date");

    try pushTagsLinks(lua, origin, id, entry);
    try pushEntryMeta(lua, entry);

    switch (entry.payload()) {
        .transaction => |tx| try pushTransaction(lua, origin, tx),
        .open => |o| {
            origin.entries.items[id].account = o.accountLoc();
            try pushOpen(lua, project, o);
        },
        .close => |c| {
            origin.entries.items[id].account = c.accountLoc();
            try pushAccount(lua, c.accountText());
        },
        .balance => |b| {
            origin.entries.items[id].account = b.accountLoc();
            try pushBalance(lua, b);
        },
        .pad => |p| {
            origin.entries.items[id].account = p.accountLoc();
            origin.entries.items[id].account2 = p.padToAccountLoc();
            try pushPad(lua, project, p);
        },
        .pnl => |pnl| {
            origin.entries.items[id].account = .{ .file_id = entry.file(), .index = pnl.account };
            origin.entries.items[id].account2 = .{ .file_id = entry.file(), .index = pnl.income_account };
            try pushPnl(lua, project, entry, pnl);
        },
        .commodity => |c| try pushCommodity(lua, project, c),
        .price => |p| try pushPriceDecl(lua, p),
        .event => |e| try pushEvent(lua, project, entry, e),
        .query => |q| try pushQuery(lua, project, entry, q),
        .note => |n| {
            origin.entries.items[id].account = .{ .file_id = entry.file(), .index = n.account };
            try pushNote(lua, project, entry, n);
        },
        .document => |d| {
            origin.entries.items[id].account = .{ .file_id = entry.file(), .index = d.account };
            try pushDocument(lua, project, entry, d);
        },
    }
}

fn pushTypeStr(lua: *Lua, tag: Data.Entry.Tag) void {
    _ = lua.pushString(@tagName(tag));
}

fn pushDate(lua: *Lua, date: anytype) void {
    // Skip std.Io.Writer.print — runtime format-string parsing is the
    // single biggest cost in this hot path. Direct byte writing for a
    // fixed YYYY-MM-DD layout.
    var buf: [10]u8 = undefined;
    const y: u16 = @intCast(date.year);
    buf[0] = '0' + @as(u8, @intCast((y / 1000) % 10));
    buf[1] = '0' + @as(u8, @intCast((y / 100) % 10));
    buf[2] = '0' + @as(u8, @intCast((y / 10) % 10));
    buf[3] = '0' + @as(u8, @intCast(y % 10));
    buf[4] = '-';
    buf[5] = '0' + @as(u8, @intCast(date.month / 10));
    buf[6] = '0' + @as(u8, @intCast(date.month % 10));
    buf[7] = '-';
    buf[8] = '0' + @as(u8, @intCast(date.day / 10));
    buf[9] = '0' + @as(u8, @intCast(date.day % 10));
    _ = lua.pushString(&buf);
}

fn pushAccount(lua: *Lua, account_text: []const u8) !void {
    _ = lua.pushString(account_text);
    lua.setField(-2, "account");
}

fn pushTransaction(lua: *Lua, origin: *Origin, tx: Data.TransactionView) !void {
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
        try pushPosting(lua, origin, p);
        lua.rawSetIndex(-2, i);
    }
    lua.setField(-2, "postings");
}

fn pushPosting(lua: *Lua, origin: *Origin, p: Data.PostingView) !void {
    const project = origin.project;
    const id = try origin.reservePosting(.{ .file_id = p.file, .index = p.accountToken() });

    // Posting has 8 fields max (_origin, account, amount, currency, flag,
    // price, lot_spec, meta) — hint past 8 so Lua picks the 16-bucket size
    // and we don't rehash when the 8th field lands in a full table.
    lua.createTable(0, 9);
    pushOriginId(lua, id);

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

fn pushTagsLinks(lua: *Lua, origin: *Origin, entry_id: u32, entry: Data.EntryView) !void {
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

    const arena = origin.arena.allocator();
    var tag_locs = try arena.alloc(Data.TokenLoc, tags_count);
    var link_locs = try arena.alloc(Data.TokenLoc, links_count);
    const file_id = entry.file();

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
                tag_locs[@intCast(ti - 1)] = .{ .file_id = file_id, .index = tl.token };
                ti += 1;
            },
            .link => {
                lua.rawSetIndex(-2, li);
                link_locs[@intCast(li - 1)] = .{ .file_id = file_id, .index = tl.token };
                li += 1;
            },
        }
    }
    lua.setField(-3, "links");
    lua.setField(-2, "tags");

    origin.entries.items[entry_id].tag_locs = tag_locs;
    origin.entries.items[entry_id].link_locs = link_locs;
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
    origin: *Origin,
    /// Slot in `data.files` where the synth file is being constructed.
    synth_id: u8,
    /// Display location applied to tokens emitted right now. The reader
    /// updates this when entering an entry / posting / payload field and
    /// restores on exit.
    current_loc: Data.TokenLoc,

    source_buf: std.ArrayList(u8) = .empty,
    pending: std.ArrayList(PendingToken) = .empty,
    /// Parallel to `pending`. Captured at emit time so each synth token
    /// remembers the original source location to surface in diagnostics.
    display_locs: std.ArrayList(Data.TokenLoc) = .empty,

    entries: Data.Entries = .{},
    postings: Data.Postings = .{},
    prices: std.ArrayList(Data.Price) = .empty,
    lot_specs: std.ArrayList(Data.LotSpec) = .empty,
    open_currencies: std.ArrayList(Data.CurrencyIndex) = .empty,
    tagslinks: Data.TagsLinks = .{},
    meta: Data.Meta = .{},

    fn alloc(self: *Rebuild) Allocator {
        return self.origin.project.alloc;
    }

    fn deinit(self: *Rebuild) void {
        self.source_buf.deinit(self.alloc());
        self.pending.deinit(self.alloc());
        self.display_locs.deinit(self.alloc());
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
        try self.display_locs.append(self.alloc(), self.current_loc);
        return idx;
    }

    fn emitAccount(self: *Rebuild, text: []const u8) !Ast.TokenIndex {
        const tok_idx = try self.emitTok(text, .account);
        const acc_idx = try self.origin.project.data.accounts.intern(self.alloc(), text);
        self.pending.items[@intFromEnum(tok_idx)].interned = @intFromEnum(acc_idx);
        return tok_idx;
    }

    fn emitCurrency(self: *Rebuild, text: []const u8) !Ast.TokenIndex {
        const tok_idx = try self.emitTok(text, .currency);
        const cur_idx = try self.origin.project.data.currencies.intern(self.alloc(), text);
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
        const data = &self.origin.project.data;

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

        // Hand off ownership of display_locs in lockstep with the new synth
        // file. Detach from `self` so Rebuild.deinit doesn't double-free.
        var locs_handle = self.display_locs;
        self.display_locs = .empty;
        errdefer locs_handle.deinit(a);

        // Install the new synth file. After this, `owned_source`/tokens/etc.
        // are owned by `data.files`; clear our handles to avoid double-free
        // via Rebuild.deinit.
        try data.replaceSynthFile(new_file, locs_handle);

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

fn applyEntries(origin: *Origin, lua: *Lua, idx: i32) !void {
    const project = origin.project;
    const loc = origin.plugin_loc;
    if (lua.isNil(idx)) return;
    if (!lua.isTable(idx)) {
        try addRuntimeError(project, loc, origin.plugin, lua, error.PluginEntriesReturnIsNotTable);
        return;
    }

    const synth_id = try project.data.ensureSynthFile();
    var rb = Rebuild{
        .origin = origin,
        .synth_id = synth_id,
        .current_loc = loc,
    };
    defer rb.deinit();

    const len = lua.rawLen(idx);
    var i: u32 = 1;
    while (i <= len) : (i += 1) {
        _ = lua.rawGetIndex(idx, @intCast(i));
        defer lua.pop(1);

        // Shapes per entry slot:
        //   1) plain table → plugin-built (or older shape), normal path.
        //   2) userdata, uv1 table → materialized; pull cached table out
        //      and fall through to `readEntry`. (Apply posting overlays
        //      onto cached postings if needed.)
        //   3) userdata, uv1 nil, posting overlays present → materialize
        //      now, apply overlays, then `readEntry`.
        //   4) userdata, uv1 nil, no posting overlays → passthrough.
        if (lua.isUserdata(-1)) {
            const entry_abs = lua.getTop();
            const cache_type = lua.getUserValue(entry_abs, 1) catch .nil;
            lua.pop(1);

            const has_posting_writes = entryHasPostingOverlays(lua, entry_abs);

            if (cache_type == .table) {
                // Plugin materialized (or wrote to) the entry table. Apply
                // any posting overlays on top of the cache, then read it.
                if (has_posting_writes) {
                    applyPostingOverlays(&rb, lua, entry_abs) catch |err| {
                        const msg = try std.fmt.allocPrint(
                            project.plugin_arena.allocator(),
                            "entry #{d}: {s}",
                            .{ i, @errorName(err) },
                        );
                        try appendPluginError(project, loc, .{ .plugin_error = .{
                            .plugin = try project.plugin_arena.allocator().dupe(u8, origin.plugin),
                            .message = msg,
                        } });
                        continue;
                    };
                }
                // Surface the cache at top so `readEntry` consumes it.
                _ = lua.getUserValue(entry_abs, 1) catch {
                    lua.pushNil();
                };
                lua.remove(-2);
            } else if (has_posting_writes) {
                // Entry never materialized but postings were modified —
                // direct-rebuild from Data + per-posting overlays. This
                // skips the Lua-table round-trip that the entry-cache path
                // would otherwise pay.
                rebuildEntryWithPostingOverlays(&rb, lua, entry_abs) catch |err| {
                    const msg = try std.fmt.allocPrint(
                        project.plugin_arena.allocator(),
                        "entry #{d}: {s}",
                        .{ i, @errorName(err) },
                    );
                    try appendPluginError(project, loc, .{ .plugin_error = .{
                        .plugin = try project.plugin_arena.allocator().dupe(u8, origin.plugin),
                        .message = msg,
                    } });
                };
                continue;
            } else {
                const ud = lua.toUserdata(EntryUD, -1) catch continue;
                passthroughEntry(&rb, ud.idx) catch |err| {
                    const msg = try std.fmt.allocPrint(
                        project.plugin_arena.allocator(),
                        "entry #{d}: {s}",
                        .{ i, @errorName(err) },
                    );
                    try appendPluginError(project, loc, .{ .plugin_error = .{
                        .plugin = try project.plugin_arena.allocator().dupe(u8, origin.plugin),
                        .message = msg,
                    } });
                };
                continue;
            }
        }

        readEntry(&rb, lua, i) catch |err| {
            const msg = try std.fmt.allocPrint(
                project.plugin_arena.allocator(),
                "entry #{d}: {s}",
                .{ i, @errorName(err) },
            );
            try appendPluginError(project, loc, .{ .plugin_error = .{
                .plugin = try project.plugin_arena.allocator().dupe(u8, origin.plugin),
                .message = msg,
            } });
        };
    }

    try rb.commit();
}

fn absIdx(lua: *Lua, idx: i32) i32 {
    if (idx >= 0) return idx;
    return lua.getTop() + 1 + idx;
}

/// True if the entry at `entry_idx` has a posting list (uv2) AND any
/// cached posting userdata in it has a non-nil overlay (uv1).
fn entryHasPostingOverlays(lua: *Lua, entry_idx: i32) bool {
    const abs = absIdx(lua, entry_idx);

    const ptype = lua.getUserValue(abs, 2) catch return false;
    if (ptype != .userdata) {
        lua.pop(1);
        return false;
    }
    // Stack: [..., PostingListUD]

    const ctype = lua.getUserValue(-1, 1) catch {
        lua.pop(1);
        return false;
    };
    if (ctype != .table) {
        lua.pop(2);
        return false;
    }
    // Stack: [..., PostingListUD, cache_table]
    const cache_abs = lua.getTop();

    var has = false;
    lua.pushNil();
    while (lua.next(cache_abs)) {
        // Stack: [..., cache, key, value]
        if (lua.isUserdata(-1)) {
            const ovt = lua.getUserValue(-1, 1) catch {
                lua.pop(1);
                continue;
            };
            const is_table = (ovt == .table);
            lua.pop(1); // pop overlay/nil
            if (is_table) {
                has = true;
                lua.pop(2); // pop value + key, exit early
                break;
            }
        }
        lua.pop(1); // pop value (and continue iteration with key)
    }
    lua.pop(2); // pop cache_table, PostingListUD
    return has;
}

/// Materialize the entry (if not already) and copy each per-posting overlay
/// into the corresponding entry of the cached postings table. After this,
/// the cached table is the unified view and `readEntry` on it produces the
/// correct result.
fn applyPostingOverlays(rb: *Rebuild, lua: *Lua, entry_idx: i32) !void {
    const origin = rb.origin;
    const entry_abs = absIdx(lua, entry_idx);

    // 1. Ensure full materialization of the entry.
    {
        const t = try lua.getUserValue(entry_abs, 1);
        if (t != .table) {
            lua.pop(1);
            const ud = try lua.toUserdata(EntryUD, entry_abs);
            const view = origin.project.data.entryAt(ud.idx);
            try pushEntry(lua, origin, view);
            lua.pushValue(-1);
            try lua.setUserValue(entry_abs, 1);
            lua.pop(1); // drop the cache table from our local view
        } else {
            lua.pop(1);
        }
    }

    // 2. Get cache → cache.postings → posting list (uv2) → posting cache.
    const t1 = try lua.getUserValue(entry_abs, 1);
    if (t1 != .table) {
        lua.pop(1);
        return;
    }
    const cache_abs = lua.getTop();

    _ = lua.getField(cache_abs, "postings");
    if (!lua.isTable(-1)) {
        lua.pop(2);
        return;
    }
    const postings_abs = lua.getTop();

    const t2 = try lua.getUserValue(entry_abs, 2);
    if (t2 != .userdata) {
        lua.pop(3);
        return;
    }
    const pl_abs = lua.getTop();

    const t3 = try lua.getUserValue(pl_abs, 1);
    if (t3 != .table) {
        lua.pop(4);
        return;
    }
    const pcache_abs = lua.getTop();

    // 3. Walk posting cache; for each posting with overlay, copy fields
    // into postings[slot].
    lua.pushNil();
    while (lua.next(pcache_abs)) {
        // Stack: [..., pcache, key, posting_ud]
        if (!lua.isUserdata(-1) or !lua.isInteger(-2)) {
            lua.pop(1);
            continue;
        }
        const slot = lua.toInteger(-2) catch {
            lua.pop(1);
            continue;
        };
        if (slot < 1) {
            lua.pop(1);
            continue;
        }

        const ovt = lua.getUserValue(-1, 1) catch {
            lua.pop(1);
            continue;
        };
        if (ovt != .table) {
            lua.pop(2); // overlay (nil) + posting_ud
            continue;
        }
        // Stack: [..., pcache, key, posting_ud, overlay]
        const overlay_abs = lua.getTop();

        _ = lua.rawGetIndex(postings_abs, @intCast(slot));
        if (!lua.isTable(-1)) {
            lua.pop(3); // cached_posting + overlay + posting_ud
            continue;
        }
        const cp_abs = lua.getTop();

        // Copy overlay's keys into cached_posting via rawset.
        lua.pushNil();
        while (lua.next(overlay_abs)) {
            // Stack: [..., overlay, cached_posting, ovkey, ovvalue]
            lua.pushValue(-2); // dup key
            lua.pushValue(-2); // dup value
            lua.rawSetTable(cp_abs);
            lua.pop(1); // pop ovvalue; leave ovkey for next iter
        }
        // Inner next consumed the last key, leaving [..., overlay, cached_posting].
        lua.pop(3); // cached_posting + overlay + posting_ud
    }
    lua.pop(4); // pcache, pl, postings, cache_table
}

/// Direct rebuild for entries that have posting overlays but no entry
/// uv1 (i.e. only the postings were touched). Emits synth tokens straight
/// from Data, consulting the overlay table for each posting's overlaid
/// fields. Skips the Lua-side materialization round-trip that
/// `pushEntry` + `applyPostingOverlays` + `readEntry` would otherwise do.
///
/// Pre: caller has confirmed entry.uv1 is nil and at least one posting
/// has a non-nil overlay. (Non-transactions can't have posting overlays
/// so the payload here is always transaction.)
fn rebuildEntryWithPostingOverlays(rb: *Rebuild, lua: *Lua, entry_idx: i32) ReadEntryError!void {
    const origin = rb.origin;
    const entry_abs = absIdx(lua, entry_idx);
    const ud = lua.toUserdata(EntryUD, entry_abs) catch return error.PluginEntryNotTable;
    const view = origin.project.data.entryAt(ud.idx);

    // Origin slot for source-loc fallbacks. The entry never materialized,
    // so its tag_locs/link_locs stay empty (no plugin reordering possible).
    const slot = try origin.reserveEntry();
    origin.entries.items[slot].entry = .{ .file_id = view.file(), .index = view.mainToken() };
    const saved_loc = rb.current_loc;
    rb.current_loc = origin.entries.items[slot].entry;
    defer rb.current_loc = saved_loc;

    const date = view.date();
    const main_token = try rb.emitDate(date);

    // Tagslinks: emit from Data, shifting current_loc per tag for accurate
    // source locs on diagnostics.
    const tl_start: u32 = @intCast(rb.tagslinks.len);
    {
        var it = view.tagslinks();
        while (it.next()) |tl| {
            if (!tl.explicit) continue;
            const slice = tl.slice();
            const text = if (slice.len > 0) slice[1..] else slice;
            const saved = rb.current_loc;
            rb.current_loc = .{ .file_id = view.file(), .index = tl.token };
            const tok = switch (tl.kind) {
                .tag => try rb.emitTag(text),
                .link => try rb.emitLink(text),
            };
            rb.current_loc = saved;
            try rb.tagslinks.append(rb.alloc(), .{ .kind = tl.kind, .token = tok, .explicit = true });
        }
    }
    const tl_range = Data.Range{ .start = tl_start, .end = @intCast(rb.tagslinks.len) };

    // Meta: emit from Data.
    const m_range = try emitMetaFromIter(rb, view.metaKVs(), view.file());

    // Transaction-specific payload. (Non-transactions never have posting
    // overlays, but defensively pass them through unchanged via the
    // payload-copy fallback would be wrong here — assert and trust the
    // precondition.)
    const tx_view = switch (view.payload()) {
        .transaction => |tx| tx,
        else => unreachable,
    };

    const flag_tok = try rb.emitFlag(tx_view.flagSlice());
    const payee_tok: Ast.OptionalTokenIndex = if (tx_view.payeeText()) |p|
        (try rb.emitString(stripQuotes(p))).toOptional()
    else
        .none;
    const narration_tok: Ast.OptionalTokenIndex = if (tx_view.narrationText()) |n|
        (try rb.emitString(stripQuotes(n))).toOptional()
    else
        .none;

    // Resolve the posting cache (entry.uv2 → uv1) once for the loop.
    // pcache_abs == 0 means no overlay anywhere — but we wouldn't be in
    // this path then. Still handle defensively.
    const pcache_pop_count: u8 = blk: {
        const t1 = lua.getUserValue(entry_abs, 2) catch .nil;
        if (t1 != .userdata) {
            lua.pop(1);
            break :blk 0;
        }
        const pl_abs = lua.getTop();
        const t2 = lua.getUserValue(pl_abs, 1) catch .nil;
        if (t2 != .table) {
            lua.pop(2);
            break :blk 0;
        }
        break :blk 2;
    };
    const pcache_abs: i32 = if (pcache_pop_count == 2) lua.getTop() else 0;
    defer if (pcache_pop_count > 0) lua.pop(pcache_pop_count);

    const ps_start: u32 = @intCast(rb.postings.len);
    var p_it = tx_view.postings();
    var offset: u32 = 0;
    while (p_it.next()) |pv| : (offset += 1) {
        try rebuildPostingWithOverlay(rb, lua, pv, pcache_abs, offset + 1);
    }
    const ps_range = Data.Range{ .start = ps_start, .end = @intCast(rb.postings.len) };

    try rb.entries.append(rb.alloc(), .{
        .file = rb.synth_id,
        .date = date,
        .main_token = main_token,
        .tagslinks = tl_range,
        .meta = m_range,
        .payload = .{ .transaction = .{
            .flag = flag_tok,
            .payee = payee_tok,
            .narration = narration_tok,
            .postings = ps_range,
        } },
    });
}

/// Rebuild a single posting in `rb`, taking each leaf field from the
/// overlay if it has one, otherwise from Data. For complex fields
/// (price/lot_spec/meta), uses the existing `read*` helpers when the
/// overlay holds them, or copies from Data otherwise.
fn rebuildPostingWithOverlay(
    rb: *Rebuild,
    lua: *Lua,
    pv: Data.PostingView,
    pcache_abs: i32,
    slot: u32,
) ReadEntryError!void {
    const origin = rb.origin;

    const saved_loc = rb.current_loc;
    rb.current_loc = pv.accountLoc();
    defer rb.current_loc = saved_loc;

    // Fetch this posting's overlay table (if any) and leave it on top.
    // overlay_abs == 0 means "no overlay; everything from Data".
    const overlay_abs: i32 = blk: {
        if (pcache_abs == 0) break :blk @as(i32, 0);
        const t = lua.rawGetIndex(pcache_abs, @intCast(slot));
        if (t != .userdata) {
            lua.pop(1);
            break :blk @as(i32, 0);
        }
        const ovt = lua.getUserValue(-1, 1) catch .nil;
        if (ovt != .table) {
            lua.pop(2);
            break :blk @as(i32, 0);
        }
        lua.remove(-2); // drop the posting userdata, leave the overlay
        break :blk lua.getTop();
    };
    defer if (overlay_abs != 0) lua.pop(1);

    _ = try origin.reservePosting(pv.accountLoc());

    // Account.
    const acct_str = overlayString(lua, overlay_abs, "account") orelse pv.accountText();
    const account_tok = try rb.emitAccount(acct_str);

    // Amount.
    var amount = Data.PackedNumber.none;
    if (overlayString(lua, overlay_abs, "amount")) |s| {
        const n = Number.fromSlice(s) catch return error.PluginEntryInvalidNumber;
        amount = Data.PackedNumber.pack(n);
    } else if (pv.amountNumber()) |n| {
        amount = Data.PackedNumber.pack(n);
    }

    // Currency.
    var amount_currency: Data.OptionalCurrencyIndex = .none;
    const cur_str = overlayString(lua, overlay_abs, "currency") orelse pv.amountCurrencyText();
    if (cur_str) |s| {
        const idx = try origin.project.data.currencies.intern(rb.alloc(), s);
        _ = try rb.emitCurrency(s);
        amount_currency = idx.toOptional();
    }

    // Flag.
    var flag: Ast.OptionalTokenIndex = .none;
    if (overlayString(lua, overlay_abs, "flag")) |s| {
        flag = (try rb.emitFlag(s)).toOptional();
    } else if (pv.flag().unwrap()) |f| {
        const fdata = &origin.project.data.files.items[pv.file];
        flag = (try rb.emitFlag(fdata.tokenSlice(f))).toOptional();
    }

    // Price: overlay sub-table wins, else copy from Data.
    var price: Data.OptionalPriceIndex = .none;
    if (overlay_abs != 0 and overlayHasField(lua, overlay_abs, "price")) {
        _ = lua.getField(overlay_abs, "price");
        defer lua.pop(1);
        if (lua.isTable(-1)) {
            const pr = try readPostingPrice(rb, lua, -1);
            const idx: Data.PriceIndex = @enumFromInt(rb.prices.items.len);
            try rb.prices.append(rb.alloc(), pr);
            price = idx.toOptional();
        }
    } else if (pv.price()) |pr| {
        const idx: Data.PriceIndex = @enumFromInt(rb.prices.items.len);
        try rb.prices.append(rb.alloc(), .{
            .amount = pr.amount,
            .amount_currency = pr.amount_currency,
            .total = pr.total,
        });
        price = idx.toOptional();
    }

    // Lot_spec.
    var lot_spec: Data.OptionalLotSpecIndex = .none;
    if (overlay_abs != 0 and overlayHasField(lua, overlay_abs, "lot_spec")) {
        _ = lua.getField(overlay_abs, "lot_spec");
        defer lua.pop(1);
        if (lua.isTable(-1)) {
            const ls = try readPostingLotSpec(rb, lua, -1);
            const idx: Data.LotSpecIndex = @enumFromInt(rb.lot_specs.items.len);
            try rb.lot_specs.append(rb.alloc(), ls);
            lot_spec = idx.toOptional();
        }
    } else if (pv.lotSpec()) |ls| {
        const idx: Data.LotSpecIndex = @enumFromInt(rb.lot_specs.items.len);
        try rb.lot_specs.append(rb.alloc(), .{
            .price = ls.price,
            .price_currency = ls.price_currency,
            .date = ls.date,
            .label = ls.label,
        });
        lot_spec = idx.toOptional();
    }

    // Meta.
    var meta_range: Data.Range = .{ .start = @intCast(rb.meta.len), .end = @intCast(rb.meta.len) };
    if (overlay_abs != 0 and overlayHasField(lua, overlay_abs, "meta")) {
        meta_range = try readMetaTable(rb, lua, overlay_abs, "meta");
    } else {
        meta_range = try emitMetaFromIter(rb, pv.metaKVs(), pv.file);
    }

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

/// Emit a Meta range to `rb` from a Data-side iterator, copying keys and
/// values as fresh synth tokens. Used by direct-rebuild paths.
fn emitMetaFromIter(rb: *Rebuild, iter_in: Data.MetaIterator, file_id: u8) !Data.Range {
    var it = iter_in;
    const start: u32 = @intCast(rb.meta.len);
    const fdata = &rb.origin.project.data.files.items[file_id];
    while (it.next()) |kv| {
        const key_raw = fdata.tokenSlice(kv.key);
        const key_text = if (key_raw.len > 0 and key_raw[key_raw.len - 1] == ':')
            key_raw[0 .. key_raw.len - 1]
        else
            key_raw;
        const key_tok = try rb.emitMetaKey(key_text);
        const val_text = stripQuotes(fdata.tokenSlice(kv.value));
        const val_tok = try rb.emitString(val_text);
        try rb.meta.append(rb.alloc(), .{ .key = key_tok, .value = val_tok });
    }
    return .{ .start = start, .end = @intCast(rb.meta.len) };
}

/// Read a string field from the overlay table at `overlay_abs`, returning
/// null if absent / not a string / overlay_abs == 0. Pops what it pushes.
fn overlayString(lua: *Lua, overlay_abs: i32, field: [:0]const u8) ?[]const u8 {
    if (overlay_abs == 0) return null;
    _ = lua.getField(overlay_abs, field);
    defer lua.pop(1);
    if (lua.isNil(-1)) return null;
    if (!lua.isString(-1)) return null;
    return lua.toString(-1) catch null;
}

/// True if the overlay has a non-nil entry for `field`.
fn overlayHasField(lua: *Lua, overlay_abs: i32, field: [:0]const u8) bool {
    if (overlay_abs == 0) return false;
    _ = lua.getField(overlay_abs, field);
    defer lua.pop(1);
    return !lua.isNil(-1);
}

/// Copy the original `Data.Entry` (and everything it references) into the
/// Rebuild's new tables. Used for entries the plugin never touched: no
/// Lua round-trip, no synth tokens emitted. The entry retains its original
/// `file` so its existing tokens stay valid; payload sub-ranges are
/// re-anchored into `rb`'s new tables.
fn passthroughEntry(rb: *Rebuild, idx: u32) !void {
    const a = rb.alloc();
    const data = &rb.origin.project.data;
    var copy = data.entries.get(idx);

    // Tagslinks: copy the slice into rb.tagslinks and rebind the range.
    const tl_start: u32 = @intCast(rb.tagslinks.len);
    var ti: u32 = copy.tagslinks.start;
    while (ti < copy.tagslinks.end) : (ti += 1) {
        try rb.tagslinks.append(a, data.tagslinks.get(ti));
    }
    copy.tagslinks = .{ .start = tl_start, .end = @intCast(rb.tagslinks.len) };

    // Meta (entry-level): copy and rebind.
    copy.meta = try passthroughMetaRange(rb, copy.meta);

    // Payload-specific copies. Transaction needs postings (each of which may
    // own its own price/lot_spec/meta). Open carries an open_currencies
    // range. Everything else is by-value already.
    switch (copy.payload) {
        .transaction => |*tx| {
            const ps_start: u32 = @intCast(rb.postings.len);
            var pi: u32 = tx.postings.start;
            while (pi < tx.postings.end) : (pi += 1) {
                var p = data.postings.get(pi);
                if (p.price.unwrap()) |pridx| {
                    const new_pridx: Data.PriceIndex = @enumFromInt(rb.prices.items.len);
                    try rb.prices.append(a, data.prices.items[@intFromEnum(pridx)]);
                    p.price = new_pridx.toOptional();
                }
                if (p.lot_spec.unwrap()) |lidx| {
                    const new_lidx: Data.LotSpecIndex = @enumFromInt(rb.lot_specs.items.len);
                    try rb.lot_specs.append(a, data.lot_specs.items[@intFromEnum(lidx)]);
                    p.lot_spec = new_lidx.toOptional();
                }
                p.meta = try passthroughMetaRange(rb, p.meta);
                try rb.postings.append(a, p);
            }
            tx.postings = .{ .start = ps_start, .end = @intCast(rb.postings.len) };
        },
        .open => |*o| {
            const cur_start: u32 = @intCast(rb.open_currencies.items.len);
            var ci: u32 = o.currencies.start;
            while (ci < o.currencies.end) : (ci += 1) {
                try rb.open_currencies.append(a, data.open_currencies.items[ci]);
            }
            o.currencies = .{ .start = cur_start, .end = @intCast(rb.open_currencies.items.len) };
        },
        else => {},
    }

    try rb.entries.append(a, copy);
}

fn passthroughMetaRange(rb: *Rebuild, r: Data.Range) !Data.Range {
    const a = rb.alloc();
    const data = &rb.origin.project.data;
    const start: u32 = @intCast(rb.meta.len);
    var mi: u32 = r.start;
    while (mi < r.end) : (mi += 1) {
        try rb.meta.append(a, data.meta.get(mi));
    }
    return .{ .start = start, .end = @intCast(rb.meta.len) };
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

    // Look up the origin side-table entry for this Lua entry. Plugin-built
    // entries with no `_origin` get a synthetic record pointing at the
    // plugin directive.
    const eo: Origin.EntryOrigin = rb.origin.entryOf(lua, -1) orelse .{ .entry = rb.origin.plugin_loc };

    const saved_loc = rb.current_loc;
    rb.current_loc = eo.entry;
    defer rb.current_loc = saved_loc;

    const type_str = (try getStringField(lua, -1, "type")) orelse return error.PluginEntryMissingType;
    const date_str = (try getStringField(lua, -1, "date")) orelse return error.PluginEntryMissingDate;
    const date = Date.fromSlice(date_str) catch return error.PluginEntryInvalidDate;

    const tagslinks_range = try readTagsLinks(rb, lua, -1, eo);
    const meta_range = try readEntryMeta(rb, lua, -1);

    const tag = parseEntryTag(type_str) orelse return error.PluginEntryUnknownType;
    const main_token: Ast.TokenIndex = try rb.emitDate(date);

    const payload: Data.Entry.Payload = switch (tag) {
        .transaction => .{ .transaction = try readTransaction(rb, lua, -1) },
        .open => .{ .open = try readOpen(rb, lua, -1, eo) },
        .close => .{ .close = .{ .account = try readAccountField(rb, lua, -1, "account", eo.account) } },
        .commodity => .{ .commodity = .{ .currency = try readCurrencyField(rb, lua, -1, "currency") } },
        .pad => .{ .pad = .{
            .account = try readAccountField(rb, lua, -1, "account", eo.account),
            .pad_to = try readAccountField(rb, lua, -1, "pad_to", eo.account2),
        } },
        .pnl => .{ .pnl = .{
            .account = try readAccountField(rb, lua, -1, "account", eo.account),
            .income_account = try readAccountField(rb, lua, -1, "income_account", eo.account2),
        } },
        .balance => .{ .balance = try readBalance(rb, lua, -1, eo) },
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
            .account = try readAccountField(rb, lua, -1, "account", eo.account),
            .note = try readStringField(rb, lua, -1, "note"),
        } },
        .document => .{ .document = .{
            .account = try readAccountField(rb, lua, -1, "account", eo.account),
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

    // The posting's own origin (account token of the source posting)
    // overrides the entry-level loc for any tokens we emit here.
    const saved_loc = rb.current_loc;
    if (rb.origin.postingOf(lua, -1)) |po| rb.current_loc = po.account;
    defer rb.current_loc = saved_loc;

    const account_text = (try getStringField(lua, -1, "account")) orelse return error.PluginEntryMissingField;
    const account_tok = try rb.emitAccount(account_text);

    var amount = Data.PackedNumber.none;
    if (try getStringField(lua, -1, "amount")) |s| {
        const n = Number.fromSlice(s) catch return error.PluginEntryInvalidNumber;
        amount = Data.PackedNumber.pack(n);
    }
    var amount_currency: Data.OptionalCurrencyIndex = .none;
    if (try getStringField(lua, -1, "currency")) |s| {
        const cur_idx = try rb.origin.project.data.currencies.intern(rb.alloc(), s);
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
        const cur_idx = try rb.origin.project.data.currencies.intern(rb.alloc(), s);
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
        const cur_idx = try rb.origin.project.data.currencies.intern(rb.alloc(), s);
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

fn readOpen(rb: *Rebuild, lua: *Lua, idx: i32, eo: Origin.EntryOrigin) ReadEntryError!Data.Open {
    const account_tok = try readAccountField(rb, lua, idx, "account", eo.account);

    const cur_start: u32 = @intCast(rb.open_currencies.items.len);
    _ = lua.getField(idx, "currencies");
    if (lua.isTable(-1)) {
        const len = lua.rawLen(-1);
        var i: u32 = 1;
        while (i <= len) : (i += 1) {
            _ = lua.rawGetIndex(-1, @intCast(i));
            defer lua.pop(1);
            if (lua.toString(-1) catch null) |s| {
                const cur_idx = try rb.origin.project.data.currencies.intern(rb.alloc(), s);
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

fn readBalance(rb: *Rebuild, lua: *Lua, idx: i32, eo: Origin.EntryOrigin) ReadEntryError!Data.Balance {
    const account_tok = try readAccountField(rb, lua, idx, "account", eo.account);
    const amount_str = (try getStringField(lua, idx, "amount")) orelse return error.PluginEntryMissingField;
    const amount_num = Number.fromSlice(amount_str) catch return error.PluginEntryInvalidNumber;
    const cur_str = (try getStringField(lua, idx, "currency")) orelse return error.PluginEntryMissingField;
    const cur_idx = try rb.origin.project.data.currencies.intern(rb.alloc(), cur_str);
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
    const cur_idx = try rb.origin.project.data.currencies.intern(rb.alloc(), cur_str);
    _ = try rb.emitCurrency(cur_str);

    const amount_cur_str = (try getStringField(lua, idx, "amount_currency")) orelse return error.PluginEntryMissingField;
    const amount_cur_idx = try rb.origin.project.data.currencies.intern(rb.alloc(), amount_cur_str);
    _ = try rb.emitCurrency(amount_cur_str);

    const amount_str = (try getStringField(lua, idx, "amount")) orelse return error.PluginEntryMissingField;
    const amount_num = Number.fromSlice(amount_str) catch return error.PluginEntryInvalidNumber;

    return .{
        .currency = cur_idx,
        .amount_currency = amount_cur_idx,
        .amount_number = Data.PackedNumber.pack(amount_num),
    };
}

fn readAccountField(rb: *Rebuild, lua: *Lua, idx: i32, field: [:0]const u8, loc: ?Data.TokenLoc) ReadEntryError!Ast.TokenIndex {
    const s = (try getStringField(lua, idx, field)) orelse return error.PluginEntryMissingField;
    const saved = rb.current_loc;
    if (loc) |l| rb.current_loc = l;
    defer rb.current_loc = saved;
    return try rb.emitAccount(s);
}

fn readCurrencyField(rb: *Rebuild, lua: *Lua, idx: i32, field: [:0]const u8) ReadEntryError!Data.CurrencyIndex {
    const s = (try getStringField(lua, idx, field)) orelse return error.PluginEntryMissingField;
    const cur_idx = try rb.origin.project.data.currencies.intern(rb.alloc(), s);
    _ = try rb.emitCurrency(s);
    return cur_idx;
}

fn readStringField(rb: *Rebuild, lua: *Lua, idx: i32, field: [:0]const u8) ReadEntryError!Ast.TokenIndex {
    const s = (try getStringField(lua, idx, field)) orelse return error.PluginEntryMissingField;
    return try rb.emitString(s);
}

fn readTagsLinks(rb: *Rebuild, lua: *Lua, idx: i32, eo: Origin.EntryOrigin) ReadEntryError!Data.Range {
    const start: u32 = @intCast(rb.tagslinks.len);

    _ = lua.getField(idx, "tags");
    if (lua.isTable(-1)) {
        const len = lua.rawLen(-1);
        var i: u32 = 0;
        while (i < len) : (i += 1) {
            _ = lua.rawGetIndex(-1, @intCast(i + 1));
            defer lua.pop(1);
            if (lua.toString(-1) catch null) |s| {
                const saved = rb.current_loc;
                if (i < eo.tag_locs.len) rb.current_loc = eo.tag_locs[i];
                defer rb.current_loc = saved;
                const tok = try rb.emitTag(s);
                try rb.tagslinks.append(rb.alloc(), .{ .kind = .tag, .token = tok, .explicit = true });
            }
        }
    }
    lua.pop(1);

    _ = lua.getField(idx, "links");
    if (lua.isTable(-1)) {
        const len = lua.rawLen(-1);
        var i: u32 = 0;
        while (i < len) : (i += 1) {
            _ = lua.rawGetIndex(-1, @intCast(i + 1));
            defer lua.pop(1);
            if (lua.toString(-1) catch null) |s| {
                const saved = rb.current_loc;
                if (i < eo.link_locs.len) rb.current_loc = eo.link_locs[i];
                defer rb.current_loc = saved;
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
