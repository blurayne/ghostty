//! Sixel graphics decoder.
//!
//! Sixel is a DEC graphics format that encodes bitmaps as sequences of
//! "six-pixel tall" color bands.  Each byte in the sixel data stream
//! (range '?'–'~', i.e. 0x3F–0x7E) encodes a vertical strip of six
//! pixels via a 6-bit mask: bit 0 = topmost pixel, bit 5 = bottommost.
//!
//! This decoder converts a raw sixel byte stream (everything after the
//! DCS `q` final byte, not including the ST terminator) into a flat
//! RGBA pixel buffer.
//!
//! References:
//!   - VT3xx Sixel Graphics Extension: https://vt100.net/docs/vt3xx-gp/chapter14.html
//!   - xterm sixel.c (MIT licence)
//!   - libsixel by Hayaki Saito (MIT licence): https://github.com/saitoha/libsixel

const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;

const log = std.log.scoped(.sixel);

/// Maximum image dimensions we will allocate.  Images larger than this
/// are truncated rather than causing OOM.
pub const max_width: u32 = 16384;
pub const max_height: u32 = 16384;

/// Maximum number of palette registers (DEC standard is 256).
pub const palette_size: usize = 256;

/// A single RGBA colour (r, g, b, a each 0–255).
pub const Rgba = packed struct { r: u8, g: u8, b: u8, a: u8 };

/// Pixel storage: a list of rows, each row being a list of pixels.
/// This allows the image to grow in both dimensions without having
/// to re-index the flat buffer when width increases mid-image.
const Row = std.ArrayListUnmanaged(Rgba);

