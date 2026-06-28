//! Schema parser for config.schema.json.
//! Loads and indexes the Ghostty config schema for use by the LSP server.

const std = @import("std");

/// A single config entry from config.schema.json.
pub const Entry = struct {
    key: []const u8,
    type: []const u8,
    default: []const u8,
    description: []const u8,
    since_version: ?[]const u8,
    deprecated: bool,
    deprecated_replaced_by: ?[]const u8,
    repeatable: bool,
    allowed_values: ?[][]const u8,
    platform: ?[]const u8,
};

/// In-memory schema loaded from the embedded JSON.
pub const Schema = struct {
    allocator: std.mem.Allocator,
    entries: []Entry,
    /// Map from key name → index in `entries` for O(1) lookup.
    index: std.StringHashMap(u32),

    pub fn deinit(self: *Schema) void {
        for (self.entries) |entry| {
            self.allocator.free(entry.key);
            self.allocator.free(entry.type);
            self.allocator.free(entry.default);
            self.allocator.free(entry.description);
            if (entry.since_version) |sv| self.allocator.free(sv);
            if (entry.deprecated_replaced_by) |dr| self.allocator.free(dr);
            if (entry.allowed_values) |avs| {
                for (avs) |av| self.allocator.free(av);
                self.allocator.free(avs);
            }
            if (entry.platform) |p| self.allocator.free(p);
        }
        self.allocator.free(self.entries);
        self.index.deinit();
    }

    /// Look up an entry by exact key name.
    pub fn get(self: *const Schema, key: []const u8) ?*const Entry {
        const idx = self.index.get(key) orelse return null;
        return &self.entries[idx];
    }
};

/// Parse the schema JSON and build an in-memory index.
/// Caller owns the returned Schema and must call deinit().
pub fn parse(allocator: std.mem.Allocator, json_text: []const u8) !Schema {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_text, .{});
    defer parsed.deinit();

    const root = switch (parsed.value) {
        .array => |arr| arr,
        else => return error.InvalidSchema,
    };

    // Allocate maximum possible entries; we'll resize to the actual count at the end.
    const entries_buf = try allocator.alloc(Entry, root.items.len);
    errdefer allocator.free(entries_buf);
    var count: usize = 0;

    var index = std.StringHashMap(u32).init(allocator);
    errdefer index.deinit();

    for (root.items) |item| {
        const obj = switch (item) {
            .object => |o| o,
            else => continue,
        };

        const key = try allocator.dupe(u8, stringField(obj, "key") orelse continue);
        errdefer allocator.free(key);
        const type_str = try allocator.dupe(u8, stringField(obj, "type") orelse "custom");
        errdefer allocator.free(type_str);
        const default = try allocator.dupe(u8, stringField(obj, "default") orelse "");
        errdefer allocator.free(default);
        const description = try allocator.dupe(u8, stringField(obj, "description") orelse "");
        errdefer allocator.free(description);

        const since_version: ?[]const u8 = if (stringField(obj, "since_version")) |sv|
            try allocator.dupe(u8, sv)
        else
            null;
        errdefer if (since_version) |sv| allocator.free(sv);

        const deprecated_replaced_by: ?[]const u8 = if (stringField(obj, "deprecated_replaced_by")) |dr|
            try allocator.dupe(u8, dr)
        else
            null;
        errdefer if (deprecated_replaced_by) |dr| allocator.free(dr);

        const deprecated = boolField(obj, "deprecated") orelse false;
        const repeatable = boolField(obj, "repeatable") orelse false;

        const allowed_values: ?[][]const u8 = if (obj.get("allowed_values")) |av_val| blk: {
            switch (av_val) {
                .array => |arr| {
                    if (arr.items.len == 0) break :blk null;
                    const avs = try allocator.alloc([]const u8, arr.items.len);
                    var av_count: usize = 0;
                    errdefer {
                        for (avs[0..av_count]) |av| allocator.free(av);
                        allocator.free(avs);
                    }
                    for (arr.items) |av_item| {
                        switch (av_item) {
                            .string => |s| {
                                avs[av_count] = try allocator.dupe(u8, s);
                                av_count += 1;
                            },
                            else => {},
                        }
                    }
                    break :blk avs[0..av_count];
                },
                else => break :blk null,
            }
        } else null;

        const platform: ?[]const u8 = if (stringField(obj, "platform")) |p|
            try allocator.dupe(u8, p)
        else
            null;

        entries_buf[count] = .{
            .key = key,
            .type = type_str,
            .default = default,
            .description = description,
            .since_version = since_version,
            .deprecated = deprecated,
            .deprecated_replaced_by = deprecated_replaced_by,
            .repeatable = repeatable,
            .allowed_values = allowed_values,
            .platform = platform,
        };
        try index.put(key, @intCast(count));
        count += 1;
    }

    // Resize the buffer to the actual number of entries (may be fewer if
    // some items were skipped due to missing "key" fields).
    const entries = if (count < entries_buf.len)
        (allocator.realloc(entries_buf, count) catch entries_buf[0..count])
    else
        entries_buf;

    return .{
        .allocator = allocator,
        .entries = entries,
        .index = index,
    };
}

