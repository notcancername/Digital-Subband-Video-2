 const std = @import("std");

pub const hme = @import("hme.zig");
pub const encoder = @import("encoder.zig");
pub const fastSad = @import("sad.zig").fastSad;

pub const fourcc = "DSV2".*;
pub const minor_version = 0;

pub const min_block_size = 16;
pub const max_block_size = 32;

pub const frame_border = max_block_size;

pub fn isRepresentable(v: anytype, T: type) bool {
    return v >= std.math.minInt(T) and v <= std.math.maxInt(T);
}

pub fn Pow2Int(T: type) type {
    const ti = @typeInfo(T).int;
    return @Type(.{.int = .{
        .bits = std.math.ceilPowerOfTwo(u16, ti.bits) catch unreachable,
        .signedness = ti.signedness,
    }});
}

fn clampToType(T: type, src: anytype) @TypeOf(src) {
    return std.math.clamp(src, std.math.minInt(T), std.math.maxInt(T));
}

fn clampCast(T: type, src: anytype) T {
    return @intCast(clampToType(T, src));
}

pub const PacketType = packed union {
    metadata: u8,
    eos: packed struct(u8) {
        _pad0: u4 = 0,
        is_eos: bool,
        _pad1: u3 = 0,
    },
    pic: packed struct(u8) {
        has_ref: bool,
        is_ref: bool,
        is_pic: bool,
        _pad: u5 = 0,
    },

    pub const Kind = enum {
        metadata,
        eos,
        pic,
    };

    pub fn isValid(pt: PacketType) bool {
        return pt.metadata == 0 or (pt.pic.is_pic and pt.pic._pad == 0) or (pt.eos.is_eos and pt.eos._pad == 0 and pt.eos._pad1 == 0);
    }

    pub fn kind(pt: PacketType) Kind {
        std.debug.assert(pt.isValid());
        return if (pt.metadata == 0)
            .metadata
        else if (pt.eos.is_eos)
            .eos
        else if (pt.pic.is_pic)
            .pic
        else
            unreachable;
    }
};

pub const Format = packed struct(c_int) {
    vertical: Shift,
    horizontal: Shift,
    _pad: @Type(.{ .Int = .{
        .bits = @bitSizeOf(c_int) - 2 * @bitSizeOf(Shift),
        .signedness = .unsigned,
        } }) = 0,

    pub const Shift = enum(u2) {
        full,
        divby_2,
        divby_4,
    };

    pub fn isValid(f: Format) bool {
        return f._pad == 0 and @as(u2, @bitCast(f.vertical)) < 2 and @as(u2, @bitCast(f.vertical)) < 2;
    }
};

pub const Plane = extern struct {
    data: [*]u8,
    _len: c_int,

    format: Format,
    _stride: c_int,

    _width: c_int,
    _height: c_int,

    _h_shift: c_int,
    _v_shift: c_int,

    pub fn isValid(p: Plane) bool {
        const representable = check: {
            var result: bool = true;
            for (.{ p._width, p._height, p._stride }) |v|
                result = result and isRepresentable(v, u32);
            break :check result;
        };

        if (!representable) return false;

        const wh_nonzero = p._width != 0 and p._height != 0;

        const wh_overflow = std.meta.isError(std.math.mul(
            u32,
            @intCast(p._width),
            @intCast(p._height),
        ));

        const shift_correct = p._h_shift < 2 and p._v_shift < 2;

        if (!shift_correct or !p.format.isValid()) return false;

        const reconstructed_format: Format = .{
            .vertical = @intCast(p._v_shift),
            .horizontal = @intCast(p._h_shift),
        };

        const format_matches_shifts = @as(c_int, @bitCast(reconstructed_format)) == @as(c_int, @bitCast(p.format));


        return format_matches_shifts and !wh_overflow and wh_nonzero;
    }


    pub fn getWidth(plane: Plane) u32 {
        std.debug.assert(plane.isValid());
        return @intCast(plane._width);
    }

    pub fn getHeight(plane: Plane) u32 {
        std.debug.assert(plane.isValid());
        return @intCast(plane._height);
    }

    pub fn getStride(plane: Plane) u32 {
        std.debug.assert(plane.isValid());
        return @intCast(plane._stride);
    }

    pub fn getFormat(plane: Plane) Format {
        std.debug.assert(plane.isValid());
        return plane.format;
    }
};

