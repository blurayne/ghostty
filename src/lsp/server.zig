//! LSP server core for ghostty config files.
//!
//! Handles LSP 3.17 request dispatching and implements:
//!   - initialize / initialized / shutdown / exit
//!   - textDocument/completion
//!   - textDocument/hover
//!   - textDocument/diagnostic (pull diagnostics, LSP 3.17)
//!   - textDocument/didOpen, didChange, didClose

const std = @import("std");
const jsonrpc = @import("jsonrpc.zig");
const schema_mod = @import("schema.zig");
const config_parser = @import("config_parser.zig");

pub const Schema = schema_mod.Schema;

// ---------------------------------------------------------------------------
// Document store
// ---------------------------------------------------------------------------

pub const Document = struct {
    uri: []const u8,
    text: []const u8,
    lines: []config_parser.Line,
};

// ---------------------------------------------------------------------------
// Server
// ---------------------------------------------------------------------------

pub const Server = struct {
    allocator: std.mem.Allocator,
    schema: *const Schema,
    documents: std.StringHashMap(Document),
    shutdown_requested: bool,

    pub fn init(allocator: std.mem.Allocator, schema: *const Schema) Server {
        return .{
            .allocator = allocator,
            .schema = schema,
            .documents = std.StringHashMap(Document).init(allocator),
            .shutdown_requested = false,
        };
    }

    pub fn deinit(self: *Server) void {
        var it = self.documents.iterator();
        while (it.next()) |entry| {
            self.freeDocument(entry.value_ptr);
        }
        self.documents.deinit();
    }

    fn freeDocument(self: *Server, doc: *Document) void {
        self.allocator.free(doc.uri);
        self.allocator.free(doc.text);
        self.allocator.free(doc.lines);
    }

    // -----------------------------------------------------------------------
    // Document management
    // -----------------------------------------------------------------------

    pub fn openDocument(self: *Server, uri: []const u8, text: []const u8) !void {
        const uri_copy = try self.allocator.dupe(u8, uri);
        errdefer self.allocator.free(uri_copy);
        const text_copy = try self.allocator.dupe(u8, text);
        errdefer self.allocator.free(text_copy);
        const lines = try config_parser.parseLines(self.allocator, text_copy);
        errdefer self.allocator.free(lines);

        // If document already exists, free old data.
        if (self.documents.getPtr(uri_copy)) |existing| {
            self.freeDocument(existing);
        }

        try self.documents.put(uri_copy, .{
            .uri = uri_copy,
            .text = text_copy,
            .lines = lines,
        });
    }

    pub fn updateDocument(self: *Server, uri: []const u8, new_text: []const u8) !void {
        try self.openDocument(uri, new_text);
    }

    pub fn closeDocument(self: *Server, uri: []const u8) void {
        if (self.documents.fetchRemove(uri)) |kv| {
            var doc = kv.value;
            self.freeDocument(&doc);
        }
    }

    // -----------------------------------------------------------------------
    // Completion
    // -----------------------------------------------------------------------

    /// Generate completion items for the given position.
    /// Returns an owned JSON string (array of CompletionItem).
    pub fn completion(
        self: *const Server,
        allocator: std.mem.Allocator,
        uri: []const u8,
        line_num: u32,
        character: u32,
    ) ![]const u8 {
        var buf: std.Io.Writer.Allocating = .init(allocator);
        defer buf.deinit();
        const w = &buf.writer;

        const doc = self.documents.get(uri);
        // If the document has not been opened yet, fall back to offering all keys.
        const context: config_parser.CursorContext = if (doc) |d|
            config_parser.contextAt(d.lines, line_num, character)
        else
            .{ .key = "" };

        try w.writeAll("[");
        var first = true;

        switch (context) {
            .none => {
                // On a comment or malformed line: no completions.
            },
            .key => |partial| {
                for (self.schema.entries) |*entry| {
                    if (entry.deprecated) continue;
                    if (partial.len > 0 and !std.mem.startsWith(u8, entry.key, partial)) continue;
                    if (!first) try w.writeAll(",");
                    first = false;
                    try writeKeyCompletion(w, entry);
                }
            },
            .value => |v| {
                // Suggest allowed values for the key.
                const entry = self.schema.get(v.key) orelse {
                    try w.writeAll("]");
                    return allocator.dupe(u8, buf.written());
                };
                if (entry.allowed_values) |avs| {
                    for (avs) |av| {
                        if (v.partial.len > 0 and !std.mem.startsWith(u8, av, v.partial)) continue;
                        if (!first) try w.writeAll(",");
                        first = false;
                        try writeValueCompletion(w, av, entry.description);
                    }
                } else if (std.mem.eql(u8, entry.type, "bool") or
                    std.mem.eql(u8, entry.type, "optional_bool"))
                {
                    for (&[_][]const u8{ "true", "false" }) |bv| {
                        if (v.partial.len > 0 and !std.mem.startsWith(u8, bv, v.partial)) continue;
                        if (!first) try w.writeAll(",");
                        first = false;
                        try writeValueCompletion(w, bv, "");
                    }
                }
            },
        }

        try w.writeAll("]");
        return allocator.dupe(u8, buf.written());
    }

    // -----------------------------------------------------------------------
    // Hover
    // -----------------------------------------------------------------------

    /// Generate hover content for the given position.
    /// Returns an owned JSON string with markdown hover content, or "null".
    pub fn hover(
        self: *const Server,
        allocator: std.mem.Allocator,
        uri: []const u8,
        line_num: u32,
        character: u32,
    ) ![]const u8 {
        const doc = self.documents.get(uri) orelse return allocator.dupe(u8, "null");
        const context = config_parser.contextAt(doc.lines, line_num, character);

        const key: []const u8 = switch (context) {
            .key => |k| k,
            .value => |v| v.key,
            .none => return allocator.dupe(u8, "null"),
        };

        // Find the complete key from the line (not just partial).
        const line = config_parser.lineAt(doc.lines, line_num) orelse return allocator.dupe(u8, "null");
        const full_key: []const u8 = switch (line.kind) {
            .assignment => |a| a.key,
            .partial_key => |pk| pk,
            else => key,
        };

        const entry = self.schema.get(full_key) orelse return allocator.dupe(u8, "null");

        var buf: std.Io.Writer.Allocating = .init(allocator);
        defer buf.deinit();
        const w = &buf.writer;

        try w.writeAll("{\"contents\":{\"kind\":\"markdown\",\"value\":\"");

        // Header: key name
        try writeJsonEscaped(w, "**`");
        try writeJsonEscaped(w, entry.key);
        try writeJsonEscaped(w, "`**");
        if (entry.type.len > 0) {
            try writeJsonEscaped(w, " _(");
            try writeJsonEscaped(w, entry.type);
            try writeJsonEscaped(w, ")_");
        }
        try writeJsonEscaped(w, "\\n\\n");

        // Description
        if (entry.description.len > 0) {
            try writeJsonEscaped(w, entry.description);
            try writeJsonEscaped(w, "\\n\\n");
        }

        // Default value
        if (entry.default.len > 0) {
            try writeJsonEscaped(w, "**Default:** `");
            try writeJsonEscaped(w, entry.default);
            try writeJsonEscaped(w, "`\\n\\n");
        }

        // Allowed values
        if (entry.allowed_values) |avs| {
            try writeJsonEscaped(w, "**Allowed values:** ");
            for (avs, 0..) |av, i| {
                if (i > 0) try writeJsonEscaped(w, ", ");
                try writeJsonEscaped(w, "`");
                try writeJsonEscaped(w, av);
                try writeJsonEscaped(w, "`");
            }
            try writeJsonEscaped(w, "\\n\\n");
        }

        // Deprecation notice
        if (entry.deprecated) {
            try writeJsonEscaped(w, "**Deprecated**");
            if (entry.deprecated_replaced_by) |r| {
                try writeJsonEscaped(w, " — use `");
                try writeJsonEscaped(w, r);
                try writeJsonEscaped(w, "` instead");
            }
            try writeJsonEscaped(w, "\\n\\n");
        }

        // Since version
        if (entry.since_version) |sv| {
            try writeJsonEscaped(w, "_Available since: ");
            try writeJsonEscaped(w, sv);
            try writeJsonEscaped(w, "_\\n");
        }

        try w.writeAll("\"}}");
        return allocator.dupe(u8, buf.written());
    }

    // -----------------------------------------------------------------------
    // Diagnostics
    // -----------------------------------------------------------------------

    /// Generate diagnostics for the given document URI.
    /// Returns an owned JSON array of Diagnostic objects.
    pub fn diagnostics(
        self: *const Server,
        allocator: std.mem.Allocator,
        uri: []const u8,
    ) ![]const u8 {
        var buf: std.Io.Writer.Allocating = .init(allocator);
        defer buf.deinit();
        const w = &buf.writer;

        try w.writeAll("[");
        var first = true;

        const doc = self.documents.get(uri) orelse {
            try w.writeAll("]");
            return allocator.dupe(u8, buf.written());
        };

        for (doc.lines) |*line| {
            switch (line.kind) {
                .blank, .comment, .partial_key => {},
                .malformed => {
                    if (!first) try w.writeAll(",");
                    first = false;
                    try writeDiagnostic(
                        w,
                        line.number,
                        0,
                        line.number,
                        @intCast(line.text.len),
                        1, // Warning severity
                        "malformed line: expected `key = value`",
                    );
                },
                .assignment => |a| {
                    // Check for unknown key.
                    if (self.schema.get(a.key) == null) {
                        if (!first) try w.writeAll(",");
                        first = false;
                        try writeDiagnostic(
                            w,
                            line.number,
                            0,
                            line.number,
                            @intCast(a.key.len),
                            2, // Warning
                            "unknown config key",
                        );
                    } else {
                        // Known key: validate value against allowed_values.
                        const entry = self.schema.get(a.key).?;
                        if (entry.allowed_values) |avs| {
                            const val_trimmed = std.mem.trim(u8, a.value, " \t");
                            var valid = false;
                            for (avs) |av| {
                                if (std.mem.eql(u8, av, val_trimmed)) {
                                    valid = true;
                                    break;
                                }
                            }
                            if (!valid and val_trimmed.len > 0) {
                                const eq_pos = std.mem.indexOfScalar(u8, line.text, '=') orelse 0;
                                const val_start: u32 = @intCast(eq_pos + 1);
                                if (!first) try w.writeAll(",");
                                first = false;
                                try writeDiagnostic(
                                    w,
                                    line.number,
                                    val_start,
                                    line.number,
                                    @intCast(line.text.len),
                                    2, // Warning
                                    "invalid value for this key",
                                );
                            }
                        }
                        // Deprecation warning.
                        if (entry.deprecated) {
                            if (!first) try w.writeAll(",");
                            first = false;
                            try writeDiagnostic(
                                w,
                                line.number,
                                0,
                                line.number,
                                @intCast(a.key.len),
                                2, // Warning
                                "this config key is deprecated",
                            );
                        }
                    }
                },
            }
        }

        try w.writeAll("]");
        return allocator.dupe(u8, buf.written());
    }
};

