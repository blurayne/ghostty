const std = @import("std");

const assert = @import("../../../quirks.zig").inlineAssert;
const simd = @import("../../../simd/main.zig");

const Parser = @import("../../osc.zig").Parser;
const Command = @import("../../osc.zig").Command;

const log = std.log.scoped(.osc_iterm2);

/// Parse the `File=` argument string of an OSC 1337 inline-image command.
///
/// The format is:
///   [key=val;key=val...]:base64encodeddata
///
/// Returns a populated `Command.Iterm2InlineImage` on success, or null if the
/// sequence is malformed or `inline=1` is absent.  The caller is responsible
/// for freeing `result.data` with the provided allocator.
fn parseFile(alloc: std.mem.Allocator, value: []const u8) ?Command.Iterm2InlineImage {
    // The colon that separates the argument list from the base64 payload is
    // *required* by the spec and by every real implementation we've seen.
    const colon_idx = std.mem.indexOfScalar(u8, value, ':') orelse {
        log.debug("OSC 1337 File= missing colon separator", .{});
        return null;
    };

    const args_str = value[0..colon_idx];
    const b64_str = value[colon_idx + 1 ..];

    if (b64_str.len == 0) {
        log.debug("OSC 1337 File= empty image data", .{});
        return null;
    }

    // Parse the semicolon-separated key=value argument list.
    var result: Command.Iterm2InlineImage = .{ .data = "" };
    var inline_flag: bool = false;

    var it = std.mem.splitScalar(u8, args_str, ';');
    while (it.next()) |pair| {
        if (pair.len == 0) continue;
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        const k = pair[0..eq];
        const v = pair[eq + 1 ..];

        // Case-insensitive key comparison.
        if (std.ascii.eqlIgnoreCase(k, "inline")) {
            inline_flag = std.mem.eql(u8, v, "1");
        } else if (std.ascii.eqlIgnoreCase(k, "width")) {
            result.columns, result.width_px, result.width_percent = parseDimension(v);
        } else if (std.ascii.eqlIgnoreCase(k, "height")) {
            result.rows, result.height_px, result.height_percent = parseDimension(v);
        } else if (std.ascii.eqlIgnoreCase(k, "preserveAspectRatio")) {
            result.preserve_aspect_ratio = !std.mem.eql(u8, v, "0");
        } else if (std.ascii.eqlIgnoreCase(k, "size")) {
            result.size = std.fmt.parseInt(u64, v, 10) catch 0;
        }
        // name= is intentionally ignored: it is a cosmetic download filename
        // that has no effect on inline rendering.
    }

    if (!inline_flag) {
        // The spec says inline=1 is required for inline display.  When
        // it is absent the image is intended to be "downloaded", which we
        // cannot do — so we just ignore the sequence entirely.
        log.debug("OSC 1337 File= without inline=1, ignoring", .{});
        return null;
    }

    // Decode the base64 payload into a freshly-allocated buffer.
    const decoded = decodeBase64(alloc, b64_str) orelse return null;
    result.data = decoded;
    return result;
}

/// Parse a dimension value such as "80" (cells), "80px" (pixels), "50%"
/// (percent of the terminal dimension), or "auto".
/// Returns { cells, pixels, percent } where at most one component is non-zero
/// (all zero for "auto" or an unparseable value).
fn parseDimension(v: []const u8) struct { u32, u32, u8 } {
    if (std.ascii.eqlIgnoreCase(v, "auto") or v.len == 0) return .{ 0, 0, 0 };

    if (std.mem.endsWith(u8, v, "px")) {
        const n = std.fmt.parseInt(u32, v[0 .. v.len - 2], 10) catch return .{ 0, 0, 0 };
        return .{ 0, n, 0 };
    }

    if (std.mem.endsWith(u8, v, "%")) {
        const n = std.fmt.parseInt(u8, v[0 .. v.len - 1], 10) catch return .{ 0, 0, 0 };
        return .{ 0, 0, n };
    }

    // Plain integer → terminal columns/rows.
    const n = std.fmt.parseInt(u32, v, 10) catch return .{ 0, 0, 0 };
    return .{ n, 0, 0 };
}

