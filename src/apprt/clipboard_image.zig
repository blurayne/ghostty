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

    // Ensure the target directory exists (e.g. a per-user cache dir under
    // Flatpak). Harmless for the system temp dir, which already exists.
    try std.fs.cwd().makePath(base);

    var name_buf: [64]u8 = undefined;
    const name = fileName(&name_buf, timestamp_ms, rand);

    const path = try std.fs.path.join(alloc, &.{ base, name });
    errdefer alloc.free(path);

    const file = try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(png);

    return path;
}

/// Resolve the base directory to write a clipboard image into.
///
/// Precedence:
///   1. `explicit` (the `clipboard-image-paste-directory` config) — used as-is.
///   2. Flatpak mode (`flatpak_mode` and `in_flatpak` both true) — the app's
///      own cache dir: `$XDG_CACHE_HOME/ghostty` (falling back to
///      `<home>/.cache/ghostty`). Under Flatpak `$XDG_CACHE_HOME` points at the
///      app's private, host-visible dir (`~/.var/app/<id>/cache`), which the
///      sandbox can write and host-side programs can read at the same absolute
///      path. Requires no extra sandbox permission (unlike `~/.cache`, which is
///      read-only under `--filesystem=home:ro`).
///   3. Otherwise `null` — `write` falls back to the system temp dir.
///
/// Returns a caller-owned slice (or null). The directory is not created here;
/// `write` ensures it exists.
pub fn resolveBaseDir(
    alloc: Allocator,
    explicit: ?[]const u8,
    flatpak_mode: bool,
    in_flatpak: bool,
    xdg_cache_home: ?[]const u8,
    home: ?[]const u8,
) !?[]u8 {
    if (explicit) |e| return try alloc.dupe(u8, e);
    if (flatpak_mode and in_flatpak) {
        if (xdg_cache_home) |xc| {
            if (xc.len > 0) return try std.fs.path.join(alloc, &.{ xc, "ghostty" });
        }
        if (home) |h| return try std.fs.path.join(alloc, &.{ h, ".cache", "ghostty" });
        return null;
    }
    return null;
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

test "clipboard image: resolveBaseDir explicit wins" {
    const testing = std.testing;
    const r = try resolveBaseDir(testing.allocator, "/custom/dir", true, true, "/x/.cache", "/home/u");
    defer if (r) |v| testing.allocator.free(v);
    try testing.expectEqualStrings("/custom/dir", r.?);
}

test "clipboard image: resolveBaseDir flatpak uses XDG cache dir" {
    const testing = std.testing;
    const r = try resolveBaseDir(testing.allocator, null, true, true, "/home/u/.var/app/x/cache", "/home/u");
    defer if (r) |v| testing.allocator.free(v);
    try testing.expectEqualStrings("/home/u/.var/app/x/cache/ghostty", r.?);
}

test "clipboard image: resolveBaseDir flatpak falls back to home cache" {
    const testing = std.testing;
    const r = try resolveBaseDir(testing.allocator, null, true, true, null, "/home/u");
    defer if (r) |v| testing.allocator.free(v);
    try testing.expectEqualStrings("/home/u/.cache/ghostty", r.?);
}

test "clipboard image: resolveBaseDir host mode is null" {
    const testing = std.testing;
    const r = try resolveBaseDir(testing.allocator, null, false, true, "/home/u/.cache", "/home/u");
    defer if (r) |v| testing.allocator.free(v);
    try testing.expect(r == null);
}

test "clipboard image: resolveBaseDir flatpak mode but not in flatpak is null" {
    const testing = std.testing;
    const r = try resolveBaseDir(testing.allocator, null, true, false, "/home/u/.cache", "/home/u");
    defer if (r) |v| testing.allocator.free(v);
    try testing.expect(r == null);
}