/// Sixel decoder state machine.
///
/// Usage:
///   var d = Decoder.init(alloc, ps, pc);
///   defer d.deinit();
///   try d.feed(raw_bytes);           // may be called multiple times
///   const rgba_buf = try d.toRgba(); // caller owns returned slice
pub const Decoder = struct {
    alloc: Allocator,

    // ── palette ──────────────────────────────────────────────────────────
    /// 256 RGBA colour registers.  Initialised to a built-in 16-colour
    /// palette; undefined registers default to opaque black.
    palette: [palette_size]Rgba,

    // ── pixel buffer ─────────────────────────────────────────────────────
    /// Per-pixel-row storage.  Each entry is one horizontal scanline.
    /// rows[0] = topmost scanline.  Rows grow lazily as data arrives.
    rows: std.ArrayListUnmanaged(Row),

    /// Maximum column index written to so far (image width).
    width: u32,

    // ── decoder state ────────────────────────────────────────────────────
    /// X position of the write cursor (in pixels).
    cursor_x: u32,

    /// Current sixel band (each band = 6 pixel rows).
    band: u32,

    /// Currently selected palette register.
    current_color: u8,

    /// Background fill: false = transparent for unwritten pixels,
    ///                  true  = use register 0 (black by default).
    background_fill: bool,

    /// Scratch buffer used to accumulate a pending numeric argument.
    arg_buf: [16]u8,
    arg_len: u8,

    /// Parser sub-state for multi-byte commands.
    parse_state: ParseState,

    /// Pending repeat count for the `!n` prefix.
    repeat: u32,

    // ── palette introduction accumulators ────────────────────────────────
    pa_reg: u16,     // register number
    pa_model: u8,    // 1=HLS, 2=RGB
    pa_vals: [3]u16, // components
    pa_idx: u2,      // which component we're reading (0–2)

    const ParseState = enum {
        normal,
        repeat_count,
        color_reg,
        color_model,
        color_component,
        raster_attr,
    };

    // ─────────────────────────────────────────────────────────────────────
    // Public API
    // ─────────────────────────────────────────────────────────────────────

    /// Initialise a new decoder.
    ///
    /// `ps` is the DCS P2 parameter (background select):
    ///   0 = transparent for unwritten pixels.
    ///   1 = black background.
    ///
    /// `pc` is the DCS P3 parameter (colour register count).  Ignored
    ///   (we always allocate 256 registers).
    pub fn init(alloc: Allocator, ps: u16, _pc: u16) Decoder {
        _ = _pc;
        var dec: Decoder = .{
            .alloc = alloc,
            .palette = undefined,
            .rows = .empty,
            .width = 0,
            .cursor_x = 0,
            .band = 0,
            .current_color = 0,
            .background_fill = ps == 1,
            .arg_buf = undefined,
            .arg_len = 0,
            .parse_state = .normal,
            .repeat = 1,
            .pa_reg = 0,
            .pa_model = 2,
            .pa_vals = .{ 0, 0, 0 },
            .pa_idx = 0,
        };
        dec.initPalette();
        return dec;
    }

    pub fn deinit(self: *Decoder) void {
        for (self.rows.items) |*row| row.deinit(self.alloc);
        self.rows.deinit(self.alloc);
    }

    /// Feed raw sixel data bytes into the decoder.  May be called multiple times.
    pub fn feed(self: *Decoder, data: []const u8) !void {
        for (data) |b| try self.putByte(b);
    }

    /// Total image height in pixels.
    pub fn imageHeight(self: *const Decoder) u32 {
        return @intCast(self.rows.items.len);
    }

    /// Return the decoded RGBA pixel buffer.
    ///
    /// The returned slice is owned by the *caller* and must be freed with
    /// `alloc.free(slice)`.  The buffer is always `width * height * 4` bytes
    /// (RGBA, 1 byte per channel, row-major order).  Returns null if the
    /// image is empty.
    pub fn toRgba(self: *const Decoder) !?[]u8 {
        const w = self.width;
        const h = self.imageHeight();
        if (w == 0 or h == 0) return null;

        const buf = try self.alloc.alloc(u8, w * h * 4);
        // Fill with transparent black by default.
        @memset(buf, 0);

        for (self.rows.items, 0..) |*row, y| {
            for (row.items, 0..) |px, x| {
                if (x >= w) break;
                const base = (y * w + x) * 4;
                buf[base + 0] = px.r;
                buf[base + 1] = px.g;
                buf[base + 2] = px.b;
                buf[base + 3] = px.a;
            }
        }

        return buf;
    }

    // ─────────────────────────────────────────────────────────────────────
    // Internals
    // ─────────────────────────────────────────────────────────────────────

    fn initPalette(self: *Decoder) void {
        // Initialise all registers to opaque black.
        for (&self.palette) |*c| c.* = .{ .r = 0, .g = 0, .b = 0, .a = 255 };

        // VT340 built-in 16-colour palette.
        const default16 = [16]Rgba{
            .{ .r = 0,   .g = 0,   .b = 0,   .a = 255 }, // 0  black
            .{ .r = 51,  .g = 51,  .b = 204, .a = 255 }, // 1  blue
            .{ .r = 204, .g = 33,  .b = 33,  .a = 255 }, // 2  red
            .{ .r = 51,  .g = 204, .b = 51,  .a = 255 }, // 3  green
            .{ .r = 204, .g = 51,  .b = 204, .a = 255 }, // 4  magenta
            .{ .r = 51,  .g = 204, .b = 204, .a = 255 }, // 5  cyan
            .{ .r = 204, .g = 204, .b = 51,  .a = 255 }, // 6  yellow
            .{ .r = 135, .g = 135, .b = 135, .a = 255 }, // 7  gray 50%
            .{ .r = 66,  .g = 66,  .b = 66,  .a = 255 }, // 8  gray 25%
            .{ .r = 84,  .g = 84,  .b = 204, .a = 255 }, // 9  bright blue
            .{ .r = 204, .g = 84,  .b = 84,  .a = 255 }, // 10 bright red
            .{ .r = 84,  .g = 204, .b = 84,  .a = 255 }, // 11 bright green
            .{ .r = 204, .g = 84,  .b = 204, .a = 255 }, // 12 bright magenta
            .{ .r = 84,  .g = 204, .b = 204, .a = 255 }, // 13 bright cyan
            .{ .r = 204, .g = 204, .b = 84,  .a = 255 }, // 14 bright yellow
            .{ .r = 204, .g = 204, .b = 204, .a = 255 }, // 15 white
        };
        for (default16, 0..) |c, i| self.palette[i] = c;
    }

    fn putByte(self: *Decoder, b: u8) !void {
        switch (self.parse_state) {
            .normal => try self.normalByte(b),
            .repeat_count => try self.repeatCountByte(b),
            .color_reg => try self.colorRegByte(b),
            .color_model => try self.colorModelByte(b),
            .color_component => try self.colorComponentByte(b),
            .raster_attr => try self.rasterAttrByte(b),
        }
    }

    fn normalByte(self: *Decoder, b: u8) !void {
        switch (b) {
            '!' => {
                self.arg_len = 0;
                self.parse_state = .repeat_count;
            },
            '#' => {
                self.arg_len = 0;
                self.pa_reg = 0;
                self.parse_state = .color_reg;
            },
            '"' => {
                self.arg_len = 0;
                self.parse_state = .raster_attr;
            },
            '$' => {
                // Carriage return: back to column 0, same band.
                self.cursor_x = 0;
            },
            '-' => {
                // New sixel band (move down 6 pixels).
                self.cursor_x = 0;
                self.band += 1;
            },
            '?'...'~' => {
                // Sixel data byte: bits 0–5 each control one pixel row.
                const mask: u6 = @intCast(b - '?');
                try self.paintSixel(mask, self.repeat);
                self.repeat = 1;
            },
            else => {
                self.repeat = 1;
            },
        }
    }

    fn repeatCountByte(self: *Decoder, b: u8) !void {
        switch (b) {
            '0'...'9' => {
                if (self.arg_len < self.arg_buf.len) {
                    self.arg_buf[self.arg_len] = b;
                    self.arg_len += 1;
                }
            },
            else => {
                self.repeat = parseU32(self.arg_buf[0..self.arg_len]) orelse 1;
                if (self.repeat == 0) self.repeat = 1;
                self.arg_len = 0;
                self.parse_state = .normal;
                try self.normalByte(b);
            },
        }
    }

    fn colorRegByte(self: *Decoder, b: u8) !void {
        switch (b) {
            '0'...'9' => {
                if (self.arg_len < self.arg_buf.len) {
                    self.arg_buf[self.arg_len] = b;
                    self.arg_len += 1;
                }
            },
            ';' => {
                // Register number followed by semicolon → colour definition follows.
                self.pa_reg = @intCast(@min(
                    parseU32(self.arg_buf[0..self.arg_len]) orelse 0,
                    palette_size - 1,
                ));
                self.arg_len = 0;
                self.pa_model = 2;
                self.pa_vals = .{ 0, 0, 0 };
                self.pa_idx = 0;
                self.parse_state = .color_model;
            },
            else => {
                // Register number with no semicolon → just a colour selection.
                self.pa_reg = @intCast(@min(
                    parseU32(self.arg_buf[0..self.arg_len]) orelse 0,
                    palette_size - 1,
                ));
                self.arg_len = 0;
                self.current_color = @intCast(self.pa_reg);
                self.parse_state = .normal;
                try self.normalByte(b);
            },
        }
    }

    fn colorModelByte(self: *Decoder, b: u8) !void {
        switch (b) {
            '0'...'9' => {
                if (self.arg_len < self.arg_buf.len) {
                    self.arg_buf[self.arg_len] = b;
                    self.arg_len += 1;
                }
            },
            ';' => {
                self.pa_model = @intCast(@min(parseU32(self.arg_buf[0..self.arg_len]) orelse 2, 255));
                self.arg_len = 0;
                self.pa_idx = 0;
                self.parse_state = .color_component;
            },
            else => {
                // Malformed; treat as selection.
                self.current_color = @intCast(self.pa_reg);
                self.parse_state = .normal;
                try self.normalByte(b);
            },
        }
    }

    fn colorComponentByte(self: *Decoder, b: u8) !void {
        switch (b) {
            '0'...'9' => {
                if (self.arg_len < self.arg_buf.len) {
                    self.arg_buf[self.arg_len] = b;
                    self.arg_len += 1;
                }
            },
            else => {
                const val: u16 = @intCast(@min(parseU32(self.arg_buf[0..self.arg_len]) orelse 0, 360));
                self.arg_len = 0;
                if (self.pa_idx < 3) {
                    self.pa_vals[self.pa_idx] = val;
                    self.pa_idx += 1;
                }

                if (b != ';' or self.pa_idx >= 3) {
                    self.commitColor();
                    self.current_color = @intCast(self.pa_reg);
                    self.parse_state = .normal;
                    if (b != ';') try self.normalByte(b);
                }
            },
        }
    }

    fn rasterAttrByte(self: *Decoder, b: u8) !void {
        // Raster attributes: "Pan;Pad;Ph;Pv
        // We just skip them (consume digits and semicolons) and return to normal.
        switch (b) {
            '0'...'9', ';' => {},
            else => {
                self.parse_state = .normal;
                try self.normalByte(b);
            },
        }
    }

    /// Paint `count` repetitions of the sixel column described by `mask`.
    fn paintSixel(self: *Decoder, mask: u6, count: u32) !void {
        if (mask == 0) {
            // Transparent sixel — still advances cursor, just no paint.
            self.cursor_x += count;
            // Update width for transparent pixels too (some images use them as spacing).
            const end_col = self.cursor_x;
            if (end_col > self.width) self.width = @min(end_col, max_width);
            return;
        }

        const color = self.palette[self.current_color];

        var rep: u32 = 0;
        while (rep < count) : (rep += 1) {
            const col = self.cursor_x + rep;
            if (col >= max_width) break;

            // Update maximum width seen.
            if (col + 1 > self.width) self.width = col + 1;

            // Paint each of the 6 rows in the current band.
            var row: u3 = 0;
            while (row < 6) : (row += 1) {
                if ((mask >> row) & 1 == 0) continue;
                const px_y: u32 = self.band * 6 + row;
                if (px_y >= max_height) continue;

                // Ensure we have a row at this y coordinate.
                try self.ensureRow(px_y);

                // Ensure the row has a slot for column `col`.
                const pixel_row = &self.rows.items[px_y];
                if (col >= pixel_row.items.len) {
                    const old_len = pixel_row.items.len;
                    try pixel_row.resize(self.alloc, col + 1);
                    // Fill new slots with transparent black.
                    @memset(pixel_row.items[old_len..], .{ .r = 0, .g = 0, .b = 0, .a = 0 });
                }

                pixel_row.items[col] = color;
            }
        }
        self.cursor_x += count;
    }

    /// Ensure `rows` has an entry at index `y`.
    fn ensureRow(self: *Decoder, y: u32) !void {
        if (y < self.rows.items.len) return;
        const old_len = self.rows.items.len;
        try self.rows.resize(self.alloc, y + 1);
        // Initialise new rows as empty.
        for (self.rows.items[old_len..]) |*row| row.* = .empty;
    }

    /// Commit the current palette introduction to self.palette.
    fn commitColor(self: *Decoder) void {
        const reg = @min(@as(usize, self.pa_reg), palette_size - 1);
        const rgba: Rgba = switch (self.pa_model) {
            2 => rgb: {
                // RGB: components are 0–100 (percentage).
                const r: u8 = @intCast((@as(u32, self.pa_vals[0]) * 255 + 50) / 100);
                const g: u8 = @intCast((@as(u32, self.pa_vals[1]) * 255 + 50) / 100);
                const bv: u8 = @intCast((@as(u32, self.pa_vals[2]) * 255 + 50) / 100);
                break :rgb .{ .r = r, .g = g, .b = bv, .a = 255 };
            },
            1 => hls: {
                // HLS: hue 0–360, lightness 0–100, saturation 0–100.
                const h = @as(f32, @floatFromInt(self.pa_vals[0]));
                const l = @as(f32, @floatFromInt(self.pa_vals[1])) / 100.0;
                const s = @as(f32, @floatFromInt(self.pa_vals[2])) / 100.0;
                break :hls hlsToRgb(h, l, s);
            },
            else => .{ .r = 0, .g = 0, .b = 0, .a = 255 },
        };
        self.palette[reg] = rgba;
    }

    // ─────────────────────────────────────────────────────────────────────
    // Helpers
    // ─────────────────────────────────────────────────────────────────────

    fn parseU32(s: []const u8) ?u32 {
        if (s.len == 0) return null;
        return std.fmt.parseInt(u32, s, 10) catch null;
    }

    /// Convert HLS (hue 0–360, lightness 0–1, saturation 0–1) to RGBA.
    fn hlsToRgb(h: f32, l: f32, s: f32) Rgba {
        if (s == 0.0) {
            const v: u8 = @intFromFloat(@round(l * 255.0));
            return .{ .r = v, .g = v, .b = v, .a = 255 };
        }
        const q = if (l < 0.5) l * (1.0 + s) else l + s - l * s;
        const p = 2.0 * l - q;
        return .{
            .r = @intFromFloat(@round(hueToRgb(p, q, h / 360.0 + 1.0 / 3.0) * 255.0)),
            .g = @intFromFloat(@round(hueToRgb(p, q, h / 360.0) * 255.0)),
            .b = @intFromFloat(@round(hueToRgb(p, q, h / 360.0 - 1.0 / 3.0) * 255.0)),
            .a = 255,
        };
    }

    fn hueToRgb(p: f32, q: f32, t_in: f32) f32 {
        var t = t_in;
        if (t < 0.0) t += 1.0;
        if (t > 1.0) t -= 1.0;
        if (t < 1.0 / 6.0) return p + (q - p) * 6.0 * t;
        if (t < 1.0 / 2.0) return q;
        if (t < 2.0 / 3.0) return p + (q - p) * (2.0 / 3.0 - t) * 6.0;
        return p;
    }
};

