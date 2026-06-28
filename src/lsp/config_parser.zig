//! Ghostty config file parser for the LSP server.
//!
//! The ghostty config format is simple line-oriented text:
//!   - `key = value`   — assignment
//!   - `# comment`     — ignored
//!   - blank lines     — ignored
//!
//! This parser extracts structured information needed for LSP features:
//! completions, hover, and diagnostics.

const std = @import("std");

/// A parsed line from a ghostty config file.
pub const Line = struct {
    /// 0-based line number.
    number: u32,
    /// Raw text of the line (without trailing newline).
    text: []const u8,
    /// What kind of line this is.
    kind: Kind,

    pub const Kind = union(enum) {
        /// Empty or whitespace-only.
        blank,
        /// `# ...`
        comment,
        /// `key = value` — both slices are sub-slices of `text`.
        assignment: Assignment,
        /// Has an `=` but the key portion is empty, or another parse error.
        malformed,
        /// Non-blank, non-comment, no `=` — the user is still typing the key.
        partial_key: []const u8,
    };

    pub const Assignment = struct {
        key: []const u8,
        value: []const u8,
    };
};

/// Parse all lines of a ghostty config text into a slice of `Line`.
/// Caller owns the returned slice; the `text` fields are sub-slices of
/// `src` so `src` must outlive the returned slice.
pub fn parseLines(allocator: std.mem.Allocator, src: []const u8) ![]Line {
    var lines: std.ArrayList(Line) = .empty;
    defer lines.deinit(allocator);

    var line_number: u32 = 0;
    var iter = std.mem.splitScalar(u8, src, '\n');
    while (iter.next()) |raw| {
        // Strip trailing \r (CRLF files).
        const text = std.mem.trimRight(u8, raw, "\r");
        const trimmed = std.mem.trim(u8, text, " \t");

        const kind: Line.Kind = if (trimmed.len == 0)
            .blank
        else if (trimmed[0] == '#')
            .comment
        else if (std.mem.indexOfScalar(u8, text, '=')) |eq_pos| blk: {
            const key = std.mem.trimRight(u8, text[0..eq_pos], " \t");
            const value = std.mem.trimLeft(u8, text[eq_pos + 1 ..], " \t");
            if (key.len == 0) break :blk .malformed;
            break :blk .{ .assignment = .{ .key = key, .value = value } };
        } else
            // Non-blank, non-comment, no `=` — user is still typing the key.
            .{ .partial_key = trimmed };

        try lines.append(allocator, .{
            .number = line_number,
            .text = text,
            .kind = kind,
        });
        line_number += 1;
    }

    return lines.toOwnedSlice(allocator);
}

/// Find the line at a given 0-based line number, returning null if out of range.
pub fn lineAt(lines: []const Line, line_num: u32) ?*const Line {
    for (lines) |*l| {
        if (l.number == line_num) return l;
    }
    return null;
}

/// Determine what the user is editing at `(line, character)`.
/// Returns the context so the LSP can decide what completions to offer.
pub const CursorContext = union(enum) {
    /// Cursor is on a key (before or at `=`).
    key: []const u8,
    /// Cursor is on a value (after `=`). `key` is the key for this line.
    value: struct { key: []const u8, partial: []const u8 },
    /// Nothing actionable (blank line, comment, out of range).
    none,
};

pub fn contextAt(lines: []const Line, line_num: u32, character: u32) CursorContext {
    const line = lineAt(lines, line_num) orelse return .none;
    switch (line.kind) {
        .comment => return .none,
        // Bare `= value` with empty key — can't offer meaningful completion.
        .malformed => return .none,
        // Blank line: treat as empty key context so the caller offers all keys.
        .blank => return .{ .key = "" },
        // User is still typing the key (no `=` yet).
        .partial_key => |pk| return .{ .key = pk },
        .assignment => |a| {
            // Determine whether the cursor is on the key or the value side.
            // eq_pos within line.text:
            const eq_pos = std.mem.indexOfScalar(u8, line.text, '=') orelse return .none;
            if (character <= eq_pos) {
                // Key side: return partial key typed so far.
                const end = @min(character, @as(u32, @intCast(a.key.len)));
                return .{ .key = a.key[0..end] };
            } else {
                // Value side
                const value_start: u32 = @intCast(eq_pos + 1);
                const ws = countLeadingSpace(line.text[value_start..]);
                const partial_start = value_start + ws;
                const partial_end = @min(character, @as(u32, @intCast(line.text.len)));
                const partial = if (partial_start < partial_end)
                    line.text[partial_start..partial_end]
                else
                    "";
                return .{ .value = .{ .key = a.key, .partial = partial } };
            }
        },
    }
}

