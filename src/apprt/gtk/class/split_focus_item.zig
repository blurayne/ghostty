//! The data model behind the split focus dialog: one GObject per window,
//! tab and split, plus the walk that builds the whole tree from the live
//! widget hierarchy.
//!
//! There are no unit tests in this file. Every function here needs a live
//! GTK application with real windows to mean anything; a test binary has
//! none. The manual checks on the dialog are what exercise this.

const std = @import("std");
const ArenaAllocator = std.heap.ArenaAllocator;

const adw = @import("adw");
const gio = @import("gio");
const glib = @import("glib");
const gobject = @import("gobject");
const gtk = @import("gtk");

const Common = @import("../class.zig").Common;
const WeakRef = @import("../weak_ref.zig").WeakRef;
const Application = @import("application.zig").Application;
const Surface = @import("surface.zig").Surface;
const Tab = @import("tab.zig").Tab;
const Window = @import("window.zig").Window;
const match = @import("split_focus_match.zig");

const log = std.log.scoped(.gtk_ghostty_split_focus_item);

/// What a row stands for. Windows and tabs are containers; only splits
/// are terminals. All three are activatable -- a container resolves to
/// its currently-active split.
pub const Kind = enum(c_int) { window, tab, split };

/// A single row of the split focus tree.
///
/// GTK list models only accept GObjects, so the tree the dialog shows has
/// to be made of these rather than of plain Zig structs.
pub const SplitFocusItem = extern struct {
    pub const Self = @This();
    pub const Parent = gobject.Object;
    parent: Parent,

    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "GhosttySplitFocusItem",
        .instanceInit = &init,
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    const Private = struct {
        kind: Kind = .window,

        /// Backs `title` and `pwd`. Freed wholesale in `finalize`.
        arena: ArenaAllocator,

        /// Owned copies: the terminal can retitle itself or change
        /// directory while the dialog is open, and a row that pointed at
        /// the surface's own storage would then read freed memory.
        title: ?[:0]const u8 = null,
        pwd: ?[:0]const u8 = null,

        /// Weak throughout: the dialog must not keep a window, a tab or a
        /// surface alive, and any of them can close while it is open.
        window: WeakRef(Window) = .empty,
        surface: WeakRef(Surface) = .empty,
        page: WeakRef(adw.TabPage) = .empty,

        /// Non-null for window and tab kinds; null for splits, which is
        /// what makes a split a leaf in the tree model.
        children: ?*gio.ListStore = null,

        pub var offset: c_int = 0;
    };

    /// Create a new item. `title` and `pwd` are copied. The caller owns
    /// the returned reference.
    pub fn new(kind: Kind, title: []const u8, pwd: ?[]const u8) *Self {
        const self = gobject.ext.newInstance(Self, .{});

        const priv = self.private();
        const alloc = priv.arena.allocator();

        priv.kind = kind;
        priv.title = alloc.dupeZ(u8, title) catch null;
        priv.pwd = if (pwd) |v| alloc.dupeZ(u8, v) catch null else null;

        return self;
    }

    //---------------------------------------------------------------
    // Virtual Methods

    fn init(self: *Self, _: *Class) callconv(.c) void {
        const priv = self.private();
        priv.arena = .init(Application.default().allocator());
    }

    fn dispose(self: *Self) callconv(.c) void {
        const priv = self.private();

        // Weak refs MUST be released before this memory goes away; see
        // the comment on `WeakRef.deinit`. Resetting to `.empty` after
        // makes a second dispose a no-op rather than a double clear.
        priv.window.deinit();
        priv.window = .empty;
        priv.surface.deinit();
        priv.surface = .empty;
        priv.page.deinit();
        priv.page = .empty;

        if (priv.children) |children| {
            priv.children = null;
            children.unref();
        }

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
    // Accessors

    pub fn getKind(self: *Self) Kind {
        return self.private().kind;
    }

    pub fn getTitle(self: *Self) ?[:0]const u8 {
        return self.private().title;
    }

    pub fn getPwd(self: *Self) ?[:0]const u8 {
        return self.private().pwd;
    }

    /// The child rows of this item, or null for a split. Not reffed.
    pub fn getChildren(self: *Self) ?*gio.ListStore {
        return self.private().children;
    }

    /// The tab page this row lives in, or null if that tab has closed.
    /// This does not ref the value, matching the rest of the apprt.
    pub fn getPage(self: *Self) ?*adw.TabPage {
        const page = self.private().page.get() orelse return null;
        page.unref();
        return page;
    }

    /// The window this row lives in, or null if it has closed.
    /// Returns a strong reference; the caller must unref.
    pub fn getWindow(self: *Self) ?*Window {
        return self.private().window.get();
    }

    //---------------------------------------------------------------

    /// Whether this row or any row beneath it matches. This is the rule
    /// the tree filter needs: keeping only rows that match themselves
    /// would strip a matching split of its window and tab and render it
    /// orphaned at the wrong depth.
    pub fn matchesDeep(self: *Self, needle: []const u8) bool {
        const priv = self.private();
        if (match.matchesFields(
            priv.title orelse "",
            priv.pwd,
            needle,
        )) return true;

        const children = priv.children orelse return false;
        const model = children.as(gio.ListModel);
        const n = model.getNItems();
        var i: c_uint = 0;
        while (i < n) : (i += 1) {
            const obj = model.getObject(i) orelse continue;
            defer obj.unref();
            const child = gobject.ext.cast(Self, obj) orelse continue;
            if (child.matchesDeep(needle)) return true;
        }
        return false;
    }

    /// The surface this row focuses when activated. Windows and tabs
    /// resolve to their currently-active split, so every row does
    /// something useful. Returns null if the target has since closed.
    ///
    /// This does not ref the returned surface, matching the contract of
    /// `Window.getActiveSurface` and `Tab.getActiveSurface`. A live
    /// surface is owned by the split tree widget that holds it, so the
    /// borrow is valid for as long as the caller is on the stack.
    pub fn resolveSurface(self: *Self) ?*Surface {
        const priv = self.private();
        return switch (priv.kind) {
            .split => split: {
                // WeakRef.get() hands back a strong reference, unlike the
                // two arms below. Drop it here so every arm returns a
                // borrow and the caller has one rule to follow.
                const surface = priv.surface.get() orelse break :split null;
                surface.unref();
                break :split surface;
            },
            .tab => tab: {
                const page = self.getPage() orelse break :tab null;
                const child = page.getChild();
                const tab = gobject.ext.cast(Tab, child) orelse break :tab null;
                break :tab tab.getActiveSurface();
            },
            .window => window: {
                const win = priv.window.get() orelse break :window null;
                defer win.unref();
                break :window win.getActiveSurface();
            },
        };
    }

    //---------------------------------------------------------------
    // Tree building

    /// Walk every window, tab and split of the application into a tree of
    /// items. Order is the application's window order, then tab-view
    /// order, then surface-tree order -- deliberately not sorted, because
    /// people navigate by remembered position.
    ///
    /// The caller owns the returned list store.
    pub fn buildRoot(app: *gtk.Application) *gio.ListStore {
        const root = gio.ListStore.new(getGObjectType());

        // The binding types this non-optional, but GTK returns NULL for
        // an application with no windows.
        var maybe_node: ?*glib.List = app.getWindows();
        while (maybe_node) |node| : (maybe_node = node.f_next) {
            const data = node.f_data orelse continue;
            const widget: *gtk.Widget = @ptrCast(@alignCast(data));
            const win = gobject.ext.cast(Window, widget) orelse continue;

            const win_item = Self.new(.window, windowTitle(win), null);
            defer win_item.unref();
            win_item.private().window.set(win);
            const tabs = gio.ListStore.new(getGObjectType());
            win_item.private().children = tabs;

            const tab_view = win.getTabView();
            const n = tab_view.getNPages();
            var i: c_int = 0;
            while (i < n) : (i += 1) {
                const page = tab_view.getNthPage(i);
                const tab = gobject.ext.cast(Tab, page.getChild()) orelse {
                    log.warn("unexpected non-Tab child in tab view", .{});
                    continue;
                };

                const tab_item = Self.new(
                    .tab,
                    std.mem.span(page.getTitle()),
                    null,
                );
                defer tab_item.unref();
                tab_item.private().window.set(win);
                tab_item.private().page.set(page);
                const splits = gio.ListStore.new(getGObjectType());
                tab_item.private().children = splits;

                if (tab.getSurfaceTree()) |tree| {
                    var it = tree.iterator();
                    while (it.next()) |entry| {
                        const surface = entry.view;
                        const split_item = Self.new(
                            .split,
                            surface.getEffectiveTitle() orelse "",
                            surface.getPwd(),
                        );
                        defer split_item.unref();
                        split_item.private().window.set(win);
                        split_item.private().page.set(page);
                        split_item.private().surface.set(surface);
                        splits.append(split_item.as(gobject.Object));
                    }
                }

                tabs.append(tab_item.as(gobject.Object));
            }

            root.append(win_item.as(gobject.Object));
        }

        return root;
    }

    /// A window's title, or a stand-in. GTK windows can legitimately have
    /// no title, and a blank row tells the user nothing.
    fn windowTitle(win: *Window) []const u8 {
        const title = win.as(gtk.Window).getTitle() orelse return "Window";
        const span = std.mem.span(title);
        if (span.len == 0) return "Window";
        return span;
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
            gobject.Object.virtual_methods.dispose.implement(class, &dispose);
            gobject.Object.virtual_methods.finalize.implement(class, &finalize);
        }

        pub const as = C.Class.as;
    };
};

comptime {
    // Nothing calls into this class until the dialog lands, and Zig only
    // analyses what is referenced -- without this the build would happily
    // accept anything in here. Harmless once the dialog uses it all.
    _ = &SplitFocusItem.getGObjectType;
    _ = &SplitFocusItem.new;
    _ = &SplitFocusItem.init;
    _ = &SplitFocusItem.dispose;
    _ = &SplitFocusItem.finalize;
    _ = &SplitFocusItem.getKind;
    _ = &SplitFocusItem.getTitle;
    _ = &SplitFocusItem.getPwd;
    _ = &SplitFocusItem.getChildren;
    _ = &SplitFocusItem.getPage;
    _ = &SplitFocusItem.getWindow;
    _ = &SplitFocusItem.matchesDeep;
    _ = &SplitFocusItem.resolveSurface;
    _ = &SplitFocusItem.buildRoot;
    _ = &SplitFocusItem.Class.init;
}
