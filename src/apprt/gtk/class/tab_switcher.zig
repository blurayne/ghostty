const std = @import("std");
const ArenaAllocator = std.heap.ArenaAllocator;

const adw = @import("adw");
const gio = @import("gio");
const gobject = @import("gobject");
const gtk = @import("gtk");

const gresource = @import("../build/gresource.zig");
const Common = @import("../class.zig").Common;
const Application = @import("application.zig").Application;
const Window = @import("window.zig").Window;
const Tab = @import("tab.zig").Tab;

const log = std.log.scoped(.gtk_ghostty_tab_switcher);

/// A dialog that presents a searchable, keyboard-navigable list of the
/// tabs in a window, allowing the user to quickly switch to one.
pub const TabSwitcher = extern struct {
    const Self = @This();
    parent_instance: Parent,
    pub const Parent = adw.Bin;
    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "GhosttyTabSwitcher",
        .instanceInit = &init,
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    const Private = struct {
        /// The dialog object containing the switcher UI.
        dialog: *adw.Dialog,

        /// The search input text field.
        search: *gtk.SearchEntry,

        /// The view containing each tab row.
        view: *gtk.ListView,

        /// The model that provides filtered data for the view to display.
        model: *gtk.SingleSelection,

        /// The filter model that wraps our data source.
        filter_model: *gtk.FilterListModel,

        /// Checkbox to show/hide splits. Unused until Task 3.
        show_splits: *gtk.CheckButton,

        /// The list that serves as the data source of the model. This is
        /// a non-owning pointer -- `filter_model` holds the strong
        /// reference for the lifetime of this widget.
        source: *gio.ListStore,

        /// The window that this switcher is currently presented over.
        /// This is not owned/reffed; the switcher is only ever presented
        /// modally over a live window.
        window: ?*Window = null,

        pub var offset: c_int = 0;
    };

    /// Create a new instance of the tab switcher. The caller will own a
    /// reference to the object.
    pub fn new() *Self {
        const self = gobject.ext.newInstance(Self, .{});

        // Sink ourselves so that we aren't floating anymore. We'll unref
        // ourselves when the switcher is closed.
        _ = self.refSink();

        // Bump the ref so that the caller has a reference.
        return self.ref();
    }

    //---------------------------------------------------------------
    // Virtual Methods

    fn init(self: *Self, _: *Class) callconv(.c) void {
        gtk.Widget.initTemplate(self.as(gtk.Widget));

        const priv = self.private();

        // Create our backing data source and wire it up to the filter
        // model. The filter model retains its own reference so we drop
        // ours immediately after.
        const source = gio.ListStore.new(TabSwitcherItem.getGObjectType());
        priv.filter_model.setModel(source.as(gio.ListModel));
        source.unref();
        priv.source = source;
    }

    fn dispose(self: *Self) callconv(.c) void {
        const priv = self.private();

        priv.source.removeAll();
        priv.window = null;

        gtk.Widget.disposeTemplate(
            self.as(gtk.Widget),
            getGObjectType(),
        );

        gobject.Object.virtual_methods.dispose.call(
            Class.parent,
            self.as(Parent),
        );
    }

    //---------------------------------------------------------------
    // Signal Handlers

    fn dialogClosed(_: *adw.Dialog, self: *TabSwitcher) callconv(.c) void {
        self.unref();
    }

    fn searchStopped(_: *gtk.SearchEntry, self: *TabSwitcher) callconv(.c) void {
        // ESC was pressed - close the switcher
        self.close();
    }

    fn searchActivated(_: *gtk.SearchEntry, self: *TabSwitcher) callconv(.c) void {
        // If Enter is pressed, activate the selected entry
        const priv = self.private();
        self.activate(priv.model.getSelected());
    }

    fn rowActivated(_: *gtk.ListView, pos: c_uint, self: *TabSwitcher) callconv(.c) void {
        self.activate(pos);
    }

    fn showSplitsToggled(_: *gtk.CheckButton, _: *TabSwitcher) callconv(.c) void {
        // No-op for now. Expanding splits is implemented in a later task.
    }

    //---------------------------------------------------------------

    /// Show or hide the tab switcher dialog. If the dialog is shown it
    /// will be modal over the given window and populated with that
    /// window's current tabs.
    pub fn toggle(self: *Self, window: *Window) void {
        const priv = self.private();

        // If the dialog has been shown, close it.
        if (priv.dialog.as(gtk.Widget).getRealized() != 0) {
            self.close();
            return;
        }

        self.populate(window);

        // Show the dialog
        priv.dialog.present(window.as(gtk.Widget));

        // Focus on the search bar when opening the dialog
        _ = priv.search.as(gtk.Widget).grabFocus();
    }

    /// Close the tab switcher dialog.
    pub fn close(self: *Self) void {
        const priv = self.private();
        _ = priv.dialog.close();
    }

    /// Rebuild the list of tabs shown in the switcher from the given
    /// window's current tab view.
    fn populate(self: *Self, window: *Window) void {
        const priv = self.private();
        priv.source.removeAll();
        priv.window = window;

        const tab_view = window.getTabView();
        const n = tab_view.getNPages();
        var i: c_int = 0;
        while (i < n) : (i += 1) {
            const page = tab_view.getNthPage(i);
            const child = page.getChild();
            const tab = gobject.ext.cast(Tab, child) orelse {
                log.warn("unexpected non-Tab child in tab view", .{});
                continue;
            };

            var count: u32 = 0;
            if (tab.getSurfaceTree()) |tree| {
                var it = tree.iterator();
                while (it.next()) |_| count += 1;
            }

            const title = std.mem.span(page.getTitle());
            const item = TabSwitcherItem.new(page, title, count);
            defer item.unref();
            priv.source.append(item.as(gobject.Object));
        }
    }

    /// Switch to the tab represented by the item at the given position in
    /// the (filtered/visible) model, then close the dialog.
    fn activate(self: *Self, pos: c_uint) void {
        const priv = self.private();

        // Use priv.model and not priv.source here to use the list of
        // *visible* results.
        const object_ = priv.model.as(gio.ListModel).getObject(pos);
        defer if (object_) |object| object.unref();

        // Close before switching tabs to avoid the dialog lingering
        // around after we've already navigated away.
        self.close();

        const item = gobject.ext.cast(TabSwitcherItem, object_ orelse return) orelse return;
        const page = item.getPage() orelse return;
        const window = priv.window orelse return;

        window.getTabView().setSelectedPage(page);
    }

    const C = Common(Self, Private);
    pub const as = C.as;
    pub const ref = C.ref;
    pub const refSink = C.refSink;
    pub const unref = C.unref;
    const private = C.private;

    pub const Class = extern struct {
        parent_class: Parent.Class,
        var parent: *Parent.Class = undefined;
        pub const Instance = Self;

        fn init(class: *Class) callconv(.c) void {
            gobject.ext.ensureType(TabSwitcherItem);
            gtk.Widget.Class.setTemplateFromResource(
                class.as(gtk.Widget.Class),
                comptime gresource.blueprint(.{
                    .major = 1,
                    .minor = 5,
                    .name = "tab-switcher",
                }),
            );

            // Bindings
            class.bindTemplateChildPrivate("dialog", .{});
            class.bindTemplateChildPrivate("search", .{});
            class.bindTemplateChildPrivate("view", .{});
            class.bindTemplateChildPrivate("model", .{});
            class.bindTemplateChildPrivate("filter_model", .{});
            class.bindTemplateChildPrivate("show_splits", .{});

            // Template Callbacks
            class.bindTemplateCallback("closed", &dialogClosed);
            class.bindTemplateCallback("search_stopped", &searchStopped);
            class.bindTemplateCallback("search_activated", &searchActivated);
            class.bindTemplateCallback("row_activated", &rowActivated);
            class.bindTemplateCallback("show_splits_toggled", &showSplitsToggled);

            // Virtual methods
            gobject.Object.virtual_methods.dispose.implement(class, &dispose);
        }

        pub const as = C.Class.as;
        pub const bindTemplateChildPrivate = C.Class.bindTemplateChildPrivate;
        pub const bindTemplateCallback = C.Class.bindTemplateCallback;
    };
};

