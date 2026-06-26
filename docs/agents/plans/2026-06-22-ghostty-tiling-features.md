---
date: 2026-06-22T14:19:08+00:00
git_commit: 4749c4e93731067049bfbf2e4572061cef2bdd17
branch: main
topic: "Ghostty Tiling Features (Linux GTK)"
tags: [plan, gtk, splits, tiling, dnd, header-bar]
status: draft
---

# Ghostty Tiling Features Implementation Plan

## Overview

Implement the tiling, split header bar, drag-and-drop, indexed split navigation, zoom-swap, and tear-off behavior described in `GHOSTTY_TILING_SPEC.md` (sections §1–§17). Targets the Linux GTK app runtime (`src/apprt/gtk/`). Broadcast input (P8), layout save/restore (P9), and macOS feature parity are deferred to `IDEAS.md`.

## Current State Analysis

- `src/apprt/gtk/` is the active GTK app runtime (the `gtk-ng` path mentioned in the spec was renamed to `gtk` before this plan). All file references in this plan use the real path.
- Split tree is split across two layers:
  - **Datastructure**: `src/datastruct/split_tree.zig` — immutable arena-backed binary tree. Leaves hold `*View` (a `*Surface` in GTK), internal nodes are `Split { layout, ratio: f16, left, right }`. Zoom is a single `?Node.Handle` on the tree. Iterator yields leaves in node-array order, which equals creation order because `split()` appends to the nodes slice.
  - **GTK wrapper**: `src/apprt/gtk/class/split_tree.zig` (`SplitTree` widget) + `SplitTreeSplit` (wraps `gtk.Paned`). `tab.blp` embeds the `SplitTree` directly; surfaces are wrapped per leaf in `SurfaceScrolledWindow`.
- Action enum lives in `src/input/Binding.zig` (`Action` union) with a parallel apprt action enum in `src/apprt/action.zig`. GTK dispatches in `src/apprt/gtk/class/application.zig:670-799` (`performAction()`).
- Linux default keybinds are registered in `src/config/Config.zig` `Keybinds.init()`, Linux block at `6611-6821` using `self.set.put()` / `self.set.putFlags()`.
- GTK 4 DnD primitives already used: `Surface` has a `gtk.DropTarget` (`surface.zig:715`) for text/file drops; no `gtk.DragSource` anywhere. No `application/x-*` MIME types in use.
- No per-split chrome exists today. The terminal surface fills its `SurfaceScrolledWindow` Adw.Bin.
- Existing actions: `new_split`, `goto_split`, `equalize_splits`, `toggle_split_zoom`, `close_surface`, `toggle_readonly`, `resize_split`, `toggle_fullscreen`, `toggle_tab_overview`. Missing: `goto_split_index`, `move_split_to_new_window`, `toggle_split_header`.
- Adwaita `TabView` is used for tabs (`window.zig:265`). Tab context menu exists (`setup-menu` signal) but currently surfaces close/duplicate. No "Detach to New Window" entry on tabs.
- macOS Swift has its own action mirror (`macos/Sources/Ghostty/GhosttyPackage.swift`) — out of scope here; tracked in `IDEAS.md`.

## Desired End State

After this plan ships:

- Five new Linux default keybinds are wired (`F11`, `F12`, `Ctrl+Shift+G`, `Super+Ctrl+=`, `Ctrl+Shift+H`).
- A `Paned` divider double-click triggers `equalize_splits`.
- `goto_split_index: usize` action exists, focuses leaves in tree creation order.
- A configurable per-split header bar exists with title / broadcast-indicator slot (hidden until broadcast lands) / zoom / close + context menu.
- Splits can be drag-and-dropped by the header bar onto other splits (with quadrant detection), into other tabs, into other windows of the same Ghostty instance, or torn off to create a new window.
- `move_split_to_new_window` exists and is reachable from the header context menu and (in P7+P12) the tab context menu (whole-tab tear-off is in P12).
- When a tab is zoomed, `goto_split:*` / `goto_split_index` transfers the zoom rather than un-zoom/re-zoom.

## What We're NOT Doing

- Broadcast input (`P8`) — deferred to `IDEAS.md`.
- Save / restore tab layout JSON (`P9`) — deferred to `IDEAS.md`.
- macOS parity for the new actions, header bar, DnD, tear-off — deferred to `IDEAS.md`.
- New keybinds that would collide with existing Ghostty defaults (the spec §14 ledger is honored exactly).
- Action plumbing for `toggle_broadcast_input` / `toggle_broadcast_opt_out` / `save_tab_layout` / `load_tab_layout` — registered only when the deferred phases land.
- Touching the `goto_window:next|prev` action.

## UI Mockups

### Split header bar (P4)

