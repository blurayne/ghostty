//! Rasterization for Glyph Protocol `fmt=colrv1` payloads — the OpenType COLR
//! version 1 paint graph.
//!
//! This is a *subset* interpreter covering the paint formats real fonts use in
//! practice:
//!
//!   1  PaintColrLayers        2  PaintSolid
//!   4  PaintLinearGradient    6  PaintRadialGradient
//!   10 PaintGlyph             11 PaintColrGlyph
//!   12 PaintTransform         14 PaintTranslate
//!   16 PaintScale             20 PaintScaleUniform      24 PaintRotate
//!
//! Deferred (rendered as no-ops for now): sweep gradients, *AroundCenter and
//! skew transforms, PaintComposite, and all variable (`Var`) formats — the
//! payloads produced for the demo fonts are non-variable subsets.
//!
//! Coordinates: the paint graph works in the glyph design space; a base affine
//! maps design→cell pixels (shared with glyf/colrv0 via `Placement`), and paint
//! transforms compose onto it. Gradients are evaluated manually (project to the
//! color line, interpolate CPAL stops in sRGB) to avoid coordinate/premultiply
//! ambiguity. Output is a premultiplied-BGRA cell bitmap.
const std = @import("std");
const Allocator = std.mem.Allocator;
const z2d = @import("z2d");

const Glyph = @import("Glyph.zig");
const glyf = @import("opentype/glyf.zig");
const Glyf = glyf.Glyf;
const cpal_mod = @import("opentype/cpal.zig");
const gr = @import("glyf_rasterize.zig");
const Container = @import("colr_rasterize.zig").Container;
const Bitmap = gr.Bitmap;
const DesignMetrics = Glyph.DesignMetrics;

pub const Error = Allocator.Error ||
    error{ InvalidContainer, UnsupportedColr } ||
    z2d.Path.Error ||
    z2d.painter.FillError;

const max_depth = 64;

/// A design→pixel affine (row-major 2x3): px = ax*x + cx*y + tx, py = by*x + dy*y + ty.
const Affine = struct {
    ax: f64,
    by: f64,
    cx: f64,
    dy: f64,
    tx: f64,
    ty: f64,

    fn apply(self: Affine, x: f64, y: f64) [2]f64 {
        return .{ self.ax * x + self.cx * y + self.tx, self.by * x + self.dy * y + self.ty };
    }

    /// self ∘ other (other applied first, in the current design space).
    fn mul(self: Affine, o: Affine) Affine {
        return .{
            .ax = self.ax * o.ax + self.cx * o.by,
            .by = self.by * o.ax + self.dy * o.by,
            .cx = self.ax * o.cx + self.cx * o.dy,
            .dy = self.by * o.cx + self.dy * o.dy,
            .tx = self.ax * o.tx + self.cx * o.ty + self.tx,
            .ty = self.by * o.tx + self.dy * o.ty + self.ty,
        };
    }

    fn translate(self: Affine, dx: f64, dy: f64) Affine {
        return self.mul(.{ .ax = 1, .by = 0, .cx = 0, .dy = 1, .tx = dx, .ty = dy });
    }
    fn scale(self: Affine, sx: f64, sy: f64) Affine {
        return self.mul(.{ .ax = sx, .by = 0, .cx = 0, .dy = sy, .tx = 0, .ty = 0 });
    }
    fn rotate(self: Affine, radians: f64) Affine {
        const c = @cos(radians);
        const s = @sin(radians);
        return self.mul(.{ .ax = c, .by = s, .cx = -s, .dy = c, .tx = 0, .ty = 0 });
    }

    /// Inverse transform of a pixel back to design space.
    fn invApply(self: Affine, px: f64, py: f64) ?[2]f64 {
        const det = self.ax * self.dy - self.by * self.cx;
        if (det == 0) return null;
        const i_ax = self.dy / det;
        const i_by = -self.by / det;
        const i_cx = -self.cx / det;
        const i_dy = self.ax / det;
        const i_tx = (self.cx * self.ty - self.dy * self.tx) / det;
        const i_ty = (self.by * self.tx - self.ax * self.ty) / det;
        return .{ i_ax * px + i_cx * py + i_tx, i_by * px + i_dy * py + i_ty };
    }
};

