const std = @import("std");
const glib = @import("glib");

pub const MIME = "application/x-ghostty-split";

pub const Payload = extern struct {
    pid: i32,
    uuid: [16]u8,

    pub fn serialize(self: *const Payload) *glib.Bytes {
        const bytes = std.mem.asBytes(self);
        return glib.Bytes.new(bytes.ptr, bytes.len);
    }

    pub fn parse(bytes: *glib.Bytes) ?Payload {
        var size: usize = 0;
        const data = bytes.getData(&size);
        if (size != @sizeOf(Payload)) return null;
        if (data == null) return null;
        var result: Payload = undefined;
        @memcpy(std.mem.asBytes(&result), @as([*]const u8, @ptrCast(data.?))[0..size]);
        return result;
    }
};

pub const Quadrant = enum { top, bottom, left, right };

/// Determine which quadrant of a widget (w×h) the cursor (x,y) is in.
/// Uses the two diagonals to split into 4 quadrants.
pub fn quadrantFor(x: f64, y: f64, w: f64, h: f64) Quadrant {
    const norm_x = x / w;
    const norm_y = y / h;
    const above_tl_br = norm_y < norm_x; // above top-left to bottom-right diagonal
    const above_tr_bl = norm_y < (1.0 - norm_x); // above top-right to bottom-left diagonal
    return if (above_tl_br and above_tr_bl)
        .top
    else if (!above_tl_br and above_tr_bl)
        .left
    else if (above_tl_br and !above_tr_bl)
        .right
    else
        .bottom;
}

test "split_dnd: quadrantFor corners" {
    const std_test = @import("std").testing;
    // Center-top → top
    try std_test.expectEqual(Quadrant.top, quadrantFor(50, 10, 100, 100));
    // Center-bottom → bottom
    try std_test.expectEqual(Quadrant.bottom, quadrantFor(50, 90, 100, 100));
    // Left-center → left
    try std_test.expectEqual(Quadrant.left, quadrantFor(10, 50, 100, 100));
    // Right-center → right
    try std_test.expectEqual(Quadrant.right, quadrantFor(90, 50, 100, 100));
}

test "split_dnd: payload serialize/parse round-trip" {
    const std_test = @import("std").testing;
    const original = Payload{
        .pid = 12345,
        .uuid = .{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 },
    };
    const bytes = original.serialize();
    defer bytes.unref();
    const parsed = Payload.parse(bytes) orelse {
        try std_test.expect(false); // should not be null
        return;
    };
    try std_test.expectEqual(original.pid, parsed.pid);
    try std_test.expectEqualSlices(u8, &original.uuid, &parsed.uuid);
}
