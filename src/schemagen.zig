//! This program generates config.schema.json from Ghostty's comptime
//! config metadata. It writes a JSON array of objects describing every
//! user-facing configuration field to stdout.
//!
//! It is run by the build system as part of the `emit-config-schema` step.

const std = @import("std");
const Config = @import("config/Config.zig");
const help_strings = @import("help_strings");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    // Use a 64 KB buffer on stdout for performance.
    var buf: [65536]u8 = undefined;
    var stdout_stream = std.fs.File.stdout().writerStreaming(&buf);
    const out = &stdout_stream.interface;

    try out.writeAll("[\n");

    var first = true;
    inline for (@typeInfo(Config).@"struct".fields) |field| {
        // Skip internal fields that start with "_".
        if (field.name[0] == '_') continue;

        if (!first) try out.writeAll(",\n");
        first = false;

        // --- type string --------------------------------------------------------
        const type_str = comptime classifyType(field.type);

        // --- default value ------------------------------------------------------
        // Build a default value string using the formatter.
        var default_buf: std.Io.Writer.Allocating = .init(alloc);
        defer default_buf.deinit();
        const default_value: field.type = if (field.default_value_ptr) |ptr|
            @as(*const field.type, @alignCast(@ptrCast(ptr))).*
        else
            @as(field.type, undefined);
        try formatFieldValue(field.type, default_value, &default_buf.writer);
        const default_str = default_buf.written();

        // --- documentation string -----------------------------------------------
        const docs: []const u8 = if (@hasDecl(help_strings.Config, field.name))
            @field(help_strings.Config, field.name)
        else
            "";

        // --- since version ------------------------------------------------------
        const since_version: ?[]const u8 = extractSinceVersion(docs);

        // --- deprecated ---------------------------------------------------------
        const deprecated: bool = comptime isDeprecated(field.name);

        // --- repeatable ---------------------------------------------------------
        const repeatable: bool = comptime isRepeatable(field.type);

        // --- allowed values -----------------------------------------------------
        const allowed_values: ?[]const [:0]const u8 = comptime buildAllowedValues(field.type);

        // --- platform -----------------------------------------------------------
        // Derive from doc string conventions used in Config.zig.
        const platform: []const u8 = detectPlatform(docs);

        // --- emit JSON ----------------------------------------------------------
        try out.writeAll("  {\n");
        try writeJsonString(out, "key", field.name);
        try out.writeAll(",\n");
        try writeJsonString(out, "type", type_str);
        try out.writeAll(",\n");
        try writeJsonString(out, "default", default_str);
        try out.writeAll(",\n");
        try writeJsonString(out, "description", docs);
        try out.writeAll(",\n");

        // since_version — null or string
        try out.print("    \"since_version\": ", .{});
        if (since_version) |sv| {
            try out.writeByte('"');
            try writeEscaped(out, sv);
            try out.writeByte('"');
        } else {
            try out.writeAll("null");
        }
        try out.writeAll(",\n");

        try out.print("    \"deprecated\": {s},\n", .{if (deprecated) "true" else "false"});
        try out.print("    \"deprecated_replaced_by\": null,\n", .{});
        try out.print("    \"repeatable\": {s},\n", .{if (repeatable) "true" else "false"});

        // allowed_values — null or array of strings
        try out.writeAll("    \"allowed_values\": ");
        if (allowed_values) |avs| {
            try out.writeAll("[");
            for (avs, 0..) |av, i| {
                if (i > 0) try out.writeAll(", ");
                try out.writeByte('"');
                try writeEscaped(out, av);
                try out.writeByte('"');
            }
            try out.writeAll("]");
        } else {
            try out.writeAll("null");
        }
        try out.writeAll(",\n");

        // platform — null or non-empty string
        try out.writeAll("    \"platform\": ");
        if (platform.len > 0) {
            try out.writeByte('"');
            try writeEscaped(out, platform);
            try out.writeByte('"');
        } else {
            try out.writeAll("null");
        }
        try out.writeAll("\n  }");
    }

    try out.writeAll("\n]\n");
    try stdout_stream.end();
}

// ---------------------------------------------------------------------------
// Type classification
// ---------------------------------------------------------------------------

