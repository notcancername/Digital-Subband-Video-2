const std = @import("std");

fn zigObject(b: *std.Build, name: []const u8, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, strip: bool) *std.Build.Step.Compile {
    return b.addObject(.{
        .name = name,
        .root_source_file = b.path(std.fmt.allocPrint(b.allocator, "src/{s}.zig", .{name}) catch @panic("OOM")),
        .target = target,
        .link_libc = true,
        .optimize = optimize,
        .strip = strip,
    });
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseFast });
    const strip = b.option(bool, "strip", "Whether to strip symbols from the binary, defaults to false") orelse false;

    const sad = zigObject(b, "sad", target, optimize, strip);
    sad.root_module.addImport("simd", b.dependency("simd", .{ .target = target, .optimize = optimize }).module("simd"));

    const hme1 = zigObject(b, "hme1", target, optimize, strip);
    hme1.root_module.addImport("simd", b.dependency("simd", .{ .target = target, .optimize = optimize }).module("simd"));

    // Create the executable
    const bin = b.addExecutable(.{
        .name = "dsv2",
        .target = target,
        .link_libc = true,
        .optimize = optimize,
        .strip = strip,
    });

    // Add C source files
    bin.addCSourceFiles(.{
        .files = &.{
            "src/bmc.c",
            "src/bs.c",
            "src/dsv.c",
            "src/dsv_decoder.c",
            "src/dsv_encoder.c",
            "src/dsv_main.c",
            "src/frame.c",
            "src/hme.c",
            "src/hzcc.c",
            "src/sbt.c",
            "src/util.c",
        },
        .flags = &.{
            "-std=c89",
            "-Wall",
            "-Wextra",
            "-Wpedantic",
            "-Werror",
            "-ggdb3",
            "-gdwarf",
        },
    });
    bin.addObject(sad);
    bin.addObject(hme1);

    b.installArtifact(bin);
}
