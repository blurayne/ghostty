//! Comptime metadata for all user-facing config fields.
//!
//! This module enumerates all public config fields at comptime and produces
//! a static `[]const FieldMeta` array that the GTK config editor can use
//! to build UI widgets without any runtime reflection.

const std = @import("std");
const Config = @import("Config.zig");
const help_strings = @import("help_strings");

/// The kind of a config field, used to select the appropriate editor widget.
pub const FieldKind = enum {
    bool,
    optional_bool,
    int,
    float,
    @"enum",
    packed_flags,
    string,
    repeatable,
    complex, // fallback — read-only display
};

/// A single enum variant name (for .@"enum" and .packed_flags kinds).
/// The name is always null-terminated (it comes from comptime field names).
pub const EnumVariant = struct { name: [:0]const u8 };

/// Metadata describing a single user-facing config field.
pub const FieldMeta = struct {
    /// The hyphenated field name, e.g. "font-size" (null-terminated).
    name: [:0]const u8,

    /// The kind of this field, used to pick an editor widget.
    kind: FieldKind,

    /// Documentation string from the generated help_strings module.
    /// Empty string when no docs are available. Not null-terminated.
    docs: []const u8,

    /// Non-empty only for .@"enum" and .packed_flags kinds.
    variants: []const EnumVariant,
};

/// Classify the concrete (non-optional) type of a config field.
fn classifyType(comptime T: type) FieldKind {
    return switch (@typeInfo(T)) {
        .bool => .bool,
        .int => .int,
        .float => .float,

        .@"enum" => .@"enum",

        .pointer => |ptr| switch (ptr.size) {
            .slice, .many, .c => if (ptr.child == u8) .string else .complex,
            .one => .complex,
        },

        .@"struct" => |info| blk: {
            // Check for repeatable: any struct with a `parseCLI` method
            // and containing list-like data (has a `list` or `value` field).
            // We identify these by checking for `parseCLI` which all Repeatable
            // types have.
            if (@hasDecl(T, "parseCLI")) break :blk .repeatable;

            // Packed structs where all fields are bool → packed_flags.
            if (info.layout == .@"packed") {
                var all_bool = true;
                for (info.fields) |f| {
                    if (f.type != bool) {
                        all_bool = false;
                        break;
                    }
                }
                if (all_bool and info.fields.len > 0) break :blk .packed_flags;
            }

            // Plain structs with formatEntry → complex (handled by formatter).
            break :blk .complex;
        },

        .@"union" => .complex,
        .void => .complex,
        .optional => unreachable, // unwrapped before calling this
        else => .complex,
    };
}

/// Collect enum variants for a type (only valid for .@"enum" kind).
/// Field names from @typeInfo are always compile-time string literals
/// so they are inherently null-terminated.
fn enumVariants(comptime T: type) []const EnumVariant {
    const info = @typeInfo(T).@"enum";
    var variants: [info.fields.len]EnumVariant = undefined;
    for (info.fields, 0..) |f, i| {
        // Zig field names are null-terminated literals at comptime.
        variants[i] = .{ .name = @as([:0]const u8, f.name) };
    }
    const static = variants;
    return &static;
}

/// Collect flag names for a packed struct (only valid for .packed_flags kind).
fn packedFlagVariants(comptime T: type) []const EnumVariant {
    const info = @typeInfo(T).@"struct";
    var variants: [info.fields.len]EnumVariant = undefined;
    for (info.fields, 0..) |f, i| {
        variants[i] = .{ .name = @as([:0]const u8, f.name) };
    }
    const static = variants;
    return &static;
}

/// Build the static field metadata array at comptime.
pub const fields: []const FieldMeta = comptime build: {
    @setEvalBranchQuota(100_000);

    const struct_fields = @typeInfo(Config).@"struct".fields;

    // First pass: count public fields (those not starting with '_').
    var count: usize = 0;
    for (struct_fields) |field| {
        if (field.name[0] == '_') continue;
        count += 1;
    }

    // Second pass: populate metadata array.
    var result: [count]FieldMeta = undefined;
    var i: usize = 0;

    for (struct_fields) |field| {
        if (field.name[0] == '_') continue;

        // Docs from help_strings (comptime-generated).
        const docs: []const u8 = if (@hasDecl(help_strings.Config, field.name))
            @field(help_strings.Config, field.name)
        else
            "";

        // Unwrap optional to find the concrete type.
        const FT = field.type;
        const is_optional = @typeInfo(FT) == .optional;
        const ConcreteT = if (is_optional) @typeInfo(FT).optional.child else FT;

        // Classify the kind.
        var kind: FieldKind = classifyType(ConcreteT);
        if (is_optional and kind == .bool) kind = .optional_bool;

        // Collect variants for enum / packed_flags.
        const variants: []const EnumVariant = switch (kind) {
            .@"enum" => enumVariants(ConcreteT),
            .packed_flags => packedFlagVariants(ConcreteT),
            else => &.{},
        };

        result[i] = .{
            // Struct field names from @typeInfo are null-terminated string
            // literals at comptime; we cast to make the type explicit.
            .name = @as([:0]const u8, field.name),
            .kind = kind,
            .docs = docs,
            .variants = variants,
        };
        i += 1;
    }

    const static = result;
    break :build &static;
};

// ---------------------------------------------------------------------------
// Unit tests

test "metadata: fields is non-empty" {
    try std.testing.expect(fields.len > 0);
}

test "metadata: font-size is float" {
    for (fields) |f| {
        if (std.mem.eql(u8, f.name, "font-size")) {
            try std.testing.expectEqual(FieldKind.float, f.kind);
            return;
        }
    }
    return error.NotFound;
}

test "metadata: cursor-style is enum with variants" {
    for (fields) |f| {
        if (std.mem.eql(u8, f.name, "cursor-style")) {
            try std.testing.expectEqual(FieldKind.@"enum", f.kind);
            try std.testing.expect(f.variants.len >= 3);
            return;
        }
    }
    return error.NotFound;
}

test "metadata: cursor-style-blink is optional_bool" {
    for (fields) |f| {
        if (std.mem.eql(u8, f.name, "cursor-style-blink")) {
            try std.testing.expectEqual(FieldKind.optional_bool, f.kind);
            return;
        }
    }
    return error.NotFound;
}

test "metadata: font-synthetic-style is packed_flags" {
    for (fields) |f| {
        if (std.mem.eql(u8, f.name, "font-synthetic-style")) {
            try std.testing.expectEqual(FieldKind.packed_flags, f.kind);
            try std.testing.expect(f.variants.len >= 2);
            return;
        }
    }
    return error.NotFound;
}

test "metadata: font-family is repeatable" {
    for (fields) |f| {
        if (std.mem.eql(u8, f.name, "font-family")) {
            try std.testing.expectEqual(FieldKind.repeatable, f.kind);
            return;
        }
    }
    return error.NotFound;
}

test "metadata: no private fields (no underscore-prefixed)" {
    for (fields) |f| {
        try std.testing.expect(f.name.len > 0);
        try std.testing.expect(f.name[0] != '_');
    }
}
