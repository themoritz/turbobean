const std = @import("std");
const builtin = @import("builtin");

pub const PyObject = opaque {};

pub const Error = error{
    /// A Python exception was raised. Call `printError` for details.
    PythonError,
    /// Failed to open the Python shared library.
    LibraryNotFound,
    /// A required symbol was not found in the Python library.
    SymbolNotFound,
};

/// Stores resolved function pointers from the dynamically loaded Python library.
const Api = struct {
    lib: std.DynLib,

    Py_Initialize: *const fn () callconv(.c) void,
    Py_FinalizeEx: *const fn () callconv(.c) c_int,
    Py_IsInitialized: *const fn () callconv(.c) c_int,

    Py_DecRef: *const fn (?*PyObject) callconv(.c) void,
    Py_IncRef: *const fn (?*PyObject) callconv(.c) void,

    PyErr_Print: *const fn () callconv(.c) void,
    PyErr_Occurred: *const fn () callconv(.c) ?*PyObject,

    PyUnicode_FromString: *const fn ([*:0]const u8) callconv(.c) ?*PyObject,
    PyUnicode_AsUTF8AndSize: *const fn (*PyObject, *isize) callconv(.c) ?[*]const u8,

    PyLong_FromLong: *const fn (c_long) callconv(.c) ?*PyObject,
    PyLong_AsLong: *const fn (*PyObject) callconv(.c) c_long,

    PyFloat_FromDouble: *const fn (f64) callconv(.c) ?*PyObject,
    PyFloat_AsDouble: *const fn (*PyObject) callconv(.c) f64,

    PyTuple_New: *const fn (isize) callconv(.c) ?*PyObject,
    PyTuple_SetItem: *const fn (*PyObject, isize, *PyObject) callconv(.c) c_int,

    PyList_New: *const fn (isize) callconv(.c) ?*PyObject,
    PyList_SetItem: *const fn (*PyObject, isize, *PyObject) callconv(.c) c_int,
    PyList_Size: *const fn (*PyObject) callconv(.c) isize,
    PyList_GetItem: *const fn (*PyObject, isize) callconv(.c) ?*PyObject,

    PyObject_GetAttrString: *const fn (*PyObject, [*:0]const u8) callconv(.c) ?*PyObject,
    PyObject_CallObject: *const fn (*PyObject, ?*PyObject) callconv(.c) ?*PyObject,
    PyCallable_Check: *const fn (*PyObject) callconv(.c) c_int,

    PyImport_ImportModule: *const fn ([*:0]const u8) callconv(.c) ?*PyObject,

    _Py_NoneStruct: *PyObject,

    fn load(lib: *std.DynLib) Error!Api {
        var self: Api = undefined;
        self.lib = lib.*;
        inline for (@typeInfo(Api).@"struct".fields) |field| {
            if (comptime std.mem.eql(u8, field.name, "lib")) continue;
            @field(self, field.name) = lib.lookup(field.type, field.name) orelse
                return error.SymbolNotFound;
        }
        return self;
    }
};

var api: ?Api = null;

fn c() *const Api {
    return &(api orelse unreachable);
}

// --- Public API ---

/// Initialize the Python runtime by loading the shared library at the given path.
/// Example: `try python.init("/usr/lib/libpython3.13.dylib");`
pub fn init(lib_path: []const u8) Error!void {
    var lib = std.DynLib.open(lib_path) catch return error.LibraryNotFound;
    var a = try Api.load(&lib);
    a.Py_Initialize();
    if (a.Py_IsInitialized() == 0) return error.PythonError;
    api = a;
}

/// Finalize the Python interpreter and close the shared library.
pub fn deinit() void {
    if (api) |*a| {
        _ = a.Py_FinalizeEx();
        a.lib.close();
        api = null;
    }
}

/// Print the current Python exception (if any) to stderr and clear it.
pub fn printError() void {
    c().PyErr_Print();
}

pub fn decref(obj: *PyObject) void {
    c().Py_DecRef(obj);
}

