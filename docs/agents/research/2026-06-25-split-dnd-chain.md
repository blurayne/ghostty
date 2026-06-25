---
date: 2026-06-25T10:17:33.954871+00:00
git_commit: e493eac615b47e81ce267885076b7bef99f829af
branch: feat/ghostty-tiling
topic: "Split drag-and-drop chain: source, targets, position computation, drop handling"
tags: [research, codebase, split-dnd, gtk, drag-and-drop, surface, split_tree]
status: complete
---

# Research: Split Drag-and-Drop Chain

## Research Question
Trace the existing drag-and-drop chain for splits in `src/apprt/gtk/class/`. Where is the drag started in `split_header.zig`, where is the drop target registered, what GTK controllers are used, how is the drop position computed today, and what happens on drop? Also look at `split_tree.zig` for the split direction enum and insertion logic.

## Summary

The split DnD system is already fully implemented. A drag is initiated from `SplitHeader` via a `gtk.DragSource` attached to `header_box`. The payload is a MIME-typed `glib.Bytes` blob (PID + UUID) serialized by `split_dnd.zig`. On the receive side, each `Surface` widget creates and attaches a dedicated `gtk.DropTarget` for the split MIME type. The drop position (quadrant: top/bottom/left/right) is computed from cursor coordinates using diagonal math in `split_dnd.quadrantFor`. The actual tree mutation is done by `SplitTree.moveSurfaceInto`, which supports both same-tree and cross-tree (cross-tab/cross-window) moves.

The visual feedback already exists as CSS classes (`dnd-target-top/bottom/left/right`) applied to the Surface widget during motion — these draw a 4px accent border on the appropriate edge.

```
src/apprt/gtk/class/
├── split_dnd.zig           — MIME type, Payload struct, quadrantFor()
├── split_header.zig        — DragSource controller, onDragPrepare/Begin/End
├── surface.zig             — DropTarget controller, enter/motion/leave/drop handlers, clearDndClasses
├── split_tree.zig          — moveSurfaceInto(), Tree.split() direction enum, SplitTreeSplit widget
└── surface_scrolled_window.zig — wraps Surface + SplitHeader in Box inside adw.Bin

src/apprt/gtk/css/style.css — .dnd-target-{top,bottom,left,right} CSS classes
src/apprt/gtk/ui/1.2/surface.blp — DropTarget in the Overlay, DrawingArea for unfocused-split
```

## Detailed Findings

### split_dnd.zig — Shared DnD utilities
**File:** `src/apprt/gtk/class/split_dnd.zig`

- `MIME = "application/x-ghostty-split"` — the custom MIME type.
- `Payload` — extern struct with `pid: i32` and `uuid: [16]u8`. Serialized/parsed as raw bytes in a `glib.Bytes`.
- `Quadrant` enum — `.top`, `.bottom`, `.left`, `.right`.
- `quadrantFor(x, y, w, h) Quadrant` — divides widget area into 4 diagonal quadrants. Uses normalized coordinates and two diagonal comparisons (`norm_y < norm_x` and `norm_y < 1-norm_x`) to classify which quadrant the cursor is in. Has unit tests.

### split_header.zig — Drag Source
**File:** `src/apprt/gtk/class/split_header.zig:106-133`

- `initDragSource()` is called in `init()` (line 71).
- Creates a `gtk.DragSource` with `.move` action.
- Attaches it to `header_box` (the template child), not to the `SplitHeader` itself.
- Three signal callbacks:
  - `onDragPrepare` (line 135): creates `gdk.ContentProvider` with the serialized Payload. Returns `null` (aborts drag) if tree is zoomed.
  - `onDragBegin` (line 155): sets the drag icon to a `gtk.WidgetPaintable` of the `Surface`, offset by ¼ of its size.
  - `onDragEnd` (line 173): if `delete_data == 0` (drag cancelled/rejected), tears off the surface into a new window via `Window.newWithSurface`.

### surface.zig — Drop Target
**File:** `src/apprt/gtk/class/surface.zig:1858-1888`

Initialized inside Surface's `init`:
- Creates `gtk.DropTarget` for `glib.Bytes.getGObjectType()` with `.move` action.
- Connects four signals:
  - `onSplitDragEnter` (line 2791): sets cursor to `"grabbing"`, returns `.{ .move = true }`. Returns `{}` (reject) if tree is zoomed.
  - `onSplitDragMotion` (line 2802): clears old DnD CSS classes, computes `quadrantFor(x, y, w, h)`, adds the matching `dnd-target-{top/bottom/left/right}` CSS class. Returns `.{ .move = true }`.
  - `onSplitDragLeave` (line 2824): clears CSS classes, resets cursor to `"text"`.
  - `onSplitDrop` (line 2832): full drop handler (see below).
- Added via `addController` to the Surface widget.

The Surface also has a general-purpose `drop_target` in its blueprint (line 3824 template bind) for file/string drops — this is separate from the split DropTarget.

#### onSplitDrop logic (line 2832–2903)
1. Parse `Payload` from `glib.Bytes`.
2. Verify same PID (rejects cross-process drops).
3. Locate source surface by UUID via `Application.findSurfaceByUuid`.
4. Reject self-drop, reject if source is in zoomed tree.
5. Locate `source_tree` and `target_tree` via `ext.getAncestor(SplitTree, ...)`.
6. Find `source_handle` by iterating source tree until `e.view == source`.
7. Find `target_handle` by iterating target tree until `e.view == self`.
8. Compute drop direction: `quadrantFor(x, y, w, h)` → `.top`→`.up`, `.bottom`→`.down`, `.left`→`.left`, `.right`→`.right`.
9. Call `target_tree.moveSurfaceInto(source_tree, source_handle, target_handle, direction)`.