```
┌────────────────────────────────────────────────────────────┐
│ user@host:~/src                          [B] [□] [×]      │  ← header bar (drag handle)
├────────────────────────────────────────────────────────────┤
│                                                            │
│  $ _                                                       │  ← terminal surface
│                                                            │
└────────────────────────────────────────────────────────────┘

Title         left: live surface title, click→menu, dbl-click→zoom
[B]           broadcast indicator (visible only when §11 ships)
[□] / [▣]     zoom button (icon toggles)
[×]           close button
```

### DnD quadrant overlay (P5)

```
Hovering over target split, accent border shows direction:

      top quadrant → "insert above"
┌────────────────────────┐
│        ▲ top edge ▲    │
│   ╲              ╱     │
│     ╲          ╱       │
│       ╲      ╱         │
│ left   ╲   ╱   right   │  left/right edges highlight on side hover
│         ╲ ╱            │
│         ╱ ╲            │
│       ╱     ╲          │
│     ╱         ╲        │
│   ╱             ╲      │
│        ▼ bot edge ▼    │
└────────────────────────┘
      bottom quadrant → "insert below"
```

### Split header context menu (P4)

```
┌─────────────────────────────┐
│ Split Right              ⌘O │  ← P12 (§16 menus)
│ Split Down               ⌘E │
├─────────────────────────────┤
│ Move to New Window          │  ← P4 (was P7 wiring)
│ Toggle Read-Only            │
│ Equalize Splits             │
├─────────────────────────────┤
│ Close                       │
└─────────────────────────────┘
```

### Tab context menu (P12)

```
existing items + new "Detach into New Window"
```

## Architecture and Code Reuse

The plan reuses three existing systems:

1. **Immutable split tree** (`src/datastruct/split_tree.zig`) — every mutation already produces a new tree which the `SplitTree` widget swaps in via `setTree()`. DnD detach + drop becomes "remove leaf from source tree, split target tree, insert leaf" — both are existing operations (`remove`, `split`).
2. **GAction map on `SplitTree`** (`split_tree.zig:186-200`) — new GActions (`equalize`, `toggle_header`, `move-to-new-window`) follow the existing `ext.actions.Action` pattern.
3. **`apprt.performAction` switch** (`application.zig:674-794`) — new variants in `Binding.Action` are dispatched here with the same wrapping pattern as `equalizeSplits` / `gotoSplit`.

```
┌──────────────────────────────────────────────────────────────┐
│ src/input/Binding.zig            Action union: + 3 variants  │
│ src/apprt/action.zig             apprt.Action: + 3 variants  │
│ src/datastruct/split_tree.zig    +zoom-swap                  │
│ src/apprt/gtk/class/                                          │
│   application.zig                +dispatch arms              │
│   split_tree.zig                 +DnD, +header glue          │
│   split_header.zig               NEW widget                  │
│   surface.zig                    +DropTarget for split MIME  │
│   tab.zig                        +tab detach context entry   │
│   window.zig                     +newWindowWithSurface()     │
│ src/apprt/gtk/ui/1.5/                                         │
│   split-header.blp               NEW                          │
│   surface-scrolled-window.blp    insert header above terminal│
│   tab.blp                        +tab menu detach            │
│   split-tree.blp                 +DropTarget controller      │
│ src/config/Config.zig            +keybinds, +2 config keys   │
└──────────────────────────────────────────────────────────────┘
```

Affected files at a glance:

- `src/config/Config.zig`
  - Linux defaults block (`6611-6821`) — add 5 new `set.put()` calls
  - Add fields `split-header: SplitHeaderMode` and `split-header-middle-click-close: bool`
- `src/input/Binding.zig`
  - `Action` union — add `goto_split_index: usize`, `move_split_to_new_window`, `toggle_split_header`
- `src/apprt/action.zig`
  - Mirror enum + values for the three new actions
- `src/apprt/gtk/class/application.zig`
  - `performAction` switch — add three new arms
  - `gotoSplit` — extend to support index target; honor zoom-swap (P10)
  - Add `newWindowWithSurface()` factory (P7)
- `src/datastruct/split_tree.zig`
  - Add `splitInto(at, direction, leaf_tree)` semantic helper if not already covered by `split()` (already covered — confirmed at `505-569`)
- `src/apprt/gtk/class/split_tree.zig`
  - New GActions, DnD source/target wiring, header insertion, "detach into new window" wiring
- New: `src/apprt/gtk/class/split_header.zig` (P4)
- New: `src/apprt/gtk/ui/1.5/split-header.blp` (P4)
- `src/apprt/gtk/ui/1.5/surface-scrolled-window.blp` — insert `SplitHeader` above scrolled window (P4)
- `src/apprt/gtk/class/window.zig` — `newWindowFromSurface()` factory + tab-detach context entry (P7, P12)
- `src/apprt/gtk/class/tab.zig` — tab-context-menu detach action handler (P12)