pub fn incref(obj: *PyObject) void {
    c().Py_IncRef(obj);
}

pub fn none() *PyObject {
    return c()._Py_NoneStruct;
}

// --- Object creation ---

pub fn newString(s: [*:0]const u8) Error!*PyObject {
    return c().PyUnicode_FromString(s) orelse return error.PythonError;
}

pub fn newLong(val: i64) Error!*PyObject {
    return c().PyLong_FromLong(val) orelse return error.PythonError;
}

pub fn newDouble(val: f64) Error!*PyObject {
    return c().PyFloat_FromDouble(val) orelse return error.PythonError;
}

pub fn newTuple(size: usize) Error!*PyObject {
    return c().PyTuple_New(@intCast(size)) orelse return error.PythonError;
}

/// Steals a reference to `val`.
pub fn tupleSetItem(tuple: *PyObject, index: usize, val: *PyObject) void {
    _ = c().PyTuple_SetItem(tuple, @intCast(index), val);
}

pub fn newList(size: usize) Error!*PyObject {
    return c().PyList_New(@intCast(size)) orelse return error.PythonError;
}

/// Steals a reference to `val`.
pub fn listSetItem(list: *PyObject, index: usize, val: *PyObject) void {
    _ = c().PyList_SetItem(list, @intCast(index), val);
}

pub fn listLen(list: *PyObject) usize {
    return @intCast(c().PyList_Size(list));
}

/// Returns a borrowed reference.
pub fn listGetItem(list: *PyObject, index: usize) Error!*PyObject {
    return c().PyList_GetItem(list, @intCast(index)) orelse return error.PythonError;
}

// --- Object extraction ---

/// The returned slice is valid only as long as the PyObject is alive.
pub fn asString(obj: *PyObject) Error![]const u8 {
    var size: isize = 0;
    const ptr = c().PyUnicode_AsUTF8AndSize(obj, &size) orelse return error.PythonError;
    return ptr[0..@intCast(size)];
}

pub fn asLong(obj: *PyObject) Error!i64 {
    const val = c().PyLong_AsLong(obj);
    if (val == -1 and c().PyErr_Occurred() != null) return error.PythonError;
    return val;
}

pub fn asDouble(obj: *PyObject) Error!f64 {
    const val = c().PyFloat_AsDouble(obj);
    if (val == -1.0 and c().PyErr_Occurred() != null) return error.PythonError;
    return val;
}

// --- Module loading ---

pub const Module = struct {
    obj: *PyObject,

    pub fn deinit(self: Module) void {
        decref(self.obj);
    }

    /// Call a function in this module by name with the given args tuple.
    /// Returns a new reference.
    pub fn call(self: Module, func_name: [*:0]const u8, args: *PyObject) Error!*PyObject {
        const a = c();
        const func = a.PyObject_GetAttrString(self.obj, func_name) orelse return error.PythonError;
        defer a.Py_DecRef(func);

        if (a.PyCallable_Check(func) == 0) return error.PythonError;

        return a.PyObject_CallObject(func, args) orelse return error.PythonError;
    }
};