/// Decode a standard base64 string into a freshly-allocated byte slice.
/// Returns null on error; caller owns the returned memory.
fn decodeBase64(alloc: std.mem.Allocator, b64: []const u8) ?[]u8 {
    if (b64.len == 0) return null;

    const max_decoded = simd.base64.maxLen(b64);
    if (max_decoded == 0) {
        log.debug("OSC 1337 File= base64 max length is 0", .{});
        return null;
    }

    // Allocate a mutable working buffer, decode in place, then shrink.
    var buf = alloc.alloc(u8, b64.len) catch {
        log.warn("OSC 1337 File= OOM allocating decode buffer size={}", .{b64.len});
        return null;
    };

    // Copy b64 into buf so we can decode in-place (simd decoder may mutate).
    @memcpy(buf[0..b64.len], b64);

    const decoded = simd.base64.decode(buf[0..b64.len], buf[0..max_decoded]) catch |err| {
        log.warn("OSC 1337 File= base64 decode error: {}", .{err});
        alloc.free(buf);
        return null;
    };

    // Shrink the allocation to the actual decoded length.
    const n = decoded.len;
    if (n == 0) {
        alloc.free(buf);
        return null;
    }
    buf = alloc.realloc(buf, n) catch buf; // best-effort shrink
    return buf[0..n];
}

const Key = enum {
    AddAnnotation,
    AddHiddenAnnotation,
    Block,
    Button,
    ClearCapturedOutput,
    ClearScrollback,
    Copy,
    CopyToClipboard,
    CurrentDir,
    CursorShape,
    Custom,
    Disinter,
    EndCopy,
    File,
    FileEnd,
    FilePart,
    HighlightCursorLine,
    MultipartFile,
    OpenURL,
    PopKeyLabels,
    PushKeyLabels,
    RemoteHost,
    ReportCellSize,
    ReportVariable,
    RequestAttention,
    RequestUpload,
    SetBackgroundImageFile,
    SetBadgeFormat,
    SetColors,
    SetKeyLabel,
    SetMark,
    SetProfile,
    SetUserVar,
    ShellIntegrationVersion,
    StealFocus,
    UnicodeVersion,
};

// Instead of using `std.meta.stringToEnum` we set up a StaticStringMap so
// that we can get ASCII case-insensitive lookups.
const Map = std.StaticStringMapWithEql(Key, std.ascii.eqlIgnoreCase);
const map: Map = .initComptime(
    map: {
        const fields = @typeInfo(Key).@"enum".fields;
        var tmp: [fields.len]struct { [:0]const u8, Key } = undefined;
        for (fields, 0..) |field, i| {
            tmp[i] = .{ field.name, @enumFromInt(field.value) };
        }
        break :map tmp;
    },
);

