const std = @import("std");

const Self = @This();
const Step = std.Build.Step;

step: Step,
exe: *Step.Compile,
test_path: []const u8,
accept: bool,

pub fn create(
    owner: *std.Build,
    exe: *Step.Compile,
    test_path: []const u8,
    accept: bool,
) *Self {
    const self = owner.allocator.create(Self) catch @panic("OOM");
    const name = std.fmt.allocPrint(owner.allocator, "golden test {s}", .{test_path}) catch @panic("OOM");
    self.* = .{
        .step = Step.init(.{
            .id = .custom,
            .name = name,
            .owner = owner,
            .makeFn = make,
        }),
        .exe = exe,
        .test_path = test_path,
        .accept = accept,
    };

    self.step.dependOn(&exe.step);

    return self;
}

fn make(step: *Step, options: Step.MakeOptions) !void {
    _ = options;
    const b = step.owner;
    const arena = b.allocator;
    const self: *Self = @fieldParentPtr("step", step);

    const inp_file = try std.fmt.allocPrint(arena, "{s}.bean", .{self.test_path});
    const out_file = try std.fmt.allocPrint(arena, "{s}.out", .{self.test_path});

    const exe_path = self.exe.getEmittedBin().getPath(b);

    var child = std.process.Child.init(&[_][]const u8{ exe_path, inp_file }, arena);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    try child.spawn();

    var stdout = std.ArrayListUnmanaged(u8){};
    var stderr = std.ArrayListUnmanaged(u8){};
    try child.collectOutput(arena, &stdout, &stderr, 1024 * 1024);

    _ = try child.wait();

    const actual_output = stderr;

    const expected_output = std.fs.cwd().readFileAlloc(
        arena,
        out_file,
        std.math.maxInt(usize),
    ) catch |err| switch (err) {
        error.FileNotFound => {
            if (self.accept) {
                b.build_root.handle.writeFile(.{
                    .sub_path = out_file,
                    .data = actual_output.items,
                }) catch |e| return step.fail("Can't write output: {any}", .{e});
                return;
            } else {
                return step.fail("Expected output file not found: {s}", .{out_file});
            }
        },
        else => return step.fail("Error reading expected output: {}", .{err}),
    };

    // Compare outputs
    if (std.mem.eql(u8, actual_output.items, expected_output)) {
        return;
    }

    // Outputs differ
    if (self.accept) {
        b.build_root.handle.writeFile(.{
            .sub_path = out_file,
            .data = actual_output.items,
        }) catch |e| return step.fail("Can't write output: {any}", .{e});
    } else {
        return step.fail(
            \\Golden test failed for {s}:
            \\========== Expected: ==========
            \\{s}
            \\=========== Actual: ===========
            \\{s}
            \\===============================
        , .{ self.test_path, expected_output, actual_output.items });
    }
}