/// Load a Python module from a .py file path.
pub fn loadModule(file_path: [*:0]const u8) Error!Module {
    const a = c();

    // import importlib.util
    const importlib_util = a.PyImport_ImportModule("importlib.util") orelse return error.PythonError;
    defer a.Py_DecRef(importlib_util);

    // spec = importlib.util.spec_from_file_location("plugin", file_path)
    const spec = blk: {
        const spec_func = a.PyObject_GetAttrString(importlib_util, "spec_from_file_location") orelse return error.PythonError;
        defer a.Py_DecRef(spec_func);

        const args = try newTuple(2);
        defer decref(args);
        tupleSetItem(args, 0, try newString("plugin"));
        tupleSetItem(args, 1, try newString(file_path));

        break :blk a.PyObject_CallObject(spec_func, args) orelse return error.PythonError;
    };
    defer a.Py_DecRef(spec);

    if (spec == none()) return error.PythonError;

    // mod = importlib.util.module_from_spec(spec)
    const module = blk: {
        const mod_func = a.PyObject_GetAttrString(importlib_util, "module_from_spec") orelse return error.PythonError;
        defer a.Py_DecRef(mod_func);

        const args = try newTuple(1);
        defer decref(args);
        tupleSetItem(args, 0, spec);
        a.Py_IncRef(spec); // tupleSetItem steals ref, but we still need spec

        break :blk a.PyObject_CallObject(mod_func, args) orelse return error.PythonError;
    };

    // spec.loader.exec_module(mod)
    {
        const loader = a.PyObject_GetAttrString(spec, "loader") orelse {
            a.Py_DecRef(module);
            return error.PythonError;
        };
        defer a.Py_DecRef(loader);

        const exec_func = a.PyObject_GetAttrString(loader, "exec_module") orelse {
            a.Py_DecRef(module);
            return error.PythonError;
        };
        defer a.Py_DecRef(exec_func);

        const args = try newTuple(1);
        defer decref(args);
        tupleSetItem(args, 0, module);
        a.Py_IncRef(module); // tupleSetItem steals ref, but we still need module

        const result = a.PyObject_CallObject(exec_func, args) orelse {
            a.Py_DecRef(module);
            return error.PythonError;
        };
        a.Py_DecRef(result);
    }

    return .{ .obj = module };
}

/// Auto-detect the Python shared library path using `python3` on the system PATH.
/// Caller owns the returned memory.
pub fn findLibPath(alloc: std.mem.Allocator) ![:0]const u8 {
    const script =
        \\import sysconfig, sys
        \\libdir = sysconfig.get_config_var('LIBDIR')
        \\version = sysconfig.get_config_var('VERSION')
        \\ext = '.dylib' if sys.platform == 'darwin' else '.so'
        \\print(f'{libdir}/libpython{version}{ext}')
    ;
    const result = try std.process.Child.run(.{
        .allocator = alloc,
        .argv = &.{ "python3", "-c", script },
    });
    defer alloc.free(result.stderr);
    defer alloc.free(result.stdout);

    const path = std.mem.trim(u8, result.stdout, " \n\r");
    return try alloc.dupeZ(u8, path);
}

test "load module and call function" {
    const lib_path = try findLibPath(std.testing.allocator);
    defer std.testing.allocator.free(lib_path);

    try init(lib_path);
    defer deinit();

    const mod = try loadModule("tests/python/test_plugin.py");
    defer mod.deinit();

    // Call greet("World") -> "Hello, World!"
    {
        const args = try newTuple(1);
        defer decref(args);
        tupleSetItem(args, 0, try newString("World"));

        const result = try mod.call("greet", args);
        defer decref(result);

        const str = try asString(result);
        try std.testing.expectEqualStrings("Hello, World!", str);
    }

    // Call add(3, 4) -> 7
    {
        const args = try newTuple(2);
        defer decref(args);
        tupleSetItem(args, 0, try newLong(3));
        tupleSetItem(args, 1, try newLong(4));

        const result = try mod.call("add", args);
        defer decref(result);

        const val = try asLong(result);
        try std.testing.expectEqual(@as(i64, 7), val);
    }

    // Call transform(["a", "b", "c"]) -> ["A", "B", "C"]
    {
        const list = try newList(3);
        listSetItem(list, 0, try newString("a"));
        listSetItem(list, 1, try newString("b"));
        listSetItem(list, 2, try newString("c"));

        const args = try newTuple(1);
        defer decref(args);
        tupleSetItem(args, 0, list); // steals ref to list

        const result = try mod.call("transform", args);
        defer decref(result);

        const expected = [_][]const u8{ "A", "B", "C" };
        try std.testing.expectEqual(@as(usize, 3), listLen(result));
        for (expected, 0..) |exp, i| {
            const item = try listGetItem(result, i);
            const s = try asString(item);
            try std.testing.expectEqualStrings(exp, s);
        }
    }
}