/// Parse OSC 1337
/// https://iterm2.com/documentation-escape-codes.html
pub fn parse(parser: *Parser, _: ?u8) ?*Command {
    assert(parser.state == .@"1337");

    const cap = if (parser.capture) |*c| c else {
        parser.state = .invalid;
        return null;
    };
    cap.writer.writeByte(0) catch {
        parser.state = .invalid;
        return null;
    };
    const data = cap.trailing();

    const key_str: [:0]u8, const value_: ?[:0]u8 = kv: {
        const index = std.mem.indexOfScalar(u8, data, '=') orelse {
            break :kv .{ data[0 .. data.len - 1 :0], null };
        };
        data[index] = 0;
        break :kv .{ data[0..index :0], data[index + 1 .. data.len - 1 :0] };
    };

    const key = map.get(key_str) orelse {
        parser.command = .invalid;
        return null;
    };

    switch (key) {
        .Copy => {
            var value = value_ orelse {
                parser.command = .invalid;
                return null;
            };

            // Sending a blank entry to clear the clipboard is an OSC 52-ism,
            // make sure that is invalid here.
            if (value.len == 0) {
                parser.command = .invalid;
                return null;
            }

            // base64 value must be prefixed by a colon
            if (value[0] != ':') {
                parser.command = .invalid;
                return null;
            }

            value = value[1..value.len :0];

            // Sending a blank entry to clear the clipboard is an OSC 52-ism,
            // make sure that is invalid here.
            if (value.len == 0) {
                parser.command = .invalid;
                return null;
            }

            // Sending a '?' to query the clipboard is an OSC 52-ism, make sure
            // that is invalid here.
            if (value.len == 1 and value[0] == '?') {
                parser.command = .invalid;
                return null;
            }

            // It would be better to check for valid base64 data here, but that
            // would mean parsing the base64 data twice in the "normal" case.

            parser.command = .{
                .clipboard_contents = .{
                    .kind = 'c',
                    .data = value,
                },
            };
            return &parser.command;
        },

        .CurrentDir => {
            const value = value_ orelse {
                parser.command = .invalid;
                return null;
            };
            if (value.len == 0) {
                parser.command = .invalid;
                return null;
            }
            parser.command = .{
                .report_pwd = .{
                    .value = value,
                },
            };
            return &parser.command;
        },

        .File => {
            const value = value_ orelse {
                log.debug("OSC 1337 File= missing value", .{});
                parser.command = .invalid;
                return null;
            };

            const alloc = parser.alloc orelse {
                log.warn("OSC 1337 File= requires an allocator but none was provided", .{});
                parser.command = .invalid;
                return null;
            };

            const img = parseFile(alloc, value) orelse {
                parser.command = .invalid;
                return null;
            };

            parser.command = .{ .iterm2_inline_image = img };
            return &parser.command;
        },

        .AddAnnotation,
        .AddHiddenAnnotation,
        .Block,
        .Button,
        .ClearCapturedOutput,
        .ClearScrollback,
        .CopyToClipboard,
        .CursorShape,
        .Custom,
        .Disinter,
        .EndCopy,
        .FileEnd,
        .FilePart,
        .HighlightCursorLine,
        .MultipartFile,
        .OpenURL,
        .PopKeyLabels,
        .PushKeyLabels,
        .RemoteHost,
        .ReportCellSize,
        .ReportVariable,
        .RequestAttention,
        .RequestUpload,
        .SetBackgroundImageFile,
        .SetBadgeFormat,
        .SetColors,
        .SetKeyLabel,
        .SetMark,
        .SetProfile,
        .SetUserVar,
        .ShellIntegrationVersion,
        .StealFocus,
        .UnicodeVersion,
        => {
            log.debug("unimplemented OSC 1337: {t}", .{key});
            parser.command = .invalid;
            return null;
        },
    }
    return &parser.command;
}

test "OSC: 1337: test valid unimplemented key with no value" {
    const testing = std.testing;

    var p: Parser = .init(testing.allocator);
    defer p.deinit();

    const input = "1337;SetBadgeFormat";
    for (input) |ch| p.next(ch);

    try testing.expect(p.end('\x1b') == null);
}

test "OSC: 1337: test valid unimplemented key with empty value" {
    const testing = std.testing;

    var p: Parser = .init(testing.allocator);
    defer p.deinit();

    const input = "1337;SetBadgeFormat=";
    for (input) |ch| p.next(ch);

    try testing.expect(p.end('\x1b') == null);
}

test "OSC: 1337: test valid unimplemented key with non-empty value" {
    const testing = std.testing;

    var p: Parser = .init(testing.allocator);
    defer p.deinit();

    const input = "1337;SetBadgeFormat=abc123";
    for (input) |ch| p.next(ch);

    try testing.expect(p.end('\x1b') == null);
}

test "OSC: 1337: test valid key with lower case and with no value" {
    const testing = std.testing;

    var p: Parser = .init(testing.allocator);
    defer p.deinit();

    const input = "1337;setbadgeformat";
    for (input) |ch| p.next(ch);

    try testing.expect(p.end('\x1b') == null);
}

test "OSC: 1337: test valid key with lower case and with empty value" {
    const testing = std.testing;

    var p: Parser = .init(testing.allocator);
    defer p.deinit();

    const input = "1337;setbadgeformat=";
    for (input) |ch| p.next(ch);

    try testing.expect(p.end('\x1b') == null);
}

test "OSC: 1337: test valid key with lower case and with non-empty value" {
    const testing = std.testing;

    var p: Parser = .init(testing.allocator);
    defer p.deinit();

    const input = "1337;setbadgeformat=abc123";
    for (input) |ch| p.next(ch);

    try testing.expect(p.end('\x1b') == null);
}

test "OSC: 1337: test invalid key with no value" {
    const testing = std.testing;

    var p: Parser = .init(testing.allocator);
    defer p.deinit();

    const input = "1337;BobrKurwa";
    for (input) |ch| p.next(ch);

    try testing.expect(p.end('\x1b') == null);
}