const Color = struct { r: f64, g: f64, b: f64, a: f64 };

/// Rasterize a `fmt=colrv1` container into a premultiplied-BGRA cell bitmap.
pub fn rasterizeColrV1(
    alloc: Allocator,
    container: []const u8,
    design: DesignMetrics,
    opts: Glyph.RenderOptions,
) Error!Bitmap {
    const c = Container.parse(container) catch return error.InvalidContainer;
    const colr = c.colr;
    if ((u16at(colr, 0) orelse 0) != 1) return error.UnsupportedColr;
    const cpal = cpal_mod.Cpal.init(c.cpal) catch return error.InvalidContainer;

    const bgl_off: usize = u32at(colr, 14) orelse return error.InvalidContainer; // baseGlyphListOffset
    const ll_off: usize = u32at(colr, 18) orelse 0; // layerListOffset (0 = none)

    const width: u32 = std.math.mul(u32, opts.grid_metrics.cell_width, opts.cell_width orelse 1) catch
        return error.InvalidContainer;
    const height = opts.grid_metrics.cell_height;
    if (width == 0 or height == 0) return error.InvalidContainer;

    // Base design→pixel transform: reuse Placement with the em square as bounds
    // so colrv1 glyphs size/place consistently with glyf/colrv0.
    const upm: f64 = @floatFromInt(design.units_per_em);
    const placement: gr.Placement = .init(
        .{ .x_min = 0, .y_min = 0, .x_max = upm, .y_max = upm },
        design,
        opts,
    );
    const sx = placement.width / upm;
    const sy = placement.height / upm;
    const base: Affine = .{
        .ax = sx,
        .by = 0,
        .cx = 0,
        .dy = -sy,
        .tx = placement.x,
        .ty = placement.bitmap_height - placement.y,
    };

    var ctx: Ctx = .{
        .alloc = alloc,
        .container = c,
        .colr = colr,
        .cpal = cpal,
        .bgl_off = bgl_off,
        .ll_off = ll_off,
        .width = width,
        .height = height,
        .acc = try alloc.alloc(f32, @as(usize, width) * @as(usize, height) * 4),
    };
    defer alloc.free(ctx.acc);
    @memset(ctx.acc, 0);

    // Paint the base glyph record's root paint. After subsetting there is one
    // base record; use it.
    const root = ctx.baseGlyphPaint(baseGlyphIdAt(colr, bgl_off, 0) orelse
        return error.InvalidContainer) orelse
        // Fall back to record 0's paint offset directly.
        (bgl_off + @as(usize, u32at(colr, bgl_off + 6) orelse return error.InvalidContainer));
    try ctx.paint(root, base, null, 0);

    // Convert premultiplied float RGBA -> premultiplied u8 BGRA.
    const px = @as(usize, width) * @as(usize, height);
    const data = try alloc.alloc(u8, px * 4);
    for (0..px) |p| {
        data[p * 4 + 0] = f2u8(ctx.acc[p * 4 + 2]); // B
        data[p * 4 + 1] = f2u8(ctx.acc[p * 4 + 1]); // G
        data[p * 4 + 2] = f2u8(ctx.acc[p * 4 + 0]); // R
        data[p * 4 + 3] = f2u8(ctx.acc[p * 4 + 3]); // A
    }
    return .{ .width = width, .height = height, .data = data };
}

