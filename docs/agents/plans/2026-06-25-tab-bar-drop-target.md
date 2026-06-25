---
date: 2026-06-25
branch: main
topic: "Tab Bar as Split Drop Target"
tags: [plan, gtk, splits, dnd, tab-bar]
status: draft
---

# Tab Bar as Split Drop Target

## Overview

Extend the existing split DnD infrastructure (P5/P6) so that the Adwaita tab bar itself
becomes a drop zone during a split drag. Dragging a split header over the tab bar highlights
individual tabs; dropping moves the split into that tab's tree. Dropping past all tabs creates
a new tab holding the split.

## Existing Infrastructure

- `application/x-ghostty-split` MIME, `split_dnd.Payload { pid, uuid }` — from P5
- `SplitTree.moveSurfaceInto()` cross-tree path — from P6
- `Window.newWithSurface()` factory — from P7
- `adw.TabView` + `adw.TabBar` in `window.blp` / `window.zig`
- `findSurfaceByUuid()` in `application.zig`

## Desired End State

- During a split header drag, hovering over the tab bar dims tab labels and shows a
  "drop here" visual on the hovered tab.
- Dropping onto a tab appends the dragged split as the rightmost leaf in that tab's tree.
- Dropping onto empty space to the right of all tabs creates a new tab containing only the
  dragged split.
- If the source tab becomes empty after the move, it is closed automatically.
- Self-drop (source and target are the same tab) is a no-op.
- Cross-window drop works: the tab bar is a valid cross-window target just like the surface
  drop targets from P6.

## Architecture

`adw.TabBar` exposes an `extra-drag-types` property (since Adwaita 1.2) designed for exactly
this use case. Setting it to a `GType` array that includes `G_TYPE_BYTES` causes the tab bar
to:
1. Enter "drag mode" whenever a drag carrying `GBytes` (our split payload) passes over it.
2. Highlight the hovered tab automatically (native Adwaita hover state).
3. Emit `extra-drag-drop(page: *adw.TabPage, value: *gobject.Value)` on drop.

This avoids manual hit-testing and gives us per-tab targeting for free.

### Files Changed

```
src/apprt/gtk/class/window.zig          ← wire extra-drag-types + handler
src/apprt/gtk/ui/1.5/window.blp         ← (no change needed; wired in Zig)
src/apprt/gtk/class/split_dnd.zig       ← re-export Payload.parse (already exists)
```

No new files required.

---

## Phase TB1: Wire Tab Bar Drop Target

**Tasks**:
- [ ] In `window.zig`, after the `adw.TabBar` widget is realized (e.g., in a `map` signal
  or directly in `init` after `bindTemplateChildPrivate`), set:
  ```zig
  // Register GBytes as an extra drag type so adw.TabBar enters drag mode
  // when our application/x-ghostty-split payload (sent as GBytes) is dragged over.
  const bytes_gtype = glib.Bytes.getGType();
  priv.tab_bar.setExtraDragTypes(&.{bytes_gtype}, 1);
  ```
- [ ] Connect the `extra-drag-drop` signal on `priv.tab_bar`:
  ```zig
  _ = adw.TabBar.signals.extraDragDrop.connect(
      priv.tab_bar,
      *Self,
      onTabBarDrop,
      self,
      .{},
  );
  ```
- [ ] Implement `onTabBarDrop(tab_bar, page, value, self)`:
  1. Extract `*glib.Bytes` from `value` via `gobject.Value.getBoxed`.
  2. Call `split_dnd.Payload.parse(bytes)` — returns `?Payload`.
  3. If null or `payload.pid != getpid()` → return `false` (reject).
  4. Resolve source via `Application.default().findSurfaceByUuid(payload.uuid)` → `?*Surface`.
  5. Get source `SplitTree` via `surface.getAncestor(SplitTree)`.
  6. Get target `SplitTree` from `page`:
     ```zig
     const tab = Tab.fromPage(page);          // existing helper
     const target_tree = tab.priv.split_tree; // adjust to actual field name
     ```
  7. If source tree == target tree → return `false` (same tab, no-op).
  8. Find target tree's root leaf handle (use `target_tree.getTree().?.iterator().next()`
     to get the last leaf, so the dropped split appends to the right).
  9. Call `target_tree.moveSurfaceInto(source_tree, source_handle, target_leaf, .right)`.
  10. If source tree is now empty: close the source page via
      `source_window.priv.tab_view.closePage(source_page)`.
  11. Focus the target tab: `self.priv.tab_view.setSelectedPage(page)`.
  12. Return `true`.

- [ ] Add the "empty space → new tab" case via the `extra-drag-drop` signal on the
  `adw.TabView` itself (not the bar). `adw.TabView` also supports `extra-drag-types`;
  connect a separate handler that fires when the drop lands on the view chrome (below
  the last tab). This handler calls `Window.newWithSurface(app, surface, null)` and
  then removes the surface from the source tree.

**Automated Verification**:
- [ ] `zig build` passes.
- [ ] `zig build test -Dtest-filter="tab_bar_dnd"` passes — unit test covering payload
  parse + same-tab self-drop no-op.
- [ ] `zig fmt --check .` passes.

**Manual Verification**:
- [ ] Open two tabs each with two splits. Drag a split header up to the tab bar — the
  tab labels illuminate as cursor passes over each one.
- [ ] Drop on Tab 2 → split appears as a new pane in Tab 2; source tab retains its
  remaining split(s).
- [ ] Drag the only remaining split in Tab 1 onto Tab 2 → Tab 1 closes automatically.
- [ ] Drag a split past all tab labels onto empty bar space → new tab opens holding the split.
- [ ] Drop a split onto the tab it came from → nothing changes.
- [ ] Cross-window: drag from Window A's split header onto Window B's tab bar → split
  moves to Window B.
- [ ] The existing surface DropTarget (text/file drops) is unaffected.

---

## References

- Split DnD payload: `src/apprt/gtk/class/split_dnd.zig`
- Cross-tree move: `src/apprt/gtk/class/split_tree.zig` `moveSurfaceInto()`
- UUID lookup: `src/apprt/gtk/class/application.zig` `findSurfaceByUuid()`
- `Tab.fromPage`: `src/apprt/gtk/class/tab.zig`
- Adwaita `extra-drag-types` API: `adw.TabBar.setExtraDragTypes`, signal `extra-drag-drop`
- Tear-off factory: `src/apprt/gtk/class/window.zig` `newWithSurface()`
