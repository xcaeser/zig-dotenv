const std = @import("std");

pub fn build(b: *std.Build) void {
    // Standard target options and optimization
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Create the module
    const mod = b.addModule("dotenv", .{
        .root_source_file = b.path("src/dotenv.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    // for local testing
    // addMainExecutable(b, target, optimize);

    // Create tests
    const lib_test = b.addTest(.{
        .root_module = mod,
    });

    const run_test = b.addRunArtifact(lib_test);
    run_test.has_side_effects = true;

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_test.step);

    const docs_step = b.step("docs", "Build the zig-dotenv library docs");
    const docs_obj = b.addObject(.{
        .name = "dotenv",
        .root_module = mod,
    });
    const docs = docs_obj.getEmittedDocs();
    docs_step.dependOn(&b.addInstallDirectory(.{
        .source_dir = docs,
        .install_dir = .prefix,
        .install_subdir = "docs",
    }).step);
}

fn addMainExecutable(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) void {
    const exe = b.addExecutable(.{
        .name = "ee",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");

    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
}