const Ctx = struct {
    alloc: Allocator,
    container: Container,
    colr: []const u8,
    cpal: cpal_mod.Cpal,
    bgl_off: usize,
    ll_off: usize,
    width: usize,
    height: usize,
    acc: []f32, // premultiplied RGBA

    /// Recursively interpret a paint table at absolute offset `off`.
    fn paint(self: *Ctx, off: usize, tr: Affine, clip: ?[]const f32, depth: u32) Error!void {
        if (depth > max_depth) return;
        const fmt = u8at(self.colr, off) orelse return;
        switch (fmt) {
            1 => { // PaintColrLayers
                const num = u8at(self.colr, off + 1) orelse return;
                const first = u32at(self.colr, off + 2) orelse return;
                var i: usize = 0;
                while (i < num) : (i += 1) {
                    const lp = self.layerPaint(@as(usize, first) + i) orelse continue;
                    try self.paint(lp, tr, clip, depth + 1);
                }
            },
            2 => { // PaintSolid
                const pal = u16at(self.colr, off + 1) orelse return;
                const alpha = f2dot14(self.colr, off + 3);
                if (clip) |m| self.fillSolid(m, self.colorFor(pal, alpha));
            },
            4 => { // PaintLinearGradient
                const cl = off + (u24at(self.colr, off + 1) orelse return);
                const x0 = fword(self.colr, off + 4);
                const y0 = fword(self.colr, off + 6);
                const x1 = fword(self.colr, off + 8);
                const y1 = fword(self.colr, off + 10);
                if (clip) |m| self.fillLinear(m, tr, cl, x0, y0, x1, y1);
            },
            6 => { // PaintRadialGradient (concentric approximation)
                const cl = off + (u24at(self.colr, off + 1) orelse return);
                const x0 = fword(self.colr, off + 4);
                const y0 = fword(self.colr, off + 6);
                const r0 = ufword(self.colr, off + 8);
                const r1 = ufword(self.colr, off + 14);
                if (clip) |m| self.fillRadial(m, tr, cl, x0, y0, r0, r1);
            },
            10 => { // PaintGlyph
                const sub = off + (u24at(self.colr, off + 1) orelse return);
                const gid = u16at(self.colr, off + 4) orelse return;
                const mask = self.glyphMask(gid, tr) catch return;
                defer if (mask) |mm| self.alloc.free(mm);
                if (mask) |gm| {
                    const combined = try self.intersect(clip, gm);
                    defer self.alloc.free(combined);
                    try self.paint(sub, tr, combined, depth + 1);
                }
            },
            11 => { // PaintColrGlyph
                const gid = u16at(self.colr, off + 1) orelse return;
                const bp = self.baseGlyphPaint(gid) orelse return;
                try self.paint(bp, tr, clip, depth + 1);
            },
            12 => { // PaintTransform
                const sub = off + (u24at(self.colr, off + 1) orelse return);
                const tro = off + (u24at(self.colr, off + 4) orelse return);
                const aff: Affine = .{
                    .ax = f16dot16(self.colr, tro),
                    .by = f16dot16(self.colr, tro + 4),
                    .cx = f16dot16(self.colr, tro + 8),
                    .dy = f16dot16(self.colr, tro + 12),
                    .tx = f16dot16(self.colr, tro + 16),
                    .ty = f16dot16(self.colr, tro + 20),
                };
                try self.paint(sub, tr.mul(aff), clip, depth + 1);
            },
            14 => { // PaintTranslate
                const sub = off + (u24at(self.colr, off + 1) orelse return);
                const dx = fword(self.colr, off + 4);
                const dy = fword(self.colr, off + 6);
                try self.paint(sub, tr.translate(dx, dy), clip, depth + 1);
            },
            16 => { // PaintScale
                const sub = off + (u24at(self.colr, off + 1) orelse return);
                const sxx = f2dot14(self.colr, off + 4);
                const syy = f2dot14(self.colr, off + 6);
                try self.paint(sub, tr.scale(sxx, syy), clip, depth + 1);
            },
            20 => { // PaintScaleUniform
                const sub = off + (u24at(self.colr, off + 1) orelse return);
                const s = f2dot14(self.colr, off + 4);
                try self.paint(sub, tr.scale(s, s), clip, depth + 1);
            },
            24 => { // PaintRotate (angle in F2DOT14 counter-clockwise turns ×180°)
                const sub = off + (u24at(self.colr, off + 1) orelse return);
                const deg = f2dot14(self.colr, off + 4) * 180.0;
                try self.paint(sub, tr.rotate(std.math.degreesToRadians(deg)), clip, depth + 1);
            },
            else => {}, // Unsupported paint format: skip (graceful degradation).
        }
    }

    /// The root paint offset for base glyph `gid`, if present.
    fn baseGlyphPaint(self: *Ctx, gid: u16) ?usize {
        const num = u32at(self.colr, self.bgl_off) orelse return null;
        var i: usize = 0;
        while (i < num) : (i += 1) {
            const rec = self.bgl_off + 4 + i * 6;
            const rec_gid = u16at(self.colr, rec) orelse return null;
            if (rec_gid == gid) {
                const po = u32at(self.colr, rec + 2) orelse return null;
                return self.bgl_off + @as(usize, po);
            }
        }
        return null;
    }

    /// The paint offset for LayerList entry `i`.
    fn layerPaint(self: *Ctx, i: usize) ?usize {
        if (self.ll_off == 0) return null;
        const num = u32at(self.colr, self.ll_off) orelse return null;
        if (i >= num) return null;
        const po = u32at(self.colr, self.ll_off + 4 + i * 4) orelse return null;
        return self.ll_off + @as(usize, po);
    }

    /// Rasterize glyph `gid`'s outline under transform `tr` into an alpha mask
    /// (0..1 per pixel). Returns null for an empty/missing glyph.
    fn glyphMask(self: *Ctx, gid: u16, tr: Affine) !?[]f32 {
        const rec = self.container.glyphRecord(gid) orelse return null;
        const entry = Glyf.Entry.init(rec) catch return null;
        var outline = entry.decode(self.alloc) catch return null;
        defer outline.deinit(self.alloc);
        if (outline.contours.len == 0 or outline.points.len == 0) return null;

        var sfc: z2d.Surface = try .init(.image_surface_alpha8, self.alloc, @intCast(self.width), @intCast(self.height));
        defer sfc.deinit(self.alloc);
        var path: z2d.Path = .empty;
        defer path.deinit(self.alloc);
        for (0..outline.contours.len) |ci| try appendOutlineAffine(self.alloc, &path, outline.contour(ci), tr);
        try z2d.painter.fill(
            self.alloc,
            &sfc,
            &.{ .opaque_pattern = .{ .pixel = .{ .alpha8 = .{ .a = 255 } } } },
            path.nodes.items,
            .{},
        );

        const src = std.mem.sliceAsBytes(sfc.image_surface_alpha8.buf);
        const n = @as(usize, self.width) * @as(usize, self.height);
        const mask = try self.alloc.alloc(f32, n);
        for (0..n) |p| mask[p] = if (p < src.len) @as(f32, @floatFromInt(src[p])) / 255.0 else 0;
        return mask;
    }

    /// Intersect an optional parent clip with a glyph mask (owned result).
    fn intersect(self: *Ctx, parent: ?[]const f32, m: []const f32) ![]f32 {
        const out = try self.alloc.alloc(f32, m.len);
        if (parent) |pm| {
            for (0..m.len) |p| out[p] = m[p] * (if (p < pm.len) pm[p] else 0);
        } else {
            @memcpy(out, m);
        }
        return out;
    }

    fn fillSolid(self: *Ctx, mask: []const f32, color: Color) void {
        const n = @as(usize, self.width) * @as(usize, self.height);
        for (0..n) |p| {
            const sa = color.a * mask[p];
            if (sa <= 0) continue;
            self.over(p, color.r, color.g, color.b, sa);
        }
    }

    fn fillLinear(self: *Ctx, mask: []const f32, tr: Affine, cl: usize, x0: f64, y0: f64, x1: f64, y1: f64) void {
        const dx = x1 - x0;
        const dy = y1 - y0;
        const len2 = dx * dx + dy * dy;
        if (len2 == 0) return;
        var y: usize = 0;
        while (y < self.height) : (y += 1) {
            var x: usize = 0;
            while (x < self.width) : (x += 1) {
                const p = y * self.width + x;
                if (mask[p] <= 0) continue;
                const d = tr.invApply(@floatFromInt(x), @floatFromInt(y)) orelse continue;
                const t = ((d[0] - x0) * dx + (d[1] - y0) * dy) / len2;
                const col = self.colorAt(cl, t);
                const sa = col.a * mask[p];
                if (sa > 0) self.over(p, col.r, col.g, col.b, sa);
            }
        }
    }

    fn fillRadial(self: *Ctx, mask: []const f32, tr: Affine, cl: usize, cx: f64, cy: f64, r0: f64, r1: f64) void {
        const dr = r1 - r0;
        if (dr == 0) return;
        var y: usize = 0;
        while (y < self.height) : (y += 1) {
            var x: usize = 0;
            while (x < self.width) : (x += 1) {
                const p = y * self.width + x;
                if (mask[p] <= 0) continue;
                const d = tr.invApply(@floatFromInt(x), @floatFromInt(y)) orelse continue;
                const dist = @sqrt((d[0] - cx) * (d[0] - cx) + (d[1] - cy) * (d[1] - cy));
                const t = (dist - r0) / dr;
                const col = self.colorAt(cl, t);
                const sa = col.a * mask[p];
                if (sa > 0) self.over(p, col.r, col.g, col.b, sa);
            }
        }
    }

    /// Premultiplied "over" composite of a straight color at pixel `p`.
    fn over(self: *Ctx, p: usize, r: f64, g: f64, b: f64, sa: f64) void {
        const inv = 1.0 - sa;
        self.acc[p * 4 + 0] = @floatCast(r * sa + self.acc[p * 4 + 0] * inv);
        self.acc[p * 4 + 1] = @floatCast(g * sa + self.acc[p * 4 + 1] * inv);
        self.acc[p * 4 + 2] = @floatCast(b * sa + self.acc[p * 4 + 2] * inv);
        self.acc[p * 4 + 3] = @floatCast(sa + self.acc[p * 4 + 3] * inv);
    }

    /// Solid color from a CPAL palette entry, scaled by an alpha factor.
    fn colorFor(self: *Ctx, palette_index: u16, alpha: f64) Color {
        if (palette_index == 0xFFFF) return .{ .r = 1, .g = 1, .b = 1, .a = alpha };
        const c = self.cpal.color(palette_index) orelse return .{ .r = 1, .g = 1, .b = 1, .a = alpha };
        return .{
            .r = @as(f64, @floatFromInt(c.r)) / 255.0,
            .g = @as(f64, @floatFromInt(c.g)) / 255.0,
            .b = @as(f64, @floatFromInt(c.b)) / 255.0,
            .a = (@as(f64, @floatFromInt(c.a)) / 255.0) * alpha,
        };
    }

    /// Evaluate a ColorLine (at absolute offset `cl`) at parameter `t`,
    /// clamping to the stop range (extend=pad). Stops are CPAL colors.
    fn colorAt(self: *Ctx, cl: usize, t: f64) Color {
        // ColorLine: u8 extend; u16 numStops; ColorStop[numStops]{F2DOT14 offset; u16 pal; F2DOT14 alpha}
        const num = u16at(self.colr, cl + 1) orelse return .{ .r = 0, .g = 0, .b = 0, .a = 0 };
        if (num == 0) return .{ .r = 0, .g = 0, .b = 0, .a = 0 };
        const stop0 = cl + 3;

        // Below first / above last: clamp (pad).
        const first_off = f2dot14(self.colr, stop0);
        if (t <= first_off) return self.stopColor(stop0);
        const last = stop0 + (@as(usize, num) - 1) * 6;
        const last_off = f2dot14(self.colr, last);
        if (t >= last_off) return self.stopColor(last);

        var i: usize = 0;
        while (i + 1 < num) : (i += 1) {
            const a = stop0 + i * 6;
            const b = stop0 + (i + 1) * 6;
            const oa = f2dot14(self.colr, a);
            const ob = f2dot14(self.colr, b);
            if (t >= oa and t <= ob) {
                const span = ob - oa;
                const f = if (span > 0) (t - oa) / span else 0;
                const ca = self.stopColor(a);
                const cb = self.stopColor(b);
                return .{
                    .r = ca.r + (cb.r - ca.r) * f,
                    .g = ca.g + (cb.g - ca.g) * f,
                    .b = ca.b + (cb.b - ca.b) * f,
                    .a = ca.a + (cb.a - ca.a) * f,
                };
            }
        }
        return self.stopColor(last);
    }

    fn stopColor(self: *Ctx, stop_off: usize) Color {
        const pal = u16at(self.colr, stop_off + 2) orelse 0xFFFF;
        const alpha = f2dot14(self.colr, stop_off + 4);
        return self.colorFor(pal, alpha);
    }
};

