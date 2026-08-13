//! GlossaryFace is a virtual "special" font face backed by a snapshot of the
//! Glyph Protocol Glossary (`terminal/apc/glyph/Glossary.zig`).
//!
//! It mirrors the sprite face model: the renderer reaches it through a special
//! `Collection.Index` (`.glossary`), which bypasses the HarfBuzz shaper
//! (`glyph_index == codepoint` for special fonts). That lets registered PUA
//! codepoints render from their stored outlines instead of tofu.
//!
//! The face holds its own deep-copied snapshot of the glossary entries so it is
//! independent of concurrent mutation of the per-terminal glossary on the IO
//! thread. The snapshot is refreshed via `updateSnapshot` under the grid lock
//! when the terminal signals `dirty.glyph_glossary`.
const GlossaryFace = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

const font = @import("main.zig");
const Atlas = font.Atlas;
const Glyph = font.Glyph;
const Presentation = font.Presentation;
const RenderOptions = font.Glyph.RenderOptions;

const glyf_rasterize = @import("glyf_rasterize.zig");
const colr_rasterize = @import("colr_rasterize.zig");
const colrv1_rasterize = @import("colrv1_rasterize.zig");
const Glyf = @import("opentype/glyf.zig").Glyf;
const Glossary = @import("../terminal/apc/glyph/Glossary.zig");

/// Owned snapshot of glossary entries keyed by codepoint. Each entry owns its
/// own outline copy so the snapshot is independent of the live glossary.
entries: std.AutoArrayHashMapUnmanaged(u21, Glossary.Entry) = .empty,

/// An empty face with no registered glyphs.
pub const empty: GlossaryFace = .{};

pub fn deinit(self: *GlossaryFace, alloc: Allocator) void {
    for (self.entries.values()) |*e| e.deinit(alloc);
    self.entries.deinit(alloc);
    self.* = undefined;
}

/// Replace the snapshot with a deep copy of `glossary`'s current entries. Any
/// previous snapshot is freed first. On error the face is left in a valid
/// (possibly partially populated) state that `deinit` will free.
pub fn updateSnapshot(
    self: *GlossaryFace,
    alloc: Allocator,
    glossary: *const Glossary,
) !void {
    for (self.entries.values()) |*e| e.deinit(alloc);
    self.entries.clearRetainingCapacity();

    try self.entries.ensureTotalCapacity(alloc, glossary.entries.count());
    var it = glossary.entries.iterator();
    while (it.next()) |kv| {
        const cloned = try cloneEntry(alloc, kv.value_ptr.*);
        self.entries.putAssumeCapacity(kv.key_ptr.*, cloned);
    }
}

/// Deep-copy a glossary entry so the snapshot owns its outline memory.
fn cloneEntry(alloc: Allocator, e: Glossary.Entry) !Glossary.Entry {
    const glyph: Glossary.Entry.Glyph = switch (e.glyph) {
        .glyf => |o| glyf: {
            const contours = try alloc.dupe(u16, o.contours);
            errdefer alloc.free(contours);
            const points = try alloc.dupe(Glyf.Outline.Point, o.points);
            break :glyf .{ .glyf = .{ .contours = contours, .points = points } };
        },
        .colrv0 => |bytes| .{ .colrv0 = try alloc.dupe(u8, bytes) },
        .colrv1 => |bytes| .{ .colrv1 = try alloc.dupe(u8, bytes) },
    };
    return .{
        .glyph = glyph,
        .design = e.design,
        .width = e.width,
        .constraint = e.constraint,
    };
}

/// True if the given codepoint has a registered glyph.
pub fn hasCodepoint(self: *const GlossaryFace, cp: u32) bool {
    const cp21 = std.math.cast(u21, cp) orelse return false;
    return self.entries.contains(cp21);
}

/// Special-index face "glyph index" is just the codepoint itself, mirroring
/// the sprite font (special fonts have `glyph_index == codepoint`).
pub fn glyphIndex(self: *const GlossaryFace, cp: u32) ?u32 {
    return if (self.hasCodepoint(cp)) cp else null;
}

/// The atlas presentation (text = grayscale, emoji = color) for a registered
/// codepoint. Monochrome `glyf` uses the grayscale atlas (`.text`); color
/// formats (`colrv0`) use the color atlas (`.emoji`).
pub fn presentation(self: *const GlossaryFace, cp: u32) Presentation {
    const cp21 = std.math.cast(u21, cp) orelse return .text;
    const entry = self.entries.get(cp21) orelse return .text;
    return switch (entry.glyph) {
        .glyf => .text,
        .colrv0, .colrv1 => .emoji,
    };
}

