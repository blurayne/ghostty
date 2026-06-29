//! Config editor window — a native GTK4/Adwaita window that lets users
//! browse and edit Ghostty's configuration fields.
//!
//! Phase 2: read-only viewer with type-dispatched edit widgets in Phase 3.
//! Phase 3: type-dispatched edit widgets via SignalListItemFactory.

const std = @import("std");

const adw = @import("adw");
const gdk = @import("gdk");
const gio = @import("gio");
const glib = @import("glib");
const gobject = @import("gobject");
const gtk = @import("gtk");
const pango = @import("pango");

const build_config = @import("../../../build_config.zig");
const configpkg = @import("../../../config.zig");
const config_edit = @import("../../../config/edit.zig");
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

        /// Custom filter that matches the search text against key-name and,
        /// when search_values_check is active, also against current-value.
        custom_filter: *gtk.CustomFilter,

        /// The search entry widget (bound from template).
        search_entry: *gtk.SearchEntry,

        /// Checkbox: when active, the search also matches current values.
        search_values_check: *gtk.CheckButton,

        /// The list view widget (bound from template).
        config_list: *gtk.ListView,

        /// Toast overlay for success/error notifications.
        toast_overlay: *adw.ToastOverlay,

        /// Whether to instantly apply changes on widget edit.
        instant_reload: bool = true,

        /// Whether to persist changes to disk on apply.
        persist: bool = false,

        // ---- Phase 5: file watcher ----

        /// Path to the config file (null-terminated, heap-allocated).
        /// Set once at window init; freed in dispose.
        config_path: ?[:0]const u8 = null,

        /// Active GIO file monitor, or null if setup failed.
        file_monitor: ?*gio.FileMonitor = null,

        /// Set to true while we are in the middle of writing the config file
        /// ourselves so that the monitor callback can ignore the self-triggered
        /// inotify events.
        writing_file: bool = false,

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
        // Wire the custom filter's match function. The function reads the
        // search text directly from priv.search_entry and gates the
        // value-side match on priv.search_values_check.
        priv.custom_filter.setFilterFunc(filterMatch, self, null);

        // ------------------------------------------------------------------
        // Phase 5: Set up the file monitor for external-change detection.
        self.setupFileMonitor();

        // ------------------------------------------------------------------
        // Phase 6: Ctrl+S keyboard shortcut — save dirty entries.
        const key_ctrl = gtk.EventControllerKey.new();
        _ = gtk.EventControllerKey.signals.key_pressed.connect(
            key_ctrl,
            *Self,
            onKeyPressed,
            self,
            .{},
        );
        self.as(gtk.Widget).addController(key_ctrl.as(gtk.EventController));
    }

    fn dispose(self: *Self) callconv(.c) void {
        const priv = self.private();

        // Phase 5: tear down file monitor first to avoid spurious events.
        self.teardownFileMonitor();

        // Free the config path string we allocated at init.
        if (priv.config_path) |p| {
            Application.default().allocator().free(p);
            priv.config_path = null;
        }

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
        _: *gtk.SearchEntry,
        self: *Self,
    ) callconv(.c) void {
        const priv = self.private();
        @as(*gtk.Filter, @ptrCast(@alignCast(priv.custom_filter))).changed(.different);
    }

    /// Called when the "in values" checkbox toggles — refilter the list.
    fn onSearchValuesToggled(
        _: *gtk.CheckButton,
        self: *Self,
    ) callconv(.c) void {
        const priv = self.private();
        @as(*gtk.Filter, @ptrCast(@alignCast(priv.custom_filter))).changed(.different);
    }

    /// Match function used by the CustomFilter. Matches when the search text
    /// is a case-insensitive substring of the key name, OR (when the "in
    /// values" checkbox is active) of the current serialized value.
    fn filterMatch(
        item: *gobject.Object,
        user_data: ?*anyopaque,
    ) callconv(.c) c_int {
        const self: *Self = @ptrCast(@alignCast(user_data orelse return 1));
        const priv = self.private();

        const entry = gobject.ext.cast(ConfigEntryObject, item) orelse return 1;

        // Empty search → match everything.
        const search_ptr = priv.search_entry.as(gtk.Editable).getText();
        const search = std.mem.span(search_ptr);
        if (search.len == 0) return 1;

        // Always check the key name.
        if (entry.propGetKeyName()) |key_z| {
            const key = std.mem.span(key_z.ptr);
            if (std.ascii.indexOfIgnoreCase(key, search) != null) return 1;
        }

        // If enabled, also check the current value.
        if (priv.search_values_check.as(gtk.CheckButton).getActive() != 0) {
            if (entry.getCurrentValue()) |val_z| {
                const val = std.mem.span(val_z.ptr);
                if (std.ascii.indexOfIgnoreCase(val, search) != null) return 1;
            }
        }

        return 0;
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

    /// Key-press handler for the editor window.
    /// Ctrl+S → save; Ctrl+R → reload from file.
    fn onKeyPressed(
        _: *gtk.EventControllerKey,
        keyval: c_uint,
        _: c_uint,
        state: gdk.ModifierType,
        self: *Self,
    ) callconv(.c) c_int {
        const ctrl = state.control_mask;
        if (!ctrl) return 0;

        const GDK_KEY_s: c_uint = 0x73;
        const GDK_KEY_r: c_uint = 0x72;

        if (keyval == GDK_KEY_s) {
            self.saveConfigToDisk() catch |err| {
                log.err("Ctrl+S save failed: {}", .{err});
                self.showToast("Save failed — check the log");
                return 1;
            };
            self.showToast("Changes saved");
            return 1; // consumed
        }

        if (keyval == GDK_KEY_r) {
            self.reloadFromFile();
            return 1;
        }

        return 0;
    }

    //---------------------------------------------------------------
    // Phase 5 — File watcher

    /// Set up a GIO file monitor on the config file path.  Called once at
    /// window init; silently skips setup if the path cannot be resolved.
    fn setupFileMonitor(self: *Self) void {
        const priv = self.private();
        const alloc = Application.default().allocator();

        // Resolve (and create-if-missing) the config file path.
        const path = config_edit.openPath(alloc) catch |err| {
            log.warn("setupFileMonitor: could not resolve config path: {}", .{err});
            return;
        };
        priv.config_path = path;

        const gfile = gio.File.newForPath(path.ptr);
        defer gfile.unref();

        // Monitor the file directly (not directory).
        var err_ptr: ?*glib.Error = null;
        const monitor = gfile.monitorFile(.flags_none, null, &err_ptr) orelse {
            if (err_ptr) |e| {
                const msg: [*:0]const u8 = if (e.f_message) |m| m else "(no message)";
                log.warn("setupFileMonitor: g_file_monitor_file failed: {s}", .{msg});
                glib.Error.free(e);
            }
            return;
        };
        // Reduce debounce rate-limit to 500 ms for reasonable responsiveness.
        monitor.setRateLimit(500);

        _ = gio.FileMonitor.signals.changed.connect(
            monitor,
            *Self,
            onFileChanged,
            self,
            .{},
        );

        priv.file_monitor = monitor;
        log.info("watching config file for external changes: {s}", .{path});
    }

    /// Cancel and release the file monitor.
    fn teardownFileMonitor(self: *Self) void {
        const priv = self.private();
        if (priv.file_monitor) |fm| {
            _ = fm.cancel();
            fm.unref();
            priv.file_monitor = null;
        }
    }

    /// GIO FileMonitor "changed" signal handler.
    ///
    /// Fires on the GLib main thread.  We ignore events that we triggered
    /// ourselves (writing_file flag) and show a conflict dialog for all
    /// others with event type `changes_done_hint`.
    fn onFileChanged(
        _: *gio.FileMonitor,
        _: *gio.File,
        _: ?*gio.File,
        event_type: gio.FileMonitorEvent,
        self: *Self,
    ) callconv(.c) void {
        const priv = self.private();

        // Ignore events triggered by our own writes.
        if (priv.writing_file) return;

        // Only act on the debounced "done writing" event.
        if (event_type != .changes_done_hint) return;

        self.showConflictDialog();
    }

    /// Show an Adw.AlertDialog offering Reload / Keep editor / Cancel.
    fn showConflictDialog(self: *Self) void {
        const dialog = adw.AlertDialog.new(
            "Config File Changed",
            "The configuration file was modified externally. " ++
                "What would you like to do?",
        );
        dialog.addResponse("reload", "_Reload from file");
        dialog.addResponse("keep", "_Keep editor state");
        dialog.setDefaultResponse("reload");
        dialog.setCloseResponse("keep");
        dialog.setResponseAppearance("reload", .suggested);

        dialog.choose(
            self.as(gtk.Widget),
            null,
            onConflictDialogResponse,
            self,
        );
    }

    /// Async callback for the conflict dialog.
    fn onConflictDialogResponse(
        source: ?*gobject.Object,
        result: *gio.AsyncResult,
        ud: ?*anyopaque,
    ) callconv(.c) void {
        const self: *Self = @ptrCast(@alignCast(ud orelse return));
        const src = source orelse return;
        const ad: *adw.AlertDialog = @ptrCast(@alignCast(src));
        const response = ad.chooseFinish(result);
        if (std.mem.eql(u8, std.mem.span(response), "reload")) {
            self.reloadFromFile();
        }
        // "keep" and "cancel" both just dismiss the dialog.
    }

    /// Reload all entry values from the live config (re-reads the file).
    ///
    /// This refreshes each ConfigEntryObject's current_value from a freshly
    /// loaded Config, and clears the dirty flag on all rows.
    fn reloadFromFile(self: *Self) void {
        const priv = self.private();
        const app = Application.default();
        const alloc = app.allocator();

        // Hard-reload the config from disk.
        var new_core_config = configpkg.Config.load(alloc) catch |err| {
            log.err("reloadFromFile: Config.load failed: {}", .{err});
            self.showToast("Reload failed — check the log");
            return;
        };
        defer new_core_config.deinit();

        // Walk the store and update each entry's current value.
        const model = priv.entry_store.as(gio.ListModel);
        const n = model.getNItems();

        var store_idx: u32 = 0;
        @setEvalBranchQuota(100_000);
        inline for (@typeInfo(configpkg.Config).@"struct".fields) |struct_field| {
            if (comptime struct_field.name[0] == '_') continue;
            if (store_idx >= n) break;

            if (model.getItem(store_idx)) |raw_obj| {
                const obj: *gobject.Object = @ptrCast(@alignCast(raw_obj));
                defer obj.unref();
                if (gobject.ext.cast(ConfigEntryObject, obj)) |entry| {
                    var buf: std.Io.Writer.Allocating = .init(alloc);
                    defer buf.deinit();

                    configpkg.formatEntry(
                        struct_field.type,
                        struct_field.name,
                        @field(new_core_config, struct_field.name),
                        &buf.writer,
                    ) catch {};

                    const written = buf.written();
                    const value_str: []const u8 = blk: {
                        if (std.mem.indexOf(u8, written, " = ")) |sep| {
                            const raw = written[sep + 3 ..];
                            break :blk std.mem.trimRight(u8, raw, "\n");
                        }
                        break :blk written;
                    };

                    entry.setCurrentValue(value_str);
                    entry.setDirty(false);
                }
            }

            store_idx += 1;
        }

        self.showToast("Reloaded from file");
        log.info("reloadFromFile: refreshed {} entries", .{store_idx});
    }

    /// Show a short toast notification in the editor window.
    fn showToast(self: *Self, comptime message: [:0]const u8) void {
        const toast = adw.Toast.new(message);
        toast.setTimeout(3);
        self.private().toast_overlay.addToast(toast);
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
        self_win: *Self,
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

        // Info button (opens docs URL for this field).
        const info_btn = gtk.Button.newFromIconName("dialog-information-symbolic");
        info_btn.as(gtk.Widget).setValign(.center);
        info_btn.as(gtk.Widget).addCssClass("flat");
        info_btn.as(gtk.Widget).addCssClass("circular");
        _ = gtk.Button.signals.clicked.connect(
            info_btn,
            *Self,
            onInfoBtnClicked,
            self_win,
            .{},
        );

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
        row_box.append(info_btn.as(gtk.Widget));
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

        // Navigate to info_btn (sits between info_box and edit_box in row_box).
        if (info_box_widget.getNextSibling()) |sibling| {
            if (gobject.ext.cast(gtk.Button, sibling)) |info_btn| {
                // Store field name so click handler can open the right URL.
                info_btn.as(gtk.Widget).setName(field.name.ptr);
                // Full docs as tooltip.
                if (entry.getDocsFull()) |docs| {
                    info_btn.as(gtk.Widget).setTooltipText(docs.ptr);
                } else {
                    info_btn.as(gtk.Widget).setTooltipText("No documentation available.");
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
                // Font-family fields get a FontDialogButton for family-only picking.
                const is_font_family = std.mem.eql(u8, field.name, "font-family") or
                    std.mem.eql(u8, field.name, "font-family-bold") or
                    std.mem.eql(u8, field.name, "font-family-italic") or
                    std.mem.eql(u8, field.name, "font-family-bold-italic");

                if (is_font_family) {
                    const font_dialog = gtk.FontDialog.new();
                    const btn = gtk.FontDialogButton.new(font_dialog);
                    btn.as(gtk.Widget).setValign(.center);
                    // Restrict the picker to family level (no style/size).
                    btn.setLevel(.family);

                    // Set initial font from the current value (family name string).
                    if (current_raw.len > 0) {
                        const desc = pango.FontDescription.new();
                        defer desc.free();
                        desc.setFamily(current_raw.ptr);
                        btn.setFontDesc(desc);
                    }

                    _ = gobject.Object.signals.notify.connect(
                        btn.as(gobject.Object),
                        *ConfigEntryObject,
                        onFontDialogButtonChanged,
                        entry,
                        .{ .detail = "font-desc" },
                    );
                    return btn.as(gtk.Widget);
                }

                // Color fields get a ColorDialogButton for visual color picking.
                const is_color_field = blk: {
                    const n = field.name;
                    if (std.mem.eql(u8, n, "background") or
                        std.mem.eql(u8, n, "foreground"))
                        break :blk true;
                    // Fields whose name contains "color" are color fields
                    // (e.g. cursor-color, split-divider-color, bold-color).
                    if (std.mem.indexOf(u8, n, "color") != null)
                        break :blk true;
                    // selection-background, selection-foreground,
                    // search-background, search-foreground, etc.
                    if (std.mem.endsWith(u8, n, "-background") or
                        std.mem.endsWith(u8, n, "-foreground"))
                        break :blk true;
                    break :blk false;
                };

                if (is_color_field) {
                    const color_dialog = gtk.ColorDialog.new();
                    const btn = gtk.ColorDialogButton.new(color_dialog);
                    btn.as(gtk.Widget).setValign(.center);

                    // Try to parse the current value as an RGB color and
                    // pre-load it into the button.
                    if (current_raw.len > 0) {
                        var rgba: gdk.RGBA = .{
                            .f_red = 0,
                            .f_green = 0,
                            .f_blue = 0,
                            .f_alpha = 1,
                        };
                        if (gdk.RGBA.parse(&rgba, current_raw.ptr) != 0) {
                            btn.setRgba(&rgba);
                        }
                    }

                    _ = gobject.Object.signals.notify.connect(
                        btn.as(gobject.Object),
                        *ConfigEntryObject,
                        onColorDialogButtonChanged,
                        entry,
                        .{ .detail = "rgba" },
                    );
                    return btn.as(gtk.Widget);
                }

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
        const str_obj_ = gobject.ext.cast(gtk.StringObject, @as(*gobject.Object, @ptrCast(@alignCast(model.getItem(selected) orelse return))));
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

    fn onFontDialogButtonChanged(
        btn_obj: *gobject.Object,
        _: *gobject.ParamSpec,
        entry: *ConfigEntryObject,
    ) callconv(.c) void {
        const btn = gobject.ext.cast(gtk.FontDialogButton, btn_obj) orelse return;
        const desc = btn.getFontDesc() orelse return;
        // getFamily() returns a borrowed pointer into the FontDescription;
        // do not free it.
        const family_ptr = desc.getFamily() orelse return;
        entry.setCurrentValue(std.mem.span(family_ptr));
        entry.setDirty(true);
    }

    fn onColorDialogButtonChanged(
        btn_obj: *gobject.Object,
        _: *gobject.ParamSpec,
        entry: *ConfigEntryObject,
    ) callconv(.c) void {
        const btn = gobject.ext.cast(gtk.ColorDialogButton, btn_obj) orelse return;
        const rgba = btn.getRgba();
        // Format as #rrggbb hex string.
        var hex_buf: [8]u8 = undefined;
        const hex = std.fmt.bufPrintZ(&hex_buf, "#{x:0>2}{x:0>2}{x:0>2}", .{
            @as(u8, @intFromFloat(rgba.f_red * 255.0)),
            @as(u8, @intFromFloat(rgba.f_green * 255.0)),
            @as(u8, @intFromFloat(rgba.f_blue * 255.0)),
        }) catch return;
        entry.setCurrentValue(hex);
        entry.setDirty(true);
    }

    //---------------------------------------------------------------
    // Info button — opens the docs URL for the field

    fn onInfoBtnClicked(
        btn: *gtk.Button,
        self: *Self,
    ) callconv(.c) void {
        _ = self;
        const name_ptr = btn.as(gtk.Widget).getName();
        const name = std.mem.span(name_ptr);
        const app = Application.default();
        const alloc = app.allocator();
        const url = std.fmt.allocPrint(alloc, "https://ghostty.org/docs/config/reference#{s}", .{name}) catch return;
        defer alloc.free(url);
        app.openUrlFallback(.text, url);
    }

    //---------------------------------------------------------------
    // Save / Restart

    fn saveConfigToDisk(self: *Self) !void {
        const priv = self.private();
        const app = Application.default();
        const alloc = app.allocator();

        const path = try config_edit.openPath(alloc);
        defer alloc.free(path);

        const model = priv.entry_store.as(gio.ListModel);
        const n = model.getNItems();
        var dirty_count: usize = 0;
        for (0..@as(usize, @intCast(n))) |i| {
            const raw = model.getItem(@intCast(i)) orelse continue;
            const obj: *gobject.Object = @ptrCast(@alignCast(raw));
            defer obj.unref();
            const entry = gobject.ext.cast(ConfigEntryObject, obj) orelse continue;
            if (!entry.getDirty()) continue;
            dirty_count += 1;
        }

        if (dirty_count == 0) return;

        // Suppress monitor events that we trigger ourselves.
        priv.writing_file = true;
        defer priv.writing_file = false;

        const file = try std.fs.openFileAbsoluteZ(path, .{ .mode = .write_only });
        defer file.close();
        try file.seekFromEnd(0);

        var wbuf: [4096]u8 = undefined;
        var file_writer = file.writer(&wbuf);
        const writer = &file_writer.interface;

        try writer.writeAll("\n# --- config editor ---\n");

        for (0..@as(usize, @intCast(n))) |i| {
            const raw = model.getItem(@intCast(i)) orelse continue;
            const obj: *gobject.Object = @ptrCast(@alignCast(raw));
            defer obj.unref();
            const entry = gobject.ext.cast(ConfigEntryObject, obj) orelse continue;
            if (!entry.getDirty()) continue;
            const field = entry.getFieldMeta();
            const val = entry.getCurrentValue() orelse "";
            try writer.print("{s} = {s}\n", .{ field.name, val });
            entry.setDirty(false);
        }
    }

    fn onSaveClicked(
        _: *gtk.Button,
        self: *Self,
    ) callconv(.c) void {
        self.saveConfigToDisk() catch |err| {
            log.err("failed to save config: {}", .{err});
            const dialog = adw.AlertDialog.new(
                "Could not save config",
                if (err == error.ReadOnlyFileSystem)
                    "The config file is on a read-only filesystem.\n\nIf you're running the Flatpak, the config may be a symlink to a read-only location. Remove the symlink and copy the file to ~/.var/app/com.mitchellh.ghostty/config/ghostty/config.ghostty, or run: flatpak override --user --filesystem=~/.config/ghostty:rw com.mitchellh.ghostty"
                else
                    "An error occurred writing the config file. Check the Ghostty log for details.",
            );
            dialog.addResponse("ok", "_OK");
            dialog.as(adw.Dialog).present(self.as(gtk.Widget));
            return;
        };
        log.info("config saved successfully", .{});
        self.showToast("Changes saved");
    }

    fn getStatePath() ![]u8 {
        const state_home = glib.getenv("XDG_STATE_HOME") orelse {
            const home = glib.getenv("HOME") orelse return error.NoHome;
            return try std.fmt.allocPrint(std.heap.c_allocator, "{s}/.local/state/ghostty/.reopen-config-editor", .{std.mem.span(home)});
        };
        return try std.fmt.allocPrint(std.heap.c_allocator, "{s}/ghostty/.reopen-config-editor", .{std.mem.span(state_home)});
    }

    fn writeSentinelFile() void {
        const path = getStatePath() catch return;
        defer std.heap.c_allocator.free(path);
        const f = std.fs.createFileAbsolute(path, .{}) catch return;
        f.close();
    }

    fn onRestartClicked(
        _: *gtk.Button,
        self: *Self,
    ) callconv(.c) void {
        self.saveConfigToDisk() catch |err| {
            log.warn("save before restart failed: {}", .{err});
        };
        writeSentinelFile();
        Application.default().as(gio.Application).quit();
    }

    fn onOpenFileClicked(
        _: *gtk.Button,
        self: *Self,
    ) callconv(.c) void {
        _ = self;
        const app = Application.default();
        _ = app.core().mailbox.push(.open_config, .forever);
    }

    fn onReloadClicked(
        _: *gtk.Button,
        self: *Self,
    ) callconv(.c) void {
        self.reloadFromFile();
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
            class.bindTemplateChildPrivate("search_values_check", .{});
            class.bindTemplateChildPrivate("config_list", .{});
            class.bindTemplateChildPrivate("entry_store", .{});
            class.bindTemplateChildPrivate("filter_model", .{});
            class.bindTemplateChildPrivate("custom_filter", .{});
            class.bindTemplateChildPrivate("toast_overlay", .{});

            // Template callbacks.
            class.bindTemplateCallback("on_search_changed", &onSearchChanged);
            class.bindTemplateCallback("on_search_values_toggled", &onSearchValuesToggled);
            class.bindTemplateCallback("on_instant_reload_toggled", &onInstantReloadToggled);
            class.bindTemplateCallback("on_persist_toggled", &onPersistToggled);
            class.bindTemplateCallback("on_save_clicked", &onSaveClicked);
            class.bindTemplateCallback("on_restart_clicked", &onRestartClicked);
            class.bindTemplateCallback("on_open_file_clicked", &onOpenFileClicked);
            class.bindTemplateCallback("on_reload_clicked", &onReloadClicked);
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