/// Build a z2d path from a glyf outline, transforming each point by `tr`.
fn appendOutlineAffine(alloc: Allocator, path: *z2d.Path, contour: []const Glyf.Outline.Point, tr: Affine) Error!void {
    if (contour.len == 0) return;
    const P = struct { x: f64, y: f64 };
    const tp = struct {
        fn f(t: Affine, p: Glyf.Outline.Point) P {
            const r = t.apply(@floatFromInt(p.x), @floatFromInt(p.y));
            return .{ .x = r[0], .y = r[1] };
        }
    }.f;
    const mid = struct {
        fn f(a: P, b: P) P {
            return .{ .x = (a.x + b.x) / 2, .y = (a.y + b.y) / 2 };
        }
    }.f;

    const first = contour[0];
    const last = contour[contour.len - 1];
    var current: P = undefined;
    var i: usize = 0;
    if (first.on_curve) {
        i = 1;
        current = tp(tr, first);
    } else if (last.on_curve) {
        current = tp(tr, last);
    } else {
        current = mid(tp(tr, last), tp(tr, first));
    }
    try path.moveTo(alloc, current.x, current.y);

    while (i < contour.len) {
        const p = contour[i];
        if (p.on_curve) {
            current = tp(tr, p);
            try path.lineTo(alloc, current.x, current.y);
            i += 1;
            continue;
        }
        const control = tp(tr, p);
        const next = contour[(i + 1) % contour.len];
        const end = if (next.on_curve) tp(tr, next) else mid(control, tp(tr, next));
        const c1 = P{ .x = current.x + (2.0 / 3.0) * (control.x - current.x), .y = current.y + (2.0 / 3.0) * (control.y - current.y) };
        const c2 = P{ .x = end.x + (2.0 / 3.0) * (control.x - end.x), .y = end.y + (2.0 / 3.0) * (control.y - end.y) };
        try path.curveTo(alloc, c1.x, c1.y, c2.x, c2.y, end.x, end.y);
        current = end;
        i += if (next.on_curve) 2 else 1;
    }
    try path.close(alloc);
}