/// Render a registered glyph (`glyph_index == codepoint`) into `atlas`.
///
/// Returns a zero-sized glyph if the codepoint isn't registered or produces no
/// coverage. Propagates `error.AtlasFull` so the caller can grow and retry,
/// exactly like the real font faces.
pub fn renderGlyph(
    self: *const GlossaryFace,
    alloc: Allocator,
    atlas: *Atlas,
    glyph_index: u32,
    opts: RenderOptions,
) !Glyph {
    const cp = std.math.cast(u21, glyph_index) orelse return zero;
    const entry = self.entries.get(cp) orelse return zero;

    // Apply the registration's sizing/alignment/padding. The renderer-provided
    // cell footprint (opts.cell_width / constraint_width) is respected as-is;
    // proper `width=2` cell reservation is a terminal-layout concern tracked
    // separately.
    var render_opts = opts;
    render_opts.constraint = entry.constraint;

    var bitmap = switch (entry.glyph) {
        .glyf => |outline| try glyf_rasterize.rasterize(
            alloc,
            outline,
            entry.design,
            render_opts,
        ),
        .colrv0 => |bytes| try colr_rasterize.rasterizeColrV0(
            alloc,
            bytes,
            entry.design,
            render_opts,
        ),
        .colrv1 => |bytes| try colrv1_rasterize.rasterizeColrV1(
            alloc,
            bytes,
            entry.design,
            render_opts,
        ),
    };
    defer bitmap.deinit(alloc);

    if (bitmap.width == 0 or bitmap.height == 0) return zero;

    // Reserve and blit the alpha8 bitmap into the (grayscale) atlas.
    const region = try atlas.reserve(alloc, bitmap.width, bitmap.height);
    if (region.width > 0 and region.height > 0) atlas.set(region, bitmap.data);

    // The rasterizer produces a full-cell bitmap with placement already baked
    // in, so the glyph fills the cell just like a sprite glyph: no left bearing
    // and a top bearing equal to the full bitmap height.
    return .{
        .width = bitmap.width,
        .height = bitmap.height,
        .offset_x = 0,
        .offset_y = @intCast(bitmap.height),
        .atlas_x = region.x,
        .atlas_y = region.y,
    };
}

/// A zero-sized glyph, returned when there's nothing to draw.
const zero: Glyph = .{
    .width = 0,
    .height = 0,
    .offset_x = 0,
    .offset_y = 0,
    .atlas_x = 0,
    .atlas_y = 0,
};

test "glyphIndex reports registered vs unregistered" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var glossary: Glossary = .empty;
    defer glossary.deinit(alloc);
    try registerTriangle(alloc, &glossary, 0xE000);

    var face: GlossaryFace = .empty;
    defer face.deinit(alloc);
    try face.updateSnapshot(alloc, &glossary);

    try testing.expect(face.glyphIndex(0xE000) != null);
    try testing.expectEqual(@as(?u32, 0xE000), face.glyphIndex(0xE000));
    try testing.expect(face.glyphIndex(0xE001) == null);
    try testing.expectEqual(Presentation.text, face.presentation(0xE000));
}

test "renderGlyph produces a non-empty atlas region for a registered glyf" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var glossary: Glossary = .empty;
    defer glossary.deinit(alloc);
    try registerTriangle(alloc, &glossary, 0xE000);

    var face: GlossaryFace = .empty;
    defer face.deinit(alloc);
    try face.updateSnapshot(alloc, &glossary);

    var atlas = try Atlas.init(alloc, 64, .grayscale);
    defer atlas.deinit(alloc);

    const g = try face.renderGlyph(alloc, &atlas, 0xE000, .{
        .grid_metrics = testMetrics(20, 20),
    });
    try testing.expect(g.width > 0 and g.height > 0);
    try testing.expectEqual(@as(i32, 0), g.offset_x);
    try testing.expectEqual(@as(i32, @intCast(g.height)), g.offset_y);
}

test "renderGlyph returns zero glyph for unregistered codepoint" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var face: GlossaryFace = .empty;
    defer face.deinit(alloc);

    var atlas = try Atlas.init(alloc, 64, .grayscale);
    defer atlas.deinit(alloc);

    const g = try face.renderGlyph(alloc, &atlas, 0xE000, .{
        .grid_metrics = testMetrics(20, 20),
    });
    try testing.expectEqual(@as(u32, 0), g.width);
    try testing.expectEqual(@as(u32, 0), g.height);
}

/// Register the shared "triangle" test glyf (one contour, three points) into
/// `glossary` at `cp`, going through the real parse + decode path so the
/// resulting entry owns allocator memory just like production.
fn registerTriangle(alloc: Allocator, glossary: *Glossary, cp: u21) !void {
    const request = @import("../terminal/apc/glyph/request.zig");
    const payload = "AAEAZABkA4QDhAACAAABAQEB9P5wAyADhPzgAAA=";
    const data = try std.fmt.allocPrint(
        alloc,
        "r;cp={x};upm=1000;aw=1000;lh=1000;width=1;{s}",
        .{ cp, payload },
    );
    var req = try request.Request.parse(alloc, data);
    defer req.deinit(alloc);
    const entry = try Glossary.Entry.init(alloc, req.register);
    try glossary.register(alloc, cp, entry);
}

fn testMetrics(width: u32, height: u32) font.Metrics {
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