## Performance Considerations

- DnD: per-frame quadrant computation on motion is trivial (two diagonal line tests on cursor coords). Highlight border is a CSS class swap on the target widget — no relayout.
- Drag icon screenshot: capture once at drag-begin via `gtk_widget_paintable_new` (no render-per-frame). Scale to ~25% via the `Gdk.Paintable` API.
- Header bar widget: one extra GObject per leaf. `auto` mode (default) shows the header only when the tab has 3+ splits, so single-split common case has zero header overhead.
- Tree clone on each split / remove / drop: already the existing cost model (immutable tree), no change.

## Migration Notes

- All five new keybinds are on previously-unbound keys (verified vs §14 ledger). No user config breakage.
- New config fields default to `auto` / `false` — current behavior is unchanged for users who don't opt in.
- DnD on the surface area must not interfere with the existing text/file `DropTarget`. We add a *new* `DropTarget` for the `application/x-ghostty-split` MIME, layered alongside.

---

## Phase P1: New Default Keybindings

Wire the five new Linux defaults from §14 and register the placeholder action `toggle_split_header` (no-op until P4 lands the widget) plus `goto_split_index` and `move_split_to_new_window` so user configs can reference them even before behavior arrives.

**Tasks**:
- [ ] Add three variants to `Action` union in `src/input/Binding.zig`:
  - `goto_split_index: usize,`
  - `move_split_to_new_window,`
  - `toggle_split_header,`
  ```zig
  /// Focus the Nth split in the current tab (1-indexed, creation order).
  goto_split_index: usize,
  /// Detach the active split into a new window.
  move_split_to_new_window,
  /// Toggle split-header visibility when split-header=manual.
  toggle_split_header,
  ```
- [ ] Add matching variants to `apprt.Action` in `src/apprt/action.zig` (same key names; payload `usize` for index, no payload for the others).
- [ ] In `src/apprt/gtk/class/application.zig` `performAction` switch, add three arms that log `unimplemented` and return `false` — replaced in later phases.
- [ ] In `src/config/Config.zig` Linux block (`6611-6821`), append:
  ```zig
  try self.set.put(alloc,
      .{ .key = .{ .unicode = 'g' }, .mods = .{ .ctrl = true, .shift = true } },
      .{ .new_split = .auto });
  try self.set.put(alloc,
      .{ .key = .{ .unicode = '=' }, .mods = .{ .super = true, .ctrl = true } },
      .{ .equalize_splits = {} });
  try self.set.put(alloc,
      .{ .key = .{ .physical = .f11 } },
      .{ .toggle_fullscreen = {} });
  try self.set.put(alloc,
      .{ .key = .{ .physical = .f12 } },
      .{ .toggle_tab_overview = {} });
  try self.set.put(alloc,
      .{ .key = .{ .unicode = 'h' }, .mods = .{ .ctrl = true, .shift = true } },
      .{ .toggle_split_header = {} });
  ```
- [ ] Update the auto-generated keybind docs in `src/input/helpgen_actions.zig` if doc comments require it (re-run as part of `zig build`).

**Automated Verification**:
- [ ] `zig build` succeeds.
- [ ] `zig build test -Dtest-filter="Binding"` passes (parser sees the new union variants).
- [ ] New test `Binding.parse: goto_split_index` round-trips `goto_split_index:3` ↔ `.{ .goto_split_index = 3 }`.
- [ ] New test `Binding.parse: toggle_split_header` round-trips `toggle_split_header`.
- [ ] New test `Binding.parse: move_split_to_new_window` round-trips `move_split_to_new_window`.
- [ ] `zig fmt --check src/config/Config.zig src/input/Binding.zig src/apprt/action.zig src/apprt/gtk/class/application.zig` passes.

**Manual Verification**:
- [ ] Launch Ghostty on Linux. Press `F11` — window enters fullscreen, `F11` again exits.
- [ ] Press `F12` — tab overview opens.
- [ ] In a wide window, press `Ctrl+Shift+G` — new split appears (vertical because width > height).
- [ ] With 3+ splits, press `Super+Ctrl+=` — all splits equalize.

---

## Phase P2: Equalize on Divider Double-Click

Add a GTK gesture controller on each `gtk.Paned` divider that fires the existing `split-tree.equalize` GAction on double-click.

**Tasks**:
- [ ] In `src/apprt/gtk/ui/1.5/split-tree-split.blp`, add a `Gtk.GestureClick` controller on the `paned` template with `button: 0` and a `pressed` handler:
  ```blueprint
  Paned paned {
    notify::max-position => $notify_max_position();
    notify::position => $notify_position();
    Gtk.GestureClick {
      // 0 = any button; we filter to primary inside the handler
      pressed => $on_divider_click() swapped;
    }
  }
  ```