fn baseGlyphIdAt(colr: []const u8, bgl_off: usize, i: usize) ?u16 {
    const num = u32at(colr, bgl_off) orelse return null;
    if (i >= num) return null;
    return u16at(colr, bgl_off + 4 + i * 6);
}

fn f2u8(v: f32) u8 {
    return @intFromFloat(@round(std.math.clamp(v, 0.0, 1.0) * 255.0));
}

fn u8at(d: []const u8, off: usize) ?u8 {
    return if (off < d.len) d[off] else null;
}
fn u16at(d: []const u8, off: usize) ?u16 {
    if (off + 2 > d.len) return null;
    return std.mem.readInt(u16, d[off..][0..2], .big);
}
fn u24at(d: []const u8, off: usize) ?u32 {
    if (off + 3 > d.len) return null;
    return std.mem.readInt(u24, d[off..][0..3], .big);
}
fn u32at(d: []const u8, off: usize) ?u32 {
    if (off + 4 > d.len) return null;
    return std.mem.readInt(u32, d[off..][0..4], .big);
}
/// FWORD (int16 design units) as f64.
fn fword(d: []const u8, off: usize) f64 {
    if (off + 2 > d.len) return 0;
    return @floatFromInt(std.mem.readInt(i16, d[off..][0..2], .big));
}
/// UFWORD (uint16 design units) as f64.
fn ufword(d: []const u8, off: usize) f64 {
    return @floatFromInt(u16at(d, off) orelse 0);
}
/// F2DOT14 fixed-point as f64.
fn f2dot14(d: []const u8, off: usize) f64 {
    if (off + 2 > d.len) return 0;
    return @as(f64, @floatFromInt(std.mem.readInt(i16, d[off..][0..2], .big))) / 16384.0;
}
/// F16DOT16 fixed-point as f64.
fn f16dot16(d: []const u8, off: usize) f64 {
    if (off + 4 > d.len) return 0;
    return @as(f64, @floatFromInt(std.mem.readInt(i32, d[off..][0..4], .big))) / 65536.0;
}

test "colrv1: unsupported/short container is rejected cleanly" {
    const testing = std.testing;
    // A COLR whose version != 1 must be rejected as UnsupportedColr, and a
    // truncated container as InvalidContainer.
    try testing.expectError(error.InvalidContainer, rasterizeColrV1(
        testing.allocator,
        &[_]u8{ 0x00, 0x01 },
        .{ .units_per_em = 1000, .advance_width = 1000, .line_height = 1000 },
        .{ .grid_metrics = testMetrics(20, 20) },
    ));
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
