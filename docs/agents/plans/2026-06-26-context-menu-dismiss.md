# Plan: Fix Context Menu Dismiss on Click
Date: 2026-06-26
Priority: P2 (bug)
Status: planned

## Bug Description

**What happens:** Right-clicking in a terminal split opens a `GtkPopoverMenu` context menu. Clicking anywhere else in the same split, in a different split, or elsewhere in the app window does NOT automatically dismiss the menu. The user must press Escape or select a menu item to close it.

**What should happen:** Clicking anywhere outside the popover should dismiss it immediately, matching standard GTK4 application behaviour.

## Root Cause Analysis

### Widget structure

The context menu and click handler live together in the `GhosttySurface` widget, defined in:

- **Blueprint:** `src/apprt/gtk/ui/1.2/surface.blp`
- **Implementation:** `src/apprt/gtk/class/surface.zig`

The relevant widget tree (from `surface.blp:15-79`):

```
Overlay terminal_page
  child: Box
    GLArea gl_area          ← focusable: true, focus-on-click: true
    PopoverMenu context_menu ← autohide is NOT explicitly set (should default to true)
    EventControllerFocus
    EventControllerKey
    EventControllerScroll × 2
    EventControllerMotion
    GestureClick            ← button: 0 (ALL buttons), no propagation-phase (defaults to bubble)
```

### How the menu is shown

`gcMouseDown` (`surface.zig:3054`) handles all button presses. On a right-click that is not consumed by the terminal core, it calls `popover.popup()` (`surface.zig:3122-3124`).

### Why autohide fails

GTK4's `GtkPopoverMenu` autohide mechanism works differently depending on the display server:

- **Wayland:** The popover is an `xdg_popup`. The compositor sends `popup_done` when the user clicks outside, which GTK translates into a `popdown()`. This is entirely compositor-side and happens before any GTK event processing.
- **X11:** GTK installs a pointer grab via `gdk_seat_grab`. All subsequent pointer events are routed to the grab owner (the popover's native window), so widgets underneath never receive them — correct dismiss would normally be automatic.

#### The blocking interaction

When the context menu is visible and the user clicks anywhere in the same (or another) terminal surface, `gcMouseDown` fires via the `GestureClick` attached to `Box`. At line `surface.zig:3073-3074`, the handler unconditionally calls:

```zig
if (!had_focus) {
    _ = gl_area_widget.grabFocus();
}
```

And regardless of focus state, the handler proceeds to call `core_surface.mouseButtonCallback(...)`.

Two compounding issues:

1. **`grabFocus()` racing with the popover grab (X11):** On X11, calling `gtk_widget_grab_focus` while a pointer grab is active by the popover can confuse GTK's internal grab stack. The focus change causes GTK to call `gdk_seat_ungrab` as a side effect in some GTK4 versions, which releases the popover's grab without triggering `popdown()`. The popover then remains visible but inert.

2. **`GestureClick` claiming the event before the popover's dismiss controller (Wayland/X11 edge cases):** The `GestureClick` on `Box` runs in the **bubble phase** (default). GTK4's popover installs a capture-phase controller at the native window level to handle dismiss. In theory capture fires first — but because `Box` is the direct parent of the `PopoverMenu`, GTK's hit-testing may classify clicks on the `Box` as "inside the popover's parent widget" and skip the dismiss path in some GTK versions.

3. **No explicit `popdown()` before processing the new click:** The `gcMouseDown` handler opens a new menu on right-click but never calls `popdown()` on an already-open menu before processing any click. This means a left-click while the menu is open never explicitly closes it.

The net result is that neither the automatic dismiss path nor any manual `popdown()` is reliably triggered when the user clicks in the terminal area.

## Fix

### Primary fix: explicitly dismiss the popover at the start of every `gcMouseDown`

Add a `popdown()` call at the very beginning of `gcMouseDown`, before any focus or event handling. Because `popdown()` is a no-op when the popover is already hidden, this is safe and has no side effects for normal clicks.

```zig
fn gcMouseDown(
    gesture: *gtk.GestureClick,
    _: c_int,
    x: f64,
    y: f64,
    self: *Self,
) callconv(.c) void {
    const event = gesture.as(gtk.EventController).getCurrentEvent() orelse return;

    // Dismiss the context menu if it is open. This handles the case where
    // GTK's autohide mechanism fails to fire (e.g. on X11 when grabFocus()
    // races with the popover's pointer grab, or when the popover's parent
    // widget captures the click before the window-level dismiss controller).
    const priv = self.private();
    priv.context_menu.as(gtk.Popover).popdown();

    // ... rest of existing handler unchanged ...
```

### Secondary fix (belt-and-suspenders): ensure autohide is explicitly enabled

In `surface.blp`, explicitly set `autohide: true` on the `PopoverMenu` so the intent is clear and not accidentally overridden by a future Blueprint change:

```blp
PopoverMenu context_menu {
  closed => $context_menu_closed();
  menu-model: context_menu_model;
  flags: nested;
  halign: start;
  has-arrow: false;
  autohide: true;   // ← add this line
}
```

### Why not rely solely on autohide?

Fixing the autohide property alone is insufficient because the `grabFocus()` call on X11 can still release the popover's grab before GTK processes the dismiss event. The explicit `popdown()` is the only guarantee that works across X11 and Wayland, across GTK patch versions.

## Implementation Steps

1. **Edit `src/apprt/gtk/class/surface.zig`**
   - At `surface.zig:3060` (start of `gcMouseDown` body, before the `getBellRinging` call), add:
     ```zig
     // Dismiss any open context menu before processing this click.
     self.private().context_menu.as(gtk.Popover).popdown();
     ```
   - Note: `priv` is already declared later in the function — move the `const priv = self.private();` line to before the new `popdown()` call (currently at `surface.zig:3067`), or access it directly as shown above.

2. **Edit `src/apprt/gtk/ui/1.2/surface.blp`**
   - At `surface.blp:44` (inside the `PopoverMenu context_menu` block, after `has-arrow: false;`), add:
     ```blp
     autohide: true;
     ```

3. **Manual verification**
   - Build with `zig build`
   - Open Ghostty, right-click to show context menu
   - Left-click in the same split → menu should dismiss
   - Left-click in a different split → menu should dismiss
   - Repeat on both X11 and Wayland sessions if possible

## Files to Change

- `src/apprt/gtk/class/surface.zig` — add `popdown()` at the top of `gcMouseDown` (~line 3060)
- `src/apprt/gtk/ui/1.2/surface.blp` — add `autohide: true` to `PopoverMenu context_menu` (~line 44)
