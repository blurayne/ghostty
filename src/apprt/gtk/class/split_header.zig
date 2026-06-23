const std = @import("std");
const adw = @import("adw");
const gobject = @import("gobject");
const gtk = @import("gtk");

const configpkg = @import("../../../config.zig");
const gresource = @import("../build/gresource.zig");
const Common = @import("../class.zig").Common;
const Surface = @import("surface.zig").Surface;

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
        title_label: *gtk.Label,
        broadcast_icon: *gtk.Image,
        zoom_button: *gtk.Button,
        close_button: *gtk.Button,

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
        _: *gtk.GestureClick,
        n_press: c_int,
        _: f64,
        _: f64,
        self: *Self,
    ) callconv(.c) void {
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
            class.bindTemplateChildPrivate("title_label", .{});
            class.bindTemplateChildPrivate("broadcast_icon", .{});
            class.bindTemplateChildPrivate("zoom_button", .{});
            class.bindTemplateChildPrivate("close_button", .{});

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