/// Object that wraps around a single tab shown in the switcher.
///
/// As GTK list models only accept objects that are within the GObject
/// hierarchy, we have to construct a wrapper to be easily consumed by
/// the list model.
const TabSwitcherItem = extern struct {
    pub const Self = @This();
    pub const Parent = gobject.Object;
    parent: Parent,

    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "GhosttyTabSwitcherItem",
        .instanceInit = &init,
        .classInit = Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    const properties = struct {
        pub const title = struct {
            pub const name = "title";
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
                            .getter = propGetTitle,
                            .getter_transfer = .none,
                        },
                    ),
                },
            );
        };

        pub const @"split-count" = struct {
            pub const name = "split-count";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                c_uint,
                .{
                    .minimum = 0,
                    .maximum = std.math.maxInt(c_uint),
                    .default = 0,
                    .accessor = gobject.ext.privateFieldAccessor(
                        Self,
                        Private,
                        &Private.offset,
                        "split_count",
                    ),
                },
            );
        };

        pub const @"split-count-label" = struct {
            pub const name = "split-count-label";
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
                            .getter = propGetSplitCountLabel,
                            .getter_transfer = .none,
                        },
                    ),
                },
            );
        };
    };

    const Private = struct {
        /// The underlying tab page this item represents. Not owned/reffed;
        /// the switcher is short-lived and modal so the tab view outlives
        /// it in all normal usage.
        page: ?*adw.TabPage = null,

        arena: ArenaAllocator,

        title: ?[:0]const u8 = null,
        split_count: c_uint = 0,
        split_count_label: ?[:0]const u8 = null,

        pub var offset: c_int = 0;
    };

    /// Create a new tab switcher item wrapping the given tab page.
    pub fn new(page: *adw.TabPage, title: [:0]const u8, split_count: u32) *Self {
        const self = gobject.ext.newInstance(Self, .{});

        const priv = self.private();
        const alloc = priv.arena.allocator();

        priv.page = page;
        priv.split_count = split_count;
        priv.title = alloc.dupeZ(u8, title) catch null;
        priv.split_count_label = label: {
            if (split_count == 0) break :label alloc.dupeZ(u8, "") catch null;
            break :label std.fmt.allocPrintSentinel(
                alloc,
                "{d} split{s}",
                .{ split_count, if (split_count == 1) "" else "s" },
                0,
            ) catch null;
        };

        return self;
    }

    fn init(self: *Self, _: *Class) callconv(.c) void {
        const priv = self.private();
        priv.arena = .init(Application.default().allocator());
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

    fn propGetTitle(self: *Self) ?[:0]const u8 {
        return self.private().title;
    }

    fn propGetSplitCountLabel(self: *Self) ?[:0]const u8 {
        return self.private().split_count_label;
    }

    /// Get the tab page this item represents.
    pub fn getPage(self: *Self) ?*adw.TabPage {
        return self.private().page;
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
            gobject.ext.registerProperties(class, &.{
                properties.title.impl,
                properties.@"split-count".impl,
                properties.@"split-count-label".impl,
            });

            gobject.Object.virtual_methods.finalize.implement(class, &finalize);
        }
    };
};