fn countLeadingSpace(s: []const u8) u32 {
    var n: u32 = 0;
    for (s) |c| {
        if (c != ' ' and c != '\t') break;
        n += 1;
    }
    return n;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "parseLines: basic" {
    const allocator = std.testing.allocator;
    const src =
        \\# comment
        \\
        \\font-size = 14
        \\theme = catppuccin-mocha
    ;
    const lines = try parseLines(allocator, src);
    defer allocator.free(lines);

    try std.testing.expectEqual(@as(usize, 4), lines.len);
    try std.testing.expect(lines[0].kind == .comment);
    try std.testing.expect(lines[1].kind == .blank);

    const a1 = lines[2].kind.assignment;
    try std.testing.expectEqualStrings("font-size", a1.key);
    try std.testing.expectEqualStrings("14", a1.value);

    const a2 = lines[3].kind.assignment;
    try std.testing.expectEqualStrings("theme", a2.key);
    try std.testing.expectEqualStrings("catppuccin-mocha", a2.value);
}

test "parseLines: CRLF" {
    const allocator = std.testing.allocator;
    const src = "font-size = 12\r\ntheme = dark\r\n";
    const lines = try parseLines(allocator, src);
    defer allocator.free(lines);
    try std.testing.expectEqual(@as(usize, 3), lines.len); // trailing empty line
    const a = lines[0].kind.assignment;
    try std.testing.expectEqualStrings("font-size", a.key);
    try std.testing.expectEqualStrings("12", a.value);
}

test "parseLines: empty key → malformed" {
    const allocator = std.testing.allocator;
    const src = " = value";
    const lines = try parseLines(allocator, src);
    defer allocator.free(lines);
    try std.testing.expectEqual(@as(usize, 1), lines.len);
    try std.testing.expect(lines[0].kind == .malformed);
}

test "parseLines: bare key (no =) → partial_key" {
    const allocator = std.testing.allocator;
    const src = "font-";
    const lines = try parseLines(allocator, src);
    defer allocator.free(lines);
    try std.testing.expectEqual(@as(usize, 1), lines.len);
    try std.testing.expect(lines[0].kind == .partial_key);
    try std.testing.expectEqualStrings("font-", lines[0].kind.partial_key);
}

test "contextAt: key side" {
    const allocator = std.testing.allocator;
    const src = "font-size = 14";
    const lines = try parseLines(allocator, src);
    defer allocator.free(lines);
    // cursor at col 4 → "font" partial
    const ctx = contextAt(lines, 0, 4);
    try std.testing.expect(ctx == .key);
    try std.testing.expectEqualStrings("font", ctx.key);
}

test "contextAt: value side" {
    const allocator = std.testing.allocator;
    const src = "cursor-style = bar";
    const lines = try parseLines(allocator, src);
    defer allocator.free(lines);
    // cursor at end of line
    const ctx = contextAt(lines, 0, @intCast(src.len));
    try std.testing.expect(ctx == .value);
    try std.testing.expectEqualStrings("cursor-style", ctx.value.key);
    try std.testing.expectEqualStrings("bar", ctx.value.partial);
}

test "contextAt: blank line → empty key (offer all completions)" {
    const allocator = std.testing.allocator;
    const src = "\n\nfont-size = 14\n";
    const lines = try parseLines(allocator, src);
    defer allocator.free(lines);
    const ctx = contextAt(lines, 0, 0);
    // Blank line → key context with empty prefix (all keys offered).
    try std.testing.expect(ctx == .key);
    try std.testing.expectEqualStrings("", ctx.key);
}

test "contextAt: comment line → none" {
    const allocator = std.testing.allocator;
    const src = "# this is a comment";
    const lines = try parseLines(allocator, src);
    defer allocator.free(lines);
    const ctx = contextAt(lines, 0, 0);
    try std.testing.expect(ctx == .none);
}