fn stringField(obj: std.json.ObjectMap, field: []const u8) ?[]const u8 {
    const val = obj.get(field) orelse return null;
    return switch (val) {
        .string => |s| s,
        else => null,
    };
}

fn boolField(obj: std.json.ObjectMap, field: []const u8) ?bool {
    const val = obj.get(field) orelse return null;
    return switch (val) {
        .bool => |b| b,
        else => null,
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "parse basic schema" {
    const allocator = std.testing.allocator;
    const json =
        \\[
        \\  {
        \\    "key": "font-size",
        \\    "type": "float",
        \\    "default": "12",
        \\    "description": "Font size in points.",
        \\    "since_version": "1.0.0",
        \\    "deprecated": false,
        \\    "deprecated_replaced_by": null,
        \\    "repeatable": false,
        \\    "allowed_values": null,
        \\    "platform": null
        \\  },
        \\  {
        \\    "key": "cursor-style",
        \\    "type": "enum",
        \\    "default": "block",
        \\    "description": "Cursor style.",
        \\    "since_version": null,
        \\    "deprecated": false,
        \\    "deprecated_replaced_by": null,
        \\    "repeatable": false,
        \\    "allowed_values": ["block", "bar", "underline"],
        \\    "platform": null
        \\  }
        \\]
    ;

    var schema = try parse(allocator, json);
    defer schema.deinit();

    try std.testing.expectEqual(@as(usize, 2), schema.entries.len);

    const fs = schema.get("font-size").?;
    try std.testing.expectEqualStrings("font-size", fs.key);
    try std.testing.expectEqualStrings("float", fs.type);
    try std.testing.expectEqualStrings("12", fs.default);
    try std.testing.expectEqualStrings("1.0.0", fs.since_version.?);
    try std.testing.expect(!fs.deprecated);
    try std.testing.expect(!fs.repeatable);
    try std.testing.expect(fs.allowed_values == null);

    const cs = schema.get("cursor-style").?;
    try std.testing.expectEqualStrings("cursor-style", cs.key);
    try std.testing.expectEqualStrings("enum", cs.type);
    try std.testing.expectEqualStrings("block", cs.default);
    try std.testing.expect(cs.allowed_values != null);
    try std.testing.expectEqual(@as(usize, 3), cs.allowed_values.?.len);
    try std.testing.expectEqualStrings("block", cs.allowed_values.?[0]);
    try std.testing.expectEqualStrings("bar", cs.allowed_values.?[1]);
    try std.testing.expectEqualStrings("underline", cs.allowed_values.?[2]);
}

test "parse: missing key is skipped" {
    const allocator = std.testing.allocator;
    const json =
        \\[
        \\  {"type": "float", "default": "", "description": "", "since_version": null,
        \\   "deprecated": false, "deprecated_replaced_by": null, "repeatable": false,
        \\   "allowed_values": null, "platform": null}
        \\]
    ;
    var schema = try parse(allocator, json);
    defer schema.deinit();
    // Entry without "key" is skipped
    try std.testing.expectEqual(@as(usize, 0), schema.entries.len);
}

test "get: non-existent key returns null" {
    const allocator = std.testing.allocator;
    const json =
        \\[{"key":"x","type":"bool","default":"false","description":"","since_version":null,
        \\  "deprecated":false,"deprecated_replaced_by":null,"repeatable":false,
        \\  "allowed_values":null,"platform":null}]
    ;
    var schema = try parse(allocator, json);
    defer schema.deinit();
    try std.testing.expect(schema.get("y") == null);
    try std.testing.expect(schema.get("x") != null);
}
