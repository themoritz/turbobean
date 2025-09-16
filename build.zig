const std = @import("std");
const GoldenTest = @import("build/GoldenTest.zig");

pub fn build(b: *std.Build) void {
    const embed_static = b.option(bool, "embed-static", "Embed static assets into the binary") orelse false;
    const options = b.addOptions();
    options.addOption(bool, "embed_static", embed_static);

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_mod.addImport("lsp", b.dependency("lsp_codegen", .{}).module("lsp"));
    exe_mod.addImport("zts", b.dependency("zts", .{}).module("zts"));
    exe_mod.addOptions("config", options);

    // Create the executable
    const exe = b.addExecutable(.{
        .name = "turbobean",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    {
        const exe_check = b.addExecutable(.{
            .name = "turbobean",
            .root_module = exe_mod,
        });

        const check = b.step("check", "Check if TurboBean compiles");
        check.dependOn(&exe_check.step);
    }

    {
        // Add a unit test step
        const unit_tests = b.addTest(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        });

        const run_unit_tests = b.addRunArtifact(unit_tests);

        const test_step = b.step("test", "Run unit tests");
        test_step.dependOn(&run_unit_tests.step);

        // Golden tests
        const accept = b.option(bool, "golden-accept", "Accept golden outputs") orelse false;
        const golden_step = b.step("golden", "Run golden tests");

        const tests_path = std.fs.path.join(
            b.allocator,
            &.{ b.build_root.path.?, "tests", "golden" },
        ) catch @panic("OOM");

        var tests_dir = std.fs.openDirAbsolute(tests_path, .{ .iterate = true }) catch
            @panic("can't open golden test folder");
        defer tests_dir.close();

        var iter = tests_dir.iterate();
        while (iter.next() catch @panic("next")) |entry| {
            if (std.mem.endsWith(u8, entry.name, ".bean")) {
                const test_path = std.fmt.allocPrint(
                    b.allocator,
                    "tests/golden/{s}",
                    .{entry.name[0 .. entry.name.len - 5]},
                ) catch @panic("OOM");
                const golden = GoldenTest.create(b, exe, test_path, accept);
                golden_step.dependOn(&golden.step);
            }
        }
    }

    {
        // Add a run step
        const run_cmd = b.addRunArtifact(exe);
        run_cmd.step.dependOn(b.getInstallStep());
        if (b.args) |args| {
            run_cmd.addArgs(args);
        }

        const run_step = b.step("run", "Run the app");
        run_step.dependOn(&run_cmd.step);
    }
}
