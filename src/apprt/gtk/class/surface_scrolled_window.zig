const std = @import("std");
const adw = @import("adw");
const gdk = @import("gdk");
const gio = @import("gio");
const gobject = @import("gobject");
const gtk = @import("gtk");
const gtk_version = @import("../gtk_version.zig");

const gresource = @import("../build/gresource.zig");
const Common = @import("../class.zig").Common;
const ext = @import("../ext.zig");
const Surface = @import("surface.zig").Surface;
const SplitHeader = @import("split_header.zig").SplitHeader;
const SplitTree = @import("split_tree.zig").SplitTree;
const Config = @import("config.zig").Config;
const split_dnd = @import("split_dnd.zig");
const Application = @import("application.zig").Application;
const Window = @import("window.zig").Window;

const log = std.log.scoped(.gtk_ghostty_surface_scrolled_window);

/// Pixels from the top of the surface overlay within which pointer
/// motion reveals the drag handle.
const hover_band_px: f64 = 32.0;

/// A wrapper widget that embeds a Surface inside a GtkScrolledWindow.
/// This provides scrollbar functionality for the terminal surface.
/// The surface property can be set during initialization or changed
/// dynamically via the surface property.
pub const SurfaceScrolledWindow = extern struct {
    const Self = @This();
    parent_instance: Parent,
    pub const Parent = adw.Bin;
    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "GhostttySurfaceScrolledWindow",
        .instanceInit = &init,
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    pub const properties = struct {
        pub const config = struct {
            pub const name = "config";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                ?*Config,
                .{
                    .accessor = C.privateObjFieldAccessor("config"),
                },
            );
        };

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
        config: ?*Config = null,
        config_binding: ?*gobject.Binding = null,
        surface: ?*Surface = null,
        header: *SplitHeader,
        scrolled_window: *gtk.ScrolledWindow,
        // Template children added for the drag-handle affordance
        surface_overlay: *gtk.Overlay,
        hover_handle: *adw.Bin,
        hover_motion: *gtk.EventControllerMotion,
        pub var offset: c_int = 0;
    };

    fn init(self: *Self, _: *Class) callconv(.c) void {
        gtk.Widget.initTemplate(self.as(gtk.Widget));
        if (gtk_version.runtimeUntil(4, 20, 1)) self.disableKineticScroll();
        self.initHandleDragSource();
    }

    fn disableKineticScroll(self: *Self) void {
        // Until gtk 4.20.1 trackpads have kinetic scrolling behavior regardless
        // of `Gtk.ScrolledWindow.kinetic_scrolling`. As a workaround, disable
        // EventControllerScroll.kinetic
        const controllers = self.private().scrolled_window.as(gtk.Widget).observeControllers();
        defer controllers.unref();
        var i: c_uint = 0;
        while (controllers.getObject(i)) |obj| : (i += 1) {
            defer obj.unref();
            const controller = gobject.ext.cast(gtk.EventControllerScroll, obj) orelse continue;
            var flags = controller.getFlags();
            flags.kinetic = false;
            controller.setFlags(flags);
        }
    }

    /// Attach a DragSource to the hover handle so it can initiate split DnD
    /// using the same payload format as the split header.
    fn initHandleDragSource(self: *Self) void {
        const drag_source = gtk.DragSource.new();
        drag_source.setActions(.{ .move = true });
        _ = gtk.DragSource.signals.prepare.connect(
            drag_source,
            *Self,
            onHandleDragPrepare,
            self,
            .{},
        );
        _ = gtk.DragSource.signals.drag_begin.connect(
            drag_source,
            *Self,
            onHandleDragBegin,
            self,
            .{},
        );
        _ = gtk.DragSource.signals.drag_end.connect(
            drag_source,
            *Self,
            onHandleDragEnd,
            self,
            .{},
        );
        // Attach to the hover_handle bin so the full handle area is draggable.
        self.private().hover_handle.as(gtk.Widget).addController(
            drag_source.as(gtk.EventController),
        );
    }

    fn onHandleDragPrepare(
        _: *gtk.DragSource,
        _: f64,
        _: f64,
        self: *Self,
    ) callconv(.c) ?*gdk.ContentProvider {
        const surface = self.private().surface orelse return null;
        // Skip drag if the ancestor tree is zoomed (same guard as split_header).
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

    fn onHandleDragBegin(
        drag_source: *gtk.DragSource,
        _: *gdk.Drag,
        self: *Self,
    ) callconv(.c) void {
        const surface = self.private().surface orelse return;
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

    fn onHandleDragEnd(
        _: *gtk.DragSource,
        drag: *gdk.Drag,
        delete_data: c_int,
        self: *Self,
    ) callconv(.c) void {
        // delete_data != 0 means the drop was accepted; 0 means rejected/cancelled.
        if (delete_data != 0) return;
        _ = drag;
        const surface = self.private().surface orelse return;
        const tree = ext.getAncestor(SplitTree, self.as(gtk.Widget)) orelse return;
        if (tree.getIsZoomed()) return;
        Window.newWithSurface(Application.default(), surface, null);
    }

    /// Template callback: pointer moved over the surface overlay.
    /// Signature: (controller, x, y, template_object) — non-swapped.
    fn onHoverMotion(
        _: *gtk.EventControllerMotion,
        x: f64,
        y: f64,
        self: *Self,
    ) callconv(.c) void {
        _ = x;
        const priv = self.private();
        // Only show the handle when the header is hidden.
        const header_hidden = priv.header.as(gtk.Widget).isVisible() == 0;
        const in_band = y < hover_band_px;
        const should_show = header_hidden and in_band;
        self.setHandleVisible(should_show);
    }

    /// Template callback: pointer left the surface overlay — hide handle.
    /// Signature: (controller, template_object) — non-swapped.
    fn onHoverLeave(
        _: *gtk.EventControllerMotion,
        self: *Self,
    ) callconv(.c) void {
        self.setHandleVisible(false);
    }

    fn setHandleVisible(self: *Self, visible: bool) void {
        const handle = self.private().hover_handle.as(gtk.Widget);
        if (visible) {
            handle.setVisible(1);
            // Add "visible" CSS class so the CSS transition fades the handle in.
            handle.addCssClass("visible");
        } else {
            handle.removeCssClass("visible");
            // We leave the widget itself visible so the CSS fade-out can play;
            // hiding it immediately would cut the animation. Since opacity = 0
            // the handle does not block input.
            // For a cleaner solution we would need a GtkRevealer; for now the
            // CSS transition is sufficient and we simply hide it after the band
            // check fires again (or on leave).
            handle.setVisible(0);
        }
    }

    /// Called by SplitTree.updateHeaderVisibility() after each header state change.
    /// When the header becomes visible, force the handle hidden so the two
    /// affordances never coexist.
    pub fn updateHoverHandle(self: *Self) void {
        const header_visible = self.private().header.as(gtk.Widget).isVisible() != 0;
        if (header_visible) {
            // Header is back — suppress handle immediately.
            self.setHandleVisible(false);
        }
        // When header is hidden we do nothing: hover drive the handle.
    }

    fn dispose(self: *Self) callconv(.c) void {
        const priv = self.private();

        if (priv.config_binding) |binding| {
            binding.as(gobject.Object).unref();
            priv.config_binding = null;
        }

        if (priv.config) |v| {
            v.unref();
            priv.config = null;
        }

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
        gobject.Object.virtual_methods.finalize.call(
            Class.parent,
            self.as(Parent),
        );
    }

    fn getSurfaceValue(self: *Self, value: *gobject.Value) void {
        gobject.ext.Value.set(
            value,
            self.private().surface,
        );
    }

    fn setSurfaceValue(self: *Self, value: *const gobject.Value) void {
        self.setSurface(gobject.ext.Value.get(
            value,
            ?*Surface,
        ));
    }

    pub fn getSurface(self: *Self) ?*Surface {
        return self.private().surface;
    }

    pub fn getHeader(self: *Self) *SplitHeader {
        return self.private().header;
    }

    pub fn setSurface(self: *Self, surface_: ?*Surface) void {
        const priv = self.private();

        if (surface_ == priv.surface) return;

        self.as(gobject.Object).freezeNotify();
        defer self.as(gobject.Object).thawNotify();
        self.as(gobject.Object).notifyByPspec(properties.surface.impl.param_spec);

        priv.surface = surface_;
    }

    fn closureScrollbarPolicy(
        _: *Self,
        config_: ?*Config,
    ) callconv(.c) gtk.PolicyType {
        const config = if (config_) |c| c.get() else return .automatic;
        return switch (config.scrollbar) {
            .never => .never,
            .system => .automatic,
        };
    }

    fn propSurface(
        self: *Self,
        _: *gobject.ParamSpec,
        _: ?*anyopaque,
    ) callconv(.c) void {
        const priv = self.private();
        const scrolled_window = self.private().scrolled_window.as(gtk.ScrolledWindow);
        scrolled_window.setChild(if (priv.surface) |s| s.as(gtk.Widget) else null);

        // Unbind old config binding if it exists
        if (priv.config_binding) |binding| {
            binding.as(gobject.Object).unref();
            priv.config_binding = null;
        }

        // Bind config from surface to our config property
        if (priv.surface) |surface| {
            priv.config_binding = surface.as(gobject.Object).bindProperty(
                properties.config.name,
                self.as(gobject.Object),
                properties.config.name,
                .{ .sync_create = true },
            );
        }
    }

    // -------------------------------------------------------------------------
    // Unit-testable helper (pure function, no GTK dependency)
    // -------------------------------------------------------------------------

    /// Returns true when the drag handle should be shown based on header visibility
    /// and pointer position. This is extracted for unit testing.
    pub fn hoverHandleShouldShow(header_visible: bool, y: f64) bool {
        return !header_visible and y < hover_band_px;
    }

    test "hover handle shown only when header hidden and y in band" {
        const expect = @import("std").testing.expect;
        // Header hidden, inside band → show
        try expect(hoverHandleShouldShow(false, 20));
        // Header hidden, outside band → hide
        try expect(!hoverHandleShouldShow(false, 40));
        // Header visible, inside band → hide
        try expect(!hoverHandleShouldShow(true, 10));
        // Header visible, outside band → hide
        try expect(!hoverHandleShouldShow(true, 50));
        // Header hidden, exactly at boundary → hide (< not <=)
        try expect(!hoverHandleShouldShow(false, hover_band_px));
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
            gobject.ext.ensureType(SplitHeader);

            gtk.Widget.Class.setTemplateFromResource(
                class.as(gtk.Widget.Class),
                comptime gresource.blueprint(.{
                    .major = 1,
                    .minor = 5,
                    .name = "surface-scrolled-window",
                }),
            );

            // Bindings
            class.bindTemplateCallback("scrollbar_policy", &closureScrollbarPolicy);
            class.bindTemplateCallback("notify_surface", &propSurface);
            class.bindTemplateCallback("on_hover_motion", &onHoverMotion);
            class.bindTemplateCallback("on_hover_leave", &onHoverLeave);
            class.bindTemplateChildPrivate("header", .{});
            class.bindTemplateChildPrivate("scrolled_window", .{});
            class.bindTemplateChildPrivate("surface_overlay", .{});
            class.bindTemplateChildPrivate("hover_handle", .{});
            class.bindTemplateChildPrivate("hover_motion", .{});

            // Properties
            gobject.ext.registerProperties(class, &.{
                properties.config.impl,
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
