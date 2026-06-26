# Plan: Hide Window Decoration + Auto Split Titlebars
Date: 2026-06-26
Priority: P2
Status: planned

## Goal

Add a context-menu item "Hide window decoration" that hides the GTK CSD/SSD
header bar at runtime on a per-window basis without touching the config file.
When both the header bar and the tab bar are hidden (i.e., the user has no
visible chrome at all), and the `split-header` config is `auto`, force split
titlebars to always show so the user retains at minimum a drag handle and pane
identifiers.

## Background

### Window decoration control

The `Window` GObject (`src/apprt/gtk/class/window.zig`) already has all the
necessary plumbing for a runtime decoration toggle:

- `Private.window_decoration: ?configpkg.WindowDecoration` (line 230) — a
  per-window override; when non-null it overrides the config value.
- `getWindowDecoration()` (line 1148) — returns the effective decoration mode,
  preferring the private override over the config.
- `toggleWindowDecorations()` (line 1156) — toggles between `.none` and the
  config default. Calls `setWindowDecoration()` → `syncAppearance()`.
- `setWindowDecoration()` (line 1177) — stores the override, calls
  `syncAppearance()`.

`syncAppearance()` (line 840) recomputes the `ssd/csd/solid-csd` CSS classes,
calls `gtk_window_set_decorated`, and re-fires `headerbar-visible` property
change notifications.

`getHeaderbarVisible()` (line 1222) is already the canonical gate for whether
the Adw.HeaderBar is shown. It returns `false` when `!csd_enabled`, which is
driven by `winproto.clientSideDecorationEnabled()`. The Adw.HeaderBar in the
blueprint (line 39–82 of `ui/1.5/window.blp`) is bound to that property:
`visible: bind template.headerbar-visible`.

So setting `priv.window_decoration = .none` → `syncAppearance()` already hides
the header bar completely — no new Private field is needed for "decoration
hidden". However, we need:

1. A **new `win.toggle-decoration` action** so it is reachable from a menu.
   (The existing `toggle_window_decorations` binding action already does the
   work; we need to expose it as a `gio.SimpleAction` on the window.)
2. A **menu entry** wired to that action — added to the surface right-click
   context menu (and optionally the tab context menu).
3. The **auto-split-header side-effect**: after decoration is toggled,
   `updateHeaderVisibility()` on the active `SplitTree` must run with adjusted
   logic that forces `always`-like behaviour when the condition is met.

### Tab bar visibility

`getTabsVisible()` (line 1277) returns `false` when:
- `priv.tab_bar_hidden == true` (user toggled via `win.toggle-tab-bar`, line
  2511), OR
- `config.@"window-show-tab-bar" == .never`, OR
- `config.@"gtk-titlebar-style" == .tabs` and the window is maximized with
  hide-when-maximized set.

`getTabsAutohide()` (line 1255) returns `true` for the `auto` show-tab-bar
mode, meaning ADW hides the tab bar when only 1 tab is present.

The "tab bar is effectively hidden" condition for our feature therefore is:
```
decoration is .none  AND
(
  priv.tab_bar_hidden == true  OR
  config.@"window-show-tab-bar" == .never  OR
  (
    config.@"window-show-tab-bar" == .auto  AND
    priv.tab_view.getNPages() == 1
  )
)
```

(The `tabs` titlebar style is excluded because in that mode there is no
separate headerbar — the tab bar IS the titlebar, so it is never truly hidden
by default.)

### Split header mode / `split-header`

`SplitHeaderMode` (`src/config/Config.zig` line 8763):
```zig
pub const SplitHeaderMode = enum {
    off, auto, always, manual,
};
```

`SplitTree.updateHeaderVisibility()` (line 937) reads
`config.@"split-header"` and, for each leaf, calls `header.setHeaderMode(mode)`
and `header.setSplitCount(count)`.

`SplitHeader.updateVisibility()` (line 711):
- `.off` → hidden
- `.always` → visible
- `.manual` → controlled by `header_manual_visible`
- `.auto` → visible if `split_count >= threshold` (default threshold 2)

The required behaviour is: when the "no chrome" condition is met AND the config
mode is `.auto`, treat it as `.always`. This must **not** mutate config; it must
be a runtime-only override passed to the split header.

### Context menus

The **surface right-click** context menu is defined in
`src/apprt/gtk/ui/1.2/surface.blp` (lines 275–393). It uses a
`Gtk.PopoverMenu` with `menu-model: context_menu_model`. Actions on the menu
are triggered by `win.<name>` etc. A new item referencing `win.toggle-decoration`
can be added to the `Window` submenu (lines 364–376) or as its own section.

The **tab bar right-click** (tab context menu) is defined in
`src/apprt/gtk/ui/1.5/window.blp` lines 323–342:
```
menu tab_context_menu {
  section { item { label "Toggle Tab Bar" action "win.toggle-tab-bar" } }
}
```
The new item can go in a new section there as well.

### Action wiring pattern

