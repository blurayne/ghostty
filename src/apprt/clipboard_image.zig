//! Helpers for the "paste clipboard image as a temp-file path" feature.
//! These build and write the temporary PNG file whose path is then pasted
//! into the running program. See docs/superpowers/specs for the design.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Prefix for all temp files we create. Used for both creation and (future)
/// pruning.
pub const prefix = "ghostty-paste-";

/// Resolve the directory to write clipboard images into. If `dir` is non-null
/// it is returned as-is; otherwise the system temp dir is used.
pub fn resolveDir(dir: ?[]const u8) []const u8 {
    return dir orelse (std.posix.getenv("TMPDIR") orelse "/tmp");
}

/// Format the file name (not the full path) for a clipboard image into `buf`.
/// Returns the slice of `buf` that was written. `buf` must be at least
/// 64 bytes.
pub fn fileName(buf: []u8, timestamp_ms: i64, rand: u32) []const u8 {
    return std.fmt.bufPrint(
        buf,
        prefix ++ "{d}-{d}.png",
        .{ timestamp_ms, rand },
    ) catch unreachable;
}

/// Write `png` to a new temp file in `dir` (or the system temp dir if null).
/// Returns the absolute file path, allocated with `alloc`; caller owns it.
pub fn write(
    alloc: Allocator,
    dir: ?[]const u8,
    png: []const u8,
    timestamp_ms: i64,
    rand: u32,
) ![]u8 {
    const base = resolveDir(dir);

    var name_buf: [64]u8 = undefined;
    const name = fileName(&name_buf, timestamp_ms, rand);

    const path = try std.fs.path.join(alloc, &.{ base, name });
    errdefer alloc.free(path);

    const file = try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(png);

    return path;
}

test "clipboard image: fileName format" {
    var buf: [64]u8 = undefined;
    const name = fileName(&buf, 1234, 56);
    try std.testing.expectEqualStrings("ghostty-paste-1234-56.png", name);
}

test "clipboard image: write creates png file with bytes" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(dir_path);

    const png = "\x89PNG\r\n\x1a\nDATA";
    const path = try write(testing.allocator, dir_path, png, 999, 7);
    defer testing.allocator.free(path);

    try testing.expect(std.mem.endsWith(u8, path, "ghostty-paste-999-7.png"));

    const contents = try std.fs.cwd().readFileAlloc(testing.allocator, path, 1024);
    defer testing.allocator.free(contents);
    try testing.expectEqualStrings(png, contents);
}