- [ ] In `src/apprt/gtk/class/split_tree.zig` `SplitTreeSplit`, add a method `onDividerClick(gesture, n_press, x, y)` that:
  - Returns if `n_press != 2`.
  - Uses `paned.computeBounds` / handle bounds to confirm the click was within the divider handle (skip if not — children get clicks too).
  - Walks up to the enclosing `SplitTree` via `ext.getAncestor` and calls `split_tree.as(gtk.Widget).activateAction("split-tree.equalize", null)`.
- [ ] Register the template callback in `SplitTreeSplit.Class.init`.

**Automated Verification**:
- [ ] `zig build` passes.
- [ ] Existing GTK class tests pass (`zig build test -Dtest-filter=gtk`).

**Manual Verification**:
- [ ] Build (`zig build`) and launch. Create three splits with unequal sizes. Double-click the divider between any two — all splits at that orientation become equal.
- [ ] Single-click and divider drag still work normally.

---

## Phase P10: Zoom-Swap on Focus Change

Ship before P3 so indexed navigation gets the correct semantics on first wiring. Today `tree.goto()` either keeps zoom (when `split-preserve-zoom.navigation` is on) by calling `tree.zoom(target)` or un-zooms. The behavior is *already* most of what the spec wants — we need to confirm semantics and ensure the user-visible default works as described.

Spec §6.3: while zoomed, `goto_split:*` and `goto_split_index:*` MUST transfer zoom to the new target without intermediate un-zoom.

**Tasks**:
- [ ] In `src/apprt/gtk/class/split_tree.zig` `goto()` (currently at `335-388`), invert the condition so that **when the tree is zoomed and the active target is being changed via navigation, we always transfer zoom** regardless of `split-preserve-zoom.navigation`. Replace:
  ```zig
  if (tree.zoomed != null) {
      ...
      if (!config.@"split-preserve-zoom".navigation) {
          tree.zoomed = null;
      } else {
          tree.zoom(target);
      }
      ...
  }
  ```
  with the unconditional transfer:
  ```zig
  if (tree.zoomed != null) {
      tree.zoom(target);
      const object = self.as(gobject.Object);
      object.notifyByPspec(properties.tree.impl.param_spec);
      object.notifyByPspec(properties.@"is-zoomed".impl.param_spec);
  }
  ```
  and remove the `split-preserve-zoom.navigation` branch.
- [ ] Audit `split-preserve-zoom`: if `navigation` becomes a no-op, remove only that sub-flag from `src/config/Config.zig` `SplitPreserveZoom` (keep `new` and other sub-flags). If removal would be a user-visible config breakage, leave the field as a deprecated no-op with a doc-comment note rather than removing it.
- [ ] In `src/datastruct/split_tree.zig`, add a debug assert in `zoom()` that the target handle's node is a leaf (we never zoom an internal split).

**Automated Verification**:
- [ ] `zig build` passes.
- [ ] New test `SplitTree: zoom transfers on goto`: build a 3-leaf tree, zoom leaf A, call `goto(.next)`, assert `tree.zoomed == handle(B)`.
- [ ] `zig build test -Dtest-filter="SplitTree"` passes.

**Manual Verification**:
- [ ] Create 3 splits, focus split #1, press `Ctrl+Shift+Enter` to zoom. Press `Ctrl+Alt+Right` (`goto_split:right`) — zoom transfers to split #2; tab is still in zoomed mode (only one terminal visible).
- [ ] Press `Ctrl+Shift+Enter` again — full split tree returns and focus is on split #2.

---

## Phase P3: goto_split_index Action

Wire the `goto_split_index: usize` action to focus the 1-indexed Nth leaf in the active tab's split tree, using the existing iterator. Zoom-aware via P10.

**Tasks**:
- [ ] In `src/apprt/gtk/class/split_tree.zig`, add `pub fn gotoIndex(self: *Self, n: usize) bool`:
  ```zig
  pub fn gotoIndex(self: *Self, n: usize) bool {
      if (n == 0) return false; // 1-indexed; 0 is a no-op
      const tree = self.getTree() orelse return false;
      var it = tree.iterator();
      var i: usize = 0;
      while (it.next()) |entry| {
          i += 1;
          if (i == n) {
              entry.view.grabFocus();
              const old = self.private().last_focused.get();
              defer if (old) |v| v.unref();
              self.private().last_focused.set(entry.view);
              if (tree.zoomed != null) tree.zoom(entry.handle);
              self.as(gobject.Object).notifyByPspec(properties.tree.impl.param_spec);
              return true;
          }
      }
      return false; // out of range
  }
  ```