pub const Frame = extern struct {
    buf: [*]u8,
    planes: [3]Plane,

    _reference_count: c_int,

    format: Format,
    _width: c_int,
    _height: c_int,

    _border: c_int,

    pub fn isValid(f: Frame) bool {
        const representable = check: {
            var result: bool = true;
            for (.{ f._width, f._height, f._border }) |v|
                result = result and isRepresentable(v, u32);
            break :check result;
        };

        if (!representable) return false;

        const is_referenced = f._reference_count > 0;

        const wh_nonzero = f._width != 0 and f._height != 0;

        const wh_overflow = std.meta.isError(std.math.mul(
            u32,
            @intCast(f._width),
            @intCast(f._height),
        ));

        const planes_valid = f.planes[0].isValid() and f.planes[1].isValid() and f.planes[2].isValid();

        return planes_valid and f.format.isValid() and !wh_overflow and is_referenced and wh_nonzero;
    }

    pub fn getWidth(frame: Frame) u32 {
        std.debug.assert(frame.isValid());
        return @intCast(frame._width);
    }

    pub fn getHeight(frame: Frame) u32 {
        std.debug.assert(frame.isValid());
        return @intCast(frame._height);
    }

    pub fn getBorder(frame: Frame) u32 {
        std.debug.assert(frame.isValid());
        return @intCast(frame._border);
    }
};

pub const Meta = extern struct {
    _width: c_int,
    _height: c_int,
    subsampling: Format,

    _fps_num: c_int,
    _fps_den: c_int,

    _sar_num: c_int,
    _sar_den: c_int,

    pub fn isValid(m: Meta) bool {
        const representable = check: {
            var result: bool = true;
            for (.{ m._width, m._height, m._fps_num, m._fps_den, m._sar_num, m._sar_den }) |v|
                result = result and isRepresentable(v, u32);
            break :check result;
        };

        if (!representable) return false;

        const wh_valid = m._width != 0 and m._height != 0;

        const wh_overflow = std.meta.isError(std.math.mul(
            u32,
            @intCast(m.block_width),
            @intCast(m.block_height),
        ));

        const ratios_nonzero = m._fps_num != 0 and m._sar_den != 0;
        const denominators_nonzero = m._fps_den != 0 and m._sar_den != 0;

        return wh_valid and ratios_nonzero and denominators_nonzero and !wh_overflow;
    }

    pub fn getWidth(m: Meta) u32 {
        std.debug.assert(m.isValid());
        return @intCast(m.width);
    }

    pub fn getHeight(m: Meta) u32 {
        std.debug.assert(m.isValid());
        return @intCast(m.height);
    }
};

pub const Params = extern struct {
    meta: Meta,

    _is_ref: c_int,
    _has_ref: c_int,

    _block_width: c_int,
    _block_height: c_int,

    _nb_column_blocks: c_int,
    _nb_row_blocks: c_int,

    pub fn isValid(p: Params) bool {
        const representable = check: {
            var result: bool = true;
            for (.{ p._block_width, p._block_height, p._nb_row_blocks, p._nb_column_blocks }) |v|
                result = result and isRepresentable(v, u32);
            break :check result;
        };

        if (!representable) return false;

        const wh_valid = p._width != 0 and p._height != 0;
        const cr_valid = p._nb_row_blocks != 0 and p._nb_column_blocks != 0;

        const wh_overflow = std.meta.isError(std.math.mul(
            u32,
            @intCast(p._block_width),
            @intCast(p._block_height),
        ));

        const cr_overflow = std.meta.isError(std.math.mul(
            u32,
            @intCast(p._nb_row_blocks),
            @intCast(p._nb_column_blocks),
        ));

        return p.meta.isValid() and wh_valid and cr_valid and !wh_overflow and !cr_overflow;
    }

    pub fn isRef(p: Params) bool {
        std.debug.assert(p.isValid());
        return p._is_ref != 0;
    }

    pub fn hasRef(p: Params) bool {
        std.debug.assert(p.isValid());
        return p._has_ref != 0;
    }

    pub fn blockWidth(p: Params) u32 {
        std.debug.assert(p.isValid());
        return @intCast(p._block_width);
    }

    pub fn blockHeight(p: Params) u32 {
        std.debug.assert(p.isValid());
        return @intCast(p._block_height);
    }

    pub fn nbColumnBlocks(p: Params) u32 {
        std.debug.assert(p.isValid());
        return @intCast(p.block_rows);
    }

    pub fn nbRowBlocks(p: Params) u32 {
        std.debug.assert(p.isValid());
        return @intCast(p.block_columns);
    }
};

