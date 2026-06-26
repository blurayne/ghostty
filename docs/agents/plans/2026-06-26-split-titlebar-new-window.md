# Plan: Split Titlebar in Torn-Off Window
Date: 2026-06-26
Priority: P2
Status: planned

## Goal

When a split pane or entire tab is dragged out of a Ghostty window and dropped to create a new window, the newly created window should immediately show split titlebars (the `GhosttySplitHeader` widget) according to the active `split-header` configuration mode (`auto`, `always`, `manual`). Currently, after any tear-off operation, the new window's split tree never receives a call to `updateHeaderVisibility`, so all split headers remain in their initial hidden state regardless of the config setting.

## Background

### Widget hierarchy

Every terminal pane lives in:

```
Window → Tab (GhosttyTab) → SplitTree (GhostttySplitTree)
  → [tree_bin] → SurfaceScrolledWindow (GhostttySurfaceScrolledWindow)
    → SplitHeader (GhosttySplitHeader)  ← the per-split titlebar
    → ScrolledWindow → Surface
```

The `SplitHeader` widget (`src/apprt/gtk/class/split_header.zig`) exposes three visibility-control methods:
- `setHeaderMode(mode: SplitHeaderMode)` — propagates the config's `split-header` enum value
- `setSplitCount(count: u32)` — used by `.auto` mode to decide if the threshold is met
- `setPaneNumber(number: u32)` — sets the displayed pane index

Its `updateVisibility()` private function (`split_header.zig:711`) evaluates the combination of those two fields and calls `gtk.Widget.setVisible`.

### What triggers header visibility

`SplitTree.updateHeaderVisibility()` (`split_tree.zig:937–971`) is the single entry-point that walks every leaf in the tree and calls the three `SplitHeader` setters above, then applies any manual override (`header_override_active` / `header_manual_visible`). This function is called from exactly one place: `SplitTree.onRebuild()` (`split_tree.zig:1175`), which is the GLib idle callback queued by `SplitTree.setTree()` → `propTree()` → `glib.idleAdd(onRebuild, ...)`.

The chain is therefore:
```
setTree() → signals.changed → propTree() → idleAdd(onRebuild) → updateHeaderVisibility()
```

### Tear-off code paths

There are three tear-off / new-window creation paths in this codebase.

**Path A — Split-header drag (primary split tear-off)**
`SplitHeader.onDragEnd()` (`split_header.zig:453–467`) fires when a `GtkDragSource` drag ends without a drop target accepting it (i.e., dropped onto the desktop). It calls `Window.newWithSurface(app, surface, null)`.

`Window.newWithSurface()` (`window.zig:309–407`):
1. Removes the surface from its source `SplitTree`.
2. Creates a new `Window` and **binds** `app.config → win.config` via `gobject.Object.bindProperty` (line 361–367).
3. Calls `Tab.newWithSurface(win.private().config, surface)` (line 370).
4. Calls `tab_view.append(tab)` and wires up the `SplitTree.signals.changed` connection + an initial call to `tabSplitTreeChanged` (lines 391–404).
5. `tabSplitTreeChanged` → `connectSurfaceHandlers` — but does NOT call `updateHeaderVisibility`.
6. Inside `Tab.newWithSurface` (line 231–248), `priv.split_tree.setTree(&single_tree)` is called, which schedules `onRebuild`, which eventually calls `updateHeaderVisibility()`.

On the surface this path looks correct. However, `Tab.newWithSurface` calls `setTree` on the **Tab's embedded SplitTree** before the Tab is attached to any Window or TabView. The `SurfaceScrolledWindow` for the surface already exists (it was built when the surface was first added to the original window's tree), so `buildTree` in `onRebuild` will exercise the `initReused` branch — it detaches and re-attaches the existing `SurfaceScrolledWindow`. After re-attachment, `updateHeaderVisibility` runs and calls `ssw.getHeader().setHeaderMode(mode)` where `mode` comes from `Application.default().getConfig()`.

**Root cause for Path A:** `updateHeaderVisibility()` reads `config.@"split-header"` freshly from the global application config object, so the mode is correct. **The real problem is timing**: `setTree` is called in `Tab.newWithSurface` synchronously (line 245 in `tab.zig`), and the resulting `onRebuild` idle callback fires before the new `Window` is presented — in particular, before the new window's `SplitTree` has ever had `header_override_active` set. Since `header_override_active` defaults to `false` and `header_manual_visible` defaults to `false`, the initial call to `updateHeaderVisibility` in `onRebuild` applies the config-based mode correctly and that should work.

Deeper investigation reveals the actual bug: When `buildTree` is called for an **existing** (reused) `SurfaceScrolledWindow`, it calls `initReused` which detaches the widget from its old parent. After re-attachment to the new window's bin, the `SplitHeader` widget already has its state from the previous window (`header_mode`, `split_count`, `pane_number`). The `updateHeaderVisibility` call in `onRebuild` does push the new mode and count via `header.setHeaderMode(mode)` and `header.setSplitCount(count)`, so this also seems correct.