// ---------------------------------------------------------------------------
// JSON output helpers
// ---------------------------------------------------------------------------

fn writeKeyCompletion(w: *std.Io.Writer, entry: *const schema_mod.Entry) !void {
    // CompletionItem
    try w.writeAll("{");
    try w.writeAll("\"label\":");
    try w.writeByte('"');
    try writeJsonEscaped(w, entry.key);
    try w.writeByte('"');
    try w.writeAll(",\"kind\":10"); // Property kind
    try w.writeAll(",\"detail\":\"");
    try writeJsonEscaped(w, entry.type);
    try w.writeByte('"');
    try w.writeAll(",\"documentation\":{\"kind\":\"markdown\",\"value\":\"");
    // First line of description only (keep tooltip brief).
    const desc = firstLine(entry.description);
    try writeJsonEscaped(w, desc);
    try w.writeAll("\"}");
    // insertText: "key = <default>" snippet
    try w.writeAll(",\"insertText\":\"");
    try writeJsonEscaped(w, entry.key);
    try w.writeAll(" = ${1:");
    if (entry.default.len > 0) {
        try writeJsonEscaped(w, entry.default);
    }
    try w.writeAll("}\"");
    try w.writeAll(",\"insertTextFormat\":2"); // Snippet
    try w.writeByte('}');
}

