//! The split focus dialog: a searchable tree of every window, tab and
//! split in the application. Activating any row focuses that terminal;
//! window and tab rows resolve to their currently-active split.
//!
//! There are no unit tests in this file. Everything here needs a live GTK
//! application with real windows to mean anything, which a test binary has
//! none of. The pure parts live in `split_focus_match.zig`, which is
//! tested; the manual checks on the dialog are what exercise the rest.

const std = @import("std");

const adw = @import("adw");
const gdk = @import("gdk");
const gio = @import("gio");
const gobject = @import("gobject");
const gtk = @import("gtk");
const pango = @import("pango");

const gresource = @import("../build/gresource.zig");
const Common = @import("../class.zig").Common;
const Application = @import("application.zig").Application;
const Surface = @import("surface.zig").Surface;
const Window = @import("window.zig").Window;
const SplitFocusItem = @import("split_focus_item.zig").SplitFocusItem;
const SplitFocusFilter = @import("split_focus_filter.zig").SplitFocusFilter;
const match = @import("split_focus_match.zig");

const log = std.log.scoped(.gtk_ghostty_split_focus);

/// `GTK_INVALID_LIST_POSITION`. The generated bindings do not export the
/// constant, only mention it in doc comments.
const invalid_position: c_uint = std.math.maxInt(c_uint);

/// How far Page Up/Page Down move the selection. GtkListView derives its
/// own page size from the visible height, which we cannot ask for here
/// without reaching into the scrolled window's adjustment; a fixed jump
/// is predictable and close enough.
const page_step: c_uint = 10;

/// Indent per tree level, in pixels, plus the base margin.
const indent_px: c_uint = 16;
const margin_px: c_uint = 8;