- [ ] In `src/apprt/gtk/class/application.zig` `Action`, add `pub fn gotoSplitIndex(target: apprt.Target, n: usize) bool` mirroring `gotoSplit`, dispatching to `tree.gotoIndex(n)`.
- [ ] In `performAction` switch, replace the P1 stub for `goto_split_index` with `return Action.gotoSplitIndex(target, value);`.
- [ ] If `apprt.action` has a Value mapping table for parametric actions, register `usize` for `goto_split_index`.

**Automated Verification**:
- [ ] `zig build` passes.
- [ ] New test `gotoIndex: out of range no-op` — call `gotoIndex(99)` on a 3-leaf tree, assert returns false and last_focused unchanged.
- [ ] New test `gotoIndex: 1-indexed creation order` — split right twice then split down, iterate via `tree.iterator()` and confirm leaves appear in creation order, call `gotoIndex(2)`, assert second-created surface is focused.
- [ ] `zig build test -Dtest-filter=goto_split_index` passes.

**Manual Verification**:
- [ ] In `~/.config/ghostty/config`, add `keybind = super+1=goto_split_index:1` (and 2, 3). Reload config. Create three splits in any layout; press `Super+1` / `Super+2` / `Super+3` — focus jumps in creation order. `Super+9` with only three splits is a no-op (no error).
- [ ] In zoomed mode (Phase P10 must be live), `Super+2` transfers the zoom to split #2 without flicker.

---

## Phase P4: Split Header Bar Widget

Add the per-split header with title / broadcast-indicator placeholder / zoom button / close button / context menu and gate visibility on the new `split-header` config option. Add the `toggle_split_header` action behavior.

**Tasks**:
- [ ] Add to `src/config/Config.zig`:
  ```zig
  /// Per-split header bar visibility.
  ///   - off       never show header (current behavior)
  ///   - auto      show only when the active tab has more than 2 splits (default)
  ///   - always    always show on every split
  ///   - manual    per-tab; user toggles via `toggle_split_header`. Initial state hidden.
  @"split-header": SplitHeaderMode = .auto,

  /// Middle-click anywhere on the split header closes the split.
  @"split-header-middle-click-close": bool = false,
  ```
  and define `pub const SplitHeaderMode = enum { off, auto, always, manual };` in the same file.
- [ ] Create `src/apprt/gtk/ui/1.5/split-header.blp`:
  ```blueprint
  using Gtk 4.0;
  using Adw 1;

  template $GhosttySplitHeader: Adw.Bin {
    styles ["split-header"]
    Gtk.Box header_box {
      orientation: horizontal;
      spacing: 4;
      Gtk.Label title { hexpand: true; ellipsize: end; xalign: 0; }
      Gtk.Image broadcast_icon { visible: false; icon-name: "audio-input-microphone-symbolic"; }
      Gtk.Button zoom_button {
        icon-name: "view-fullscreen-symbolic";
        clicked => $on_zoom_clicked();
      }
      Gtk.Button close_button {
        icon-name: "window-close-symbolic";
        clicked => $on_close_clicked();
      }
      Gtk.GestureClick title_click {
        button: 0;
        pressed => $on_title_click() swapped;
      }
      Gtk.GestureClick middle_click {
        button: 2;
        pressed => $on_middle_click() swapped;
      }
    }
  }
  ```
- [ ] Create `src/apprt/gtk/class/split_header.zig` as a GObject widget with:
  - Bindable `surface: *Surface` property (drives title binding via `bindProperty("title", title_label, "label")`).
  - Bindable `header-mode: SplitHeaderMode` and `split-count: u32` properties driving `visible`.
  - Callbacks for zoom/close/title-click/middle-click → activate `split-tree.zoom`, `split-tree.close-split`, `split-tree.zoom`, conditional close (based on `split-header-middle-click-close`).
  - A `Gtk.PopoverMenu` set up with the menu items: Move to New Window / Toggle Read-Only / Equalize Splits / Close, attached to the title via right-click.
  - A method `setBroadcastIndicator(bool)` (the indicator stays hidden until P8 ships).
- [ ] Edit `src/apprt/gtk/ui/1.5/surface-scrolled-window.blp` to add a `$GhosttySplitHeader header` ahead of the existing nested `Adw.Bin`, wrapping both in a `Gtk.Box` with `orientation: vertical`:
  ```blueprint
  template $GhostttySurfaceScrolledWindow: Adw.Bin {
    notify::surface => $notify_surface();
    Gtk.Box {
      orientation: vertical;
      $GhosttySplitHeader header { surface: bind template.surface; }
      Adw.Bin {
        Gtk.ScrolledWindow scrolled_window {
          hscrollbar-policy: never;
          vscrollbar-policy: bind $scrollbar_policy(template.config) as <Gtk.PolicyType>;
        }
      }
    }
  }
  ```
