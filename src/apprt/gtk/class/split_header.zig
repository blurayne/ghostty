const std = @import("std");
const adw = @import("adw");
const gdk = @import("gdk");
const gio = @import("gio");
const glib = @import("glib");
const gobject = @import("gobject");
const gtk = @import("gtk");

const configpkg = @import("../../../config.zig");
const gresource = @import("../build/gresource.zig");
const ext = @import("../ext.zig");
const Common = @import("../class.zig").Common;
const Application = @import("application.zig").Application;
const Surface = @import("surface.zig").Surface;
const SplitTree = @import("split_tree.zig").SplitTree;
const TitleDialog = @import("title_dialog.zig").TitleDialog;
const Window = @import("window.zig").Window;
const split_dnd = @import("split_dnd.zig");

const log = std.log.scoped(.gtk_ghostty_split_header);

pub const SplitHeader = extern struct {
    const Self = @This();
    parent_instance: Parent,
    pub const Parent = adw.Bin;
    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "GhosttySplitHeader",
        .instanceInit = &init,
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    pub const properties = struct {
        pub const surface = struct {
            pub const name = "surface";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                ?*Surface,
                .{
                    .accessor = .{
                        .getter = getSurfaceValue,
                        .setter = setSurfaceValue,
                    },
                },
            );
        };
    };

    const Private = struct {
        // Template children
        header_box: *gtk.Box,
        title_label: *gtk.Label,
        broadcast_icon: *gtk.Image,
        zoom_button: *gtk.Button,
        close_button: *gtk.Button,
        context_menu: *gtk.PopoverMenu,

        // State
        surface: ?*Surface = null,
        title_notify_id: c_ulong = 0,
        title_override_notify_id: c_ulong = 0,
        zoom_notify_id: c_ulong = 0,
        split_tree: ?*SplitTree = null,
        header_mode: configpkg.Config.SplitHeaderMode = .auto,
        split_count: u32 = 1,
        pane_number: u32 = 1,

        // Per-split color customization
        custom_colors: ?CustomColors = null,
        css_provider: ?*gtk.CssProvider = null,
        css_class: [32]u8 = std.mem.zeroes([32]u8),

        pub var offset: c_int = 0;
    };

    /// Colors chosen by the user for this split's header.
    const CustomColors = struct {
        bg: gdk.RGBA,
        fg: gdk.RGBA,
        btn: gdk.RGBA,
        bold: bool,
        italic: bool,
    };

    fn init(self: *Self, _: *Class) callconv(.c) void {
        gtk.Widget.initTemplate(self.as(gtk.Widget));
        self.updateVisibility();
        self.initDragSource();
        self.initActionMap();
    }

    fn initActionMap(self: *Self) void {
        const actions = [_]ext.actions.Action(Self){
            .init("copy-as-source", actionCopyAsSource, null),
            .init("attach-sourced-pane", actionAttachSourcedPane, null),
            .init("rename", actionRename, null),
            .init("customize", actionCustomize, null),
        };
        _ = ext.actions.addAsGroup(Self, self, "split-header", &actions);
    }

    fn actionCopyAsSource(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Self,
    ) callconv(.c) void {
        const surface = self.private().surface orelse return;
        const window = ext.getAncestor(Window, self.as(gtk.Widget)) orelse return;
        window.setMirrorSource(surface.getUuid().*);
    }

    fn actionAttachSourcedPane(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Self,
    ) callconv(.c) void {
        const window = ext.getAncestor(Window, self.as(gtk.Widget)) orelse return;
        const uuid = window.getMirrorSource() orelse return;
        const split_tree = ext.getAncestor(SplitTree, self.as(gtk.Widget)) orelse return;
        split_tree.newSplitMirrored(uuid) catch |err| {
            log.warn("attach sourced pane failed err={}", .{err});
        };
    }

    fn actionRename(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Self,
    ) callconv(.c) void {
        const surface = self.private().surface orelse return;
        const initial = surface.getEffectiveTitle();
        const dialog = TitleDialog.new(.surface, initial);
        _ = TitleDialog.signals.set.connect(
            dialog,
            *Self,
            titleDialogSet,
            self,
            .{},
        );
        dialog.present(self.as(gtk.Widget));
    }

    fn titleDialogSet(
        _: *TitleDialog,
        title_ptr: [*:0]const u8,
        self: *Self,
    ) callconv(.c) void {
        const surface = self.private().surface orelse return;
        const title = std.mem.span(title_ptr);
        surface.setTitleOverride(if (title.len == 0) null else title);
    }

    // -------------------------------------------------------------------------
    // "Customize Colors…" action
    // -------------------------------------------------------------------------

    /// State passed to the AlertDialog callback so we can read the buttons.
    const ColorDialogState = struct {
        header: *Self,
        btn_bg: *gtk.ColorDialogButton,
        btn_fg: *gtk.ColorDialogButton,
        btn_btn: *gtk.ColorDialogButton,
        chk_bold: *gtk.CheckButton,
        chk_italic: *gtk.CheckButton,
    };

    /// Counter for generating unique per-instance CSS class names.
    var css_class_counter: u32 = 0;

    fn actionCustomize(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Self,
    ) callconv(.c) void {
        const priv = self.private();

        // Assign a unique CSS class to this header if it doesn't have one yet.
        if (priv.css_class[0] == 0) {
            const id = @atomicRmw(u32, &css_class_counter, .Add, 1, .monotonic);
            // Write "sh-custom-<id>\0" into the fixed 32-byte buffer.
            _ = std.fmt.bufPrintZ(&priv.css_class, "sh-custom-{d}", .{id}) catch {};
        }

        // Default initial colors: derive from current custom state if any.
        const init_bg = if (priv.custom_colors) |c| c.bg else gdk.RGBA{ .f_red = 0.122, .f_green = 0.122, .f_blue = 0.122, .f_alpha = 1.0 };
        const init_fg = if (priv.custom_colors) |c| c.fg else gdk.RGBA{ .f_red = 1.0, .f_green = 1.0, .f_blue = 1.0, .f_alpha = 1.0 };
        const init_btn = if (priv.custom_colors) |c| c.btn else gdk.RGBA{ .f_red = 0.8, .f_green = 0.8, .f_blue = 0.8, .f_alpha = 1.0 };
        const init_bold = if (priv.custom_colors) |c| c.bold else false;
        const init_italic = if (priv.custom_colors) |c| c.italic else false;

        // Build the dialog imperatively.
        const dialog = adw.AlertDialog.new("Customize Header Colors", null);
        dialog.addResponse("cancel", "_Cancel");
        dialog.addResponse("apply", "_Apply");
        dialog.setResponseAppearance("apply", .suggested);
        dialog.setDefaultResponse("apply");
        dialog.setCloseResponse("cancel");

        // Shared ColorDialog (no title needed per-button; each button shows its own).
        const color_dialog = gtk.ColorDialog.new();
        defer color_dialog.as(gobject.Object).unref();

        // Outer vertical box
        const vbox = gtk.Box.new(.vertical, 8);
        vbox.as(gtk.Widget).setMarginTop(8);
        vbox.as(gtk.Widget).setMarginBottom(8);
        vbox.as(gtk.Widget).setMarginStart(8);
        vbox.as(gtk.Widget).setMarginEnd(8);

        // -- Background row --
        const row_bg = gtk.Box.new(.horizontal, 8);
        const lbl_bg = gtk.Label.new("Background");
        lbl_bg.as(gtk.Widget).setHalign(.start);
        lbl_bg.as(gtk.Widget).setHexpand(1);
        const btn_bg = gtk.ColorDialogButton.new(color_dialog);
        btn_bg.setRgba(&init_bg);
        row_bg.append(lbl_bg.as(gtk.Widget));
        row_bg.append(btn_bg.as(gtk.Widget));
        vbox.append(row_bg.as(gtk.Widget));

        // -- Foreground row --
        const row_fg = gtk.Box.new(.horizontal, 8);
        const lbl_fg = gtk.Label.new("Title Text");
        lbl_fg.as(gtk.Widget).setHalign(.start);
        lbl_fg.as(gtk.Widget).setHexpand(1);
        const btn_fg = gtk.ColorDialogButton.new(color_dialog);
        btn_fg.setRgba(&init_fg);
        row_fg.append(lbl_fg.as(gtk.Widget));
        row_fg.append(btn_fg.as(gtk.Widget));
        vbox.append(row_fg.as(gtk.Widget));

        // -- Button color row --
        const row_btn = gtk.Box.new(.horizontal, 8);
        const lbl_btn = gtk.Label.new("Button Color");
        lbl_btn.as(gtk.Widget).setHalign(.start);
        lbl_btn.as(gtk.Widget).setHexpand(1);
        const btn_btn = gtk.ColorDialogButton.new(color_dialog);
        btn_btn.setRgba(&init_btn);
        row_btn.append(lbl_btn.as(gtk.Widget));
        row_btn.append(btn_btn.as(gtk.Widget));
        vbox.append(row_btn.as(gtk.Widget));

        // -- Style row --
        const row_style = gtk.Box.new(.horizontal, 16);
        const chk_bold = gtk.CheckButton.newWithLabel("Bold");
        chk_bold.setActive(@intFromBool(init_bold));
        const chk_italic = gtk.CheckButton.newWithLabel("Italic");
        chk_italic.setActive(@intFromBool(init_italic));
        row_style.append(chk_bold.as(gtk.Widget));
        row_style.append(chk_italic.as(gtk.Widget));
        vbox.append(row_style.as(gtk.Widget));

        // Reset button row
        const row_reset = gtk.Box.new(.horizontal, 8);
        const btn_reset = gtk.Button.newWithLabel("Reset to Default");
        btn_reset.as(gtk.Widget).setHalign(.end);
        btn_reset.as(gtk.Widget).setHexpand(1);
        row_reset.append(btn_reset.as(gtk.Widget));
        vbox.append(row_reset.as(gtk.Widget));

        dialog.setExtraChild(vbox.as(gtk.Widget));

        // Wire up the Reset button — stores self pointer via user_data on the button.
        const state = glib.malloc(@sizeOf(ColorDialogState)).?;
        const s: *ColorDialogState = @ptrCast(@alignCast(state));
        s.* = .{
            .header = self,
            .btn_bg = btn_bg,
            .btn_fg = btn_fg,
            .btn_btn = btn_btn,
            .chk_bold = chk_bold,
            .chk_italic = chk_italic,
        };
        _ = gtk.Button.signals.clicked.connect(
            btn_reset,
            *ColorDialogState,
            onCustomizeReset,
            s,
            .{},
        );

        // Find window ancestor for presentation.
        const parent: ?*gtk.Widget = if (ext.getAncestor(adw.ApplicationWindow, self.as(gtk.Widget))) |w|
            w.as(gtk.Widget)
        else if (ext.getAncestor(adw.Window, self.as(gtk.Widget))) |w|
            w.as(gtk.Widget)
        else
            null;

        dialog.choose(parent, null, colorDialogReady, s);
    }

    fn onCustomizeReset(
        _: *gtk.Button,
        s: *ColorDialogState,
    ) callconv(.c) void {
        // Clear stored colors and remove the CSS provider.
        const priv = s.header.private();
        priv.custom_colors = null;
        if (priv.css_provider) |p| {
            s.header.as(gtk.Widget).getStyleContext().removeProvider(p.as(gtk.StyleProvider));
            p.unref();
            priv.css_provider = null;
        }
    }

    fn colorDialogReady(
        source: ?*gobject.Object,
        result: *gio.AsyncResult,
        ud: ?*anyopaque,
    ) callconv(.c) void {
        const s: *ColorDialogState = @ptrCast(@alignCast(ud));
        // Read colors before any early returns that free s.
        const colors = CustomColors{
            .bg = s.btn_bg.getRgba().*,
            .fg = s.btn_fg.getRgba().*,
            .btn = s.btn_btn.getRgba().*,
            .bold = s.chk_bold.getActive() != 0,
            .italic = s.chk_italic.getActive() != 0,
        };
        const self = s.header;
        const priv = self.private();
        glib.free(s);

        // The source object is the AlertDialog.
        const src = source orelse return;
        const ad: *adw.AlertDialog = @ptrCast(@alignCast(src));
        const response = ad.chooseFinish(result);
        if (!std.mem.eql(u8, std.mem.span(response), "apply")) return;

        priv.custom_colors = colors;
        self.applyCustomColors(&colors);
    }

    fn applyCustomColors(self: *Self, colors: *const CustomColors) void {
        const priv = self.private();
        // css_class is always null-terminated (zeroed at init, written with bufPrintZ).
        const css_class_cstr: [*:0]const u8 = @ptrCast(&priv.css_class);
        const css_class_slice = std.mem.span(css_class_cstr);

        // Ensure the unique CSS class is set on this widget.
        self.as(gtk.Widget).addCssClass(css_class_cstr);

        // Build CSS string targeting the per-instance class.
        var buf: [512]u8 = undefined;
        const font_style: []const u8 = if (colors.italic) "italic" else "normal";
        const font_weight: []const u8 = if (colors.bold) "bold" else "normal";
        const css = std.fmt.bufPrintZ(&buf,
            ".{s} {{ background-color: rgba({d},{d},{d},{d:.3}); color: rgba({d},{d},{d},{d:.3}); font-style: {s}; font-weight: {s}; }}" ++
            " .{s} button {{ color: rgba({d},{d},{d},{d:.3}); }}",
            .{
                css_class_slice,
                @as(u8, @intFromFloat(colors.bg.f_red * 255)),
                @as(u8, @intFromFloat(colors.bg.f_green * 255)),
                @as(u8, @intFromFloat(colors.bg.f_blue * 255)),
                colors.bg.f_alpha,
                @as(u8, @intFromFloat(colors.fg.f_red * 255)),
                @as(u8, @intFromFloat(colors.fg.f_green * 255)),
                @as(u8, @intFromFloat(colors.fg.f_blue * 255)),
                colors.fg.f_alpha,
                font_style,
                font_weight,
                css_class_slice,
                @as(u8, @intFromFloat(colors.btn.f_red * 255)),
                @as(u8, @intFromFloat(colors.btn.f_green * 255)),
                @as(u8, @intFromFloat(colors.btn.f_blue * 255)),
                colors.btn.f_alpha,
            },
        ) catch return;

        // Create or reuse the per-instance CSS provider.
        const provider = if (priv.css_provider) |p| p else blk: {
            const p = gtk.CssProvider.new();
            priv.css_provider = p;
            self.as(gtk.Widget).getStyleContext().addProvider(
                p.as(gtk.StyleProvider),
                gtk.STYLE_PROVIDER_PRIORITY_APPLICATION + 10,
            );
            break :blk p;
        };
        provider.loadFromString(css.ptr);
    }

    fn initDragSource(self: *Self) void {
        const drag_source = gtk.DragSource.new();
        drag_source.setActions(.{ .move = true });
        _ = gtk.DragSource.signals.prepare.connect(
            drag_source,
            *Self,
            onDragPrepare,
            self,
            .{},
        );
        _ = gtk.DragSource.signals.drag_begin.connect(
            drag_source,
            *Self,
            onDragBegin,
            self,
            .{},
        );
        _ = gtk.DragSource.signals.drag_end.connect(
            drag_source,
            *Self,
            onDragEnd,
            self,
            .{},
        );
        self.private().header_box.as(gtk.Widget).addController(
            drag_source.as(gtk.EventController),
        );
    }

    fn onDragPrepare(
        _: *gtk.DragSource,
        _: f64,
        _: f64,
        self: *Self,
    ) callconv(.c) ?*gdk.ContentProvider {
        const surface = self.private().surface orelse return null;
        // Skip drag if tree is zoomed
        const tree = ext.getAncestor(SplitTree, self.as(gtk.Widget)) orelse return null;
        if (tree.getIsZoomed()) return null;

        const payload = split_dnd.Payload{
            .pid = @intCast(std.os.linux.getpid()),
            .uuid = surface.getUuid().*,
        };
        const bytes = payload.serialize();
        defer bytes.unref();
        return gdk.ContentProvider.newForBytes(split_dnd.MIME, bytes);
    }

    fn onDragBegin(
        drag_source: *gtk.DragSource,
        _: *gdk.Drag,
        self: *Self,
    ) callconv(.c) void {
        const surface = self.private().surface orelse return;
        // Use the terminal surface as the drag icon
        const paintable = gtk.WidgetPaintable.new(surface.as(gtk.Widget));
        defer paintable.as(gobject.Object).unref();
        const w = paintable.as(gdk.Paintable).getIntrinsicWidth();
        const h = paintable.as(gdk.Paintable).getIntrinsicHeight();
        drag_source.setIcon(
            paintable.as(gdk.Paintable),
            @divTrunc(w, 4),
            @divTrunc(h, 4),
        );
    }

    fn onDragEnd(
        _: *gtk.DragSource,
        drag: *gdk.Drag,
        delete_data: c_int,
        self: *Self,
    ) callconv(.c) void {
        // delete_data != 0 means the drop was accepted; 0 means cancelled/rejected
        if (delete_data != 0) return;
        _ = drag;
        const surface = self.private().surface orelse return;
        // Don't tear off if from a zoomed tree (guard consistent with onDragPrepare)
        const tree = ext.getAncestor(SplitTree, self.as(gtk.Widget)) orelse return;
        if (tree.getIsZoomed()) return;
        Window.newWithSurface(Application.default(), surface, null);
    }

    fn dispose(self: *Self) callconv(.c) void {
        const priv = self.private();
        if (priv.surface) |s| {
            if (priv.title_notify_id != 0) {
                gobject.signalHandlerDisconnect(s.as(gobject.Object), priv.title_notify_id);
                priv.title_notify_id = 0;
            }
            if (priv.title_override_notify_id != 0) {
                gobject.signalHandlerDisconnect(s.as(gobject.Object), priv.title_override_notify_id);
                priv.title_override_notify_id = 0;
            }
        }
        if (priv.split_tree) |tree| {
            if (priv.zoom_notify_id != 0) {
                gobject.signalHandlerDisconnect(tree.as(gobject.Object), priv.zoom_notify_id);
                priv.zoom_notify_id = 0;
            }
            priv.split_tree = null;
        }
        if (priv.css_provider) |p| {
            p.unref();
            priv.css_provider = null;
        }
        gtk.Widget.disposeTemplate(self.as(gtk.Widget), getGObjectType());
        gobject.Object.virtual_methods.dispose.call(Class.parent, self.as(Parent));
    }

    fn finalize(self: *Self) callconv(.c) void {
        gobject.Object.virtual_methods.finalize.call(Class.parent, self.as(Parent));
    }

    fn getSurfaceValue(self: *Self, value: *gobject.Value) void {
        gobject.ext.Value.set(value, self.private().surface);
    }

    fn setSurfaceValue(self: *Self, value: *const gobject.Value) void {
        self.setSurface(gobject.ext.Value.get(value, ?*Surface));
    }

    pub fn setSurface(self: *Self, surface_: ?*Surface) void {
        const priv = self.private();
        if (surface_ == priv.surface) return;

        // Disconnect old title notify handlers
        if (priv.surface) |old| {
            if (priv.title_notify_id != 0) {
                gobject.signalHandlerDisconnect(old.as(gobject.Object), priv.title_notify_id);
                priv.title_notify_id = 0;
            }
            if (priv.title_override_notify_id != 0) {
                gobject.signalHandlerDisconnect(old.as(gobject.Object), priv.title_override_notify_id);
                priv.title_override_notify_id = 0;
            }
        }

        // Disconnect old zoom notify handler
        if (priv.split_tree) |tree| {
            if (priv.zoom_notify_id != 0) {
                gobject.signalHandlerDisconnect(tree.as(gobject.Object), priv.zoom_notify_id);
                priv.zoom_notify_id = 0;
            }
            priv.split_tree = null;
        }

        priv.surface = surface_;

        // Bind new surface title to label
        if (surface_) |s| {
            priv.title_label.as(gtk.Widget).setVisible(@intFromBool(true));
            // Use notify handlers so title-override takes precedence over title
            priv.title_notify_id = gobject.Object.signals.notify.connect(
                s,
                *Self,
                onSurfaceTitleNotify,
                self,
                .{ .detail = "title" },
            );
            priv.title_override_notify_id = gobject.Object.signals.notify.connect(
                s,
                *Self,
                onSurfaceTitleNotify,
                self,
                .{ .detail = "title-override" },
            );
            // Sync initial value
            self.syncTitleLabel();
        } else {
            priv.title_label.as(gtk.Widget).setVisible(@intFromBool(false));
        }

        // Subscribe to zoom-state changes on the ancestor SplitTree
        if (ext.getAncestor(SplitTree, self.as(gtk.Widget))) |tree| {
            priv.split_tree = tree;
            priv.zoom_notify_id = gobject.Object.signals.notify.connect(
                tree,
                *Self,
                onZoomStateNotify,
                self,
                .{ .detail = "is-zoomed" },
            );
            self.syncZoomButton();
        }
    }

    fn onSurfaceTitleNotify(
        _: *Surface,
        _: *gobject.ParamSpec,
        self: *Self,
    ) callconv(.c) void {
        self.syncTitleLabel();
    }

    fn onZoomStateNotify(
        _: *SplitTree,
        _: *gobject.ParamSpec,
        self: *Self,
    ) callconv(.c) void {
        self.syncZoomButton();
    }

    fn syncZoomButton(self: *Self) void {
        const tree = self.private().split_tree orelse return;
        const zoomed = tree.getIsZoomed();
        const icon: [*:0]const u8 = if (zoomed) "view-restore-symbolic" else "view-fullscreen-symbolic";
        const tooltip: [*:0]const u8 = if (zoomed) "Restore Split" else "Maximize Split";
        self.private().zoom_button.setIconName(icon);
        self.private().zoom_button.as(gtk.Widget).setTooltipText(tooltip);
    }

    fn syncTitleLabel(self: *Self) void {
        const priv = self.private();
        const s = priv.surface orelse return;
        const title = s.getEffectiveTitle() orelse "";
        const app = Application.default();
        const config_obj = app.getConfig();
        defer config_obj.unref();
        const config = config_obj.get();
        const fmt: []const u8 = config.@"split-title-format";
        var buf: [1024]u8 = undefined;
        const rendered = formatSplitTitle(fmt, priv.pane_number, title, &buf);
        priv.title_label.setLabel(rendered.ptr);
    }

    /// Render a split title format string. Supports {number} and {title}
    /// placeholders. Use \{ to emit a literal {. Output is truncated to fit buf.
    /// Returns a sentinel-terminated slice into buf.
    fn formatSplitTitle(
        fmt: []const u8,
        number: u32,
        title: []const u8,
        buf: []u8,
    ) [:0]const u8 {
        var out: usize = 0;
        var i: usize = 0;
        while (i < fmt.len and out + 1 < buf.len) {
            // Escaped brace: \{
            if (fmt[i] == '\\' and i + 1 < fmt.len and fmt[i + 1] == '{') {
                buf[out] = '{';
                out += 1;
                i += 2;
                continue;
            }
            // Placeholder start
            if (fmt[i] == '{') {
                const close = std.mem.indexOfScalarPos(u8, fmt, i + 1, '}') orelse {
                    // No closing brace — emit literally
                    buf[out] = fmt[i];
                    out += 1;
                    i += 1;
                    continue;
                };
                const name = fmt[i + 1 .. close];
                if (std.mem.eql(u8, name, "number")) {
                    const s = std.fmt.bufPrint(buf[out .. buf.len - 1], "{}", .{number}) catch "";
                    out += s.len;
                } else if (std.mem.eql(u8, name, "title")) {
                    const rem = buf.len - 1 - out;
                    const n = @min(title.len, rem);
                    @memcpy(buf[out .. out + n], title[0..n]);
                    out += n;
                } else {
                    // Unknown placeholder — emit verbatim including braces
                    const src = fmt[i .. close + 1];
                    const rem = buf.len - 1 - out;
                    const n = @min(src.len, rem);
                    @memcpy(buf[out .. out + n], src[0..n]);
                    out += n;
                }
                i = close + 1;
                continue;
            }
            buf[out] = fmt[i];
            out += 1;
            i += 1;
        }
        buf[out] = 0;
        return buf[0..out :0];
    }

    test "formatSplitTitle basic" {
        var buf: [256]u8 = undefined;
        const result = formatSplitTitle("#{number}: {title}", 3, "bash", &buf);
        try std.testing.expectEqualStrings("#3: bash", result);
    }

    test "formatSplitTitle escape brace" {
        var buf: [256]u8 = undefined;
        const result = formatSplitTitle("\\{{number}}", 1, "t", &buf);
        try std.testing.expectEqualStrings("{1}", result);
    }

    test "formatSplitTitle unknown placeholder" {
        var buf: [256]u8 = undefined;
        const result = formatSplitTitle("{foo}", 1, "t", &buf);
        try std.testing.expectEqualStrings("{foo}", result);
    }

    test "formatSplitTitle empty title" {
        var buf: [256]u8 = undefined;
        const result = formatSplitTitle("#{number}: {title}", 1, "", &buf);
        try std.testing.expectEqualStrings("#1: ", result);
    }

    pub fn setHeaderMode(self: *Self, mode: configpkg.Config.SplitHeaderMode) void {
        self.private().header_mode = mode;
        self.updateVisibility();
    }

    pub fn setSplitCount(self: *Self, count: u32) void {
        self.private().split_count = count;
        self.updateVisibility();
    }

    pub fn setPaneNumber(self: *Self, number: u32) void {
        self.private().pane_number = number;
        self.syncTitleLabel();
    }

    pub fn setBroadcastIndicator(self: *Self, active: bool) void {
        self.private().broadcast_icon.as(gtk.Widget).setVisible(@intFromBool(active));
    }

    fn updateVisibility(self: *Self) void {
        const priv = self.private();
        const visible = switch (priv.header_mode) {
            .off => false,
            .auto => blk: {
                const app = Application.default();
                const config_obj = app.getConfig();
                defer config_obj.unref();
                const threshold = @max(2, config_obj.get().@"split-header-auto-threshold");
                break :blk priv.split_count >= threshold;
            },
            .always => true,
            // manual visibility is controlled externally by SplitTree's toggle-header action
            .manual => false,
        };
        self.as(gtk.Widget).setVisible(@intFromBool(visible));
    }

    // Template callbacks

    fn onZoomClicked(
        _: *gtk.Button,
        self: *Self,
    ) callconv(.c) void {
        _ = self.as(gtk.Widget).activateAction("split-tree.zoom", null);
    }

    fn onCloseClicked(
        _: *gtk.Button,
        self: *Self,
    ) callconv(.c) void {
        _ = self.as(gtk.Widget).activateAction("split-tree.close-split", null);
    }

    fn onTitleClick(
        gesture: *gtk.GestureClick,
        n_press: c_int,
        x: f64,
        y: f64,
        self: *Self,
    ) callconv(.c) void {
        const button = gesture.as(gtk.GestureSingle).getCurrentButton();
        if (button == 3) {
            const popover = self.private().context_menu.as(gtk.Popover);
            const rect = gdk.Rectangle{ .f_x = @intFromFloat(x), .f_y = @intFromFloat(y), .f_width = 1, .f_height = 1 };
            popover.setPointingTo(&rect);
            popover.popup();
            return;
        }
        if (n_press == 2) {
            const app = @import("application.zig").Application.default();
            const config_obj = app.getConfig();
            defer config_obj.unref();
            const config = config_obj.get();
            switch (config.@"split-title-doubleclick-action") {
                .rename => _ = self.as(gtk.Widget).activateAction("split-header.rename", null),
                .zoom => _ = self.as(gtk.Widget).activateAction("split-tree.zoom", null),
                .none => {},
            }
        }
    }

    fn onMiddleClick(
        gesture: *gtk.GestureClick,
        _: c_int,
        _: f64,
        _: f64,
        self: *Self,
    ) callconv(.c) void {
        if (gesture.as(gtk.GestureSingle).getCurrentButton() != 2) return;
        // Check config to see if middle-click-close is enabled
        const app = @import("application.zig").Application.default();
        const config_obj = app.getConfig();
        defer config_obj.unref();
        const config = config_obj.get();
        if (config.@"split-header-middle-click-close") {
            _ = self.as(gtk.Widget).activateAction("split-tree.close-split", null);
        }
    }

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
            gobject.ext.ensureType(Surface);

            gtk.Widget.Class.setTemplateFromResource(
                class.as(gtk.Widget.Class),
                comptime gresource.blueprint(.{
                    .major = 1,
                    .minor = 5,
                    .name = "split-header",
                }),
            );

            // Template children
            class.bindTemplateChildPrivate("header_box", .{});
            class.bindTemplateChildPrivate("title_label", .{});
            class.bindTemplateChildPrivate("broadcast_icon", .{});
            class.bindTemplateChildPrivate("zoom_button", .{});
            class.bindTemplateChildPrivate("close_button", .{});
            class.bindTemplateChildPrivate("context_menu", .{});

            // Template callbacks
            class.bindTemplateCallback("on_zoom_clicked", &onZoomClicked);
            class.bindTemplateCallback("on_close_clicked", &onCloseClicked);
            class.bindTemplateCallback("on_title_click", &onTitleClick);
            class.bindTemplateCallback("on_middle_click", &onMiddleClick);

            // Properties
            gobject.ext.registerProperties(class, &.{
                properties.surface.impl,
            });

            // Virtual methods
            gobject.Object.virtual_methods.dispose.implement(class, &dispose);
            gobject.Object.virtual_methods.finalize.implement(class, &finalize);
        }

        pub const as = C.Class.as;
        pub const bindTemplateChildPrivate = C.Class.bindTemplateChildPrivate;
        pub const bindTemplateCallback = C.Class.bindTemplateCallback;
    };
};