test "OSC: 1337: test invalid key with empty value" {
    const testing = std.testing;

    var p: Parser = .init(testing.allocator);
    defer p.deinit();

    const input = "1337;BobrKurwa=";
    for (input) |ch| p.next(ch);

    try testing.expect(p.end('\x1b') == null);
}

test "OSC: 1337: test invalid key with non-empty value" {
    const testing = std.testing;

    var p: Parser = .init(testing.allocator);
    defer p.deinit();

    const input = "1337;BobrKurwa=abc123";
    for (input) |ch| p.next(ch);

    try testing.expect(p.end('\x1b') == null);
}

test "OSC: 1337: test Copy with no value" {
    const testing = std.testing;

    var p: Parser = .init(testing.allocator);
    defer p.deinit();

    const input = "1337;Copy";
    for (input) |ch| p.next(ch);

    try testing.expect(p.end('\x1b') == null);
}

test "OSC: 1337: test Copy with empty value" {
    const testing = std.testing;

    var p: Parser = .init(testing.allocator);
    defer p.deinit();

    const input = "1337;Copy=";
    for (input) |ch| p.next(ch);

    try testing.expect(p.end('\x1b') == null);
}

test "OSC: 1337: test Copy with only prefix colon" {
    const testing = std.testing;

    var p: Parser = .init(testing.allocator);
    defer p.deinit();

    const input = "1337;Copy=:";
    for (input) |ch| p.next(ch);

    try testing.expect(p.end('\x1b') == null);
}

test "OSC: 1337: test Copy with question mark" {
    const testing = std.testing;

    var p: Parser = .init(testing.allocator);
    defer p.deinit();

    const input = "1337;Copy=:?";
    for (input) |ch| p.next(ch);

    try testing.expect(p.end('\x1b') == null);
}

test "OSC: 1337: test Copy with non-empty value that is invalid base64" {
    // For performance reasons, we don't check for valid base64 data
    // right now.
    return error.SkipZigTest;

    // const testing = std.testing;

    // var p: Parser = .init(testing.allocator);
    // defer p.deinit();

    // const input = "1337;Copy=:abc123";
    // for (input) |ch| p.next(ch);

    // try testing.expect(p.end('\x1b') == null);
}

test "OSC: 1337: test Copy with non-empty value that is valid base64 but not prefixed with a colon" {
    const testing = std.testing;

    var p: Parser = .init(testing.allocator);
    defer p.deinit();

    const input = "1337;Copy=YWJjMTIz";
    for (input) |ch| p.next(ch);

    try testing.expect(p.end('\x1b') == null);
}

test "OSC: 1337: test Copy with non-empty value that is valid base64" {
    const testing = std.testing;

    var p: Parser = .init(testing.allocator);
    defer p.deinit();

    const input = "1337;Copy=:YWJjMTIz";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;
    try testing.expect(cmd == .clipboard_contents);
    try testing.expectEqual('c', cmd.clipboard_contents.kind);
    try testing.expectEqualStrings("YWJjMTIz", cmd.clipboard_contents.data);
}

test "OSC: 1337: test CurrentDir with no value" {
    const testing = std.testing;

    var p: Parser = .init(testing.allocator);
    defer p.deinit();

    const input = "1337;CurrentDir";
    for (input) |ch| p.next(ch);

    try testing.expect(p.end('\x1b') == null);
}

test "OSC: 1337: test CurrentDir with empty value" {
    const testing = std.testing;

    var p: Parser = .init(testing.allocator);
    defer p.deinit();

    const input = "1337;CurrentDir=";
    for (input) |ch| p.next(ch);

    try testing.expect(p.end('\x1b') == null);
}

test "OSC: 1337: test CurrentDir with non-empty value" {
    const testing = std.testing;

    var p: Parser = .init(testing.allocator);
    defer p.deinit();

    const input = "1337;CurrentDir=abc123";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;
    try testing.expect(cmd == .report_pwd);
    try testing.expectEqualStrings("abc123", cmd.report_pwd.value);
}

test "OSC: 1337: File= without inline=1 is ignored" {
    const testing = std.testing;

    var p: Parser = .init(testing.allocator);
    defer p.deinit();

    // "aGVsbG8=" is base64 for "hello"
    const input = "1337;File=name=test.png;size=5:aGVsbG8=";
    for (input) |ch| p.next(ch);

    // inline=1 is absent, should be null
    try testing.expect(p.end('\x1b') == null);
}