Existing example: `win.toggle-tab-bar` (window.zig line 595, action handler
line 2505):
```zig
.init("toggle-tab-bar", actionToggleTabBar, null),
```
```zig
fn actionToggleTabBar(...) void {
    priv.tab_bar_hidden = !priv.tab_bar_hidden;
    self.as(gobject.Object).notifyByPspec(properties.@"tabs-visible".impl.param_spec);
}
```

We follow the same pattern for `win.toggle-decoration`.

## Implementation Steps

### Step 1 — Add `win.toggle-decoration` window action

**File:** `src/apprt/gtk/class/window.zig`

1a. In `initActionMap()` (line 572), add to the `actions` array:
```zig
.init("toggle-decoration", actionToggleDecoration, null),
```

1b. Add the action handler function (after `actionToggleTabBar`, ~line 2514):
```zig
fn actionToggleDecoration(
    _: *gio.SimpleAction,
    _: ?*glib.Variant,
    self: *Self,
) callconv(.c) void {
    self.toggleWindowDecorations();
    // After toggling decorations, re-evaluate split header visibility
    // for the active tab's SplitTree so the auto-force logic can fire.
    if (self.getSelectedTab()) |tab| {
        if (tab.getSplitTree()) |tree| {
            tree.updateHeaderVisibility();
        }
    }
}
```

Note: `toggleWindowDecorations()` already calls `syncAppearance()` which
re-fires `headerbar-visible`. We additionally call `tree.updateHeaderVisibility()`
to propagate the auto-force logic to split headers.

### Step 2 — Add "Hide window decoration" to the surface right-click menu

**File:** `src/apprt/gtk/ui/1.2/surface.blp`

In the `Window` submenu (after the "Close Window" item, around line 374):
```
item {
  label: _("Toggle Window Decoration");
  action: "win.toggle-decoration";
}
```

Or add it as a separate top-level section in `context_menu_model`:
```
section {
  item {
    label: _("Toggle Window Decoration");
    action: "win.toggle-decoration";
  }
}
```

The exact placement and label is a UX decision; adding it inside the existing
"Window" submenu is less intrusive.

### Step 3 — Add "Toggle window decoration" to the tab context menu (optional but consistent)

**File:** `src/apprt/gtk/ui/1.5/window.blp`

Add a new section in `tab_context_menu` (after the "Toggle Tab Bar" section):
```
section {
  item {
    label: _("Toggle Window Decoration");
    action: "win.toggle-decoration";
  }
}
```

### Step 4 — Expose a "chrome-hidden" query on Window for SplitTree to call

**File:** `src/apprt/gtk/class/window.zig`

Add a public helper method so `SplitTree.updateHeaderVisibility()` can ask the
window whether all chrome is hidden:

```zig
/// Returns true when both the header bar and the tab bar are
/// effectively hidden — i.e. there is no window chrome visible.
/// This is used by SplitTree to decide whether to force split headers on.
pub fn isChromelessMode(self: *Self) bool {
    const priv = self.private();

    // Header bar hidden?
    const headerbar_hidden = !self.getHeaderbarVisible();

    // Tab bar hidden? (covers: explicit hide, never, or auto with 1 tab)
    const tab_bar_hidden = tab_bar_blk: {
        if (priv.tab_bar_hidden) break :tab_bar_blk true;
        const config = if (priv.config) |v| v.get() else break :tab_bar_blk false;
        switch (config.@"gtk-titlebar-style") {
            // tabs style: tab bar IS the titlebar — never truly "hidden"
            .tabs => break :tab_bar_blk false,
            .native => break :tab_bar_blk switch (config.@"window-show-tab-bar") {
                .never => true,
                .always => false,
                .auto => priv.tab_view.getNPages() <= 1,
            },
        }
    };

    return headerbar_hidden and tab_bar_hidden;
}
```

### Step 5 — Propagate the auto-force logic into SplitTree.updateHeaderVisibility()

**File:** `src/apprt/gtk/class/split_tree.zig`

Modify `updateHeaderVisibility()` (line 937). The function already has access to
`config.@"split-header"`. We need to look up the ancestor `Window` and check
`isChromelessMode()`:

```zig
fn updateHeaderVisibility(self: *Self) void {
    const tree = self.getTree() orelse return;
    const app = Application.default();
    const config_obj = app.getConfig();
    defer config_obj.unref();
    const config = config_obj.get();
    const mode = config.@"split-header";
    const priv = self.private();

    // Determine the effective mode: when chrome is completely hidden and the
    // user has chosen "auto", force "always" so the split headers remain
    // the only navigation chrome.
    const effective_mode: configpkg.Config.SplitHeaderMode = effective: {
        if (mode == .auto) {
            const window = ext.getAncestor(
                Window,
                self.as(gtk.Widget),
            ) orelse break :effective mode;
            if (window.isChromelessMode()) break :effective .always;
        }
        break :effective mode;
    };

    var count: u32 = 0;
    var it = tree.iterator();
    while (it.next()) |_| count += 1;

    var pane_number: u32 = 1;
    var it2 = tree.iterator();
    while (it2.next()) |entry| {
        const surface = entry.view;
        const ssw = ext.getAncestor(
            SurfaceScrolledWindow,
            surface.as(gtk.Widget),
        ) orelse continue;
        const header = ssw.getHeader();
        header.setSplitCount(count);
        header.setHeaderMode(effective_mode);   // <-- use effective_mode
        header.setPaneNumber(pane_number);
        pane_number += 1;
        if (priv.header_override_active) {
            header.as(gtk.Widget).setVisible(@intFromBool(priv.header_manual_visible));
        } else if (mode == .manual) {
            header.as(gtk.Widget).setVisible(@intFromBool(priv.header_manual_visible));
        }
    }
}
```

