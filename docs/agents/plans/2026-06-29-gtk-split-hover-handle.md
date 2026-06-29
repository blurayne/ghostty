# Plan: GTK Split Drag Hover Handle
Date: 2026-06-29
Priority: P6.5
Status: in-progress

## Goal

When a split's header bar is hidden (any of the five reasons: `split-header = off`, auto below
threshold, manual toggle, chromeless window, override-hidden), surface the same grab affordance that
macOS #10090 provides: a small drag-handle appears when the pointer enters the top ~32 px of the
terminal surface, letting the user initiate the existing split-DnD flow without needing the header
bar.

## Scope

**In scope:**

1. **`SplitDragHandle` widget** — a new small overlay (`adw.Bin` subclass, not template-driven)
   that renders a `gtk.Image` with the `"view-list-symbolic"` icon. Sized 24×8 dp, centred
   horizontally, positioned 4 dp from the top of its parent. Initially `visible = false`.
2. **Hover-near-top detection** — an `EventControllerMotion` added to the
   `SurfaceScrolledWindow`. When motion enters the top 32-pixel band (y < 32) and the split header
   is hidden, show the handle; otherwise hide it. The controller also hides the handle on leave.
3. **Drag source on the handle** — `gtk.DragSource` attached to the handle's inner image widget,
   using the same `split_dnd.MIME`, `split_dnd.Payload`, and `drag_begin`/`drag_end` callbacks
   already used by `SplitHeader.initDragSource`. Zoomed-tree guard identical to the header.
4. **Suppression hook** — `SurfaceScrolledWindow.updateHoverHandleVisibility()` is called from
   `SplitTree.updateHeaderVisibility()` (after the per-header mutations). It reads
   `header.as(gtk.Widget).isVisible()` and, if the header is now visible, forces the hover handle
   hidden.
5. **CSS fade** — the handle widget gets a CSS class `split-drag-handle` with
   `transition: opacity 150ms ease` so show/hide fades rather than snapping.

**Out of scope:**

- No new config key.
- No changes to macOS code.
- No changes to drop targets or DnD wire-up beyond the new drag source.
- No pixel-perfect macOS look — functional drag pickup is the goal.

## Widget Hierarchy

Current `SurfaceScrolledWindow` layout:

```
SurfaceScrolledWindow (Adw.Bin)
  Gtk.Box (vertical)
    GhosttySplitHeader          ← visible when header on
    Adw.Bin (vexpand)
      Gtk.ScrolledWindow        ← contains Surface
```

New layout (the Overlay wraps the inner Adw.Bin, not the whole Box):

```
SurfaceScrolledWindow (Adw.Bin)
  Gtk.Box (vertical)
    GhosttySplitHeader          ← visible when header on
    Gtk.Overlay                 ← NEW: wraps the scrolled-window bin
      Adw.Bin (vexpand)
        Gtk.ScrolledWindow      ← unchanged
      [overlay] GhosttyHandleOverlay  ← NEW: invisible until hover
```

The overlay child is a thin `Adw.Bin` (`handle_overlay`) with:
- `halign: center`
- `valign: start`
- `margin-top: 4`
- `can-target: true` (so it can receive clicks and start the drag)
- `visible: false` initially

Inside it: a `Gtk.Image` (`icon-name: "view-list-symbolic"`, `pixel-size: 16`), wrapped in an
`Adw.Bin` with CSS class `split-drag-handle` (adds sizing / rounded corners).

The `EventControllerMotion` is placed on the same `Gtk.Overlay` widget so it receives events from
the full stacked area.

## Hover Region

y < 32 px from the top of the `Gtk.Overlay` widget (covers the header-absent area). This is
intentionally slightly larger than the visible 24-px handle to give a generous activation zone.
When the split header is visible the condition `header.visible == false` is false so the handle is
never shown even if y < 32.

## Drag-Source Wiring

Identical to `SplitHeader.initDragSource` except:
- The controller is added to the **handle image** widget (not the header_box).
- `onDragPrepare` finds the surface by walking up to `SurfaceScrolledWindow` and reading its
  `surface` property.
- `onDragBegin` uses `WidgetPaintable` from the surface, offset to quarter-size, same as the header.
- `onDragEnd` tears off to a new window when the drop is rejected, same as the header.

All logic reuses `split_dnd.Payload`, `split_dnd.MIME`, and the `Application.default()` allocator —
no new protocol.

## Suppression Hook

`SplitTree.updateHeaderVisibility()` already calls `header.setVisible(...)` on each leaf's header.
After each such mutation we also call
`ssw.updateHoverHandle()` which does:

```zig
pub fn updateHoverHandle(self: *Self) void {
    const header_visible = self.private().header.as(gtk.Widget).isVisible() != 0;
    if (header_visible) {
        // Force handle hidden — drag via header is available
        self.private().hover_handle.as(gtk.Widget).setVisible(0);
    }
    // If header is hidden the handle becomes eligible again (hover shows it)
}
```

This is a one-way suppression: showing the handle is always driven by hover, never by this hook.

## Edge Cases

