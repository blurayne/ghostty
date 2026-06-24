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
        title_binding: ?*gobject.Binding = null,
        header_mode: configpkg.Config.SplitHeaderMode = .auto,
        split_count: u32 = 1,

        pub var offset: c_int = 0;
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
        _ = gtk.DragSource.signals.@"drag-begin".connect(
            drag_source,
            *Self,
            onDragBegin,
            self,
            .{},
        );
        _ = gtk.DragSource.signals.@"drag-end".connect(
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
        drag_source.setIconPaintable(
            paintable.as(gdk.Paintable),
            @divTrunc(w, 4),
            @divTrunc(h, 4),
        );
    }

    fn onDragEnd(
        _: *gtk.DragSource,
        drag: *gdk.Drag,
        delete_data: bool,
        self: *Self,
    ) callconv(.c) void {
        // delete_data == true means the drop was accepted; false means cancelled/rejected
        if (delete_data) return;
        _ = drag;
        const surface = self.private().surface orelse return;
        // Don't tear off if from a zoomed tree (guard consistent with onDragPrepare)
        const tree = ext.getAncestor(SplitTree, self.as(gtk.Widget)) orelse return;
        if (tree.getIsZoomed()) return;
        Window.newWithSurface(Application.default(), surface, null);
    }

    fn dispose(self: *Self) callconv(.c) void {
        const priv = self.private();
        if (priv.title_binding) |b| {
            b.as(gobject.Object).unref();
            priv.title_binding = null;
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

        // Unbind old title binding
        if (priv.title_binding) |b| {
            b.as(gobject.Object).unref();
            priv.title_binding = null;
        }

        priv.surface = surface_;

        // Bind new surface title to label
        if (surface_) |s| {
            priv.title_label.as(gtk.Widget).setVisible(true);
            priv.title_binding = s.as(gobject.Object).bindProperty(
                "title",
                priv.title_label.as(gobject.Object),
                "label",
                .{ .sync_create = true },
            );
        } else {
            priv.title_label.as(gtk.Widget).setVisible(false);
        }
    }

    pub fn setHeaderMode(self: *Self, mode: configpkg.Config.SplitHeaderMode) void {
        self.private().header_mode = mode;
        self.updateVisibility();
    }

    pub fn setSplitCount(self: *Self, count: u32) void {
        self.private().split_count = count;
        self.updateVisibility();
    }

    pub fn setBroadcastIndicator(self: *Self, active: bool) void {
        self.private().broadcast_icon.as(gtk.Widget).setVisible(active);
    }

    fn updateVisibility(self: *Self) void {
        const priv = self.private();
        const visible = switch (priv.header_mode) {
            .off => false,
            .auto => priv.split_count > 2,
            .always => true,
            // manual visibility is controlled externally by SplitTree's toggle-header action
            .manual => false,
        };
        self.as(gtk.Widget).setVisible(visible);
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
        const button = gesture.getCurrentButton();
        if (button == 3) {
            const popover = self.private().context_menu.as(gtk.Popover);
            const rect = gdk.Rectangle{ .f_x = @intFromFloat(x), .f_y = @intFromFloat(y), .f_width = 1, .f_height = 1 };
            popover.setPointingTo(&rect);
            popover.popup();
            return;
        }
        if (n_press == 2) {
            _ = self.as(gtk.Widget).activateAction("split-tree.zoom", null);
        }
    }

    fn onMiddleClick(
        gesture: *gtk.GestureClick,
        _: c_int,
        _: f64,
        _: f64,
        self: *Self,
    ) callconv(.c) void {
        if (gesture.getCurrentButton() != 2) return;
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