- [ ] In `src/apprt/gtk/class/surface_scrolled_window.zig`, bind the new `header` template child and forward `surface` plus a computed `header-mode` and `split-count` (count via `getAncestor(SplitTree)` + iterator).
- [ ] In `src/apprt/gtk/class/split_tree.zig`, add a `private.header_manual_visible: bool = false` and:
  - Add GAction `toggle-header` that flips `header_manual_visible` and re-evaluates visibility on every leaf.
  - In `onRebuild`, after `tree_bin.setChild`, walk the new tree and push `header-mode`/`split-count`/`manual-visible` updates.
- [ ] In `application.zig` `performAction`, wire `toggle_split_header` to dispatch via the active surface's enclosing `SplitTree` activating `split-tree.toggle-header` (no-op when mode != `manual`).
- [ ] Register the new gresource entry for `split-header.blp` in `src/apprt/gtk/build/gresource.zig`.
- [ ] CSS: add a `.split-header` style class with theme-default colors in `src/apprt/gtk/css/` (use existing CSS conventions).

**Automated Verification**:
- [ ] `zig build` passes.
- [ ] `prettier -w .` is a no-op or its diff is only the new files.
- [ ] `zig build test -Dtest-filter="SplitHeader"` passes (tests for visibility logic given mode + split count).
- [ ] New test `SplitHeader: auto mode hides at 1 split` — create a single-leaf tree, expect `header.visible == false`.
- [ ] New test `SplitHeader: auto mode shows at 3+ splits` — three leaves, expect visible.
- [ ] New test `SplitHeader: manual mode default-hidden, toggles on action` — activate `toggle-header`, expect visible flips.

**Manual Verification**:
- [ ] With default config (`split-header = auto`), open a single split → no header. Create a 2nd split → still no header. Create a 3rd → headers appear on all splits.
- [ ] Set `split-header = always` → header shows even on a single-split tab.
- [ ] Set `split-header = manual`. Open splits — no header. Press `Ctrl+Shift+H` — headers appear on the current tab. Press again — they hide. Switch tabs — other tabs unaffected.
- [ ] With `split-header-middle-click-close = true`, middle-click the header → split closes (with close confirm if configured).
- [ ] Double-click the title text → split zooms; double-click again → unzooms.
- [ ] Right-click the header → menu shows. Click "Equalize Splits" → tree equalizes. Click "Toggle Read-Only" → surface becomes read-only.

---

## Phase P5: Split Drag-and-Drop Within Tab

Make the header a GTK 4 `gtk.DragSource` with a `application/x-ghostty-split` payload `{pid, surface_uuid}` and a scaled screenshot drag icon. Make each terminal surface a `gtk.DropTarget` for that MIME. On hover, compute the quadrant under the cursor and draw a 4px accent border on the corresponding edge. On drop, detach the dragged surface from its source `SplitTree` and split the target in the indicated direction.

**Tasks**:
- [ ] Define `src/apprt/gtk/class/split_dnd.zig` with:
  - `pub const MIME = "application/x-ghostty-split";`
  - `pub const Payload = struct { pid: std.posix.pid_t, uuid: [16]u8 };` plus `serialize`/`parse` helpers using `glib.Bytes`.
  - `pub fn quadrantFor(x: f64, y: f64, w: f64, h: f64) Quadrant` where `Quadrant = enum { top, bottom, left, right };` using the two diagonals.
- [ ] In `src/apprt/gtk/class/split_header.zig`, attach a `gtk.DragSource` to the header_box:
  - `set_actions(.{ .move = true })`.
  - `prepare` signal returns a `gdk.ContentProvider` carrying the serialized `Payload` for MIME `application/x-ghostty-split`.
  - `drag-begin` sets the drag icon to a `gdk.Paintable` from `gtk.WidgetPaintable.new(surface)` scaled via `Adw.styled_paintable` or manually.
  - Skip activation if the source surface's tree is currently zoomed (US-8.7).
- [ ] In `src/apprt/gtk/class/surface.zig`, add a second `gtk.DropTarget` for the split MIME (alongside existing text/file target):
  - `set_actions(.{ .move = true })`.
  - `enter`/`motion` signals: compute quadrant, add the CSS class `dnd-target-{top,bottom,left,right}` (mutually exclusive), update cursor via `set_cursor_from_name("grabbing")`. Skip and reject if the target is zoomed.
  - `leave`: remove all `dnd-target-*` classes.
  - `drop` signal: verify the payload is from the same process (`pid == getpid()`), resolve the source `Surface` by UUID, refuse self-drop, otherwise call into the cross-tree move helper below.
- [ ] In `src/apprt/gtk/class/split_tree.zig`, add a pub helper:
  ```zig
  pub fn moveSurfaceInto(
      self: *Self,
      source_tree: *SplitTree,
      source_handle: Surface.Tree.Node.Handle,
      target_handle: Surface.Tree.Node.Handle,
      direction: Surface.Tree.Split.Direction,
  ) Allocator.Error!void
  ```
  When `source_tree == self`: clone tree → remove `source_handle` → split `target_handle` in `direction` inserting the detached single-leaf tree.
  When `source_tree != self`: covered in P6 (this phase: assert same-tree).
