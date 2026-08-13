//! Rasterization for Glyph Protocol color payloads (`fmt=colrv0`).
//!
//! The payload is the Glyph Protocol §8.7 container:
//!
//!     u16 n_glyphs; { u16 glyf_len; glyf_len bytes }×n_glyphs   # outlines, GID order
//!     u16 colr_len; colr_len bytes                              # OpenType COLR table
//!     u16 cpal_len; cpal_len bytes                              # OpenType CPAL table
//!
//! For COLR v0 we render the (single, after subsetting) base glyph's layers
//! bottom-to-top: each layer references a glyf outline by GID and a CPAL palette
//! entry. All layers share one design→cell transform (computed from the union of
//! their bounds) so they composite correctly. Output is a premultiplied-BGRA
//! cell bitmap matching Ghostty's color (emoji) atlas.
const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const z2d = @import("z2d");

const Glyph = @import("Glyph.zig");
const glyf = @import("opentype/glyf.zig");
const Glyf = glyf.Glyf;
const colr_mod = @import("opentype/colr.zig");
const cpal_mod = @import("opentype/cpal.zig");
const gr = @import("glyf_rasterize.zig");
const Bitmap = gr.Bitmap;
const DesignMetrics = Glyph.DesignMetrics;
const Color = cpal_mod.Color;

pub const Error = Allocator.Error ||
    error{ InvalidContainer, UnsupportedColr } ||
    z2d.Path.Error ||
    z2d.painter.FillError;

/// Max glyph outlines a container may carry (Glyph Protocol §8.7 cap).
const max_glyphs = 256;

/// Rasterize a `fmt=colrv0` container into a premultiplied-BGRA cell bitmap.
/// The returned bitmap is `cell_width * (opts.cell_width orelse 1)` by
/// `cell_height`, depth 4 (BGRA). Caller owns the bitmap.
pub fn rasterizeColrV0(
    alloc: Allocator,
    container: []const u8,
    design: DesignMetrics,
    opts: Glyph.RenderOptions,
) Error!Bitmap {
    const parsed = try Container.parse(container);
    const colr = colr_mod.Colr.init(parsed.colr) catch return error.InvalidContainer;
    if (colr.version != 0) return error.UnsupportedColr;
    const cpal = cpal_mod.Cpal.init(parsed.cpal) catch return error.InvalidContainer;
    const base = colr.baseGlyph(0) orelse return error.InvalidContainer;

    const width: u32 = std.math.mul(
        u32,
        opts.grid_metrics.cell_width,
        opts.cell_width orelse 1,
    ) catch return error.InvalidContainer;
    const height = opts.grid_metrics.cell_height;
    if (width == 0 or height == 0) return error.InvalidContainer;

    // Decode each layer's outline once, collecting (outline, color) and the
    // union of all layer bounds for a shared transform.
    const Layer = struct { outline: Glyf.Outline, color: Color };
    var layers: std.ArrayList(Layer) = .empty;
    defer {
        for (layers.items) |*l| l.outline.deinit(alloc);
        layers.deinit(alloc);
    }

    var union_bounds: ?gr.Bounds = null;
    var i: usize = 0;
    while (i < base.num_layers) : (i += 1) {
        const layer = colr.layer(@as(usize, base.first_layer_index) + i) orelse continue;
        const rec = parsed.glyphRecord(layer.glyph_id) orelse continue;
        const entry = Glyf.Entry.init(rec) catch continue;
        const outline = entry.decode(alloc) catch continue;
        if (gr.boundsOf(outline)) |b| {
            union_bounds = if (union_bounds) |u| u.unite(b) else b;
        }
        try layers.append(alloc, .{
            .outline = outline,
            .color = colorFor(cpal, layer.palette_index),
        });
    }

    // Premultiplied RGBA float accumulator, composited bottom-to-top.
    const px = @as(usize, width) * @as(usize, height);
    const acc = try alloc.alloc(f32, px * 4);
    defer alloc.free(acc);
    @memset(acc, 0);

    if (union_bounds) |ub| {
        if (ub.width() > 0 and ub.height() > 0) {
            const placement: gr.Placement = .init(ub, design, opts);
            for (layers.items) |l| {
                try blendLayer(alloc, acc, width, height, l.outline, ub, placement, l.color);
            }
        }
    }

    // Convert premultiplied float RGBA -> premultiplied u8 BGRA.
    const data = try alloc.alloc(u8, px * 4);
    for (0..px) |p| {
        data[p * 4 + 0] = f2u8(acc[p * 4 + 2]); // B
        data[p * 4 + 1] = f2u8(acc[p * 4 + 1]); // G
        data[p * 4 + 2] = f2u8(acc[p * 4 + 0]); // R
        data[p * 4 + 3] = f2u8(acc[p * 4 + 3]); // A
    }
    return .{ .width = width, .height = height, .data = data };
}

