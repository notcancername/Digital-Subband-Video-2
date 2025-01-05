const std = @import("std");
const simd = @import("simd");
const builtin = @import("builtin");

// TODO: use CPUID

pub fn _sad(
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
            sum += @abs(@as(i16, a_sample) - @as(i16, b_sample));
        }
    }

    return @intCast(sum);
}

pub fn sadSimd(
    noalias a: [*]const u8,
    a_stride: usize,
    noalias b: [*]const u8,
    b_stride: usize,
    height: usize,
    width: usize,
) u32 {
    if (comptime !simd.have_sad_u8x8) return _sad(a, a_stride, b, b_stride, height, width);

    var sum: u32 = 0;

    for (0..height) |row| {
        var a_row = a + row * a_stride;
        const a_end = a_row + width;
        var b_row = b + row * b_stride;
        comptime var len = std.simd.suggestVectorLength(u8).?;

        inline while (len >= 8) : (len = @divExact(len, 2)) {
            const offset = width % len;

            const V = @Vector(len, u8);

            const a_end_of_simd = a_end - offset;

            while (@intFromPtr(a_row) < @intFromPtr(a_end_of_simd)) {
                const va: V = a_row[0..len].*;
                const vb: V = b_row[0..len].*;
                sum += simd.sad(V, va, vb);
                b_row += len;
                a_row += len;
            }
        }

        const rest_len = a_end - a_row;
        for (a_row, b_row, 0..rest_len) |a_sample, b_sample, _| {
            @branchHint(.unlikely);
            sum += @abs(@as(i16, a_sample) - @as(i16, b_sample));
        }
    }

    return @intCast(sum);
}

fn rmseSimd(
    noalias a: [*]const u8,
    a_stride: usize,
    noalias b: [*]const u8,
    b_stride: usize,
    height: usize,
    comptime width: usize,
) u32 {
    if (comptime !simd.have_sad_u8x8) return _sad(a, a_stride, b, b_stride, height, width);

    var sum: u32 = 0;

    for (0..height) |row| {
        var a_row = a + row * a_stride;
        const a_end = a_row + width;
        var b_row = b + row * b_stride;
        comptime var len = std.simd.suggestVectorLength(u8).?;

        inline while (len >= 8) : (len = @divExact(len, 2)) {
            const offset = width % len;

            if (len <= offset) {
                const V = @Vector(len, u8);

                const a_end_of_simd = a_end - offset;

                while (@intFromPtr(a_row) < @intFromPtr(a_end_of_simd)) {
                    const va: V = a_row[0..len].*;
                    const vb: V = b_row[0..len].*;
                    sum += simd.sad(V, va, vb);
                    b_row += len;
                    a_row += len;
                }
            }
        }

        const rest_len = a_end - a_row;
        for (a_row, b_row, 0..rest_len) |a_sample, b_sample, _| {
            @branchHint(.unlikely);
            sum += @abs(@as(i16, a_sample) - @as(i16, b_sample));
        }
    }

    return @intCast(sum);
}

pub fn sadCW(
    sad: anytype,
    noalias a: [*]const u8,
    a_stride: usize,
    noalias b: [*]const u8,
    b_stride: usize,
    height: usize,
    comptime width: usize,
) u32 {
    return @call(.always_inline, sad, .{ a, a_stride, b, b_stride, height, comptime width });
}

const use_rmse = false;

pub fn fastSad(
    noalias a: [*]const u8,
    a_stride: usize,
    noalias b: [*]const u8,
    b_stride: usize,
    height: usize,
    width: usize,
) usize {
    const sad = if (use_rmse) rmseSimd else sadSimd;
    return switch (width) {
        inline 16, 24, 32, 48, 64 => |cw| sadCW(sad, a, a_stride, b, b_stride, height, cw),
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
