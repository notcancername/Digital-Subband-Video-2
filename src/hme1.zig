const std = @import("std");
const simd = @import("simd");

fn blockTex(a: [*]const u8, stride: usize, width: usize, height: usize) usize {
    std.debug.assert(width <= 64);
    std.debug.assert(height <= 64);

    var sum_diff_h: u32 = 0;
    var sum_diff_v: u32 = 0;

    var row_cursor = a;
    var up_row_cursor = a;
    for (0..height) |_| {
        var left_sample = row_cursor[0];
        for (row_cursor, up_row_cursor, 0..width) |sample, up_sample, _| {
            sum_diff_h += @abs(@as(i16, sample) - @as(i16, left_sample));
            sum_diff_v += @abs(@as(i16, sample) - @as(i16, up_sample));

            left_sample = sample;
        }
        up_row_cursor = row_cursor;
        row_cursor += stride;
    }

    const nb_samples = width * height;
    std.debug.assert(@popCount(nb_samples) == 1);

    // bsf has undefined results for its operand being zero, no branch if tzcnt is not available
    std.debug.assert(nb_samples != 0);

    const log2_width_times_height: std.math.Log2Int(u32) = @intCast(@ctz(nb_samples));

    return @intCast(@max(sum_diff_h, sum_diff_v) >> log2_width_times_height);
}

fn blockTexSimd(a: [*]const u8, stride: usize, width: usize, height: usize) usize {
    std.debug.assert(width % 4 == 0);
    std.debug.assert(width <= 64);
    std.debug.assert(height <= 64);

    var sum_diff_h: u32 = 0;
    var sum_diff_v: u32 = 0;

    var row_cursor = a;
    var up_row_cursor = a;
    for (0..height) |_| {
        const row_end = row_cursor + width;
        var column_cursor = row_cursor;
        var up_column_cursor = up_row_cursor;
        var left_sample: i16 = column_cursor[0];

        comptime var len = std.simd.suggestVectorLength(i16) orelse 0;

        inline while (len >= 4) : (len = @divExact(len, 2)) {
            const offset = width % (len);

            const V = @Vector(len, i16);

            const end_of_simd = row_end - offset;

            while (@intFromPtr(column_cursor) < @intFromPtr(end_of_simd)) {
                const v_left: V = column_cursor[0..len].*;

                const v_up: V = up_column_cursor[0..len].*;

                sum_diff_h += @reduce(.Add, @abs(std.simd.shiftElementsRight(v_left, 1, left_sample) - v_left));
                sum_diff_v += @reduce(.Add, @abs(v_left - v_up));

                column_cursor += len;
                up_column_cursor += len;
                left_sample = v_left[len - 1];
            }
        }

        // {
        //     while (@intFromPtr(column_cursor) < @intFromPtr(row_end)) {
        //         const sample = column_cursor[0];
        //         const up_sample = up_column_cursor[0];
        //         sum_diff_h += @abs(@as(i16, sample) - @as(i16, left_sample));
        //         sum_diff_v += @abs(@as(i16, sample) - @as(i16, up_sample));

        //         left_sample = sample;

        //         column_cursor += 1;
        //         up_column_cursor += 1;
        //     }
        // }
        up_row_cursor = row_cursor;
        row_cursor += stride;
    }

    const nb_samples = width * height;
    std.debug.assert(@popCount(nb_samples) == 1);

    // bsf has undefined results for its operand being zero, no branch if tzcnt is not available
    std.debug.assert(nb_samples != 0);

    const log2_width_times_height: std.math.Log2Int(u32) = @intCast(@ctz(nb_samples));

    return @intCast(@max(sum_diff_h, sum_diff_v) >> log2_width_times_height);
}

export fn block_tex(a: [*]const u8, a_stride: c_int, width: c_int, height: c_int) c_uint {
    const res: c_uint = @intCast(blockTexSimd(
        a,
        @intCast(a_stride),
        @intCast(width),
        @intCast(height),
    ));
    if (@import("builtin").mode == .Debug) {
        const c_res = @extern(*const @TypeOf(block_tex), .{ .name = "c_block_tex" })(
            a,
            a_stride,
            width,
            height,
        );
        if (c_res != res) {
            @panic("mfw");
        }
    }
    return res;
}

fn blockVar(a: [*]const u8, stride: usize, width: usize, height: usize) struct { u8, u32 } {
    std.debug.assert(width % 4 == 0);
    std.debug.assert(width <= 64);
    std.debug.assert(height <= 64);

    var sum_of_samples: u32 = 0;

    for (0..width) |row| {
        var a_cursor = a + row * stride;
        const row_end = a_cursor + width;

        comptime var len = std.simd.suggestVectorLength(u16) orelse 0;
        inline while (len >= 4) : (len = @divExact(len, 2)) {
            const V = @Vector(len, u16);
            const offset = width % len;
            const end_of_simd = row_end - offset;

            while (@intFromPtr(a_cursor) < @intFromPtr(end_of_simd)) : (a_cursor += len) {
                const a_vec: V = a_cursor[0..len].*;

                sum_of_samples += @reduce(.Add, a_vec);
            }
        }

        // while (@intFromPtr(a_cursor) < @intFromPtr(row_end)) : (a_cursor += 1) {
        //     sum_of_samples += a_cursor[0];
        // }
    }

    const nb_samples = width * height;
    std.debug.assert(@popCount(nb_samples) == 1);

    // bsf has undefined results for its operand being zero, no branch if tzcnt is not available
    std.debug.assert(nb_samples != 0);

    const log2_width_times_height: std.math.Log2Int(u32) = @intCast(@ctz(nb_samples));

    const average: i16 = @intCast(sum_of_samples >> log2_width_times_height);

    var sum_abs_diff_var: u32 = 0;

    for (0..width) |row| {
        var a_cursor = a + row * stride;
        const row_end = a_cursor + width;

        comptime var len = std.simd.suggestVectorLength(i16) orelse 0;
        inline while (len >= 4) : (len = @divExact(len, 2)) {
            const V = @Vector(len, i16);
            const offset = width % len;
            const end_of_simd = row_end - offset;

            while (@intFromPtr(a_cursor) < @intFromPtr(end_of_simd)) : (a_cursor += len) {
                const a_vec: V = a_cursor[0..len].*;
                const all_average: V = @splat(average);

                sum_abs_diff_var += @reduce(.Add, @abs(a_vec - all_average));
            }
        }

        while (@intFromPtr(a_cursor) < @intFromPtr(row_end)) : (a_cursor += 1) {
            sum_abs_diff_var += @abs(@as(i16, a_cursor[0]) - average);
        }
    }

    const variance: u32 = @intCast(sum_abs_diff_var >> @intCast(log2_width_times_height));

    return .{
        @intCast(average),
        variance,
    };
}

export fn block_var(
    a: [*]const u8,
    a_stride: c_int,
    width: c_int,
    height: c_int,
    avg: *c_uint,
) c_uint {
    const average, const res = blockVar(
        a,
        @intCast(a_stride),
        @intCast(width),
        @intCast(height),
    );

    if (@import("builtin").mode == .Debug) {
        var c_avg: c_uint = undefined;
        const c_res = @extern(*const @TypeOf(block_var), .{ .name = "c_block_var" })(
            a,
            @intCast(a_stride),
            @intCast(width),
            @intCast(height),
            &c_avg,
        );
        if (c_res != res or c_avg != average) {
            std.log.debug("res {d} {d} avg {d} {d}", .{ c_res, res, c_avg, average });
            @panic("mfw");
        }
    }

    avg.* = @intCast(average);
    return @intCast(res);
}