/// Map a Zig field type to a human-readable JSON schema type string.
/// This is evaluated at comptime for every field.
fn classifyType(comptime T: type) []const u8 {
    return switch (@typeInfo(T)) {
        .bool => "bool",
        .int => "int",
        .float => "float",

        .@"enum" => "enum",

        .optional => |info| switch (@typeInfo(info.child)) {
            .bool => "optional_bool",
            .@"enum" => "optional_enum",
            .pointer => |p| switch (p.child) {
                u8 => "string",
                else => "optional_custom",
            },
            .@"struct" => blk: {
                const name = @typeName(info.child);
                if (std.mem.indexOfScalar(u8, name, '.') != null) {
                    // Namespaced — check for known types by simple suffix
                    if (std.mem.endsWith(u8, name, "Color") or
                        std.mem.endsWith(u8, name, "TerminalColor") or
                        std.mem.eql(u8, name, "Color"))
                        break :blk "optional_color";
                }
                break :blk "optional_custom";
            },
            .@"union" => "optional_custom",
            else => "optional_custom",
        },

        .pointer => |info| switch (info.child) {
            u8 => "string",
            else => "custom",
        },

        .@"struct" => |info| blk: {
            const name = @typeName(T);
            // Check for known Repeatable* types
            if (std.mem.indexOf(u8, name, "Repeatable") != null)
                break :blk "repeatable";
            // Palette
            if (std.mem.endsWith(u8, name, "Palette"))
                break :blk "palette";
            // Color
            if (std.mem.endsWith(u8, name, "Color"))
                break :blk "color";
            // Packed structs (flags)
            if (info.layout == .@"packed")
                break :blk "flags";
            break :blk "custom";
        },

        .@"union" => blk: {
            const name = @typeName(T);
            if (std.mem.endsWith(u8, name, "Color") or
                std.mem.endsWith(u8, name, "TerminalColor") or
                std.mem.endsWith(u8, name, "BoldColor"))
                break :blk "color";
            break :blk "custom";
        },

        .void => "void",

        else => "custom",
    };
}

// ---------------------------------------------------------------------------
// Default value formatting
// ---------------------------------------------------------------------------

/// Format a field's default value to a human-readable string, writing the
/// result to `writer`. For complex types this calls `formatEntry` which
/// already knows how to handle structs, enums, etc.
fn formatFieldValue(comptime T: type, value: T, writer: *std.Io.Writer) !void {
    switch (@typeInfo(T)) {
        .bool => try writer.print("{}", .{value}),
        .int => try writer.print("{d}", .{value}),
        .float => try writer.print("{d}", .{value}),
        .@"enum" => try writer.print("{t}", .{value}),

        .optional => |info| {
            if (value) |inner| {
                try formatFieldValue(info.child, inner, writer);
            }
            // null → empty string (omit)
        },

        .pointer => |info| switch (info.child) {
            u8 => try writer.writeAll(value),
            else => {},
        },

        .void => {},

        .@"struct" => |info| {
            if (@hasDecl(T, "formatEntry")) {
                // Use a temporary dummy name so we only get the value part.
                // The formatter writes "name = value\n" so we strip the prefix.
                var tmp: std.Io.Writer.Allocating = .init(std.heap.page_allocator);
                defer tmp.deinit();
                try value.formatEntry(
                    @import("config/formatter.zig").entryFormatter("__v", &tmp.writer),
                );
                const s = tmp.written();
                // Strip "__v = " prefix and trailing newline
                const prefix = "__v = ";
                const stripped = if (std.mem.startsWith(u8, s, prefix))
                    s[prefix.len..]
                else
                    s;
                const trimmed = std.mem.trimRight(u8, stripped, "\n");
                try writer.writeAll(trimmed);
            } else switch (info.layout) {
                .@"packed" => {
                    var first_flag = true;
                    inline for (info.fields) |f| {
                        if (!first_flag) try writer.writeByte(',');
                        first_flag = false;
                        if (!@field(value, f.name)) try writer.writeAll("no-");
                        try writer.writeAll(f.name);
                    }
                },
                else => {},
            }
        },

        .@"union" => {
            if (@hasDecl(T, "formatEntry")) {
                var tmp: std.Io.Writer.Allocating = .init(std.heap.page_allocator);
                defer tmp.deinit();
                try value.formatEntry(
                    @import("config/formatter.zig").entryFormatter("__v", &tmp.writer),
                );
                const s = tmp.written();
                const prefix = "__v = ";
                const stripped = if (std.mem.startsWith(u8, s, prefix))
                    s[prefix.len..]
                else
                    s;
                const trimmed = std.mem.trimRight(u8, stripped, "\n");
                try writer.writeAll(trimmed);
            }
        },

        else => {},
    }
}

