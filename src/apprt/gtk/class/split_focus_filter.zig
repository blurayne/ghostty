//! A GtkFilter for the split focus tree.
//!
//! GtkStringFilter cannot do this job. Over a GtkTreeListModel it sees a
//! flat sequence of GtkTreeListRow objects and drops them individually,
//! so a matching split whose window and tab do not match loses its
//! ancestors and renders orphaned at the wrong depth. This keeps a row if
//! it matches OR any of its descendants match.
//!
//! There are no unit tests here. The rule this delegates to is tested in
//! `split_focus_match.zig`; everything left needs a live GtkTreeListModel
//! with real rows, which a test binary has none of.

const std = @import("std");
const glib = @import("glib");
const gobject = @import("gobject");
const gtk = @import("gtk");

const Common = @import("../class.zig").Common;
const SplitFocusItem = @import("split_focus_item.zig").SplitFocusItem;

pub const SplitFocusFilter = extern struct {
    pub const Self = @This();
    pub const Parent = gtk.Filter;
    parent: Parent,

    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "GhosttySplitFocusFilter",
        .instanceInit = &init,
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    const Private = struct {
        /// Owned; the current search text. Null or empty matches all.
        needle: ?[:0]const u8 = null,

        /// When false the filter passes everything through, so the tree
        /// stays whole and only the highlighting marks matches.
        enabled: bool = true,

        pub var offset: c_int = 0;
    };

    pub fn new() *Self {
        return gobject.ext.newInstance(Self, .{});
    }

    //---------------------------------------------------------------
    // Virtual Methods

    fn init(self: *Self, _: *Class) callconv(.c) void {
        // GObject hands out private data zero-filled, which is not the
        // same as Zig's field defaults -- `enabled` would come out false
        // and the filter would start disabled. Write the defaults in.
        self.private().* = .{};
    }

    fn finalize(self: *Self) callconv(.c) void {
        const priv = self.private();

        if (priv.needle) |v| glib.free(@ptrCast(@constCast(v)));
        priv.needle = null;

        gobject.Object.virtual_methods.finalize.call(
            Class.parent,
            self.as(Parent),
        );
    }

    /// GtkTreeListModel hands us GtkTreeListRow objects, not our items --
    /// unwrap before matching.
    ///
    /// Returning 1 for anything unexpected is deliberate: a filter that
    /// hides rows it does not understand would silently empty the tree.
    fn match(self: *Self, item: ?*gobject.Object) callconv(.c) c_int {
        const priv = self.private();
        if (!priv.enabled) return 1;
        const needle = priv.needle orelse return 1;
        if (needle.len == 0) return 1;

        const obj = item orelse return 1;
        const row = gobject.ext.cast(gtk.TreeListRow, obj) orelse return 1;
        const inner = row.getItem() orelse return 1;
        defer inner.unref();
        const focus_item = gobject.ext.cast(SplitFocusItem, inner) orelse return 1;

        return @intFromBool(focus_item.matchesDeep(needle));
    }

    //---------------------------------------------------------------
    // Accessors

    /// Set the search text and tell GTK how the result changed, so it can
    /// re-filter incrementally instead of rebuilding the whole list.
    pub fn setNeedle(self: *Self, needle: ?[:0]const u8) void {
        const priv = self.private();
        const old_len = if (priv.needle) |n| n.len else 0;
        const new_len = if (needle) |n| n.len else 0;

        if (priv.needle) |v| glib.free(@ptrCast(@constCast(v)));
        priv.needle = if (needle) |n| glib.ext.dupeZ(u8, n) else null;

        // A longer needle can only remove rows; a shorter one can only
        // add them. Anything else is a general change.
        const change: gtk.FilterChange = if (new_len > old_len)
            .more_strict
        else if (new_len < old_len)
            .less_strict
        else
            .different;
        self.as(gtk.Filter).changed(change);
    }

    pub fn setEnabled(self: *Self, enabled: bool) void {
        const priv = self.private();
        if (priv.enabled == enabled) return;
        priv.enabled = enabled;
        self.as(gtk.Filter).changed(if (enabled) .more_strict else .less_strict);
    }

    /// The current search text. Borrowed, owned by the filter. The
    /// highlighter needs it and the filter already holds it, so there is
    /// no reason for the dialog to keep a second copy in sync.
    pub fn getNeedle(self: *Self) ?[:0]const u8 {
        return self.private().needle;
    }

    //---------------------------------------------------------------

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
            gobject.Object.virtual_methods.finalize.implement(class, &finalize);
            gtk.Filter.virtual_methods.match.implement(class, &match);
        }

        pub const as = C.Class.as;
    };
};

comptime {
    // Nothing calls into this class until the dialog lands, and Zig only
    // analyses what is referenced -- without this the build would happily
    // accept anything in here. Harmless once the dialog uses it all.
    _ = &SplitFocusFilter.getGObjectType;
    _ = &SplitFocusFilter.new;
    _ = &SplitFocusFilter.init;
    _ = &SplitFocusFilter.finalize;
    _ = &SplitFocusFilter.match;
    _ = &SplitFocusFilter.setNeedle;
    _ = &SplitFocusFilter.setEnabled;
    _ = &SplitFocusFilter.getNeedle;
    _ = &SplitFocusFilter.Class.init;
}
