//! Pure matching logic for the split focus dialog. Kept separate from the
//! widgets so it can be tested without a compositor: everything else in
//! this feature needs a live GTK application to exercise.

const std = @import("std");

/// A byte range within a haystack. Pango attribute ranges are byte
/// offsets, so these are too.
pub const Range = struct {
    start: usize,
    end: usize,
};

/// Case-insensitive substring search, returning the byte range of the
/// first match. Returns null when the needle is empty: an empty search
/// box matches every row but has nothing to highlight.
///
/// Case folding is ASCII-only. A search for "STRASSE" will not match
/// "straße"; matching Unicode case folding is not worth the dependency
/// for a title search box.
pub fn find(haystack: []const u8, needle: []const u8) ?Range {
    if (needle.len == 0) return null;
    const idx = std.ascii.indexOfIgnoreCase(haystack, needle) orelse return null;
    return .{ .start = idx, .end = idx + needle.len };
}

/// Whether a row's own text matches, ignoring its descendants. An empty
/// needle matches everything so that clearing the search box restores the
/// whole tree.
pub fn matchesFields(title: []const u8, pwd: ?[]const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (find(title, needle) != null) return true;
    if (pwd) |p| if (find(p, needle) != null) return true;
    return false;
}

test "find: match at the start" {
    const r = find("deploy.sh", "dep") orelse return error.TestExpectedMatch;
    try std.testing.expectEqual(@as(usize, 0), r.start);
    try std.testing.expectEqual(@as(usize, 3), r.end);
}

test "find: match in the middle" {
    const r = find("./deploy.sh", "loy") orelse return error.TestExpectedMatch;
    try std.testing.expectEqual(@as(usize, 5), r.start);
    try std.testing.expectEqual(@as(usize, 8), r.end);
}

test "find: is case insensitive" {
    const r = find("Deploy", "dEp") orelse return error.TestExpectedMatch;
    try std.testing.expectEqual(@as(usize, 0), r.start);
    try std.testing.expectEqual(@as(usize, 3), r.end);
}

test "find: no match" {
    try std.testing.expect(find("deploy.sh", "zzz") == null);
}

test "find: an empty needle never highlights" {
    // An empty search box matches everything, but there is nothing to
    // invert -- returning a zero-length range would paint a stray cell.
    try std.testing.expect(find("deploy.sh", "") == null);
}

test "find: offsets are bytes, not codepoints" {
    // "über" is 5 bytes: ü=2, b=1, e=1, r=1. A Pango attribute range
    // is in bytes, so a match after a multi-byte character must not shift.
    const r = find("über-deploy", "deploy") orelse return error.TestExpectedMatch;
    try std.testing.expectEqual(@as(usize, 6), r.start);
    try std.testing.expectEqual(@as(usize, 12), r.end);
}

test "matchesFields: title matches" {
    try std.testing.expect(matchesFields("deploy.sh", null, "dep"));
}

test "matchesFields: pwd matches when the title does not" {
    try std.testing.expect(matchesFields("zsh", "/home/me/ghostty", "ghost"));
}

test "matchesFields: neither matches" {
    try std.testing.expect(!matchesFields("zsh", "/home/me/ghostty", "zzz"));
}

test "matchesFields: an absent pwd is not a match" {
    try std.testing.expect(!matchesFields("zsh", null, "ghost"));
}

test "matchesFields: an empty needle matches everything" {
    // An empty search box must not empty the tree.
    try std.testing.expect(matchesFields("zsh", null, ""));
}
