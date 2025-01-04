const std = @import("std");
const builtin = @import("builtin");

// TODO: use CPUID
const has_sse2 = builtin.cpu.arch.isX86() and std.Target.x86.featureSetHas(builtin.cpu.features, .sse2);

pub fn sad(
    noalias a: [*]const u8,
    a_stride: usize,
    noalias b: [*]const u8,
    b_stride: usize,
    height: usize,
    width: usize,
) usize {
    var sum: usize = 0;

    for (0..height) |row| {
        const a_row = a + row * a_stride;
        const b_row = b + row * b_stride;

        for (a_row, b_row, 0..width) |a_sample, b_sample, _| {
            sum += @abs(@as(i32, a_sample) - @as(i32, b_sample));
        }
    }

    return @intCast(sum);
}

pub fn fastSad(
    noalias a: [*]const u8,
    a_stride: usize,
    noalias b: [*]const u8,
    b_stride: usize,
    height: usize,
    width: usize,
) usize {
    return switch (width) {
        16 => @call(.always_inline, sad, .{ a, a_stride, b, b_stride, height, comptime 16 }),
        24 => @call(.always_inline, sad, .{ a, a_stride, b, b_stride, height, comptime 24 }),
        32 => @call(.always_inline, sad, .{ a, a_stride, b, b_stride, height, comptime 32 }),
        48 => @call(.always_inline, sad, .{ a, a_stride, b, b_stride, height, comptime 48 }),
        64 => @call(.always_inline, sad, .{ a, a_stride, b, b_stride, height, comptime 64 }),
        else => sad(a, a_stride, b, b_stride, height, width),
    };
}

export fn fastsad(
    a: [*]const u8,
    as: c_int,
    b: [*]const u8,
    bs: c_int,
    w: c_int,
    h: c_int,
) c_int {
    return @intCast(fastSad(a, @intCast(as), b, @intCast(bs), @intCast(w), @intCast(h)));
}
