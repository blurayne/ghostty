//! GObject wrapper for a single config field, used as the item type in the
//! ConfigEditorWindow's GListStore.
//!
//! Each ConfigEntryObject stores:
//!   - A reference to the FieldMeta (by index into metadata.fields)
//!   - The current serialized string value of the field
//!   - A dirty flag that is set when the user has changed the value

const std = @import("std");
const gobject = @import("gobject");

const configpkg = @import("../../../config.zig");
const metadata = configpkg.metadata;
const Common = @import("../class.zig").Common;
const Application = @import("application.zig").Application;

const log = std.log.scoped(.gtk_ghostty_config_entry_object);

pub const ConfigEntryObject = extern struct {
    const Self = @This();
    pub const Parent = gobject.Object;
    parent: Parent,

    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "GhosttyConfigEntryObject",
        .instanceInit = &init,
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    pub const properties = struct {
        /// The hyphenated config key name (e.g. "font-size").
        pub const key_name = struct {
            pub const name = "key-name";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                ?[:0]const u8,
                .{
                    .default = null,
                    .accessor = gobject.ext.typedAccessor(
                        Self,
                        ?[:0]const u8,
                        .{
                            .getter = propGetKeyName,
                            .getter_transfer = .none,
                        },
                    ),
                },
            );
        };

        /// First line of the documentation string for the field.
        pub const doc_summary = struct {
            pub const name = "doc-summary";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                ?[:0]const u8,
                .{
                    .default = null,
                    .accessor = gobject.ext.typedAccessor(
                        Self,
                        ?[:0]const u8,
                        .{
                            .getter = propGetDocSummary,
                            .getter_transfer = .none,
                        },
                    ),
                },
            );
        };

        /// The current serialized string value (e.g. "13" for font-size = 13).
        pub const current_value = struct {
            pub const name = "current-value";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                ?[:0]const u8,
                .{
                    .default = null,
                    .accessor = .{
                        .getter = getCurrentValueGobject,
                        .setter = setCurrentValueGobject,
                    },
                },
            );
        };

        /// True when the user has modified this field from the loaded value.
        pub const dirty = struct {
            pub const name = "dirty";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                bool,
                .{
                    .default = false,
                    .accessor = gobject.ext.typedAccessor(Self, bool, .{
                        .getter = propGetDirty,
                        .setter = propSetDirty,
                    }),
                },
            );
        };
    };

    pub const signals = struct {};

    const Private = struct {
        /// Index into metadata.fields.
        field_index: usize = 0,

        /// Cached sentinel-terminated key name (allocated from arena).
        key_name_z: ?[:0]const u8 = null,

        /// Cached sentinel-terminated doc summary (allocated from arena).
        doc_summary_z: ?[:0]const u8 = null,

        /// Cached sentinel-terminated full docs (allocated from arena).
        doc_full_z: ?[:0]const u8 = null,

        /// The current serialized value (sentinel-terminated, allocated from arena).
        current_value_z: ?[:0]const u8 = null,

        /// True when the value differs from what was loaded.
        dirty: bool = false,

        /// Arena allocator for cached strings.
        arena: std.heap.ArenaAllocator,

        pub var offset: c_int = 0;
    };

    //---------------------------------------------------------------
    // Construction

    pub fn new(field_index: usize, initial_value: []const u8) *Self {
        const self = gobject.ext.newInstance(Self, .{});
        const priv = self.private();
        priv.field_index = field_index;

        // Copy the initial value into the arena.
        priv.current_value_z = priv.arena.allocator().dupeZ(u8, initial_value) catch null;

        return self;
    }

    //---------------------------------------------------------------
    // Virtual Methods

    fn init(self: *Self, _: *Class) callconv(.c) void {
        const priv = self.private();
        priv.arena = .init(Application.default().allocator());
    }

    fn dispose(self: *Self) callconv(.c) void {
        gobject.Object.virtual_methods.dispose.call(
            Class.parent,
            self.as(Parent),
        );
    }

    fn finalize(self: *Self) callconv(.c) void {
        const priv = self.private();
        priv.arena.deinit();
        gobject.Object.virtual_methods.finalize.call(
            Class.parent,
            self.as(Parent),
        );
    }

    //---------------------------------------------------------------
    // Property getters / setters

    pub fn propGetKeyName(self: *Self) ?[:0]const u8 {
        const priv = self.private();
        if (priv.key_name_z) |v| return v;

        const field = metadata.fields[priv.field_index];
        // field.name is already [:0]const u8 from metadata, no dupeZ needed.
        priv.key_name_z = field.name;
        return priv.key_name_z;
    }

    pub fn propGetDocSummary(self: *Self) ?[:0]const u8 {
        const priv = self.private();
        if (priv.doc_summary_z) |v| return v;

        const field = metadata.fields[priv.field_index];
        if (field.docs.len == 0) return null;

        // Use the first non-empty line as the summary.
        var lines = std.mem.splitScalar(u8, field.docs, '\n');
        const first_line = while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len > 0) break trimmed;
        } else return null;

        priv.doc_summary_z = priv.arena.allocator().dupeZ(u8, first_line) catch return null;
        return priv.doc_summary_z;
    }

    fn getCurrentValueGobject(self: *Self, value: *gobject.Value) void {
        gobject.ext.Value.set(value, self.private().current_value_z);
    }

    fn setCurrentValueGobject(self: *Self, value: *const gobject.Value) void {
        const priv = self.private();
        const s = gobject.ext.Value.get(value, ?[:0]const u8) orelse {
            priv.current_value_z = null;
            return;
        };
        priv.current_value_z = priv.arena.allocator().dupeZ(u8, s) catch null;
    }

    fn propGetDirty(self: *Self) bool {
        return self.private().dirty;
    }

    fn propSetDirty(self: *Self, v: bool) void {
        self.private().dirty = v;
    }

    //---------------------------------------------------------------
    // Public API

    pub fn getFieldMeta(self: *Self) metadata.FieldMeta {
        return metadata.fields[self.private().field_index];
    }

    pub fn getFieldIndex(self: *Self) usize {
        return self.private().field_index;
    }

    pub fn getDocsFull(self: *Self) ?[:0]const u8 {
        const priv = self.private();
        if (priv.doc_full_z) |v| return v;

        const field = metadata.fields[priv.field_index];
        if (field.docs.len == 0) return null;

        priv.doc_full_z = priv.arena.allocator().dupeZ(u8, field.docs) catch return null;
        return priv.doc_full_z;
    }

    pub fn getCurrentValue(self: *Self) ?[:0]const u8 {
        return self.private().current_value_z;
    }

    pub fn setCurrentValue(self: *Self, v: []const u8) void {
        const priv = self.private();
        priv.current_value_z = priv.arena.allocator().dupeZ(u8, v) catch return;
        self.as(gobject.Object).notifyByPspec(properties.current_value.impl.param_spec);
    }

    pub fn getDirty(self: *Self) bool {
        return self.private().dirty;
    }

    pub fn setDirty(self: *Self, v: bool) void {
        self.private().dirty = v;
        self.as(gobject.Object).notifyByPspec(properties.dirty.impl.param_spec);
    }

    //---------------------------------------------------------------
    // Boilerplate

    const C = Common(Self, Private);
    pub const as = C.as;
    pub const ref = C.ref;
    pub const unref = C.unref;
    const private = C.private;

    pub const Class = extern struct {
        parent_class: Parent.Class,
        var parent: *Parent.Class = undefined;
        pub const Instance = Self;

        fn init(class: *Class) callconv(.c) void {
            gobject.ext.registerProperties(class, &.{
                properties.key_name.impl,
                properties.doc_summary.impl,
                properties.current_value.impl,
                properties.dirty.impl,
            });

            gobject.Object.virtual_methods.dispose.implement(class, &dispose);
            gobject.Object.virtual_methods.finalize.implement(class, &finalize);
        }
    };
};
