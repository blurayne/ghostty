//! Minimal JSON-RPC 2.0 transport for the LSP server.
//!
//! The LSP wire protocol wraps JSON-RPC messages in HTTP-style headers:
//!
//!   Content-Length: <byte-count>\r\n
//!   \r\n
//!   <JSON body>
//!
//! This module handles reading and writing those framed messages over stdio.

const std = @import("std");

pub const MAX_CONTENT_LENGTH = 16 * 1024 * 1024; // 16 MiB sanity limit

/// Read one JSON-RPC message from `reader`.
/// Returns an owned slice that the caller must free.
/// Returns `null` on EOF (clean shutdown).
pub fn readMessage(allocator: std.mem.Allocator, reader: *std.Io.Reader) !?[]u8 {
    var content_length: ?usize = null;

    // Read headers until we see the blank line.
    while (true) {
        var header_buf: [512]u8 = undefined;
        const line = readLine(reader, &header_buf) catch |err| switch (err) {
            error.EndOfStream => return null,
            error.StreamTooLong,
            error.ReadFailed,
            => return null,
            else => return err,
        };

        if (line.len == 0) break; // blank line → end of headers

        // Parse Content-Length header (case-insensitive prefix match).
        const prefix = "Content-Length:";
        if (std.ascii.startsWithIgnoreCase(line, prefix)) {
            const rest = std.mem.trimLeft(u8, line[prefix.len..], " \t");
            content_length = std.fmt.parseInt(usize, rest, 10) catch continue;
        }
        // Ignore other headers (e.g. Content-Type).
    }

    const length = content_length orelse return error.MissingContentLength;
    if (length > MAX_CONTENT_LENGTH) return error.MessageTooLarge;

    const body = try allocator.alloc(u8, length);
    errdefer allocator.free(body);
    // streamExact reads exactly `length` bytes into `body` via a fixed Writer.
    var body_writer = std.Io.Writer.fixed(body);
    reader.streamExact(&body_writer, length) catch return null;
    return body;
}

/// Read a line (up to `\n`) from `reader` into `buf`.
/// Returns the line without the terminator (strips trailing `\r`).
/// Uses takeDelimiter which reads until `\n` into the internal buffer.
fn readLine(reader: *std.Io.Reader, buf: []u8) ![]u8 {
    // takeDelimiter reads up to the delimiter (exclusive) into the internal
    // reader buffer, returning the slice. We copy it to our buf.
    const line_or_null = try reader.takeDelimiter('\n');
    const raw = line_or_null orelse return error.EndOfStream;
    // Strip trailing \r for CRLF.
    const trimmed = std.mem.trimRight(u8, raw, "\r");
    if (trimmed.len > buf.len) return error.HeaderLineTooLong;
    @memcpy(buf[0..trimmed.len], trimmed);
    return buf[0..trimmed.len];
}

/// Write a JSON-RPC message to `writer` with the appropriate headers.
pub fn writeMessage(writer: *std.Io.Writer, body: []const u8) !void {
    try writer.print("Content-Length: {d}\r\n\r\n", .{body.len});
    try writer.writeAll(body);
}

/// A decoded JSON-RPC request or notification.
pub const Request = struct {
    id: Id,
    method: []const u8,
    /// Raw JSON of the `params` field (or null if absent).
    params_raw: ?[]const u8,

    pub const Id = union(enum) {
        number: i64,
        string: []const u8,
        null,
    };
};

/// Parse a JSON-RPC message from raw JSON bytes.
/// The returned `Request` contains slices into `json_text` — do not free
/// `json_text` while using the `Request`.
pub fn parseRequest(allocator: std.mem.Allocator, json_text: []const u8) !Request {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_text, .{});
    defer parsed.deinit();

    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return error.InvalidRequest,
    };

    // Decode id
    const id: Request.Id = if (obj.get("id")) |id_val| switch (id_val) {
        .integer => |n| .{ .number = n },
        .string => |s| .{ .string = try allocator.dupe(u8, s) },
        .null => .null,
        else => .null,
    } else .null;

    const method_val = obj.get("method") orelse return error.InvalidRequest;
    const method = switch (method_val) {
        .string => |s| try allocator.dupe(u8, s),
        else => return error.InvalidRequest,
    };
    errdefer allocator.free(method);

    // Capture raw params as a string for method-specific parsing.
    const params_raw: ?[]const u8 = if (obj.get("params")) |p| blk: {
        var buf: std.Io.Writer.Allocating = .init(allocator);
        defer buf.deinit(); // always free the writer buffer, even on success
        try valueToJson(p, &buf.writer);
        break :blk try allocator.dupe(u8, buf.written());
    } else null;

    return .{
        .id = id,
        .method = method,
        .params_raw = params_raw,
    };
}

pub fn freeRequest(allocator: std.mem.Allocator, req: Request) void {
    if (req.id == .string) allocator.free(req.id.string);
    allocator.free(req.method);
    if (req.params_raw) |p| allocator.free(p);
}

// ---------------------------------------------------------------------------
// JSON serialization helper
// ---------------------------------------------------------------------------

/// Serialize a std.json.Value back to a JSON string.
fn valueToJson(v: std.json.Value, w: *std.Io.Writer) !void {
    switch (v) {
        .null => try w.writeAll("null"),
        .bool => |b| try w.writeAll(if (b) "true" else "false"),
        .integer => |n| try w.print("{d}", .{n}),
        .float => |f| try w.print("{d}", .{f}),
        .number_string => |s| try w.writeAll(s),
        .string => |s| {
            try w.writeByte('"');
            for (s) |c| {
                switch (c) {
                    '"' => try w.writeAll("\\\""),
                    '\\' => try w.writeAll("\\\\"),
                    '\n' => try w.writeAll("\\n"),
                    '\r' => try w.writeAll("\\r"),
                    '\t' => try w.writeAll("\\t"),
                    0x00...0x08, 0x0B...0x0C, 0x0E...0x1F => try w.print("\\u{X:0>4}", .{c}),
                    else => try w.writeByte(c),
                }
            }
            try w.writeByte('"');
        },
        .array => |arr| {
            try w.writeByte('[');
            for (arr.items, 0..) |item, i| {
                if (i > 0) try w.writeByte(',');
                try valueToJson(item, w);
            }
            try w.writeByte(']');
        },
        .object => |map| {
            try w.writeByte('{');
            var it = map.iterator();
            var first = true;
            while (it.next()) |entry| {
                if (!first) try w.writeByte(',');
                first = false;
                try w.writeByte('"');
                try w.writeAll(entry.key_ptr.*);
                try w.writeAll("\":");
                try valueToJson(entry.value_ptr.*, w);
            }
            try w.writeByte('}');
        },
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "parseRequest: basic" {
    const allocator = std.testing.allocator;
    const json =
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{}}}
    ;
    const req = try parseRequest(allocator, json);
    defer freeRequest(allocator, req);

    try std.testing.expectEqual(Request.Id{ .number = 1 }, req.id);
    try std.testing.expectEqualStrings("initialize", req.method);
    try std.testing.expect(req.params_raw != null);
}

test "parseRequest: notification (no id)" {
    const allocator = std.testing.allocator;
    const json =
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{}}
    ;
    const req = try parseRequest(allocator, json);
    defer freeRequest(allocator, req);
    try std.testing.expect(req.id == .null);
    try std.testing.expectEqualStrings("textDocument/didOpen", req.method);
}