- [ ] In `src/apprt/gtk/css/`, define `.dnd-target-top`, `.dnd-target-bottom`, `.dnd-target-left`, `.dnd-target-right` rules each rendering a 4px `@accent_bg_color` inset border on the relevant edge.
- [ ] Surface UUID: extend `Surface` with a stable `uuid: [16]u8` generated at `init` (`std.crypto.random.bytes`); expose via getter.

**Automated Verification**:
- [ ] `zig build` passes.
- [ ] `zig build test -Dtest-filter="split_dnd"` passes — covers `quadrantFor` math, payload serialize/parse round-trip.
- [ ] New test `SplitTree: move within tree`: 3-leaf tree, call `moveSurfaceInto(self, self, leaf_a, leaf_c, .right)`, assert leaf_a is now the right child of a new split parented at leaf_c's old position, and old position of leaf_a is replaced by its sibling.
- [ ] `zig fmt --check .` passes.

**Manual Verification**:
- [ ] Open 3 splits in a tab. Drag the header of split A onto split B. While hovering near the top of B, a top edge highlight appears. Release → A is now stacked above B.
- [ ] Hover near the right side of B → right edge highlights. Release → A is to the right of B.
- [ ] Drop on self → nothing changes, no error.
- [ ] Zoom a split, attempt to drag — drag does not start (US-8.7).
- [ ] Drop onto a zoomed split — drop is rejected, layout unchanged.
- [ ] Existing text/file drops onto the terminal still work.

---

## Phase P6: Cross-Tab and Cross-Window DnD

Extend P5's `DropTarget` to accept payloads whose source surface lives in a different tab or different top-level window within the same Ghostty process. Reject foreign payloads.

**Tasks**:
- [ ] Add `pub fn findSurfaceByUuid(app: *Application, uuid: [16]u8) ?*Surface` to `application.zig` — walk all top-level windows → all tab pages → all split trees → iterator, comparing UUID.
- [ ] In `surface.zig` `DropTarget.drop` handler, validate `payload.pid == std.os.linux.getpid()`. Resolve the source surface via `Application.default().findSurfaceByUuid(payload.uuid)`. On nil → return false (reject).
- [ ] Extend `SplitTree.moveSurfaceInto` to handle the cross-tree case:
  - Locate `source_handle` in `source_tree`, remove it from `source_tree`'s cloned tree → `setTree(new_source)` on source_tree.
  - If `new_source` is empty: emit a close-request on the source tab (close-page on `adw.TabView` via the source window).
  - In self, clone target tree → split at `target_handle` inserting the moved single-leaf tree.
- [ ] Surface reparenting: when a `Surface` widget is moved between `SplitTree` instances, its `gtk.Widget` parent changes via the same `detachWidget` path. Verify with manual test that the Surface's PTY remains alive (`ref` count on Surface is bumped before remove, dropped after insert).
- [ ] Focus: after a cross-tab drop, focus the destination tab (`window.selectTab(.{ .n = idx })`).

**Automated Verification**:
- [ ] `zig build` passes.
- [ ] New test `findSurfaceByUuid: not found returns null`.
- [ ] New test `SplitTree: cross-tree move closes empty source` (using a unit harness that uses two `SplitTree` instances).
- [ ] `zig fmt --check .` passes.

**Manual Verification**:
- [ ] Open two tabs each with two splits. Drag the header of a split from Tab 1 onto a split in Tab 2 → it moves; Tab 2 becomes active.
- [ ] Drag the only remaining split in Tab 1 onto Tab 2 → Tab 1 closes automatically.
- [ ] Open two Ghostty windows of the same instance. Drag a split header from window A onto a split in window B → moves successfully.
- [ ] Open a second Ghostty instance (different PID). Drag a split from instance 1 onto instance 2 → drop is rejected silently.

---

## Phase P7: Tear-Off to New Window & `move_split_to_new_window`

When a DnD ends with no valid drop target (drop on desktop / foreign app), create a new Ghostty window at the drop coordinates and move the dragged surface into it as the sole split. Also wire the explicit `move_split_to_new_window` action (already a placeholder from P1) and the header context-menu entry.

**Tasks**:
- [ ] In `src/apprt/gtk/class/window.zig`, add factory:
  ```zig
  pub fn newWithSurface(
      app: *Application,
      surface: *Surface,
      position: ?struct { x: i32, y: i32 } = null,
  ) *Self
  ```
  Behavior: creates a new `Window` like `new()`, but instead of spawning a fresh surface for the initial tab, takes the existing one and assigns it as the only leaf of the only tab's `SplitTree`. If `position` is set, the window is positioned at those screen coordinates (via wayland/x11 winproto helpers in `winproto/`).