fn writeValueCompletion(w: *std.Io.Writer, value: []const u8, description: []const u8) !void {
    try w.writeAll("{");
    try w.writeAll("\"label\":");
    try w.writeByte('"');
    try writeJsonEscaped(w, value);
    try w.writeByte('"');
    try w.writeAll(",\"kind\":12"); // Value kind
    if (description.len > 0) {
        try w.writeAll(",\"documentation\":{\"kind\":\"markdown\",\"value\":\"");
        try writeJsonEscaped(w, firstLine(description));
        try w.writeAll("\"}");
    }
    try w.writeByte('}');
}

fn writeDiagnostic(
    w: *std.Io.Writer,
    start_line: u32,
    start_char: u32,
    end_line: u32,
    end_char: u32,
    severity: u8,
    message: []const u8,
) !void {
    try w.print(
        \\{{"range":{{"start":{{"line":{d},"character":{d}}},"end":{{"line":{d},"character":{d}}}}},"severity":{d},"source":"ghostty-lsp","message":"
    , .{ start_line, start_char, end_line, end_char, severity });
    try writeJsonEscaped(w, message);
    try w.writeAll("\"}}");
}

/// Write `s` with JSON string escaping (for embedding in a JSON string literal).
pub fn writeJsonEscaped(w: *std.Io.Writer, s: []const u8) !void {
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
}

fn firstLine(s: []const u8) []const u8 {
    return if (std.mem.indexOfScalar(u8, s, '\n')) |n| s[0..n] else s;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const test_schema_json =
    \\[
    \\  {"key":"font-size","type":"float","default":"12","description":"Font size in points.\nAvailable since: 1.0.0","since_version":"1.0.0","deprecated":false,"deprecated_replaced_by":null,"repeatable":false,"allowed_values":null,"platform":null},
    \\  {"key":"cursor-style","type":"enum","default":"block","description":"Cursor shape.","since_version":null,"deprecated":false,"deprecated_replaced_by":null,"repeatable":false,"allowed_values":["block","bar","underline"],"platform":null},
    \\  {"key":"bold-is-bright","type":"bool","default":"false","description":"Bold renders bright.","since_version":null,"deprecated":false,"deprecated_replaced_by":null,"repeatable":false,"allowed_values":null,"platform":null},
    \\  {"key":"old-key","type":"string","default":"","description":"Old key.","since_version":null,"deprecated":true,"deprecated_replaced_by":"new-key","repeatable":false,"allowed_values":null,"platform":null}
    \\]
;

test "completion: key prefix" {
    const allocator = std.testing.allocator;
    var schema = try schema_mod.parse(allocator, test_schema_json);
    defer schema.deinit();

    var server = Server.init(allocator, &schema);
    defer server.deinit();

    try server.openDocument("file:///test", "font-");
    const result = try server.completion(allocator, "file:///test", 0, 5);
    defer allocator.free(result);

    // Should include font-size
    try std.testing.expect(std.mem.indexOf(u8, result, "font-size") != null);
    // Should NOT include cursor-style (different prefix)
    try std.testing.expect(std.mem.indexOf(u8, result, "cursor-style") == null);
}

test "completion: value suggestions for enum" {
    const allocator = std.testing.allocator;
    var schema = try schema_mod.parse(allocator, test_schema_json);
    defer schema.deinit();

    var server = Server.init(allocator, &schema);
    defer server.deinit();

    try server.openDocument("file:///test", "cursor-style = b");
    const result = try server.completion(allocator, "file:///test", 0, @intCast("cursor-style = b".len));
    defer allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "block") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "bar") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "underline") == null); // doesn't start with 'b'
}