pub const SmallMvs = struct {
    pub const Flags = packed struct(u8) {
        is_intra: bool,
        is_top_left_intra: bool,
        is_top_right_intra: bool,
        is_bottom_left_intra: bool,
        is_bottom_right_intra: bool,
        is_variance_low: bool,
        is_texture_low: bool,
        is_detail_high: bool,
    };

    pub const Vec = struct {
        x: i16,
        y: i16,

        pub fn isNonzero(v: Vec) bool {
            return v.x != 0 and v.y != 0;
        }
    };

    flags: [*]u32,
    vecs: [*]Vec
};

pub const Mv = extern struct {
    pub const Mask = packed struct(u8) {
        top_left_intra: bool,
        top_right_intra: bool,
        bottom_left_intra: bool,
        bottom_right_intra: bool,
        _pad: u4 = 0,

        pub fn isValid(m: Mask) bool {
            return m._pad == 0;
        }
    };

    v: extern struct {
        x: i16,
        y: i16,

        pub fn isNonzero(v: @This()) bool {
            return v.x != 0 and v.y != 0;
        }
    },

    _is_intra: u8,
    _mask: Mask,
    _is_variance_low: u8,
    _is_texture_low: u8,
    _is_detail_high: u8,

    pub const zero: Mv = std.mem.zeroes(Mv);

    pub fn isValid(m: Mv) bool {
        return m._mask.isValid();
    }

    pub fn getMask(m: Mv) Mask {
        std.debug.assert(m.isValid());
        std.debug.assert(m.isIntra());
        return m._mask;
    }

    pub fn isIntra(m: Mv) bool {
        std.debug.assert(m.isValid());
        return m._is_intra != 0;
    }

    pub fn isVarianceLow(m: Mv) bool {
        std.debug.assert(m.isValid());
        return m._is_variance_low != 0;
    }

    pub fn isTextureLow(m: Mv) bool {
        std.debug.assert(m.isValid());
        return m._is_texture_low != 0;
    }

    pub fn isDetailHigh(m: Mv) bool {
        std.debug.assert(m.isValid());
        return m._is_detail_high != 0;
    }
};

const alloc_fns = struct {
    extern fn dsv_alloc(size: c_int) ?*align(16) anyopaque;
    extern fn dsv_free(ptr: *align(16) anyopaque) void;

    fn alloc(_: *anyopaque, len: usize, ptr_align: u8, _: usize) ?[*]u8 {
        if (len > std.math.maxInt(c_int)) @panic("alloc len > MAX_INT");
        if (ptr_align > 16) @panic("alloc ptr_align > 16");
        return @ptrCast(dsv_alloc(@intCast(len)));
    }

    fn free(_: *anyopaque, buf: []u8, _: u8, _: usize) void {
        dsv_free(@ptrCast(@alignCast(buf.ptr)));
    }

};

pub const allocator: std.mem.Allocator = .{
    .ptr = undefined,
    .vtable = .{
        .alloc = &alloc_fns.alloc,
        .resize = std.mem.Allocator.noResize,
        .free = &alloc_fns.free,
    }
};
