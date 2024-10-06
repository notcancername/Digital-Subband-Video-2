// Hierarchical Motion Estimation
const std = @import("std");
const dsv = @import("dsv.zig");

// TODO: maybe it's better to use more descriptive types like `Pow2Int(std.math.IntFittingRange(0, 255 * 255 / 4))` instead of `u16`

const qpel_check_threshold = 3;

// luma value under which chroma errors are given less or no importance
const luma_chroma_cutoff = 64;

// subpel_sad_size + 1 should be a power of two for performance reasons
const subpel_sad_size = 15;
const subpel_dim = subpel_sad_size + 1;
const halfpel_dim = subpel_dim * 2;

const Subpel = enum(u3) {
    full = 1,
    half = 2,
    quarter = 4,

    pub fn stride(sp: Subpel) usize {
        return @as(usize, subpel_dim) * @intFromEnum(sp);
    }

    pub fn offset(sp: Subpel, full_x: usize, full_y: usize) usize {
        return (@intFromEnum(sp) * full_x + @intFromEnum(sp) * full_y) * stride(sp);
    }
};

const ChromaAnalysis = struct {
    // green in color, our eyes are more sensitive to greener colors
    greenish: bool,

    // high frequency colors (blue, violet), our eyes are less sensitive to these
    hifreq: bool,

    // almost achromatic, (I think) our eyes can notice chroma error more in greyish regions
    greyish: bool,

    // similar in hue to human skin, important to keep these better quality
    // (least racist video codec --cancername)
    skinnish: bool,

    pub fn analyze(y: u8, cb: u8, cr: u8) ChromaAnalysis {
        const i_cb, const i_cr = .{
            @as(i16, cb),
            @as(i16, cr),
        };

        const ca: ChromaAnalysis = .{
            .greenish = cb < 128 and cr < 128,
            .greyish = @abs(i_cb - 128) < 8 and @abs(i_cr - 128) < 8,
            // terrible approximation
            .skinnish = y > 80 and y < 230 and @abs(i_cb - 108) < 24 and @abs(i_cr - 148) < 24,
            .hifreq = undefined,
        };
        ca.hifreq = cb > 160 and !ca.greyish and !ca.skinnish;
        return ca;
    }
};

// this function is intended to 'prove' to the intra decision
// that the ref block with (0,0) motion does more good than evil
pub fn isRefBlockGood(
    a: [*]const u8,
    a_stride: usize,
    b: [*]const u8,
    b_stride: usize,
    height: usize,
    width: usize,
) u32 {
    var good_score: u32 = 0;
    var evil_score: u32 = 0;

    var up_a_row = a;
    var up_b_row = b;

    for (0..height) |row| {
        const a_row = a + row * a_stride;
        const b_row = b + row * b_stride;

        var left_a_sample = a_row[0];
        var left_b_sample = b_row[0];

        for (a_row, b_row, up_a_row, up_b_row, 0..width) |
            a_sample,
            b_sample,
            up_a_sample,
            up_b_sample,
            _,
        | {
            // high texture = beneficial to 'good' decision (inter)
            // because intra blocks don't keep high frequency details
            var texture: u32 = @abs(@as(i16, a_sample) - b_sample);

            texture += @abs(@as(i16, a_sample) - left_a_sample);
            texture += @abs(@as(i16, a_sample) - up_a_sample);

            texture += @abs(@as(i16, b_sample) - left_b_sample);
            texture += @abs(@as(i16, b_sample) - up_b_sample);

            left_a_sample = a_sample;
            left_b_sample = b_sample;
        }

        up_a_row = a_row;
        up_b_row = b_row;
    }

    return good_score >= (((width + height) / 2) * evil_score);
}

pub fn isBlockInvalid(frame: dsv.Frame, x: i32, y: i32, sx: i32, sy: i32) bool {
    const b = @as(i32, @intCast(frame._border)) * dsv.constants.frame_border;
    return x < -b or y < -b or x + sx > frame._width + b or y + sy > frame._height + b;
}


pub fn isBlockEncodable(
    decoded_plane: dsv.Plane,
    reference_plane: dsv.Plane,
    width: u32,
    height: u32,
) u32 {
    const threshold = 0;

    const reference_avg: u8 = compute_average: {
        var row_cursor = reference_plane.data;
        var sum: u32 = 0;
        for (0..height) |_| {
            for (0..width) |column| {
                sum += row_cursor[column];
            }
            row_cursor += reference_plane._stride;
        }
        break :compute_average @intCast(sum / (width * height));
    };

    var nb_errors: u8 = 0;

    var decoded_row_cursor = decoded_plane.data;
    for (0..height) |_| {
        for (decoded_row_cursor[0..width]) |decoded_sample| {
            const expected_sample = clampToType(u8, (reference_avg + clampToType(u8, (@as(i16, decoded_sample - reference_avg) + 128))) - 128);

            if (expected_sample != decoded_sample) nb_errors += 1;
        }
        if (nb_errors > threshold) return false;

        decoded_row_cursor += decoded_plane._stride;
    }
    return true;
}

