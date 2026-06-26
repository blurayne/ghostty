//! Config editor window — a native GTK4/Adwaita window that lets users
//! browse and edit Ghostty's configuration fields.
//!
//! Phase 2: read-only viewer with type-dispatched edit widgets in Phase 3.
//! Phase 3: type-dispatched edit widgets via SignalListItemFactory.

const std = @import("std");

const adw = @import("adw");
const gio = @import("gio");
const gobject = @import("gobject");
const gtk = @import("gtk");

const build_config = @import("../../../build_config.zig");
const configpkg = @import("../../../config.zig");
const metadata = configpkg.metadata;
const gresource = @import("../build/gresource.zig");
const Common = @import("../class.zig").Common;
const Application = @import("application.zig").Application;
const ConfigEntryObject = @import("config_entry_object.zig").ConfigEntryObject;

const log = std.log.scoped(.gtk_ghostty_config_editor_window);

pub const ConfigEditorWindow = extern struct {
    const Self = @This();
    parent_instance: Parent,
    pub const Parent = adw.ApplicationWindow;
    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "GhosttyConfigEditorWindow",
        .instanceInit = &init,
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    pub const properties = struct {};
    pub const signals = struct {};

    const Private = struct {
        /// The GListStore holding all ConfigEntryObject items.
        entry_store: *gio.ListStore,

        /// The filter list model (wraps entry_store with search filter).
        filter_model: *gtk.FilterListModel,

        /// The string filter connected to the search entry.
        string_filter: *gtk.StringFilter,

        /// The search entry widget (bound from template).
        search_entry: *gtk.SearchEntry,

        /// The list view widget (bound from template).
        config_list: *gtk.ListView,

        /// Whether to instantly apply changes on widget edit.
        instant_reload: bool = true,

        /// Whether to persist changes to disk on apply.
        persist: bool = false,

        pub var offset: c_int = 0;
    };

    //---------------------------------------------------------------
    // Construction

    pub fn new(app: *Application) *Self {
        return gobject.ext.newInstance(Self, .{
            .application = app.as(adw.Application),
        });
    }

    pub fn present(self: *Self) void {
        self.as(gtk.Window).present();
    }

    //---------------------------------------------------------------
    // Virtual Methods

    fn init(self: *Self, _: *Class) callconv(.c) void {
        gtk.Widget.initTemplate(self.as(gtk.Widget));

        if (comptime build_config.is_debug) {
            self.as(gtk.Widget).addCssClass("devel");
        }

        self.as(gtk.Window).setIconName(build_config.bundle_id);

        const priv = self.private();

        // ------------------------------------------------------------------
        // Populate the list store from metadata + current config values.
        const app = Application.default();
        const alloc = app.allocator();

        // Get a snapshot of the live config to read current values.
        // getConfig() returns a ref-counted wrapper; we unref after populating.
        const config_wrapper = app.getConfig();
        defer config_wrapper.unref();
        const live_config = config_wrapper.get();

        // We iterate over Config struct fields at comptime to be able to use
        // @field() with comptime-known names, then match to our metadata array.
        @setEvalBranchQuota(100_000);
        comptime var meta_idx: usize = 0;
        inline for (@typeInfo(configpkg.Config).@"struct".fields) |struct_field| {
            // Skip internal fields (name starts with '_').
            if (comptime struct_field.name[0] == '_') continue;

            // Serialize the current value for this field.
            var buf: std.Io.Writer.Allocating = .init(alloc);
            defer buf.deinit();

            configpkg.formatEntry(
                struct_field.type,
                struct_field.name,
                @field(live_config.*, struct_field.name),
                &buf.writer,
            ) catch {};

            // The formatter outputs "key = value\n"; extract just the value part.
            const written = buf.written();
            const value_str: []const u8 = value_str: {
                if (std.mem.indexOf(u8, written, " = ")) |sep| {
                    const raw = written[sep + 3 ..];
                    // Trim trailing newline.
                    break :value_str std.mem.trimRight(u8, raw, "\n");
                }
                break :value_str written;
            };

            const entry = ConfigEntryObject.new(meta_idx, value_str);
            defer entry.unref();
            priv.entry_store.append(entry.as(gobject.Object));

            meta_idx += 1;
        }

        // ------------------------------------------------------------------
        // Wire up search filter.
        // The filter is already created in initTemplate from the blueprint;
        // here we just ensure the search-changed signal does a refilter.
        // (Signal connections happen via template callbacks below.)
    }

    fn dispose(self: *Self) callconv(.c) void {
        const priv = self.private();

        // Clear the store so the list items are released.
        priv.entry_store.removeAll();

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
    // Template Callbacks

    /// Called when the search text changes — refilter the list.
    fn onSearchChanged(
        search: *gtk.SearchEntry,
        self: *Self,
    ) callconv(.c) void {
        const priv = self.private();
        _ = search;
        // gtk.FilterListModel refilters automatically when the filter changes
        // (our StringFilter is bound to search_entry.text via the blueprint).
        @as(*gtk.Filter, @alignCast(@ptrCast(priv.string_filter))).changed(.different);
    }

    /// Toggle instant-reload behaviour.
    fn onInstantReloadToggled(
        button: *gtk.CheckButton,
        self: *Self,
    ) callconv(.c) void {
        self.private().instant_reload = button.getActive() != 0;
    }

    /// Toggle persist-to-disk behaviour.
    fn onPersistToggled(
        button: *gtk.CheckButton,
        self: *Self,
    ) callconv(.c) void {
        self.private().persist = button.getActive() != 0;
    }

    //---------------------------------------------------------------
    // Phase 3 — List factory setup
    //
    // We use a SignalListItemFactory rather than BuilderListItemFactory so that
    // we can create type-specific widgets per row in Zig code.
    //
    // Row layout (all inside a Gtk.Box horizontal):
    //
    //   [info_box (vertical, hexpand)]   [edit_box (vertical)]
    //     key_label (monospace)            reset_btn
    //     doc_label (subtitle)             <edit widget>
    //
    // The edit_box is the LAST child of the outer row_box. On bind/unbind,
    // we simply replace the edit_box's first child (the value widget).

    fn factorySetup(
        _: *gtk.SignalListItemFactory,
        list_item_obj: *gobject.Object,
        _: *Self,
    ) callconv(.c) void {
        const list_item = gobject.ext.cast(gtk.ListItem, list_item_obj) orelse return;

        // Outer horizontal box.
        const row_box = gtk.Box.new(.horizontal, 12);
        row_box.as(gtk.Widget).setMarginTop(8);
        row_box.as(gtk.Widget).setMarginBottom(8);
        row_box.as(gtk.Widget).setMarginStart(12);
        row_box.as(gtk.Widget).setMarginEnd(12);

        // Info box (left): key name + doc summary.
        const info_box = gtk.Box.new(.vertical, 2);
        info_box.as(gtk.Widget).setHexpand(1);
        info_box.as(gtk.Widget).setValign(.center);

        const key_label = gtk.Label.new("");
        key_label.as(gtk.Widget).setHalign(.start);
        key_label.as(gtk.Widget).addCssClass("monospace");
        key_label.setEllipsize(.end);
        key_label.setMaxWidthChars(40);
        info_box.append(key_label.as(gtk.Widget));

        const doc_label = gtk.Label.new("");
        doc_label.as(gtk.Widget).setHalign(.start);
        doc_label.as(gtk.Widget).addCssClass("caption");
        doc_label.as(gtk.Widget).addCssClass("dim-label");
        doc_label.setEllipsize(.end);
        doc_label.setMaxWidthChars(60);
        info_box.append(doc_label.as(gtk.Widget));

        // Edit box (right): placeholder for the value widget.
        // The edit widget will be prepended in factoryBind.
        const edit_box = gtk.Box.new(.horizontal, 4);
        edit_box.as(gtk.Widget).setValign(.center);

        // Reset button.
        const reset_btn = gtk.Button.newFromIconName("edit-undo-symbolic");
        reset_btn.as(gtk.Widget).setTooltipText("Reset to default");
        reset_btn.as(gtk.Widget).addCssClass("flat");
        reset_btn.as(gtk.Widget).setValign(.center);
        edit_box.append(reset_btn.as(gtk.Widget));

        row_box.append(info_box.as(gtk.Widget));
        row_box.append(edit_box.as(gtk.Widget));

        list_item.setChild(row_box.as(gtk.Widget));
    }

    fn factoryBind(
        _: *gtk.SignalListItemFactory,
        list_item_obj: *gobject.Object,
        self: *Self,
    ) callconv(.c) void {
        const list_item = gobject.ext.cast(gtk.ListItem, list_item_obj) orelse return;
        // getItem() is transfer-none; do not unref — the model owns the entry.
        const entry_obj = list_item.getItem() orelse return;
        const entry = gobject.ext.cast(ConfigEntryObject, entry_obj) orelse return;

        const row_box_widget = list_item.getChild() orelse return;
        const row_box = gobject.ext.cast(gtk.Box, row_box_widget) orelse return;

        const field = entry.getFieldMeta();

        // Find the info_box (first child) and edit_box (last child).
        const info_box_widget = row_box.as(gtk.Widget).getFirstChild() orelse return;
        const info_box = gobject.ext.cast(gtk.Box, info_box_widget) orelse return;
        const edit_box_widget = row_box.as(gtk.Widget).getLastChild() orelse return;
        const edit_box = gobject.ext.cast(gtk.Box, edit_box_widget) orelse return;

        // Update key label (first child of info_box).
        if (info_box.as(gtk.Widget).getFirstChild()) |lbl_w| {
            if (gobject.ext.cast(gtk.Label, lbl_w)) |lbl| {
                // field.name is [:0]const u8 — pass directly.
                lbl.setLabel(field.name);
            }
        }

        // Update doc label (last child of info_box).
        if (info_box.as(gtk.Widget).getLastChild()) |lbl_w| {
            if (gobject.ext.cast(gtk.Label, lbl_w)) |lbl| {
                if (entry.propGetDocSummary()) |summary| {
                    lbl.setLabel(summary);
                    lbl.as(gtk.Widget).setVisible(1);
                } else {
                    lbl.setLabel(&.{});
                    lbl.as(gtk.Widget).setVisible(0);
                }
            }
        }

        // Remove the old edit widget from edit_box.
        // The reset button is the LAST child; the edit widget is first.
        // In factorySetup the reset button is the only child, so we only
        // remove when there are 2+ children.
        const first_child = edit_box.as(gtk.Widget).getFirstChild();
        const last_child = edit_box.as(gtk.Widget).getLastChild();
        if (first_child) |fc| {
            if (last_child) |lc| {
                if (@intFromPtr(fc) != @intFromPtr(lc)) {
                    // There's a previously bound edit widget; remove it.
                    edit_box.remove(fc);
                }
            }
        }

        // Build and prepend the new edit widget.
        const current_value: [:0]const u8 = entry.getCurrentValue() orelse "";
        const edit_widget = buildValueWidget(self, entry, field, current_value);
        edit_box.prepend(edit_widget);

        // Highlight dirty rows.
        if (entry.getDirty()) {
            row_box.as(gtk.Widget).addCssClass("modified");
        } else {
            row_box.as(gtk.Widget).removeCssClass("modified");
        }
    }

    fn factoryUnbind(
        _: *gtk.SignalListItemFactory,
        list_item_obj: *gobject.Object,
        _: *Self,
    ) callconv(.c) void {
        const list_item = gobject.ext.cast(gtk.ListItem, list_item_obj) orelse return;
        const row_box_widget = list_item.getChild() orelse return;
        const row_box = gobject.ext.cast(gtk.Box, row_box_widget) orelse return;

        // Find the edit_box (last child of row_box) and remove the edit widget.
        const edit_box_widget = row_box.as(gtk.Widget).getLastChild() orelse return;
        const edit_box = gobject.ext.cast(gtk.Box, edit_box_widget) orelse return;

        // Remove the edit widget (first child) if there are 2+ children.
        const first_child = edit_box.as(gtk.Widget).getFirstChild();
        const last_child = edit_box.as(gtk.Widget).getLastChild();
        if (first_child) |fc| {
            if (last_child) |lc| {
                if (@intFromPtr(fc) != @intFromPtr(lc)) {
                    edit_box.remove(fc);
                }
            }
        }
    }

    //---------------------------------------------------------------
    // Phase 3 — Widget builder

    /// Build the appropriate edit widget for a config field based on its kind.
    fn buildValueWidget(
        self: *Self,
        entry: *ConfigEntryObject,
        field: metadata.FieldMeta,
        current_raw: [:0]const u8,
    ) *gtk.Widget {
        _ = self;

        switch (field.kind) {
            .bool => {
                const sw = gtk.Switch.new();
                sw.as(gtk.Widget).setValign(.center);
                sw.setActive(@intFromBool(std.mem.eql(u8, current_raw, "true")));
                _ = gtk.Switch.signals.state_set.connect(
                    sw,
                    *ConfigEntryObject,
                    onSwitchStateSet,
                    entry,
                    .{},
                );
                return sw.as(gtk.Widget);
            },

            .optional_bool => {
                const str_list = gtk.StringList.new(null);
                str_list.append("default");
                str_list.append("true");
                str_list.append("false");
                const dd = gtk.DropDown.new(str_list.as(gio.ListModel), null);
                dd.as(gtk.Widget).setValign(.center);
                // Select the right item.
                const selected: c_uint = if (std.mem.eql(u8, current_raw, "true"))
                    1
                else if (std.mem.eql(u8, current_raw, "false"))
                    2
                else
                    0;
                dd.setSelected(selected);
                _ = gobject.Object.signals.notify.connect(
                    dd.as(gobject.Object),
                    *ConfigEntryObject,
                    onDropDownSelectedChanged,
                    entry,
                    .{ .detail = "selected" },
                );
                return dd.as(gtk.Widget);
            },

            .int => {
                const adj = gtk.Adjustment.new(0, -2147483648, 2147483647, 1, 10, 0);
                const spin = gtk.SpinButton.new(adj, 1, 0);
                spin.as(gtk.Widget).setValign(.center);
                // Parse the current value.
                const v = std.fmt.parseInt(i64, current_raw, 10) catch 0;
                spin.setValue(@floatFromInt(v));
                _ = gtk.SpinButton.signals.value_changed.connect(
                    spin,
                    *ConfigEntryObject,
                    onSpinButtonChanged,
                    entry,
                    .{},
                );
                return spin.as(gtk.Widget);
            },

            .float => {
                const adj = gtk.Adjustment.new(0, -1e9, 1e9, 0.5, 1, 0);
                const spin = gtk.SpinButton.new(adj, 0.5, 1);
                spin.as(gtk.Widget).setValign(.center);
                const v = std.fmt.parseFloat(f64, current_raw) catch 0;
                spin.setValue(v);
                _ = gtk.SpinButton.signals.value_changed.connect(
                    spin,
                    *ConfigEntryObject,
                    onSpinButtonChanged,
                    entry,
                    .{},
                );
                return spin.as(gtk.Widget);
            },

            .@"enum" => {
                const str_list = gtk.StringList.new(null);
                var selected: c_uint = 0;
                for (field.variants, 0..) |v, i| {
                    // v.name is [:0]const u8 so .ptr is [*:0]const u8.
                    str_list.append(v.name.ptr);
                    if (std.mem.eql(u8, current_raw, v.name)) {
                        selected = @intCast(i);
                    }
                }
                const dd = gtk.DropDown.new(str_list.as(gio.ListModel), null);
                dd.as(gtk.Widget).setValign(.center);
                dd.setSelected(selected);
                _ = gobject.Object.signals.notify.connect(
                    dd.as(gobject.Object),
                    *ConfigEntryObject,
                    onDropDownSelectedChanged,
                    entry,
                    .{ .detail = "selected" },
                );
                return dd.as(gtk.Widget);
            },

            .packed_flags => {
                const box = gtk.Box.new(.horizontal, 4);
                box.as(gtk.Widget).setValign(.center);
                for (field.variants) |v| {
                    const cb = gtk.CheckButton.new();
                    // v.name is [:0]const u8.
                    cb.setLabel(v.name);
                    // Active if the raw value contains the flag name (no "no-" prefix).
                    const flag_found = std.mem.indexOf(u8, current_raw, v.name) != null;
                    const is_negated = if (std.mem.indexOf(u8, current_raw, v.name)) |pos|
                        (pos >= 3 and std.mem.eql(u8, current_raw[pos - 3 .. pos], "no-"))
                    else
                        false;
                    cb.setActive(@intFromBool(flag_found and !is_negated));
                    _ = gtk.CheckButton.signals.toggled.connect(
                        cb,
                        *ConfigEntryObject,
                        onCheckButtonToggled,
                        entry,
                        .{},
                    );
                    box.append(cb.as(gtk.Widget));
                }
                return box.as(gtk.Widget);
            },

            .string, .repeatable, .complex => {
                const entry_widget = gtk.Entry.new();
                entry_widget.as(gtk.Widget).setValign(.center);
                entry_widget.as(gtk.Widget).setHexpand(0);
                // current_raw is [:0]const u8, so setText is safe.
                entry_widget.as(gtk.Editable).setText(current_raw);
                _ = gtk.Entry.signals.activate.connect(
                    entry_widget,
                    *ConfigEntryObject,
                    onEntryActivated,
                    entry,
                    .{},
                );
                return entry_widget.as(gtk.Widget);
            },
        }
    }

    //---------------------------------------------------------------
    // Widget signal handlers (Phase 3)

    fn onSwitchStateSet(
        sw: *gtk.Switch,
        state: c_int,
        entry: *ConfigEntryObject,
    ) callconv(.c) c_int {
        entry.setCurrentValue(if (state != 0) "true" else "false");
        entry.setDirty(true);
        _ = sw;
        return 0; // allow GTK to update the visual state
    }

    fn onDropDownSelectedChanged(
        dd: *gobject.Object,
        _: *gobject.ParamSpec,
        entry: *ConfigEntryObject,
    ) callconv(.c) void {
        const dropdown = gobject.ext.cast(gtk.DropDown, dd) orelse return;
        const selected = dropdown.getSelected();
        const model = dropdown.getModel() orelse return;
        const str_obj_ = gobject.ext.cast(gtk.StringObject, @as(*gobject.Object, @alignCast(@ptrCast(model.getItem(selected) orelse return))));
        const str_obj = str_obj_ orelse return;
        const text = str_obj.getString();
        entry.setCurrentValue(std.mem.span(text));
        entry.setDirty(true);
    }

    fn onSpinButtonChanged(
        spin: *gtk.SpinButton,
        entry: *ConfigEntryObject,
    ) callconv(.c) void {
        const val = spin.getValue();
        var buf: [64]u8 = undefined;
        // Format as integer if it looks like one, float otherwise.
        const s = if (val == @round(val))
            std.fmt.bufPrint(&buf, "{d}", .{@as(i64, @intFromFloat(val))}) catch return
        else
            std.fmt.bufPrint(&buf, "{d:.1}", .{val}) catch return;
        entry.setCurrentValue(s);
        entry.setDirty(true);
    }

    fn onCheckButtonToggled(
        _: *gtk.CheckButton,
        entry: *ConfigEntryObject,
    ) callconv(.c) void {
        // Mark dirty; the parent row's reset button can restore the value.
        entry.setDirty(true);
    }

    fn onEntryActivated(
        entry_widget: *gtk.Entry,
        entry: *ConfigEntryObject,
    ) callconv(.c) void {
        const text = entry_widget.as(gtk.Editable).getText();
        entry.setCurrentValue(std.mem.span(text));
        entry.setDirty(true);
    }

    //---------------------------------------------------------------
    // Boilerplate

    const C = Common(Self, Private);
    pub const as = C.as;
    pub const ref = C.ref;
    pub const refSink = C.refSink;
    pub const unref = C.unref;
    pub const private = C.private;

    pub const Class = extern struct {
        parent_class: Parent.Class,
        var parent: *Parent.Class = undefined;
        pub const Instance = Self;

        fn init(class: *Class) callconv(.c) void {
            gobject.ext.ensureType(ConfigEntryObject);
            gtk.Widget.Class.setTemplateFromResource(
                class.as(gtk.Widget.Class),
                comptime gresource.blueprint(.{
                    .major = 1,
                    .minor = 5,
                    .name = "config-editor-window",
                }),
            );

            // Template bindings from blueprint.
            class.bindTemplateChildPrivate("search_entry", .{});
            class.bindTemplateChildPrivate("config_list", .{});
            class.bindTemplateChildPrivate("entry_store", .{});
            class.bindTemplateChildPrivate("filter_model", .{});
            class.bindTemplateChildPrivate("string_filter", .{});

            // Template callbacks.
            class.bindTemplateCallback("on_search_changed", &onSearchChanged);
            class.bindTemplateCallback("on_instant_reload_toggled", &onInstantReloadToggled);
            class.bindTemplateCallback("on_persist_toggled", &onPersistToggled);
            class.bindTemplateCallback("factory_setup", &factorySetup);
            class.bindTemplateCallback("factory_bind", &factoryBind);
            class.bindTemplateCallback("factory_unbind", &factoryUnbind);

            // Virtual methods.
            gobject.Object.virtual_methods.dispose.implement(class, &dispose);
        }

        pub const as = C.Class.as;
        pub const bindTemplateChildPrivate = C.Class.bindTemplateChildPrivate;
        pub const bindTemplateCallback = C.Class.bindTemplateCallback;
    };
};