test "OSC: 1337: File= missing colon separator is invalid" {
    const testing = std.testing;

    var p: Parser = .init(testing.allocator);
    defer p.deinit();

    const input = "1337;File=inline=1aGVsbG8=";
    for (input) |ch| p.next(ch);

    try testing.expect(p.end('\x1b') == null);
}

test "OSC: 1337: File= with inline=1 parses image data" {
    const testing = std.testing;

    var p: Parser = .init(testing.allocator);
    defer p.deinit();

    // "aGVsbG8=" is base64 for "hello"
    const input = "1337;File=inline=1:aGVsbG8=";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;
    try testing.expect(cmd == .iterm2_inline_image);
    const img = cmd.iterm2_inline_image;
    try testing.expectEqualStrings("hello", img.data);
    try testing.expectEqual(0, img.columns);
    try testing.expectEqual(0, img.rows);
    try testing.expectEqual(true, img.preserve_aspect_ratio);
}

test "OSC: 1337: File= with width/height columns" {
    const testing = std.testing;

    var p: Parser = .init(testing.allocator);
    defer p.deinit();

    // "dGVzdA==" is base64 for "test"
    const input = "1337;File=inline=1;width=80;height=24:dGVzdA==";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;
    try testing.expect(cmd == .iterm2_inline_image);
    const img = cmd.iterm2_inline_image;
    try testing.expectEqualStrings("test", img.data);
    try testing.expectEqual(80, img.columns);
    try testing.expectEqual(24, img.rows);
    try testing.expectEqual(0, img.width_px);
    try testing.expectEqual(0, img.height_px);
}

test "OSC: 1337: File= with pixel dimensions" {
    const testing = std.testing;

    var p: Parser = .init(testing.allocator);
    defer p.deinit();

    // "dGVzdA==" is base64 for "test"
    const input = "1337;File=inline=1;width=640px;height=480px:dGVzdA==";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;
    try testing.expect(cmd == .iterm2_inline_image);
    const img = cmd.iterm2_inline_image;
    try testing.expectEqual(0, img.columns);
    try testing.expectEqual(0, img.rows);
    try testing.expectEqual(640, img.width_px);
    try testing.expectEqual(480, img.height_px);
}

test "OSC: 1337: File= with preserveAspectRatio=0" {
    const testing = std.testing;

    var p: Parser = .init(testing.allocator);
    defer p.deinit();

    // "dGVzdA==" is base64 for "test"
    const input = "1337;File=inline=1;preserveAspectRatio=0:dGVzdA==";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;
    try testing.expect(cmd == .iterm2_inline_image);
    try testing.expectEqual(false, cmd.iterm2_inline_image.preserve_aspect_ratio);
}

test "OSC: 1337: File= with percent dimensions" {
    const testing = std.testing;

    var p: Parser = .init(testing.allocator);
    defer p.deinit();

    // "dGVzdA==" is base64 for "test"
    const input = "1337;File=inline=1;width=50%;height=25%:dGVzdA==";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;
    try testing.expect(cmd == .iterm2_inline_image);
    const img = cmd.iterm2_inline_image;
    try testing.expectEqual(0, img.columns);
    try testing.expectEqual(0, img.width_px);
    try testing.expectEqual(50, img.width_percent);
    try testing.expectEqual(0, img.rows);
    try testing.expectEqual(0, img.height_px);
    try testing.expectEqual(25, img.height_percent);
}

test "OSC: 1337: File= with size metadata" {
    const testing = std.testing;

    var p: Parser = .init(testing.allocator);
    defer p.deinit();

    // "dGVzdA==" is base64 for "test"
    const input = "1337;File=inline=1;size=2048:dGVzdA==";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;
    try testing.expect(cmd == .iterm2_inline_image);
    try testing.expectEqual(2048, cmd.iterm2_inline_image.size);
}

test "OSC: 1337: File= auto dimensions" {
    const testing = std.testing;

    var p: Parser = .init(testing.allocator);
    defer p.deinit();

    // "dGVzdA==" is base64 for "test"
    const input = "1337;File=inline=1;width=auto;height=auto:dGVzdA==";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;
    try testing.expect(cmd == .iterm2_inline_image);
    const img = cmd.iterm2_inline_image;
    try testing.expectEqual(0, img.columns);
    try testing.expectEqual(0, img.rows);
    try testing.expectEqual(0, img.width_px);
    try testing.expectEqual(0, img.height_px);
}