// ─────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────

test "sixel: minimal 1-wide single-color image" {
    // Sixel `~` = 0b111111 → all 6 pixels ON.
    // We paint register 2 (red in default palette) with `~`.
    // Sequence: #2~
    var dec = Decoder.init(testing.allocator, 0, 0);
    defer dec.deinit();

    try dec.feed("#2~");
    // width=1, height=6 (one band painted).
    try testing.expectEqual(@as(u32, 1), dec.width);
    try testing.expectEqual(@as(u32, 6), dec.imageHeight());

    const rgba = try dec.toRgba();
    try testing.expect(rgba != null);
    defer testing.allocator.free(rgba.?);

    // All 6 pixels should be palette[2] = red (204, 33, 33, 255).
    var i: usize = 0;
    while (i < 6) : (i += 1) {
        try testing.expectEqual(@as(u8, 204), rgba.?[i * 4 + 0]); // R
        try testing.expectEqual(@as(u8, 33),  rgba.?[i * 4 + 1]); // G
        try testing.expectEqual(@as(u8, 255), rgba.?[i * 4 + 3]); // A
    }
}

test "sixel: carriage return and next band" {
    // Sixel sequence:
    //   #1~~ → paint col0 and col1 in band0 with color1, cursor_x=2
    //   $    → CR: cursor_x=0
    //   #2~  → paint col0 in band0 with color2 (overwrite), cursor_x=1
    //   -    → next band, cursor_x=0, band=1
    //   #3~  → paint col0 in band1 with color3, cursor_x=1
    //
    // Result: width=2 (two columns painted in band 0), height=12 (2 bands * 6).
    var dec = Decoder.init(testing.allocator, 0, 0);
    defer dec.deinit();

    try dec.feed("#1~~$#2~-#3~");
    // Width: 2 columns were touched in band 0.
    // Height: 2 bands * 6 = 12 rows.
    try testing.expectEqual(@as(u32, 2), dec.width);
    try testing.expectEqual(@as(u32, 12), dec.imageHeight());

    const rgba = try dec.toRgba();
    try testing.expect(rgba != null);
    defer testing.allocator.free(rgba.?);

    // Band 0, row 0, col 0 should be color2 (was overwritten: red 204,33,33).
    // palette[2] = { r=204, g=33, b=33, a=255 }
    try testing.expectEqual(@as(u8, 204), rgba.?[0]); // R at (row=0, col=0)
    try testing.expectEqual(@as(u8, 33),  rgba.?[1]); // G at (row=0, col=0)

    // Band 0, row 0, col 1 should be color1 (blue: 51,51,204).
    // palette[1] = { r=51, g=51, b=204, a=255 }
    try testing.expectEqual(@as(u8, 51),  rgba.?[4]); // R at (row=0, col=1)
    try testing.expectEqual(@as(u8, 51),  rgba.?[5]); // G at (row=0, col=1)
}