### split_tree.zig — Tree Mutation
**File:** `src/apprt/gtk/class/split_tree.zig`

#### `Surface.Tree.Split.Direction` enum
Referenced at lines 219, 339, 703, etc. Values: `.up`, `.down`, `.left`, `.right`. Used by `newSplit`, `resize`, `goto`, and `moveSurfaceInto`.

#### `moveSurfaceInto` (line 747–871)
The central drop handler that mutates the tree:
- **Same-tree move:** Removes source from tree → finds new target handle by pointer → wraps source in single-leaf tree → `tree.split(alloc, new_target_handle, direction, 0.5, &source_single_tree)` → `setTree`.
- **Cross-tree move:** Removes source from source tree. If source tree becomes empty, walks up to `adw.TabView` and closes the page. Otherwise updates source tree. Then splits target tree. Finally focuses the destination tab.

#### `SplitTreeSplit` (line 1351–1646)
Internal widget wrapping `gtk.Paned`. Created by `buildTree` for split nodes. Layout is `horizontal` for left/right splits and `vertical` for up/down. The split ratio is tracked in `Surface.Tree.Split.ratio` (f64).

### surface_scrolled_window.zig — Widget Wrapper
**File:** `src/apprt/gtk/class/surface_scrolled_window.zig`

`SurfaceScrolledWindow` wraps `SplitHeader` + `gtk.ScrolledWindow` in a vertical `gtk.Box` inside an `adw.Bin`. The Surface itself is set as the child of the `ScrolledWindow`.

### Existing Visual Feedback — CSS Classes
**File:** `src/apprt/gtk/css/style.css:183-197`

Four CSS classes exist and are already applied on motion:
```css
.dnd-target-top    { border-top: 4px solid @accent_bg_color; }
.dnd-target-bottom { border-bottom: 4px solid @accent_bg_color; }
.dnd-target-left   { border-left: 4px solid @accent_bg_color; }
.dnd-target-right  { border-right: 4px solid @accent_bg_color; }
```
These produce a thin 4px edge highlight — not a quadrant fill overlay.

### Blueprint: surface.blp — Overlay Structure
**File:** `src/apprt/gtk/ui/1.2/surface.blp`

The root of `GhosttySurface` template is `Adw.Bin`. Its child is `terminal_page` — a `gtk.Overlay`. The overlay has these layers (in order):
1. Main `Box` with `GLArea` + controllers (the actual terminal).
2. Multiple `[overlay]` children: `Revealer` (readonly), `ProgressBar`, `Revealer` (bell), `child_exited_overlay`, `ResizeOverlay`, URL labels, `SearchOverlay`, `KeyStateOverlay`, `Revealer`+`DrawingArea` (unfocused-split).
3. `DropTarget drop_target` for file/string drops.

The `DrawingArea` used for `unfocused-split` (line 217) is inside a `Revealer` with `can-target: false` — it draws but does not intercept events. This is the pattern available for custom drawing overlays.

## Code References
- `src/apprt/gtk/class/split_dnd.zig:4` — MIME type constant
- `src/apprt/gtk/class/split_dnd.zig:6-23` — Payload struct + serialize/parse
- `src/apprt/gtk/class/split_dnd.zig:26-43` — `Quadrant` enum + `quadrantFor()` 
- `src/apprt/gtk/class/split_header.zig:106-133` — `initDragSource()` — attaches DragSource to header_box
- `src/apprt/gtk/class/split_header.zig:135-153` — `onDragPrepare` — creates ContentProvider with Payload
- `src/apprt/gtk/class/split_header.zig:155-171` — `onDragBegin` — sets WidgetPaintable drag icon
- `src/apprt/gtk/class/split_header.zig:173-187` — `onDragEnd` — tear-off to new window on cancel
- `src/apprt/gtk/class/surface.zig:1858-1888` — DropTarget creation and signal connections
- `src/apprt/gtk/class/surface.zig:2779-2830` — `clearDndClasses`, `onSplitDragEnter`, `onSplitDragMotion`, `onSplitDragLeave`
- `src/apprt/gtk/class/surface.zig:2832-2903` — `onSplitDrop` — full drop handling
- `src/apprt/gtk/class/split_tree.zig:747-871` — `moveSurfaceInto` — tree mutation on drop
- `src/apprt/gtk/css/style.css:183-197` — DnD CSS indicator classes
- `src/apprt/gtk/ui/1.2/surface.blp:15-228` — Overlay structure with DrawingArea pattern

## Architecture Documentation

The system uses a **producer/consumer** pattern:
- **Producer:** `SplitHeader` owns the `gtk.DragSource` on its inner `header_box`.
- **Consumer:** `Surface` creates its own `gtk.DropTarget` in `init`, separate from the file-drop target.
- **Payload:** A PID+UUID struct serialized to `glib.Bytes` under a custom MIME type.
- **Position:** Computed at both motion and drop time using diagonal quadrant math.
- **Mutation:** All tree changes go through `SplitTree.moveSurfaceInto`, which is the single point of truth for both same-tree and cross-tree (cross-tab) moves.
- **Visual feedback (current):** CSS class additions/removals on the Surface widget, producing a 4px accent border on the active edge.

The existing CSS approach (border on one edge) gives directional hint but does not show the full quadrant breakdown visually. The `DrawingArea`-in-`Revealer` pattern (used for unfocused-split dimming) is the established way to add non-interactive drawing overlays to the surface.
