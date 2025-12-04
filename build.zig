const std = @import("std");
const GoldenTest = @import("build/GoldenTest.zig");

const zon_version = std.SemanticVersion.parse(@import("build.zig.zon").version) catch unreachable;

pub fn build(b: *std.Build) void {
    const embed_static = b.option(bool, "embed-static", "Embed static assets into the binary") orelse false;
    const options = b.addOptions();
    options.addOption(bool, "embed_static", embed_static);
    options.addOption(std.SemanticVersion, "version", getVersion(b));

    const tracy_options = .{
        .enable_ztracy = b.option(
            bool,
            "enable-ztracy",
            "Enable Tracy profile markers",
        ) orelse false,
        .on_demand = b.option(
            bool,
            "tracy-on-demand",
            "Build tracy with TRACY_ON_DEMAND",
        ) orelse false,
    };

    const ztracy = b.dependency("ztracy", .{
        .enable_ztracy = tracy_options.enable_ztracy,
        .enable_fibers = false,
        .on_demand = tracy_options.on_demand,
    });

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_mod.addImport("lsp", b.dependency("lsp_kit", .{}).module("lsp"));
    exe_mod.addImport("zts", b.dependency("zts", .{}).module("zts"));
    exe_mod.addImport("ztracy", ztracy.module("root"));
    exe_mod.addOptions("config", options);

    // Create the executable
    const exe = b.addExecutable(.{
        .name = "turbobean",
        .root_module = exe_mod,
    });
    if (tracy_options.enable_ztracy) {
        exe.linkLibrary(ztracy.artifact("tracy"));
    }

    if (embed_static) {
        addAssetsOption(b, exe, target, optimize) catch |err| {
            std.log.err("Problem adding assets: {t}", .{err});
        };
    }

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
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/main.zig"),
                .target = target,
                .optimize = optimize,
            }),
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

/// Credits: https://github.com/ringtailsoftware/zig-embeddir
pub fn addAssetsOption(b: *std.Build, exe: anytype, target: anytype, optimize: anytype) !void {
    var options = b.addOptions();

    var files = std.array_list.Managed([]const u8).init(b.allocator);
    defer files.deinit();

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fs.cwd().realpath("src/assets", buf[0..]);

    var dir = try std.fs.openDirAbsolute(path, .{ .iterate = true });
    var walker = try dir.walk(b.allocator);
    defer walker.deinit();

    while (try walker.next()) |file| {
        if (file.kind != .file) {
            continue;
        }
        try files.append(b.dupe(file.path));
    }
    options.addOption([]const []const u8, "files", files.items);
    exe.step.dependOn(&options.step);

    const assets = b.addModule("assets", .{
        .root_source_file = options.getOutput(),
        .target = target,
        .optimize = optimize,
    });

    exe.root_module.addImport("assets", assets);
}

/// Leverage git describe to get the version
fn getVersion(b: *std.Build) std.SemanticVersion {
    const argv: []const []const u8 = &.{
        "git", "-C", b.pathFromRoot("."), "--git-dir", ".git", "describe", "--match", "*.*.*", "--tags",
    };
    var code: u8 = undefined;
    const git_describe_untrimmed = b.runAllowFail(argv, &code, .Ignore) catch |err| {
        const argv_joined = std.mem.join(b.allocator, " ", argv) catch @panic("OOM");
        std.log.warn(
            \\Failed to run git describe to resolve turbobean version: {}
            \\command: {s}
            \\
            \\Falling back to zon file version: {f}
        , .{ err, argv_joined, zon_version });
        return zon_version;
    };

    const git_describe = std.mem.trim(u8, git_describe_untrimmed, " \n\r");

    switch (std.mem.count(u8, git_describe, "-")) {
        0 => {
            // Tagged release version (e.g. 0.10.0).
            return std.SemanticVersion.parse(git_describe) catch unreachable;
        },
        2 => {
            // Untagged development build (e.g. 0.10.0-dev.216+34ce200).
            var it = std.mem.splitScalar(u8, git_describe, '-');
            const tagged_ancestor = it.first();
            const commit_height = it.next().?;
            const commit_id = it.next().?;
            std.debug.assert(std.mem.startsWith(u8, commit_id, "g")); // commit hash is prefixed with a 'g'

            const ancestor_ver = std.SemanticVersion.parse(tagged_ancestor) catch unreachable;

            return .{
                .major = ancestor_ver.major,
                .minor = ancestor_ver.minor,
                .patch = ancestor_ver.patch,
                .pre = b.fmt("dev.{s}", .{commit_height}),
                .build = commit_id[1..],
            };
        },
        else => {
            std.debug.print("Unexpected 'git describe' output: '{s}'\n", .{git_describe});
            std.process.exit(1);
        },
    }
}