// ---------------------------------------------------------------------------
// Comptime helpers
// ---------------------------------------------------------------------------

/// Returns true if the field name appears in Config.compatibility — meaning
/// the key has been deprecated/renamed.
fn isDeprecated(comptime name: []const u8) bool {
    return Config.compatibility.has(name);
}

/// Returns true if the type name contains "Repeatable", indicating the field
/// accumulates multiple values.
fn isRepeatable(comptime T: type) bool {
    return std.mem.indexOf(u8, @typeName(T), "Repeatable") != null;
}

/// For enum and packed-struct (flags) types, collect the valid identifiers.
/// Returns null for all other types. Field names are returned as
/// `[:0]const u8` (null-terminated string literals) which coerce to
/// `[]const u8` at the call sites.
fn buildAllowedValues(comptime T: type) ?[]const [:0]const u8 {
    return switch (@typeInfo(T)) {
        .@"enum" => std.meta.fieldNames(T),

        .optional => |info| switch (@typeInfo(info.child)) {
            .@"enum" => std.meta.fieldNames(info.child),
            else => null,
        },

        .@"struct" => |info| switch (info.layout) {
            .@"packed" => std.meta.fieldNames(T),
            else => null,
        },

        else => null,
    };
}

// ---------------------------------------------------------------------------
// Runtime helpers (operate on doc strings at runtime)
// ---------------------------------------------------------------------------

/// Search the doc string for "Available since: X.Y.Z" and return the version
/// string if found, otherwise null.
fn extractSinceVersion(docs: []const u8) ?[]const u8 {
    const needle = "Available since";
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, docs, pos, needle)) |start| {
        // Skip past "Available since" and optional ": " or " "
        var i = start + needle.len;
        while (i < docs.len and (docs[i] == ':' or docs[i] == ' ')) i += 1;
        // Now we should be at the version number
        const ver_start = i;
        while (i < docs.len and (std.ascii.isDigit(docs[i]) or docs[i] == '.')) i += 1;
        if (i > ver_start) {
            return docs[ver_start..i];
        }
        pos = start + 1;
    }
    return null;
}

/// Derive a simple platform hint string from the doc string.
/// Returns "gtk" if "GTK only" is present, "macos" if "macOS only" is
/// present (case-insensitive), or "" (empty) if no platform hint is found.
fn detectPlatform(docs: []const u8) []const u8 {
    if (std.ascii.indexOfIgnoreCase(docs, "gtk only") != null)
        return "gtk";
    if (std.ascii.indexOfIgnoreCase(docs, "macos only") != null or
        std.ascii.indexOfIgnoreCase(docs, "macos-only") != null or
        std.ascii.indexOfIgnoreCase(docs, "mac os only") != null)
        return "macos";
    return "";
}

// ---------------------------------------------------------------------------
// JSON output helpers
// ---------------------------------------------------------------------------

/// Write a JSON string key-value pair: `    "key": "value"`.
fn writeJsonString(writer: *std.Io.Writer, key: []const u8, value: []const u8) !void {
    try writer.writeAll("    \"");
    try writeEscaped(writer, key);
    try writer.writeAll("\": \"");
    try writeEscaped(writer, value);
    try writer.writeByte('"');
}

/// Write `s` to `writer` with JSON string escaping.
fn writeEscaped(writer: *std.Io.Writer, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            // Other control characters (excluding the ones handled above)
            0x00...0x08, 0x0B...0x0C, 0x0E...0x1F => try writer.print("\\u{X:0>4}", .{c}),
            else => try writer.writeByte(c),
        }
    }
}
