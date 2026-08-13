//! Minimal OpenType COLR (Color) table parser.
//!
//! Full support is limited to **version 0** (flat layered color glyphs): a base
//! glyph maps to an ordered list of layers, each a (glyph id, palette index)
//! pair rendered bottom-to-top. Version 1 (the paint graph) is detected but not
//! decoded here. See:
//! https://learn.microsoft.com/en-us/typography/opentype/spec/colr
const std = @import("std");

pub const BaseGlyph = struct {
    glyph_id: u16,
    first_layer_index: u16,
    num_layers: u16,
};

pub const Layer = struct {
    glyph_id: u16,
    /// Palette entry index, or 0xFFFF meaning "use the text foreground color".
    palette_index: u16,
};

pub const Colr = struct {
    data: []const u8,
    version: u16,
    num_base_glyph_records: u16,
    base_glyph_records_offset: u32,
    layer_records_offset: u32,
    num_layer_records: u16,

    pub const Error = error{InvalidColr};

    /// Parse the fixed COLR v0 header (also present as the prefix of a v1
    /// table). Keeps a reference to `data`.
    pub fn init(data: []const u8) Error!Colr {
        const version = u16at(data, 0) orelse return error.InvalidColr;
        const num_base = u16at(data, 2) orelse return error.InvalidColr;
        const base_off = u32at(data, 4) orelse return error.InvalidColr;
        const layer_off = u32at(data, 8) orelse return error.InvalidColr;
        const num_layers = u16at(data, 12) orelse return error.InvalidColr;

        if (@as(usize, base_off) + @as(usize, num_base) * 6 > data.len)
            return error.InvalidColr;
        if (@as(usize, layer_off) + @as(usize, num_layers) * 4 > data.len)
            return error.InvalidColr;

        return .{
            .data = data,
            .version = version,
            .num_base_glyph_records = num_base,
            .base_glyph_records_offset = base_off,
            .layer_records_offset = layer_off,
            .num_layer_records = num_layers,
        };
    }

    /// The COLR v0 base glyph record at `i`, or null if out of range.
    pub fn baseGlyph(self: Colr, i: usize) ?BaseGlyph {
        if (i >= self.num_base_glyph_records) return null;
        const off = @as(usize, self.base_glyph_records_offset) + i * 6;
        return .{
            .glyph_id = self.read16(off),
            .first_layer_index = self.read16(off + 2),
            .num_layers = self.read16(off + 4),
        };
    }

    /// The layer record at absolute layer index `i`, or null if out of range.
    pub fn layer(self: Colr, i: usize) ?Layer {
        if (i >= self.num_layer_records) return null;
        const off = @as(usize, self.layer_records_offset) + i * 4;
        return .{
            .glyph_id = self.read16(off),
            .palette_index = self.read16(off + 2),
        };
    }

    /// Find the base glyph record covering `gid` (records are sorted ascending
    /// by glyph id, so we binary search).
    pub fn findBaseGlyph(self: Colr, gid: u16) ?BaseGlyph {
        var lo: usize = 0;
        var hi: usize = self.num_base_glyph_records;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const bg = self.baseGlyph(mid).?;
            if (bg.glyph_id == gid) return bg;
            if (bg.glyph_id < gid) lo = mid + 1 else hi = mid;
        }
        return null;
    }

    fn read16(self: Colr, off: usize) u16 {
        // Offsets are validated in init(); default to 0 on any overflow.
        return u16at(self.data, off) orelse 0;
    }
};

fn u16at(d: []const u8, off: usize) ?u16 {
    if (off + 2 > d.len) return null;
    return std.mem.readInt(u16, d[off..][0..2], .big);
}

fn u32at(d: []const u8, off: usize) ?u32 {
    if (off + 4 > d.len) return null;
    return std.mem.readInt(u32, d[off..][0..4], .big);
}

test "colr: parse v0 base + layer records" {
    const testing = std.testing;
    // version=0, numBaseGlyph=1, baseOff=14, layerOff=20, numLayer=2
    // base[0] = {glyph_id=5, first_layer=0, num_layers=2}
    // layer[0] = {glyph_id=6, palette=0}; layer[1] = {glyph_id=7, palette=1}
    const data = [_]u8{
        0x00, 0x00, // version
        0x00, 0x01, // numBaseGlyphRecords
        0x00, 0x00, 0x00, 0x0E, // baseGlyphRecordsOffset = 14
        0x00, 0x00, 0x00, 0x14, // layerRecordsOffset = 20
        0x00, 0x02, // numLayerRecords
        0x00, 0x05, 0x00, 0x00, 0x00, 0x02, // base[0]
        0x00, 0x06, 0x00, 0x00, // layer[0]
        0x00, 0x07, 0x00, 0x01, // layer[1]
    };
    const colr = try Colr.init(&data);
    try testing.expectEqual(@as(u16, 0), colr.version);

    const bg = colr.baseGlyph(0).?;
    try testing.expectEqual(@as(u16, 5), bg.glyph_id);
    try testing.expectEqual(@as(u16, 0), bg.first_layer_index);
    try testing.expectEqual(@as(u16, 2), bg.num_layers);

    try testing.expectEqual(@as(u16, 6), colr.layer(0).?.glyph_id);
    try testing.expectEqual(@as(u16, 0), colr.layer(0).?.palette_index);
    try testing.expectEqual(@as(u16, 7), colr.layer(1).?.glyph_id);
    try testing.expectEqual(@as(u16, 1), colr.layer(1).?.palette_index);

    try testing.expectEqual(@as(u16, 5), colr.findBaseGlyph(5).?.glyph_id);
    try testing.expect(colr.findBaseGlyph(99) == null);
}

test "colr: rejects out-of-range offsets" {
    const testing = std.testing;
    const data = [_]u8{
        0x00, 0x00, 0x00, 0x01,
        0xFF, 0xFF, 0xFF, 0xFF, // baseGlyphRecordsOffset way out of range
        0x00, 0x00, 0x00, 0x14,
        0x00, 0x00,
    };
    try testing.expectError(error.InvalidColr, Colr.init(&data));
}