test "sixel: repeat prefix" {
    // !3~ paints 3 consecutive columns with the current color.
    var dec = Decoder.init(testing.allocator, 0, 0);
    defer dec.deinit();

    try dec.feed("!3~");
    try testing.expectEqual(@as(u32, 3), dec.width);
    try testing.expectEqual(@as(u32, 6), dec.imageHeight());
}

test "sixel: palette introduction RGB" {
    // #1;2;100;0;0 → register 1 = pure red (r=100%, g=0%, b=0%)
    var dec = Decoder.init(testing.allocator, 0, 0);
    defer dec.deinit();

    try dec.feed("#1;2;100;0;0~");

    // Palette register 1 should now be (255, 0, 0, 255).
    try testing.expectEqual(@as(u8, 255), dec.palette[1].r);
    try testing.expectEqual(@as(u8, 0),   dec.palette[1].g);
    try testing.expectEqual(@as(u8, 0),   dec.palette[1].b);
    try testing.expectEqual(@as(u8, 255), dec.palette[1].a);

    // Column 0 should be painted with register 1 (pure red).
    const rgba = try dec.toRgba();
    try testing.expect(rgba != null);
    defer testing.allocator.free(rgba.?);
    try testing.expectEqual(@as(u8, 255), rgba.?[0]); // R
    try testing.expectEqual(@as(u8, 0),   rgba.?[1]); // G
    try testing.expectEqual(@as(u8, 0),   rgba.?[2]); // B
}