However, looking at `SplitHeader.setHeaderMode` (`split_header.zig:692–695`), it stores the mode and calls `updateVisibility`. `updateVisibility` (`split_header.zig:711–727`) for `.auto` mode uses `config_obj.get().@"split-header-auto-threshold"` which it reads at call time — so that is fine.

**The true root cause** is in **Path C** below.

**Path B — "Move split to new window" action**
`Window.actionMoveToNewWindow` (`window.zig:2483–2491`) calls `Window.newWithSurface`. This has the same flow as Path A.

**Path C — ADW native tab drag-out (tabViewCreateWindow)**
When the user drags a **whole tab** out of the ADW tab bar (which ADW handles natively), ADW calls the `create-window` signal handler `tabViewCreateWindow` (`window.zig:1819–1836`).

This handler creates a **bare new `Window`** using `gobject.ext.newInstance` with only `application` set, then returns its `tab_view`. ADW then calls `source_tv.transferPage(...)` internally, which emits `page-detached` on the source TabView and `page-attached` on the new TabView.

`tabViewPageAttached` (`window.zig:1751–1792`) is the handler for `page-attached`. It connects `Tab.signals.close-request` and `connectSurfaceHandlers`, but it does NOT:
1. Connect `SplitTree.signals.changed` to `tabSplitTreeChanged` on the new window.
2. Call `tabSplitTreeChanged` (which would re-evaluate surface handlers).
3. Call `updateHeaderVisibility` on the split tree.

Furthermore, `tabViewCreateWindow` does NOT:
- Call `gobject.Object.bindProperty` to bind `app.config → win.config` (unlike `newWithSurface` and `newWithTab`).