pub const TextureInfo = struct {
    average: u8,
    variance: u16,
    texture: u8,

    pub fn analyze(
        data: [*]const u8,
        stride: u32,
    ) TextureInfo {
        var sum_diff_2: u32 = 0;
        var sum: u32 = 0;
        var sum_of_squares: u32 = 0;

        var row_cursor = data;
        var up_row_cursor = data;
        for (0..half_pel_sad_size) |_| {
            var left_sample = row_cursor[0];
            for (row_cursor, up_row_cursor, 0..half_pel_sad_size) |sample, up_sample, _| {
                sum_diff_2 += @abs(@as(i16, sample) - @as(i16, left_sample));
                sum_diff_2 += @abs(@as(i16, sample) - @as(i16, up_sample));

                sum += sample;
                sum_of_squares += @as(u16, sample) * @as(u16, sample);

                left_sample = sample;
            }
            up_row_cursor = row_cursor;
            row_cursor += stride;
        }

        const nb_samples = half_pel_sad_size * half_pel_sad_size;

        const sum_diff = sum_diff_2 / 2;
        return .{
            .average = @intCast(sum / nb_samples),
            .variance = @intCast((sum_of_squares - @as(u64, sum) * @as(u64, sum)) / nb_samples),
            .texture = @intCast(sum_diff / nb_samples),
        };
    }

    inline fn unpack(ti: TextureInfo) struct { u8, u16, u8 } {
        return .{ ti.average, ti.variance, ti.texture };
    }
};

pub const AnalysisInfo = struct {
    variance: u16,
    texture: u8,

    pub fn analyze(
        plane: *const dsv.Plane,
        stride: u32,

        width: u32,
        height: u32,
    ) AnalysisInfo {
        // max block size
        std.debug.assert(width <= 64);
        std.debug.assert(height <= 64);

        var sum_diff_2: u32 = 0;
        var sum: u32 = 0;
        var sum_of_squares: u32 = 0;

        var row_cursor = plane.data;
        var up_row_cursor = plane.data;
        for (0..height) |_| {
            var left_sample = row_cursor[0];
            for (row_cursor, up_row_cursor, 0..width) |sample, up_sample, _| {
                sum_diff_2 += @abs(@as(i16, sample) - @as(i16, left_sample));
                sum_diff_2 += @abs(@as(i16, sample) - @as(i16, up_sample));

                sum += sample;
                sum_of_squares += @as(u16, sample) * @as(u16, sample);

                left_sample = sample;
            }
            up_row_cursor = row_cursor;
            row_cursor += stride;
        }

        const sum_diff = sum_diff_2 / 2;

        const nb_samples = width * height;
        // safety check
        std.debug.assert(@popCount(nb_samples) == 1);

        // bsf has undefined results for its operand being zero, no branch if tzcnt is not available
        std.debug.assert(nb_samples != 0);

        const log2_width_times_height: std.math.Log2Int(u32) = @intCast(@ctz(width * height));

        // TODO experiment: avoid 64-bit math and overflow by dividing early
        if (false) {
            const avg = sum >> log2_width_times_height;
            const avg_of_sq = sum_of_squares >> log2_width_times_height;

            return .{
                // this expression rewritten to avoid overflow. less precise.
                .variance = @intCast(avg_of_sq - (avg * avg)),
                .texture = @intCast(sum_diff >> log2_width_times_height),
            };
        } else {
            return .{
                // 2^64-1 > (255 * 64^2)^2 > 2^32-1
                .variance = @intCast((sum_of_squares - @as(u64, sum) * @as(u64, sum)) >> log2_width_times_height),
                .texture = @intCast(sum_diff >> log2_width_times_height),
            };
        }
    }

    inline fn unpack(ai: AnalysisInfo) struct { u16, u8 } {
        return .{ ai.variance, ai.texture };
    }
};

pub const Hme = extern struct {
    params: *dsv.Params,
    source_frames: [dsv.encoder.max_pyramid_levels + 1]?*dsv.Frame,
    ref_frames: [dsv.encoder.max_pyramid_levels + 1]?*dsv.Frame,
    mv_field: [dsv.encoder.max_pyramid_levels + 1]?[*]dsv.Mv,
    _nb_levels: c_int,

    pub fn refineLevel(hme: Hme, level: u8) u32 {
        std.debug.assert(level <= hme._nb_levels);

        const blk_columns = hme.params._block_width;
        const blk_rows = hme.params._block_height;

        const source = hme.source_frames[level] orelse unreachable;
        const ref = hme.ref_frames[level] orelse unreachable;
        _ = ref; // autofix

        const nb_row_blk = hme.params.nbRowBlocks();
        const nb_column_blk = hme.params.nbColumnBlocks();

        hme.mv_field[level] = dsv.allocator.alloc(dsv.Mv, nb_row_blk * nb_column_blk) catch @panic("OOM");

        const mv_field = hme.mv_field[level];

        const step = 1 << level;

        var row_cursor: usize = 0;
        while (row_cursor < nb_row_blk) : (row_cursor += step) {
            var column_cursor: usize = 0;
            while (column_cursor < nb_column_blk) : (column_cursor += step) {
                const full = struct {
                    const nb_search = 9;
                    const x: [nb_search]comptime_int = .{ 0,  1, -1, 0,  0, -1,  1, -1, 1 };
                    const y: [nb_search]comptime_int = .{ 0,  0,  0, 1, -1, -1, -1,  1, 1 };
                };
                _ = full; // autofix
                const half = struct {
                    const nb_search = 8;
                    const x: [nb_search]comptime_int = .{ 1, -1, 0,  0, -1,  1, -1, 1 };
                    const y: [nb_search]comptime_int = .{ 0,  0, 1, -1, -1, -1,  1, 1 };
                };
                _ = half; // autofix

                var best_mv = dsv.Mv.zero;
                best_mv._is_intra = @intFromBool(false);

                const b_column = (column_cursor * blk_columns) >> level;
                const b_row = (row_cursor * blk_rows) >> level;

                if (b_column >= source.getWidth() or b_row >= source.getHeight()) {
                    mv_field[row_cursor * nb_column_blk + column_cursor] = best_mv;
                    continue;
                }



            }
        }

    }

};
