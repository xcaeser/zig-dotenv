const std = @import("std");

pub fn build(b: *std.Build) void {
    // Standard target options and optimization
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Create the module
    _ = b.addModule("dotenv", .{
        .root_source_file = b.path("src/dotenv.zig"),
    });

    // Add the library for consumers
    const lib = b.addStaticLibrary(.{
        .name = "dotenv",
        .root_source_file = b.path("src/dotenv.zig"),
        .target = target,
        .optimize = optimize,
    });
    lib.linkLibC();
    b.installArtifact(lib);

    // Create tests
    const lib_test = b.addTest(.{
        .root_source_file = b.path("src/dotenv.zig"),
        .target = target,
        .optimize = optimize,
    });
    lib_test.linkLibC();

    const run_test = b.addRunArtifact(lib_test);
    run_test.has_side_effects = true;

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_test.step);
}
