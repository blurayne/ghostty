# Plan: Fix Double-Click Split Title Crash
Date: 2026-06-26
Priority: P1 (bug)
Status: planned

## Bug Description

Double-clicking anywhere on the split pane header bar (the `GhosttySplitHeader` widget)
kills the Ghostty app process. The header bar includes the title label, zoom button,
and close button. The crash is most reliably reproduced by double-clicking the close
button area, and may also occur anywhere on the header depending on timing.

## Root Cause Analysis

### Gesture Placement Bug

In `src/apprt/gtk/ui/1.5/split-header.blp`, the `GestureClick title_gesture` is
declared as a **child of `Gtk.Box header_box`** rather than as a child of
`Gtk.Label title_label`:

```blueprint
Gtk.Box header_box {
  Gtk.Label title_label { ... }
  Gtk.Button zoom_button { ... }
  Gtk.Button close_button { ... }

  Gtk.GestureClick title_gesture {    ← WRONG: attached to the whole box
    button: 0;
    pressed => $on_title_click() swapped;
  }
  Gtk.GestureClick middle_gesture {   ← same problem
    button: 2;
    pressed => $on_middle_click() swapped;
  }
}
```

In GTK4 Blueprint, an `EventController`/`GestureClick` placed inside a widget's
block is added to that widget as a controller via `gtk_widget_add_controller()`.
By placing `title_gesture` (with `button: 0`, meaning **any** button) inside
`header_box`, it fires for clicks anywhere on the entire header bar — including
on the `zoom_button` and `close_button`.

The commit `0f4b61d14 fix(gtk): P4 — correct gesture placement, fix title_label
visibility` was supposed to fix gesture placement but only addressed
`title_label.setVisible()` in the Zig code; it did not move the gesture in the
`.blp` file.

### Crash Path: Double-Click on Close Button

GTK4 event sequencing for double-clicking the `close_button`:

1. **Press 1** (n_press=1): `title_gesture::pressed` fires on `header_box`
   (button=1, n_press=1) → `onTitleClick` handler runs → no-op (not button 3,
   not n_press==2).

2. **Release 1**: `close_button::clicked` signal fires (GTK `GtkButton` fires
   `clicked` on button release). This triggers:
   - `onCloseClicked` → `activateAction("split-tree.close-split", null)`
   - `actionCloseSplit` in `split_tree.zig:894` → `surface.close()`
   - `Surface::close-request` signal emitted (`surface.zig:1530`)
   - `surfaceCloseRequest` in `split_tree.zig:974` → `closeConfirmationClose`
   - `setTree(null)` if last pane → `Tab::close-request` → `tabCloseRequest`
     in `window.zig:1838` → `tab_view.closePage(page)`
   - If last tab: `tabViewNPages` → `window.close()` → `windowCloseRequest`
     → `gtk_window_destroy()` — **the entire widget tree including `SplitHeader`
     is synchronously destroyed here**.

3. **Press 2** (n_press=2, double-click): `title_gesture::pressed` fires again.
   `self` is a `*SplitHeader` that was passed as user_data when the gesture
   was connected. The `SplitHeader` widget has been **freed by `gtk_window_destroy`
   in step 2**. `onTitleClick` dereferences `self` → **use-after-free → SIGSEGV
   or abort**.

### Secondary UX Bug: Double-Click on Zoom Button

A similar (non-crashing but incorrect) event sequence occurs for the zoom button:

1. Press 1: `title_gesture` fires (no-op)
2. Release 1: `zoom_button::clicked` fires → zoom action
3. Press 2: `title_gesture` fires (n_press=2) → rename/zoom action fires again

This means zoom is toggled AND a rename dialog opens (or zoom toggles twice)
on a single double-click of the zoom button.

### Secondary UX Bug: Middle Gesture on Entire Header

`middle_gesture` with `button: 2` is also on `header_box`. Middle-clicking the
zoom or close buttons can trigger `split-header-middle-click-close` if enabled.

### Why Title-Area Double-Click Appears Safe But May Not Be

Double-clicking the **plain title label area** (not buttons) fires:
- Press 1: no-op
- Press 2: `onTitleClick` with n_press=2 → `activateAction("split-header.rename", null)`