/// A layer's color from palette entry, or opaque white when the layer requests
/// the (context-dependent) text foreground color (paletteIndex 0xFFFF).
fn colorFor(cpal: cpal_mod.Cpal, palette_index: u16) Color {
    if (palette_index == 0xFFFF) return .{ .r = 255, .g = 255, .b = 255, .a = 255 };
    return cpal.color(palette_index) orelse .{ .r = 255, .g = 255, .b = 255, .a = 255 };
}

/// Rasterize one layer outline to an alpha mask (shared transform) and
/// composite its color over `acc` (premultiplied "over").
fn blendLayer(
    alloc: Allocator,
    acc: []f32,
    width: u32,
    height: u32,
    outline: Glyf.Outline,
    bounds: gr.Bounds,
    placement: gr.Placement,
    color: Color,
) Error!void {
    if (outline.contours.len == 0 or outline.points.len == 0) return;

    var sfc: z2d.Surface = try .init(.image_surface_alpha8, alloc, @intCast(width), @intCast(height));
    defer sfc.deinit(alloc);

    var path: z2d.Path = .empty;
    defer path.deinit(alloc);
    for (0..outline.contours.len) |c| try gr.appendContourPath(
        alloc,
        &path,
        outline.contour(c),
        bounds,
        placement,
    );

    try z2d.painter.fill(
        alloc,
        &sfc,
        &.{ .opaque_pattern = .{ .pixel = .{ .alpha8 = .{ .a = 255 } } } },
        path.nodes.items,
        .{},
    );

    const mask = std.mem.sliceAsBytes(sfc.image_surface_alpha8.buf);
    const cr = @as(f32, @floatFromInt(color.r)) / 255.0;
    const cg = @as(f32, @floatFromInt(color.g)) / 255.0;
    const cb = @as(f32, @floatFromInt(color.b)) / 255.0;
    const ca = @as(f32, @floatFromInt(color.a)) / 255.0;

    const n = @min(mask.len, @as(usize, width) * @as(usize, height));
    for (0..n) |p| {
        const cov = @as(f32, @floatFromInt(mask[p])) / 255.0;
        const sa = ca * cov; // source (premultiplied) alpha
        if (sa <= 0) continue;
        const inv = 1.0 - sa;
        acc[p * 4 + 0] = cr * sa + acc[p * 4 + 0] * inv;
        acc[p * 4 + 1] = cg * sa + acc[p * 4 + 1] * inv;
        acc[p * 4 + 2] = cb * sa + acc[p * 4 + 2] * inv;
        acc[p * 4 + 3] = sa + acc[p * 4 + 3] * inv;
    }
}

fn f2u8(v: f32) u8 {
    const s = std.math.clamp(v, 0.0, 1.0) * 255.0;
    return @intFromFloat(@round(s));
}

/// The parsed §8.7 container: glyf record slices (by GID) + COLR + CPAL bytes.
/// Shared with the colrv1 rasterizer.
pub const Container = struct {
    data: []const u8,
    n_glyphs: u16,
    /// (offset,len) into `data` for each glyf record, indexed by GID.
    records: [max_glyphs]struct { off: u32, len: u16 },
    colr: []const u8,
    cpal: []const u8,

    pub fn parse(data: []const u8) Error!Container {
        var self: Container = undefined;
        self.data = data;

        var off: usize = 0;
        const n = u16at(data, off) orelse return error.InvalidContainer;
        if (n > max_glyphs) return error.InvalidContainer;
        self.n_glyphs = n;
        off += 2;

        for (0..n) |i| {
            const glen = u16at(data, off) orelse return error.InvalidContainer;
            off += 2;
            if (off + glen > data.len) return error.InvalidContainer;
            self.records[i] = .{ .off = @intCast(off), .len = glen };
            off += glen;
        }

        const colr_len = u16at(data, off) orelse return error.InvalidContainer;
        off += 2;
        if (off + colr_len > data.len) return error.InvalidContainer;
        self.colr = data[off .. off + colr_len];
        off += colr_len;

        const cpal_len = u16at(data, off) orelse return error.InvalidContainer;
        off += 2;
        if (off + cpal_len > data.len) return error.InvalidContainer;
        self.cpal = data[off .. off + cpal_len];

        return self;
    }

    pub fn glyphRecord(self: Container, gid: u16) ?[]const u8 {
        if (gid >= self.n_glyphs) return null;
        const r = self.records[gid];
        return self.data[r.off .. r.off + r.len];
    }
};