pub const SplitFocus = extern struct {
    const Self = @This();
    parent_instance: Parent,
    pub const Parent = adw.Bin;
    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "GhosttySplitFocus",
        .instanceInit = &init,
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    const Private = struct {
        /// The dialog object containing the UI. This is the blueprint's
        /// top-level object: it is deliberately NOT a template wrapped in
        /// this Bin. A wrapper parents the dialog to the Bin, which stops
        /// `adw_dialog_present` from reparenting it into the window's
        /// AdwDialogHost, and the app takes a modal grab it never
        /// releases.
        dialog: *adw.Dialog,

        /// The search input text field. It keeps focus for the whole life
        /// of the dialog; the list is driven through the key controller
        /// installed on it in `init`.
        search: *gtk.SearchEntry,

        /// The view containing each row.
        view: *gtk.ListView,

        /// The selection model over the filtered rows.
        model: *gtk.SingleSelection,

        /// Wraps the tree model. Its model is set in `populate` and its
        /// filter in `init`.
        filter_model: *gtk.FilterListModel,

        /// "Hide non-matching". When off the whole tree stays visible and
        /// only the highlight marks matches.
        hide_unmatched: *gtk.CheckButton,

        /// Owned; released in `finalize`. Also held by `filter_model`, but
        /// we keep our own reference so the search handlers never have to
        /// go fishing for it.
        filter: *SplitFocusFilter,

        /// Owned; released in `finalize`. Rows are built in Zig because
        /// blueprint cannot express per-row Pango attributes.
        factory: *gtk.SignalListItemFactory,

        pub var offset: c_int = 0;
    };

    /// Create a new split focus dialog. The caller owns a reference.
    pub fn new() *Self {
        const self = gobject.ext.newInstance(Self, .{});

        // Sink ourselves so that we aren't floating anymore. We unref
        // ourselves when the dialog is closed.
        _ = self.refSink();

        // Bump the ref so that the caller has a reference.
        return self.ref();
    }

    //---------------------------------------------------------------
    // Virtual Methods

    fn init(self: *Self, _: *Class) callconv(.c) void {
        gtk.Widget.initTemplate(self.as(gtk.Widget));

        const priv = self.private();

        // Every field of Private is either a template child, written by
        // `initTemplate` above, or written here. None of them has a
        // non-zero Zig default, so the zero-filled private data GObject
        // hands out is not a trap in this class -- but it is one field
        // away from being one.

        // Our own filter. The model side of the chain is only completed in
        // `populate`, where the tree gets built.
        priv.filter = SplitFocusFilter.new();
        priv.filter_model.setFilter(priv.filter.as(gtk.Filter));

        priv.factory = gtk.SignalListItemFactory.new();
        _ = gtk.SignalListItemFactory.signals.setup.connect(
            priv.factory,
            *Self,
            setupItem,
            self,
            .{},
        );
        _ = gtk.SignalListItemFactory.signals.bind.connect(
            priv.factory,
            *Self,
            bindItem,
            self,
            .{},
        );
        priv.view.setFactory(priv.factory.as(gtk.ListItemFactory));

        // Up/Down/Page navigate the list while the search entry keeps
        // focus, so typing never has to be interrupted to move.
        const keys = gtk.EventControllerKey.new();
        _ = gtk.EventControllerKey.signals.key_pressed.connect(
            keys,
            *Self,
            keyPressed,
            self,
            .{},
        );
        priv.search.as(gtk.Widget).addController(keys.as(gtk.EventController));
    }

    fn dispose(self: *Self) callconv(.c) void {
        gtk.Widget.disposeTemplate(
            self.as(gtk.Widget),
            getGObjectType(),
        );

        gobject.Object.virtual_methods.dispose.call(
            Class.parent,
            self.as(Parent),
        );
    }

    fn finalize(self: *Self) callconv(.c) void {
        const priv = self.private();

        // These are released here rather than in `dispose` because
        // `dispose` can run more than once and these are plain owned
        // references, not a cycle anyone can break.
        priv.filter.unref();
        priv.factory.unref();

        gobject.Object.virtual_methods.finalize.call(
            Class.parent,
            self.as(Parent),
        );
    }

    //---------------------------------------------------------------
    // Signal Handlers

    fn dialogClosed(_: *adw.Dialog, self: *Self) callconv(.c) void {
        self.unref();
    }

    fn searchStopped(_: *gtk.SearchEntry, self: *Self) callconv(.c) void {
        // ESC was pressed - close the dialog.
        self.close();
    }

    fn searchActivated(_: *gtk.SearchEntry, self: *Self) callconv(.c) void {
        self.activate(self.private().model.getSelected());
    }

    fn searchChanged(entry: *gtk.SearchEntry, self: *Self) callconv(.c) void {
        const priv = self.private();
        const text = std.mem.span(entry.as(gtk.Editable).getText());
        priv.filter.setNeedle(text);

        // The highlight moved even when the visible rows did not, which is
        // the whole point of the unfiltered mode.
        self.refreshRows();

        // Selection holds while the selected row still passes the filter;
        // otherwise fall to the first visible row so Enter always does
        // something.
        if (!self.selectionStillVisible()) self.selectFirst();
    }

    fn hideUnmatchedToggled(button: *gtk.CheckButton, self: *Self) callconv(.c) void {
        self.private().filter.setEnabled(button.getActive() != 0);
    }

    fn rowActivated(_: *gtk.ListView, pos: c_uint, self: *Self) callconv(.c) void {
        self.activate(pos);
    }

    /// Drive the list from the search entry. Returning 1 consumes the key
    /// so the entry does not also move its cursor.
    fn keyPressed(
        _: *gtk.EventControllerKey,
        keyval: c_uint,
        _: c_uint,
        _: gdk.ModifierType,
        self: *Self,
    ) callconv(.c) c_int {
        const priv = self.private();

        const n = priv.model.as(gio.ListModel).getNItems();
        if (n == 0) return 0;
        const last = n - 1;

        const cur = priv.model.getSelected();
        const next: c_uint = switch (keyval) {
            gdk.KEY_Up => if (cur == invalid_position or cur == 0)
                0
            else
                cur - 1,

            gdk.KEY_Down => if (cur == invalid_position)
                0
            else
                @min(cur + 1, last),

            gdk.KEY_Page_Up => if (cur == invalid_position or cur < page_step)
                0
            else
                cur - page_step,

            gdk.KEY_Page_Down => if (cur == invalid_position)
                0
            else
                @min(cur + page_step, last),

            // Home and End are deliberately absent. Up/Down/Page do
            // nothing in a single-line entry, so taking them costs the
            // user nothing, but every Home/End -- plain, with Ctrl, with
            // Shift -- moves or extends the text cursor. Jumping to the
            // first or last row is not worth breaking editing in the box
            // the user is typing into.
            else => return 0,
        };

        priv.model.setSelected(next);
        priv.view.scrollTo(next, .{}, null);
        return 1;
    }

    //---------------------------------------------------------------
    // Public API

    /// Show or hide the split focus dialog. When shown it is modal over
    /// the given window and populated with the whole application tree.
    pub fn toggle(self: *Self, window: *Window) void {
        const priv = self.private();

        // If the dialog has been shown, close it.
        if (priv.dialog.as(gtk.Widget).getRealized() != 0) {
            self.close();
            return;
        }

        self.populate();

        // The checkbox starts from the config, and the filter has to be
        // told directly: `setActive` only emits `toggled` if the state
        // actually changed, and the default is already checked.
        const hide = hide: {
            const config = window.getConfig() orelse break :hide true;
            break :hide config.get().@"split-focus-hide-unmatched";
        };
        priv.hide_unmatched.setActive(@intFromBool(hide));
        priv.filter.setEnabled(hide);

        // Preselect the row for the surface the user is currently in, so
        // the dialog opens showing where they are.
        self.selectSurface(window.getActiveSurface());

        priv.dialog.present(window.as(gtk.Widget));

        // Focus stays here for the dialog's whole life.
        _ = priv.search.as(gtk.Widget).grabFocus();

        // Scroll only once presented; before that the view has no size to
        // scroll within.
        const pos = priv.model.getSelected();
        if (pos != invalid_position) priv.view.scrollTo(pos, .{}, null);
    }

    /// Close the split focus dialog.
    pub fn close(self: *Self) void {
        _ = self.private().dialog.close();
    }

    //---------------------------------------------------------------
    // Model

    /// Rebuild the tree from the live widget hierarchy and hand it to the
    /// filter model.
    fn populate(self: *Self) void {
        const priv = self.private();

        const root = SplitFocusItem.buildRoot(
            Application.default().as(gtk.Application),
        );
        pruneQuickTerminals(root);

        // Tree over the item store; splits have no child model, which is
        // what makes them leaves. `new` takes ownership of `root`.
        const tree = gtk.TreeListModel.new(
            root.as(gio.ListModel),
            0, // passthrough: false, so rows are GtkTreeListRow
            1, // autoexpand: true, "always show everything"
            &createChildModel,
            null,
            null,
        );
        defer tree.unref();

        priv.filter_model.setModel(tree.as(gio.ListModel));
    }

    /// Drop the quick terminal from the tree.
    ///
    /// It is a transient overlay summoned by a hotkey and dismissed on
    /// focus loss, not a place you navigate to. Its row would name a
    /// window the user cannot meaningfully be sent to, and activating it
    /// would fight the overlay's own show/hide logic.
    fn pruneQuickTerminals(root: *gio.ListStore) void {
        const model = root.as(gio.ListModel);

        // Backwards: removing shifts everything after the index down.
        var i: c_uint = model.getNItems();
        while (i > 0) {
            i -= 1;

            const obj = model.getObject(i) orelse continue;
            defer obj.unref();
            const item = gobject.ext.cast(SplitFocusItem, obj) orelse continue;

            // getWindow hands back a strong reference, unlike most of the
            // apprt's accessors.
            const win = item.getWindow() orelse continue;
            defer win.unref();

            if (win.isQuickTerminal()) root.remove(i);
        }
    }

    fn createChildModel(item: *gobject.Object, _: ?*anyopaque) callconv(.c) ?*gio.ListModel {
        const focus_item = gobject.ext.cast(SplitFocusItem, item) orelse return null;
        const children = focus_item.getChildren() orelse return null;

        // Transfer full: the tree model takes the reference we return, and
        // `getChildren` does not ref.
        children.ref();
        return children.as(gio.ListModel);
    }

    //---------------------------------------------------------------
    // Selection

    /// Select the row for the given surface, if the tree contains it.
    fn selectSurface(self: *Self, surface_: ?*Surface) void {
        const surface = surface_ orelse return;
        const priv = self.private();

        const model = priv.model.as(gio.ListModel);
        const n = model.getNItems();
        var i: c_uint = 0;
        while (i < n) : (i += 1) {
            const obj = model.getObject(i) orelse continue;
            defer obj.unref();
            const row = gobject.ext.cast(gtk.TreeListRow, obj) orelse continue;
            const inner = row.getItem() orelse continue;
            defer inner.unref();
            const item = gobject.ext.cast(SplitFocusItem, inner) orelse continue;

            // Only a split row *is* a surface; a window or tab row merely
            // resolves to one, and selecting those would put the cursor on
            // a container two levels up from where the user actually is.
            if (item.getKind() != .split) continue;

            // resolveSurface returns a borrow, not a reference.
            if (item.resolveSurface() != surface) continue;

            priv.model.setSelected(i);
            return;
        }
    }

    fn selectionStillVisible(self: *Self) bool {
        const priv = self.private();
        const pos = priv.model.getSelected();
        if (pos == invalid_position) return false;
        return pos < priv.model.as(gio.ListModel).getNItems();
    }

    fn selectFirst(self: *Self) void {
        const priv = self.private();
        if (priv.model.as(gio.ListModel).getNItems() == 0) return;
        priv.model.setSelected(0);
        priv.view.scrollTo(0, .{}, null);
    }

    /// Force every visible row to rebind.
    ///
    /// Needed in both modes. A row only rebinds when the model says it
    /// changed, and typing changes which characters are highlighted, not
    /// which rows exist -- with hiding off nothing changes at all, and
    /// with it on the rows that survive the new needle are not part of the
    /// `items-changed` either. Both would keep the previous needle's
    /// highlight. Swapping the factory out and back is the cheapest way to
    /// say "redo the rows" without disturbing the model, and so without
    /// disturbing the selection.
    fn refreshRows(self: *Self) void {
        const priv = self.private();
        priv.view.setFactory(null);
        priv.view.setFactory(priv.factory.as(gtk.ListItemFactory));
    }

    //---------------------------------------------------------------
    // Activation

    /// Focus the terminal behind the row at the given position in the
    /// *visible* model, then close.
    fn activate(self: *Self, pos: c_uint) void {
        const priv = self.private();
        if (pos == invalid_position) {
            self.close();
            return;
        }

        // Read from the filtered model, not the source: pos is an index
        // into what the user can actually see.
        const obj = priv.model.as(gio.ListModel).getObject(pos) orelse return;
        defer obj.unref();
        const row = gobject.ext.cast(gtk.TreeListRow, obj) orelse return;
        const inner = row.getItem() orelse return;
        defer inner.unref();
        const item = gobject.ext.cast(SplitFocusItem, inner) orelse return;

        // Close first so the dialog does not linger over the window we
        // are about to focus.
        self.close();

        // The pane may have closed while the dialog was open. Weak refs
        // mean we find out here rather than crashing.
        const surface = item.resolveSurface() orelse {
            log.debug("split focus target no longer exists, ignoring", .{});
            return;
        };

        // Selects the owning tab, focuses the pane and raises the window,
        // in that order. The window is found by walking up from the
        // surface widget rather than from the item, so a tab dragged into
        // another window since the tree was built still lands correctly.
        surface.present();
    }

    //---------------------------------------------------------------
    // Rows

    fn setupItem(
        _: *gtk.SignalListItemFactory,
        list_item_obj: *gobject.Object,
        _: *Self,
    ) callconv(.c) void {
        const list_item = gobject.ext.cast(gtk.ListItem, list_item_obj) orelse return;

        const box = gtk.Box.new(.horizontal, 8);
        box.as(gtk.Widget).setMarginTop(2);
        box.as(gtk.Widget).setMarginBottom(2);
        box.as(gtk.Widget).setMarginEnd(margin_px);

        const title = gtk.Label.new("");
        title.as(gtk.Widget).setHalign(.start);
        title.setXalign(0);
        title.setEllipsize(.end);
        box.append(title.as(gtk.Widget));

        // Ellipsized at the *start*: the interesting end of a path is the
        // last component.
        const pwd = gtk.Label.new("");
        pwd.as(gtk.Widget).setHalign(.start);
        pwd.as(gtk.Widget).setHexpand(1);
        pwd.setXalign(0);
        pwd.setEllipsize(.start);
        pwd.as(gtk.Widget).addCssClass("dim-label");
        box.append(pwd.as(gtk.Widget));

        list_item.setChild(box.as(gtk.Widget));
    }

    fn bindItem(
        _: *gtk.SignalListItemFactory,
        list_item_obj: *gobject.Object,
        self: *Self,
    ) callconv(.c) void {
        const list_item = gobject.ext.cast(gtk.ListItem, list_item_obj) orelse return;

        // `gtk_list_item_get_item` is transfer none;
        // `gtk_tree_list_row_get_item` is transfer full.
        const row_obj = list_item.getItem() orelse return;
        const row = gobject.ext.cast(gtk.TreeListRow, row_obj) orelse return;
        const inner = row.getItem() orelse return;
        defer inner.unref();
        const item = gobject.ext.cast(SplitFocusItem, inner) orelse return;

        const child = list_item.getChild() orelse return;
        const box = gobject.ext.cast(gtk.Box, child) orelse return;
        const title_label = gobject.ext.cast(
            gtk.Label,
            box.as(gtk.Widget).getFirstChild() orelse return,
        ) orelse return;
        const pwd_label = gobject.ext.cast(
            gtk.Label,
            box.as(gtk.Widget).getLastChild() orelse return,
        ) orelse return;

        // Depth is what shows the tree; there are no expanders because
        // every row is always expanded.
        box.as(gtk.Widget).setMarginStart(
            @intCast(margin_px + (row.getDepth() * indent_px)),
        );

        // Borrowed from the filter, and invalidated by the next
        // `setNeedle` -- used here and not kept.
        const needle = self.private().filter.getNeedle() orelse "";

        const title = item.getTitle() orelse "";
        title_label.setText(title.ptr);
        setHighlight(title_label, title, needle);

        if (item.getPwd()) |pwd| {
            pwd_label.setText(pwd.ptr);
            setHighlight(pwd_label, pwd, needle);
            pwd_label.as(gtk.Widget).setVisible(1);
        } else {
            // Window and tab rows, and splits with no known working
            // directory. Hide rather than leave an empty gap.
            pwd_label.setText("");
            pwd_label.setAttributes(null);
            pwd_label.as(gtk.Widget).setVisible(0);
        }
    }

    /// Invert the matched characters of `text` on `label`.
    ///
    /// Attributes rather than markup: terminal titles routinely contain
    /// `&` and `<`, and attributes need no escaping.
    fn setHighlight(label: *gtk.Label, text: []const u8, needle: []const u8) void {
        const range = match.find(text, needle) orelse {
            label.setAttributes(null);
            return;
        };

        const swap = invertedColors(label.as(gtk.Widget));
        const attrs = pango.AttrList.new();
        defer attrs.unref();

        const fg = pango.attrForegroundNew(swap.fg.r, swap.fg.g, swap.fg.b);
        const bg = pango.attrBackgroundNew(swap.bg.r, swap.bg.g, swap.bg.b);

        // Byte offsets, which is what `match.find` returns and what Pango
        // wants -- a character count would slide the highlight on any
        // title with a multi-byte character before the match.
        fg.f_start_index = @intCast(range.start);
        fg.f_end_index = @intCast(range.end);
        bg.f_start_index = @intCast(range.start);
        bg.f_end_index = @intCast(range.end);

        attrs.insert(fg);
        attrs.insert(bg);
        label.setAttributes(attrs);
    }

    const Rgb16 = struct { r: u16, g: u16, b: u16 };
    const Swap = struct { fg: Rgb16, bg: Rgb16 };

    /// The label's own colours, swapped. Pango wants 16-bit channels
    /// while GdkRGBA is 0..1 floats, hence the scaling.
    ///
    /// Reading the *current* colour is what makes this follow light and
    /// dark themes without a hardcoded palette. If a theme ever reports
    /// a fully transparent background -- some do, leaving the parent to
    /// paint it -- fall back to libadwaita's accent pair, which is how
    /// GTK itself draws selected text.
    fn invertedColors(widget: *gtk.Widget) Swap {
        const ctx = widget.getStyleContext();
        var color: gdk.RGBA = undefined;
        ctx.getColor(&color);

        var bg: gdk.RGBA = undefined;
        const have_bg = ctx.lookupColor("theme_bg_color", &bg) != 0;
        if (!have_bg or bg.f_alpha < 0.01) {
            const accent = adw.StyleManager.getDefault().getAccentColorRgba();
            return .{
                .fg = toRgb16(.{
                    .f_red = 1,
                    .f_green = 1,
                    .f_blue = 1,
                    .f_alpha = 1,
                }),
                .bg = toRgb16(accent.*),
            };
        }

        // Swapped: the text colour becomes the background and vice versa.
        return .{ .fg = toRgb16(bg), .bg = toRgb16(color) };
    }

    fn toRgb16(c: gdk.RGBA) Rgb16 {
        return .{
            .r = @intFromFloat(std.math.clamp(c.f_red, 0, 1) * 65535),
            .g = @intFromFloat(std.math.clamp(c.f_green, 0, 1) * 65535),
            .b = @intFromFloat(std.math.clamp(c.f_blue, 0, 1) * 65535),
        };
    }

    //---------------------------------------------------------------

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
            gtk.Widget.Class.setTemplateFromResource(
                class.as(gtk.Widget.Class),
                comptime gresource.blueprint(.{
                    .major = 1,
                    .minor = 5,
                    .name = "split-focus",
                }),
            );

            // Bindings
            class.bindTemplateChildPrivate("dialog", .{});
            class.bindTemplateChildPrivate("search", .{});
            class.bindTemplateChildPrivate("view", .{});
            class.bindTemplateChildPrivate("model", .{});
            class.bindTemplateChildPrivate("filter_model", .{});
            class.bindTemplateChildPrivate("hide_unmatched", .{});

            // Template Callbacks
            class.bindTemplateCallback("closed", &dialogClosed);
            class.bindTemplateCallback("search_stopped", &searchStopped);
            class.bindTemplateCallback("search_activated", &searchActivated);
            class.bindTemplateCallback("search_changed", &searchChanged);
            class.bindTemplateCallback("row_activated", &rowActivated);
            class.bindTemplateCallback("hide_unmatched_toggled", &hideUnmatchedToggled);

            // Virtual methods
            gobject.Object.virtual_methods.dispose.implement(class, &dispose);
            gobject.Object.virtual_methods.finalize.implement(class, &finalize);
        }

        pub const as = C.Class.as;
        pub const bindTemplateChildPrivate = C.Class.bindTemplateChildPrivate;
        pub const bindTemplateCallback = C.Class.bindTemplateCallback;
    };
};