If `self` is still alive, this safely opens the rename dialog. However, the
`GtkDragSource` is also attached to `header_box` and fires `prepare` on every
button-1 press. On certain timing combinations or compositor behavior, the
interaction between the drag source and the double-click gesture sequence
could produce unexpected behavior (drag-start interpreted as double-click or
vice versa).

## Fix

**Move `title_gesture` and `middle_gesture` to be children of `title_label`**,
not `header_box`. This scopes the gestures to the title label widget only,
preventing them from firing when the zoom or close buttons are clicked.

**File:** `src/apprt/gtk/ui/1.5/split-header.blp`

### Before

```blueprint
Gtk.Box header_box {
  orientation: horizontal;
  spacing: 4;

  Gtk.Label title_label {
    hexpand: true;
    ellipsize: end;
    xalign: 0;
  }

  Gtk.Image broadcast_icon { ... }

  Gtk.Button zoom_button { ... }

  Gtk.Button close_button { ... }

  Gtk.GestureClick title_gesture {
    button: 0;
    pressed => $on_title_click() swapped;
  }

  Gtk.GestureClick middle_gesture {
    button: 2;
    pressed => $on_middle_click() swapped;
  }

  Gtk.PopoverMenu context_menu { ... }
}
```

### After

```blueprint
Gtk.Box header_box {
  orientation: horizontal;
  spacing: 4;

  Gtk.Label title_label {
    hexpand: true;
    ellipsize: end;
    xalign: 0;

    Gtk.GestureClick title_gesture {
      button: 0;
      pressed => $on_title_click() swapped;
    }

    Gtk.GestureClick middle_gesture {
      button: 2;
      pressed => $on_middle_click() swapped;
    }
  }

  Gtk.Image broadcast_icon { ... }

  Gtk.Button zoom_button { ... }

  Gtk.Button close_button { ... }

  Gtk.PopoverMenu context_menu { ... }
}
```

With this change, `title_gesture` and `middle_gesture` are controllers on
`title_label` only. Clicks on the zoom button, close button, or broadcast icon
will not trigger `onTitleClick` or `onMiddleClick`.

### Zig Code Changes

No changes to `split_header.zig` are required. The blueprint template callbacks
`on_title_click` and `on_middle_click` are still bound in `Class.init()` and
the handler signatures remain correct. The template child binding for
`title_gesture` (if any — currently neither gesture is a bound template child)
also requires no change since they are not accessed by name in Zig.

Verify that neither `title_gesture` nor `middle_gesture` appear in
`bindTemplateChildPrivate` calls in `Class.init()` (they do not — only
`header_box`, `title_label`, `broadcast_icon`, `zoom_button`, `close_button`,
and `context_menu` are bound, per `split_header.zig:815–820`).

## Implementation Steps

1. Open `src/apprt/gtk/ui/1.5/split-header.blp`.
2. Move the `Gtk.GestureClick title_gesture { ... }` block from inside
   `Gtk.Box header_box { }` to inside `Gtk.Label title_label { }`.
3. Move the `Gtk.GestureClick middle_gesture { ... }` block from inside
   `Gtk.Box header_box { }` to inside `Gtk.Label title_label { }`.
4. Leave the `Gtk.PopoverMenu context_menu` in place inside `header_box`
   (it is not a controller; it is a child widget of the box as an overlay).
5. Build (`zig build`) and run Ghostty.
6. Verify:
   - Single-click on title label: no action
   - Double-click on title label: rename dialog opens (or zoom, per config)
   - Middle-click on title label: close-split fires (if `split-header-middle-click-close = true`)
   - Right-click on title label: context menu appears
   - Single-click on close button: split closes (no dialog)
   - Double-click on close button: split closes once, no crash, no rename dialog
   - Single-click on zoom button: zoom toggles
   - Double-click on zoom button: zoom toggles once, no rename dialog
   - Drag on title label: split drag-and-drop works (DragSource is on header_box, unaffected)

## Files to Change

- `src/apprt/gtk/ui/1.5/split-header.blp` — move gesture declarations from
  `header_box` block to `title_label` block (lines 32–40 approximately)

No changes required to:
- `src/apprt/gtk/class/split_header.zig`
- `src/apprt/gtk/class/split_tree.zig`
- `src/config/Config.zig`