test "completion: bool values" {
    const allocator = std.testing.allocator;
    var schema = try schema_mod.parse(allocator, test_schema_json);
    defer schema.deinit();

    var server = Server.init(allocator, &schema);
    defer server.deinit();

    try server.openDocument("file:///test", "bold-is-bright = ");
    const result = try server.completion(allocator, "file:///test", 0, @intCast("bold-is-bright = ".len));
    defer allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "true") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "false") != null);
}

test "hover: known key" {
    const allocator = std.testing.allocator;
    var schema = try schema_mod.parse(allocator, test_schema_json);
    defer schema.deinit();

    var server = Server.init(allocator, &schema);
    defer server.deinit();

    try server.openDocument("file:///test", "font-size = 14");
    const result = try server.hover(allocator, "file:///test", 0, 3);
    defer allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "font-size") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "float") != null);
    try std.testing.expect(result.len > 4); // not "null"
}

test "hover: unknown key returns null" {
    const allocator = std.testing.allocator;
    var schema = try schema_mod.parse(allocator, test_schema_json);
    defer schema.deinit();

    var server = Server.init(allocator, &schema);
    defer server.deinit();

    try server.openDocument("file:///test", "nonexistent-key = foo");
    const result = try server.hover(allocator, "file:///test", 0, 3);
    defer allocator.free(result);

    try std.testing.expectEqualStrings("null", result);
}