The result: when a tab is dragged out natively:
- The split tree's `header_override_active` is `false` (default).
- `onRebuild` was already called when the tab was in the original window.
- No new `setTree` is called (the tab's SplitTree is untouched), so no new `onRebuild` / `updateHeaderVisibility` is triggered for the new window context.
- The `SplitHeader` widgets retain whatever visibility state they had in the source window.

**Path D — "Detach tab" context menu action**
`Window.actionDetachTab` (`window.zig:2493–2503`) calls `Window.newWithTab(app, tab)`. `newWithTab` (`window.zig:412–492`) does bind `app.config → win.config` and does connect `SplitTree.signals.changed`, and calls `tabSplitTreeChanged` explicitly (line 479). However, it does NOT call `updateHeaderVisibility` directly — it relies on a subsequent `setTree` to trigger `onRebuild`. Since the SplitTree's tree data is never replaced (only reparented), `onRebuild` is not triggered, and headers are not re-evaluated.

## Root Cause

There are two distinct failure modes:

1. **Path C (`tabViewCreateWindow`)**: The new window is a bare shell. `tabViewPageAttached` fires but never connects the `SplitTree.signals.changed` signal to the new window's `tabSplitTreeChanged`, and never forces a `updateHeaderVisibility` call. The `SplitHeader` state is frozen from the old window.

2. **Path D (`newWithTab`)**: `tabSplitTreeChanged` is called (line 479) but this only calls `connectSurfaceHandlers` / `disconnectSurfaceHandlers` — it does NOT call `updateHeaderVisibility`. Since no `setTree` happens, `onRebuild` never fires and headers are never re-evaluated in the new window context.

3. **Path A/B (`newWithSurface`)**: `Tab.newWithSurface` calls `setTree` which triggers `onRebuild` → `updateHeaderVisibility`, so in theory this path works. However, a subtle race exists: `onRebuild` is an **idle callback**, meaning it fires on the next main-loop iteration, potentially before the new `Window` is fully realized. If `split-header = manual` and the user had toggled headers on in the source window, the `header_override_active` state lives on the **SplitTree** widget (not the surface or window), and that state is correctly carried to the new window because the same `SplitTree` widget is re-used. So Path A/B is likely correct for `auto` and `always` modes. The only gap is if `split-header = manual` with `header_manual_visible = true` in the source and the new single-pane window should show headers — but `setSplitCount(1)` followed by `setHeaderMode(.manual)` leaves `header_manual_visible = false` (the SplitTree default), because a new `Tab.newWithSurface` creates a fresh `SplitTree`.

**Summary**: The core issue for all paths is that `updateHeaderVisibility()` on the new window's `SplitTree` is either (a) never called, or (b) called before the new window is realized and with `header_manual_visible` state reset to `false` instead of inheriting the source window's intent.

## Implementation Steps

### Step 1 — Fix `tabViewCreateWindow`: bind config and connect split-tree signal

**File:** `src/apprt/gtk/class/window.zig`  
**Location:** `tabViewCreateWindow` function, line 1819

In `tabViewCreateWindow`, after creating the new window, bind the application config and wire the split-tree signal. However, because `tabViewCreateWindow` fires before the Tab page is attached (ADW transfers the page after receiving the TabView), the split-tree signal must be connected via `tabViewPageAttached` after the page lands.

Change `tabViewCreateWindow` to bind config:
```zig
fn tabViewCreateWindow(
    _: *adw.TabView,
    self: *Self,
) callconv(.c) *adw.TabView {
    const win = gobject.ext.newInstance(
        Self,
        .{
            .application = Application.default(),
        },
    );

    // Bind application config to the new window (matches newWithSurface/newWithTab).
    _ = gobject.Object.bindProperty(
        Application.default().as(gobject.Object),
        "config",
        win.as(gobject.Object),
        "config",
        .{},
    );

    gtk.Window.present(win.as(gtk.Window));
    return win.private().tab_view;
}
```

### Step 2 — Fix `tabViewPageAttached`: connect split-tree and force header update

**File:** `src/apprt/gtk/class/window.zig`  
**Location:** `tabViewPageAttached` function, line 1751

After connecting the tab's close-request signal and surface handlers, also connect `SplitTree.signals.changed` and force a `updateHeaderVisibility` call on the page's split tree:

```zig
fn tabViewPageAttached(
    _: *adw.TabView,
    page: *adw.TabPage,
    _: c_int,
    self: *Self,
) callconv(.c) void {
    const child = page.getChild();
    const tab = gobject.ext.cast(Tab, child) orelse return;

    _ = Tab.signals.@"close-request".connect(
        tab,
        *Self,
        tabCloseRequest,
        self,
        .{},
    );

    if (tab.getSurfaceTree()) |tree| {
        self.connectSurfaceHandlers(tree);
    }

    // NEW: wire split-tree changes and force an immediate header-visibility
    // refresh so that tear-off windows show headers per config.
    const split_tree = tab.getSplitTree();
    _ = SplitTree.signals.changed.connect(
        split_tree,
        *Self,
        tabSplitTreeChanged,
        self,
        .{},
    );
    // Force header refresh; the tree hasn't changed so onRebuild won't fire.
    split_tree.updateHeaderVisibility();
}
```

Note: `updateHeaderVisibility` is currently `fn` (private). It needs to be made `pub` or we add a thin public wrapper `pub fn refreshHeaders(self: *Self) void { self.updateHeaderVisibility(); }`.

### Step 3 — Make `SplitTree.updateHeaderVisibility` pub (or add public wrapper)

**File:** `src/apprt/gtk/class/split_tree.zig`  
**Location:** line 937, `fn updateHeaderVisibility`

Change:
```zig
fn updateHeaderVisibility(self: *Self) void {
```
to:
```zig
pub fn updateHeaderVisibility(self: *Self) void {
```

### Step 4 — Fix `newWithTab`: call `updateHeaderVisibility` after wiring

**File:** `src/apprt/gtk/class/window.zig`  
**Location:** `newWithTab` function, line 412, after line 479 (`tabSplitTreeChanged(split_tree, null, split_tree.getTree(), win)`)

After the explicit `tabSplitTreeChanged` call, force a header refresh:

```zig
tabSplitTreeChanged(split_tree, null, split_tree.getTree(), win);
// Force header visibility refresh: the tree didn't change (no setTree call),
// so onRebuild won't fire automatically.
split_tree.updateHeaderVisibility();
```

### Step 5 — Fix `tabViewPageDetached`: disconnect the split-tree signal

**File:** `src/apprt/gtk/class/window.zig`  
**Location:** `tabViewPageDetached` function, line 1794

Currently the detach handler disconnects all handlers on the Tab object (line 1803–1811) and on surface objects. With Step 2, we now also connect to the `SplitTree` object. Since `gobject.signalHandlersDisconnectMatched` with `.data = true` and `self` as data already covers all signals where `self` (the Window) is the data pointer, the SplitTree disconnect should be handled automatically — **provided** the `connect` call in Step 2 passes `self` as the data argument (which it does via `*Self, tabSplitTreeChanged, self`).

Verify that no additional disconnect is needed by checking all signals connected with `self` as data. If the SplitTree's `changed` signal was connected with `self` as data, the existing `signalHandlersDisconnectMatched` call in `tabViewPageDetached` will handle it correctly.

However, `tabViewPageDetached` currently only disconnects on the **Tab** object (`tab.as(gobject.Object)`), not on the SplitTree. Add an explicit disconnect:

```zig
fn tabViewPageDetached(
    _: *adw.TabView,
    page: *adw.TabPage,
    _: c_int,
    self: *Self,
) callconv(.c) void {
    const child = page.getChild();
    const tab = gobject.ext.cast(Tab, child) orelse return;

    _ = gobject.signalHandlersDisconnectMatched(
        tab.as(gobject.Object),
        .{ .data = true },
        0, 0, null, null, self,
    );

    // NEW: also disconnect from the SplitTree (added in tabViewPageAttached).
    const split_tree = tab.getSplitTree();
    _ = gobject.signalHandlersDisconnectMatched(
        split_tree.as(gobject.Object),
        .{ .data = true },
        0, 0, null, null, self,
    );

    if (tab.getSurfaceTree()) |tree| {
        self.disconnectSurfaceHandlers(tree);
    }
}
```

### Step 6 — Handle `manual` mode across tear-off

**Context:** When `split-header = manual` and the user has toggled headers on in the source window (`header_override_active = true, header_manual_visible = true`), tearing off a surface creates a new `SplitTree` (in `Tab.newWithSurface`, line 243–245). The new SplitTree has `header_override_active = false` and `header_manual_visible = false`. The torn-off window will therefore not show headers even if the user had them visible in the source.

This is somewhat acceptable behaviour for the single-surface tear-off case (you're tearing one pane into its own window; whether it should inherit "manual on" is debatable). However, for the `newWithTab` path (detaching a whole tab), the existing SplitTree is reused and its `header_manual_visible` state is preserved correctly.

No code change is needed for this edge case in the initial fix — document it as a known limitation.

## Edge Cases

1. **Single-pane tear-off with `split-header = auto`**: After tear-off, the new window has exactly 1 pane. `auto` mode requires `split_count >= threshold` (default threshold = 2). So headers are correctly hidden. No regression here.

2. **Single-pane tear-off with `split-header = always`**: Headers should appear. With the fix (Steps 2–3), `updateHeaderVisibility` will set mode = `.always` and the header becomes visible. Correct.

3. **Whole-tab tear-off via ADW tab bar with multiple splits**: The `tabViewCreateWindow` path is now fixed by Steps 1–3. All splits in the tab retain their existing `SurfaceScrolledWindow` widgets; `updateHeaderVisibility` re-applies mode and count correctly.

4. **Whole-tab tear-off (action "detach-tab")**: Fixed by Step 4.

5. **Split dragged onto existing tab bar (drop on tab)**: This is handled by `onTabBarExtraDrop` which calls `moveSurfaceInto` which calls `setTree` on the target SplitTree, triggering `onRebuild` → `updateHeaderVisibility`. No fix needed.

6. **Split dropped onto empty tab-bar area (`addTabWithSurface`)**: Calls `Tab.newWithSurface` which calls `setTree`, triggering `onRebuild` → `updateHeaderVisibility`. No fix needed.

7. **Double-disconnect risk**: `tabViewPageDetached` is also called on the source window when ADW transfers a page to a new window. The SplitTree disconnect (Step 5) must only disconnect handlers belonging to this window (`self`). Using `signalHandlersDisconnectMatched` with `.data = self` is safe — it only disconnects handlers where the data pointer equals `self`.

8. **`tabViewPageAttached` fires for all page attachments**, not just tear-offs. The change in Step 2 will connect a `SplitTree.signals.changed` handler on every new tab. For normal `newTabPage` flow, `tabSplitTreeChanged` is already connected via `newTabPage` (lines 704–720 in `window.zig`). This would result in **double connections**. To avoid duplicates: in `tabViewPageAttached`, check whether a handler already exists before connecting, or skip the new connection if this Tab was created by `newTabPage` (which already wired the signal). The safest approach: use `signalHandlersDisconnectMatched` before connecting to ensure idempotency:
```zig
// Ensure only one handler per window per split-tree.
_ = gobject.signalHandlersDisconnectMatched(
    split_tree.as(gobject.Object),
    .{ .data = true },
    0, 0, null, null, self,
);
_ = SplitTree.signals.changed.connect(
    split_tree,
    *Self,
    tabSplitTreeChanged,
    self,
    .{},
);
```

9. **`tabViewPageAttached` calls `connectSurfaceHandlers` but `newTabPage` also calls it via `tabSplitTreeChanged`**: Already double-called today without issue, since `connectSurfaceHandlers` disconnects before reconnecting.

## Files to Change

| File | Purpose |
|------|---------|
| `src/apprt/gtk/class/window.zig` | Fix `tabViewCreateWindow` to bind config; fix `tabViewPageAttached` to wire split-tree signal and call `updateHeaderVisibility`; fix `tabViewPageDetached` to disconnect split-tree signal; fix `newWithTab` to call `updateHeaderVisibility` after re-wire. |
| `src/apprt/gtk/class/split_tree.zig` | Change `fn updateHeaderVisibility` to `pub fn updateHeaderVisibility` so it can be called from `window.zig`. |