fn u16at(d: []const u8, off: usize) ?u16 {
    if (off + 2 > d.len) return null;
    return std.mem.readInt(u16, d[off..][0..2], .big);
}

fn testMetrics(width: u32, height: u32) @import("Metrics.zig") {
    return .{
        .cell_width = width,
        .cell_height = height,
        .cell_baseline = 0,
        .underline_position = height,
        .underline_thickness = 1,
        .strikethrough_position = height / 2,
        .strikethrough_thickness = 1,
        .overline_position = 0,
        .overline_thickness = 1,
        .box_thickness = 1,
        .cursor_thickness = 1,
        .cursor_height = height,
        .icon_height = @floatFromInt(height),
        .icon_height_single = @floatFromInt(height),
        .face_width = @floatFromInt(width),
        .face_height = @floatFromInt(height),
        .face_y = 0,
    };
}

// The "triangle" glyf record (one contour, three points), base64, from the
// glyf/Glossary tests. A real, decodable simple-glyph record.
const test_triangle_b64 = "AAEAZABkA4QDhAACAAABAQEB9P5wAyADhPzgAAA=";

test "colr_rasterize: single red layer composites into BGRA" {
    const testing = std.testing;
    const alloc = testing.allocator;

    // Decode the triangle glyf record.
    const Decoder = std.base64.standard.Decoder;
    const tri_len = try Decoder.calcSizeForSlice(test_triangle_b64);
    const tri = try alloc.alloc(u8, tri_len);
    defer alloc.free(tri);
    try Decoder.decode(tri, test_triangle_b64);

    // Container: 1 glyph (the triangle), a COLR v0 with base glyph id 0 and one
    // layer (glyf gid 0, palette 0), and a CPAL with a single red entry.
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try putU16(alloc, &buf, 1); // n_glyphs
    try putU16(alloc, &buf, @intCast(tri.len));
    try buf.appendSlice(alloc, tri);

    const colr = [_]u8{
        0x00, 0x00, // version 0
        0x00, 0x01, // 1 base glyph record
        0x00, 0x00, 0x00, 0x0E, // baseGlyphRecordsOffset = 14
        0x00, 0x00, 0x00, 0x14, // layerRecordsOffset = 20
        0x00, 0x01, // 1 layer record
        0x00, 0x00, 0x00, 0x00, 0x00, 0x01, // base: gid 0, first 0, num 1
        0x00, 0x00, 0x00, 0x00, // layer0: glyf gid 0, palette 0
    };
    try putU16(alloc, &buf, colr.len);
    try buf.appendSlice(alloc, &colr);

    const cpal = [_]u8{
        0x00, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x01, // v0, 1 entry, 1 palette, 1 record
        0x00, 0x00, 0x00, 0x0E, // colorRecordsArrayOffset = 14
        0x00, 0x00, // colorRecordIndices[0] = 0
        0x00, 0x00, 0xFF, 0xFF, // record 0: B G R A = red
    };
    try putU16(alloc, &buf, cpal.len);
    try buf.appendSlice(alloc, &cpal);

    var bm = try rasterizeColrV0(alloc, buf.items, .{
        .units_per_em = 1000,
        .advance_width = 1000,
        .line_height = 1000,
    }, .{ .grid_metrics = testMetrics(20, 20) });
    defer bm.deinit(alloc);

    try testing.expectEqual(@as(u32, 20), bm.width);
    try testing.expectEqual(@as(u32, 20), bm.height);
    try testing.expectEqual(@as(usize, 20 * 20 * 4), bm.data.len);

    // Somewhere in the bitmap the triangle should have painted opaque red:
    // premultiplied BGRA with R high, G/B low, A high.
    var found_red = false;
    var p: usize = 0;
    while (p < 20 * 20) : (p += 1) {
        const b = bm.data[p * 4 + 0];
        const g = bm.data[p * 4 + 1];
        const r = bm.data[p * 4 + 2];
        const a = bm.data[p * 4 + 3];
        if (a > 200 and r > 200 and g < 60 and b < 60) {
            found_red = true;
            break;
        }
    }
    try testing.expect(found_red);
}

test "colr_rasterize: rejects a truncated container" {
    const testing = std.testing;
    try testing.expectError(
        error.InvalidContainer,
        rasterizeColrV0(testing.allocator, &[_]u8{ 0x00, 0x05 }, .{
            .units_per_em = 1000,
            .advance_width = 1000,
            .line_height = 1000,
        }, .{ .grid_metrics = testMetrics(20, 20) }),
    );
}

fn putU16(alloc: Allocator, list: *std.ArrayList(u8), v: u16) !void {
    var b: [2]u8 = undefined;
    std.mem.writeInt(u16, &b, v, .big);
    try list.appendSlice(alloc, &b);
}