- [ ] In `surface.zig`'s `DragSource`, listen for `drag-end` and check if the drop succeeded (the `Gdk.Drag` reports `.none`). On `.none` (no drop accepted):
  - Get drop screen coords from the `Gdk.Drag` (or last-known cursor via `gdk.Display.getDefaultSeat().getPointer().getPosition`).
  - Detach the source surface from its `SplitTree` (use `moveSurfaceInto` removal half plus reparent into the new window's tree).
  - Call `Window.newWithSurface(app, surface, .{ .x, .y })`.
- [ ] Replace the P1 stub for `move_split_to_new_window` in `application.zig` `performAction` with: call `Window.newWithSurface(app, source, null)` and `position` defaults to "near the source window" (offset by 40,40 from source window origin).
- [ ] In `split_header.zig`'s context menu, the existing "Move to New Window" entry (added in P4) now actually dispatches: bind the menu action to `app.move-split-to-new-window` and have it call the same action handler.

**Automated Verification**:
- [ ] `zig build` passes.
- [ ] `zig fmt --check .` passes.
- [ ] Build with all build targets (`zig build -Demit-macos-app=false`) — no regressions.
- [ ] New test `Window.newWithSurface: takes ownership of existing surface` — drive at the apprt boundary with a stub `Surface` so the test runs in CI (no real GTK display needed). If the apprt-layer harness cannot host two `Window` instances, refactor `newWithSurface` to split the pure logic (transfer Surface from old tree to new tree datastructure) from the GTK glue and test the pure half.

**Manual Verification**:
- [ ] Open a tab with 3 splits. Drag a split header to the desktop background → a new Ghostty window appears under the cursor, holding that surface; source tab now has 2 splits.
- [ ] Right-click a split header → "Move to New Window" → a new window appears near the source.
- [ ] Tear off the only split in a tab → the source tab closes; new window holds the surface.
- [ ] Bind `keybind = ctrl+alt+m=move_split_to_new_window` in config, press it → behaves as menu.

---

## Phase P12: §16 Right-Click Menu Items

Add the §16 menu entries that don't already exist:

- Tab context menu: **"Detach into New Window"** — moves the entire tab (with its full split tree) into a new window.
- Split header context menu: explicit **"Split Right"** / **"Split Down"** entries (current keybind-only).

(Header "Move to New Window" already lands in P4.)

**Tasks**:
- [ ] In `src/apprt/gtk/class/window.zig`, add a tab context menu action `detach-tab` that:
  - Reads `priv.context_menu_page` (the `adw.TabPage`).
  - Calls a new factory `Window.newWithTab(app, tab)` that creates a new window and reparents the `Tab` widget into the new window's `TabView`.
  - Removes the page from the source `TabView`. If that was the only tab, closes the source window.
- [ ] In `src/apprt/gtk/ui/1.5/window.blp` (tab menu section), add the menu entry binding to `win.detach-tab`.
- [ ] In `src/apprt/gtk/class/split_header.zig` context menu, add **"Split Right"** and **"Split Down"** entries → `split-tree.new-split('right')` and `split-tree.new-split('down')`.

**Automated Verification**:
- [ ] `zig build` passes.
- [ ] `zig fmt --check .` passes.
- [ ] New test `Window.detachTab: moves tab into new window` (or document as manual if test harness can't host two windows).

**Manual Verification**:
- [ ] Open a window with 2 tabs, each with multiple splits. Right-click a tab → "Detach into New Window" → that tab and all its splits appear in a new window; source window has only the remaining tab.
- [ ] Detach the only tab in a window → new window opens, source window closes.
- [ ] Right-click a split header → "Split Right" / "Split Down" → new splits appear as if `new_split:right` / `new_split:down` had been triggered.

---

## References

- Source spec: `/home/markusg/Projects/tilix/GHOSTTY_TILING_SPEC.md` (§§1–17)
- Linux default keybinds: `src/config/Config.zig:6611-6821`
- Action union: `src/input/Binding.zig:303-971`
- GTK action dispatch: `src/apprt/gtk/class/application.zig:670-799`
- Split tree datastructure: `src/datastruct/split_tree.zig`
- GTK split tree widget: `src/apprt/gtk/class/split_tree.zig`
- Existing GTK DnD pattern (surface text/file drop): `src/apprt/gtk/class/surface.zig:715,2627,3784-3824`
- Adwaita TabView + tab context menu: `src/apprt/gtk/class/window.zig:258-260,1637-1673`
- macOS SplitTreeTests for parity reference: `macos/Tests/Splits/SplitTreeTests.swift`
- Deferred: `IDEAS.md` (P8 broadcast, P9 layout save/load, macOS parity)