test "diagnostics: unknown key" {
    const allocator = std.testing.allocator;
    var schema = try schema_mod.parse(allocator, test_schema_json);
    defer schema.deinit();

    var server = Server.init(allocator, &schema);
    defer server.deinit();

    try server.openDocument("file:///test", "nonexistent = foo\nfont-size = 14");
    const result = try server.diagnostics(allocator, "file:///test");
    defer allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "unknown config key") != null);
    // Second line is valid — no extra diagnostics for font-size.
}

test "diagnostics: invalid enum value" {
    const allocator = std.testing.allocator;
    var schema = try schema_mod.parse(allocator, test_schema_json);
    defer schema.deinit();

    var server = Server.init(allocator, &schema);
    defer server.deinit();

    try server.openDocument("file:///test", "cursor-style = notavalue");
    const result = try server.diagnostics(allocator, "file:///test");
    defer allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "invalid value") != null);
}

test "diagnostics: deprecated key" {
    const allocator = std.testing.allocator;
    var schema = try schema_mod.parse(allocator, test_schema_json);
    defer schema.deinit();

    var server = Server.init(allocator, &schema);
    defer server.deinit();

    try server.openDocument("file:///test", "old-key = foo");
    const result = try server.diagnostics(allocator, "file:///test");
    defer allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "deprecated") != null);
}

test "diagnostics: valid config produces no diagnostics" {
    const allocator = std.testing.allocator;
    var schema = try schema_mod.parse(allocator, test_schema_json);
    defer schema.deinit();

    var server = Server.init(allocator, &schema);
    defer server.deinit();

    try server.openDocument("file:///test",
        \\# A comment
        \\font-size = 14
        \\cursor-style = block
        \\
    );
    const result = try server.diagnostics(allocator, "file:///test");
    defer allocator.free(result);

    try std.testing.expectEqualStrings("[]", result);
}