Need to add `const Window = @import("window.zig").Window;` import at the top of
`split_tree.zig` (it already imports `window.zig` for `Window.newWithSurface`
calls — check line 21 of split_tree.zig).

Actually `Window` is already imported in `split_tree.zig` (line 21:
`const Window = @import("window.zig").Window;`), so no new import is needed.

### Step 6 — Wire `updateHeaderVisibility` call when tab count changes

The tab-count change that makes the tab bar disappear (auto, 1 tab) needs to
trigger re-evaluation. `tabViewNPages` (window.zig line 1848) fires whenever
the page count changes. We should call `updateHeaderVisibility` on all
SplitTrees in all tabs when this fires.

Add a helper in window.zig:

```zig
/// Call updateHeaderVisibility on every SplitTree in all tabs.
fn syncAllSplitHeaders(self: *Self) void {
    const priv = self.private();
    const n = priv.tab_view.getNPages();
    var i: c_int = 0;
    while (i < n) : (i += 1) {
        const page = priv.tab_view.getNthPage(i);
        const child = page.getChild();
        const tab = gobject.ext.cast(Tab, child) orelse continue;
        tab.getSplitTree().updateHeaderVisibility();
    }
}
```

Call `self.syncAllSplitHeaders()` from:
- `tabViewNPages()` (line 1848) — after the existing empty-page check.
- `actionToggleDecoration()` — already handled by step 1b via the selected-tab
  approach; extend to all tabs for consistency, or keep it per-tab.

Also call `syncAllSplitHeaders()` at the end of `syncAppearance()` (line 840)
so that config reloads and fullscreen/maximize changes propagate correctly.

## Config / Action Schema

| Item | Value |
|---|---|
| New GTK window action name | `win.toggle-decoration` |
| Toggle state storage | `Private.window_decoration: ?configpkg.WindowDecoration` (already exists at window.zig:230) |
| Toggle logic | Reuse existing `Window.toggleWindowDecorations()` (window.zig:1156) |
| No new config key needed | Runtime-only, per-window |
| No Zig binding action needed | Feature is GTK-UI-only (right-click menu); the existing `toggle_window_decorations` keybind already covers keyboard use |

## Auto Split-Titlebar Logic

**Condition that forces split headers to "always" mode:**

```
config.@"split-header" == .auto
AND window.getHeaderbarVisible() == false   (decoration hidden or CSD disabled)
AND (
      priv.tab_bar_hidden == true
   OR config.@"window-show-tab-bar" == .never
   OR (config.@"window-show-tab-bar" == .auto AND tab_view.getNPages() <= 1)
   // NOTE: titlebar-style == .tabs is excluded (tab bar IS the title bar)
   )
```

**Where this logic lives:** `SplitTree.updateHeaderVisibility()` — it computes
`effective_mode` before the per-leaf loop. If the condition is met,
`effective_mode = .always`; otherwise `effective_mode = mode` (from config).

The `manual` and `off` modes are intentionally **not** overridden: if the user
set `split-header = off` or `= manual`, the auto-force is skipped. Only `.auto`
is upgraded.

**Trigger points for re-evaluation:**
1. `actionToggleDecoration` (decoration toggle, window.zig — new)
2. `tabViewNPages` (tab count changed, window.zig:1848 — modification)
3. `syncAppearance` (config reload / fullscreen / maximize, window.zig:840 — modification)
4. `SplitTree.onRebuild` (tree rebuild already calls `updateHeaderVisibility`, split_tree.zig:1175 — no change needed)

## Files to Change

| File | What changes |
|---|---|
| `src/apprt/gtk/class/window.zig` | Add `win.toggle-decoration` to `initActionMap()` (~line 595); add `actionToggleDecoration()` handler; add `isChromelessMode()` public method; add `syncAllSplitHeaders()` helper; call it from `tabViewNPages()` and `syncAppearance()` |
| `src/apprt/gtk/class/split_tree.zig` | Modify `updateHeaderVisibility()` to compute `effective_mode` using `Window.isChromelessMode()` |
| `src/apprt/gtk/ui/1.2/surface.blp` | Add "Toggle Window Decoration" item to the `context_menu_model` (Window submenu or new section) |
| `src/apprt/gtk/ui/1.5/window.blp` | Add "Toggle Window Decoration" item to `tab_context_menu` |

No changes to `src/config/Config.zig` or any config structs — this is entirely
a runtime per-window feature.
