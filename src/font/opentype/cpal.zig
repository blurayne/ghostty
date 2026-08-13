//! Minimal OpenType CPAL (Color Palette) table parser.
//!
//! We only need read access to palette 0 (the default palette), which is all
//! the Glyph Protocol color formats reference. See:
//! https://learn.microsoft.com/en-us/typography/opentype/spec/cpal
const std = @import("std");

/// A straight-alpha RGBA color.
pub const Color = struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8,
};

pub const Cpal = struct {
    data: []const u8,
    num_palette_entries: u16,
    num_color_records: u16,
    color_records_offset: u32,
    /// Index into the color records array where palette 0 begins.
    palette0_first: u16,

    pub const Error = error{InvalidCpal};

    /// Parse a standalone CPAL table. Keeps a reference to `data`.
    pub fn init(data: []const u8) Error!Cpal {
        // Header (v0): version, numPaletteEntries, numPalettes,
        // numColorRecords (all u16), colorRecordsArrayOffset (u32).
        const num_palette_entries = u16at(data, 2) orelse return error.InvalidCpal;
        const num_palettes = u16at(data, 4) orelse return error.InvalidCpal;
        const num_color_records = u16at(data, 6) orelse return error.InvalidCpal;
        const color_records_offset = u32at(data, 8) orelse return error.InvalidCpal;
        if (num_palettes == 0) return error.InvalidCpal;

        // colorRecordIndices[numPalettes] follows the 12-byte header.
        const palette0_first = u16at(data, 12) orelse return error.InvalidCpal;

        // Validate the color records region (each record is 4 bytes: BGRA).
        const records_end = @as(usize, color_records_offset) +
            @as(usize, num_color_records) * 4;
        if (records_end > data.len) return error.InvalidCpal;

        return .{
            .data = data,
            .num_palette_entries = num_palette_entries,
            .num_color_records = num_color_records,
            .color_records_offset = color_records_offset,
            .palette0_first = palette0_first,
        };
    }

    /// The color for palette entry `index` in palette 0, or null if out of
    /// range. Color records are stored BGRA on disk.
    pub fn color(self: Cpal, index: u16) ?Color {
        if (index >= self.num_palette_entries) return null;
        const rec = @as(usize, self.palette0_first) + index;
        if (rec >= self.num_color_records) return null;
        const off = @as(usize, self.color_records_offset) + rec * 4;
        // Bounds already validated in init(), but keep this defensive.
        if (off + 4 > self.data.len) return null;
        return .{
            .b = self.data[off],
            .g = self.data[off + 1],
            .r = self.data[off + 2],
            .a = self.data[off + 3],
        };
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

test "cpal: parse a two-color palette" {
    const testing = std.testing;
    // version=0, entries=2, palettes=1, records=2, offset=14,
    // colorRecordIndices=[0], then 2 BGRA records:
    //   red   = FF0000FF -> BGRA 00 00 FF FF
    //   green = 00FF00FF -> BGRA 00 FF 00 FF
    const data = [_]u8{
        0x00, 0x00, // version
        0x00, 0x02, // numPaletteEntries
        0x00, 0x01, // numPalettes
        0x00, 0x02, // numColorRecords
        0x00, 0x00, 0x00, 0x0E, // colorRecordsArrayOffset = 14
        0x00, 0x00, // colorRecordIndices[0] = 0
        0x00, 0x00, 0xFF, 0xFF, // record 0: B G R A = red
        0x00, 0xFF, 0x00, 0xFF, // record 1: green
    };
    const cpal = try Cpal.init(&data);
    try testing.expectEqual(@as(u16, 2), cpal.num_palette_entries);

    const c0 = cpal.color(0).?;
    try testing.expectEqual(@as(u8, 0xFF), c0.r);
    try testing.expectEqual(@as(u8, 0x00), c0.g);
    try testing.expectEqual(@as(u8, 0x00), c0.b);
    try testing.expectEqual(@as(u8, 0xFF), c0.a);

    const c1 = cpal.color(1).?;
    try testing.expectEqual(@as(u8, 0x00), c1.r);
    try testing.expectEqual(@as(u8, 0xFF), c1.g);

    try testing.expect(cpal.color(2) == null);
}

test "cpal: rejects truncated header" {
    const testing = std.testing;
    try testing.expectError(error.InvalidCpal, Cpal.init(&[_]u8{ 0, 0, 0 }));
}