| Scenario | Behavior |
|---|---|
| **Zoomed split** | `onDragPrepare` checks `tree.getIsZoomed()` and returns null; drag doesn't start. Handle still shows (cosmetic), which is acceptable. |
| **Single-pane no-header** | `split-header = off` → header hidden → handle shows on hover. Drag initiates a tear-off (single-pane `onDragEnd` → `Window.newWithSurface`). |
| **Header just became visible mid-hover** | `updateHoverHandle()` forces handle hidden immediately. Motion controller still fires on next movement and would show the handle only if header is still hidden — so there is no jitter. |
| **Torn-off window** | torn-off windows force the header visible; handle suppressed by hook. |
| **Chromeless mode** | chromeless forces header visible; handle suppressed. |
| **Rapid show/hide** | 150 ms CSS transition; no timer-based show/hide in Zig code, so no source leak. |
| **Multiple splits** | Each `SurfaceScrolledWindow` owns its own overlay, motion controller, and handle; they are fully independent. |
| **Keyboard navigation / AT** | Handle has `can-focus: false` and no accessible label — it is purely a drag affordance; keyboard DnD is not part of this feature. |

## Files Touched

| File | Change |
|---|---|
| `src/apprt/gtk/class/split_handle.zig` | **NEW** — `SplitHandle` GObject: overlay image + drag source + `updateVisibility()` |
| `src/apprt/gtk/class/surface_scrolled_window.zig` | Add `hover_handle` private field, motion controller, call `handle.updateVisibility(header_visible)` |
| `src/apprt/gtk/ui/1.5/surface-scrolled-window.blp` | Wrap inner `Adw.Bin` in `Gtk.Overlay`; add `$GhosttyHandleOverlay` as overlay child |
| `src/apprt/gtk/class/split_tree.zig` | In `updateHeaderVisibility()`, after mutating each header, call `ssw.updateHoverHandle()` |
| `src/apprt/gtk/css/style.css` | Add `.split-drag-handle` CSS rule with fade transition |
| `src/apprt/gtk/build/gresource.zig` | Register new blueprint (if approach requires one — see note below) |

**Note on blueprint vs. pure Zig:** The `SplitHandle` widget is simple enough to construct entirely
in Zig (`init` function) without a Blueprint file, avoiding the need to add a new blueprint entry.
The overlay and motion controller are assembled in Zig inside `SurfaceScrolledWindow.init` or
lazily when the surface is first set.

**Revised approach (no new blueprint, no new GObject class):** After reviewing the existing code
more carefully, the simplest implementation is:

1. In `surface-scrolled-window.blp`: wrap the existing `Adw.Bin { vexpand; ScrolledWindow }` in a
   `Gtk.Overlay` and add a child `Adw.Bin hover_handle { ... Gtk.Image }` as an overlay child.
2. Bind `hover_handle` as a template child in `SurfaceScrolledWindow`.
3. Add an `EventControllerMotion` (also a template child or added in `init`) on the overlay.
4. Add the drag source on the image in `SurfaceScrolledWindow.init`.

This avoids creating a new GObject class entirely.

## Phases

1. **Phase 1** — Plan (this document). ✓
2. **Phase 2** — Add CSS rule for `.split-drag-handle`.
3. **Phase 3** — Update `surface-scrolled-window.blp`: wrap in Overlay, add handle overlay child.
4. **Phase 4** — Update `SurfaceScrolledWindow.zig`: add private fields, motion callbacks,
   drag source init, `updateHoverHandle()` public method.
5. **Phase 5** — Update `SplitTree.updateHeaderVisibility()` to call `ssw.updateHoverHandle()`.
6. **Phase 6** — Build check: `mise run zig-build`.
7. **Phase 7** — Targeted test for the visibility logic: compile-only (runtime GTK tests are not
   feasible here; the unit-testable part is the `formatSplitTitle`-style logic which is trivially
   correct).
8. **Phase 8** — Commit on `feat/gtk-split-hover-handle`.

## Test Approach

The visibility-vs-header logic is purely conditional (no allocations, no timers). A Zig unit test
inside `surface_scrolled_window.zig` can test the decision function in isolation:

```zig
// updateHoverHandleNeeded(header_visible: bool, y: f64) bool
test "hover handle shown only when header hidden and y in band" {
    try expect(updateHoverHandleNeeded(false, 20) == true);   // header hidden, y < 32
    try expect(updateHoverHandleNeeded(false, 40) == false);  // header hidden, y >= 32
    try expect(updateHoverHandleNeeded(true, 10)  == false);  // header visible → always false
}
```

## References

- `src/apprt/gtk/class/split_header.zig` — drag source reference implementation
- `src/apprt/gtk/class/split_dnd.zig` — MIME / Payload / Quadrant
- `src/apprt/gtk/class/split_tree.zig` — `updateHeaderVisibility()`
- `src/apprt/gtk/class/surface_scrolled_window.zig` — host widget
- `src/apprt/gtk/ui/1.5/surface-scrolled-window.blp` — blueprint to modify
- `src/apprt/gtk/css/style.css` — CSS to extend
- macOS reference: `macos/Sources/Ghostty/SwiftUI/Surface*.swift` (PR #10090)