test "sixel: empty data returns null" {
    var dec = Decoder.init(testing.allocator, 0, 0);
    defer dec.deinit();

    const rgba = try dec.toRgba();
    try testing.expect(rgba == null);
}

test "sixel: raster attribute parsing does not crash" {
    // Raster attribute sequence followed by data.
    var dec = Decoder.init(testing.allocator, 0, 0);
    defer dec.deinit();

    // "1;1;10;6 → Pan=1,Pad=1,Ph=10,Pv=6 then paints register 0.
    try dec.feed("\"1;1;10;6#0~");
    try testing.expectEqual(@as(u32, 1), dec.width);
    try testing.expectEqual(@as(u32, 6), dec.imageHeight());
}

test "sixel: transparent sixel advances cursor" {
    // `?` = 0b000000 → all 6 pixels OFF (transparent).  The cursor should still advance.
    // Then `~` → all 6 pixels ON at column 1.
    var dec = Decoder.init(testing.allocator, 0, 0);
    defer dec.deinit();

    try dec.feed("#2?~");
    // cursor advanced past col 0 (transparent) to col 1 (opaque).
    try testing.expectEqual(@as(u32, 2), dec.width);
    try testing.expectEqual(@as(u32, 6), dec.imageHeight());

    const rgba = try dec.toRgba();
    try testing.expect(rgba != null);
    defer testing.allocator.free(rgba.?);

    // Col 0 should be transparent (a=0).
    try testing.expectEqual(@as(u8, 0), rgba.?[3]); // A at (0,0)
    // Col 1 should be opaque (palette[2]).
    try testing.expectEqual(@as(u8, 255), rgba.?[4 + 3]); // A at (0,1)
}
