# Plan: Right-Click Context Menu Restructure
Date: 2026-06-26
Priority: P2
Status: planned

## Goal

When window decoration is hidden (headerbar not visible), replace the right-click context
menu in any split with a flattened, split-centric menu that surfaces the most common
split/window actions directly — without submenus. When decoration is visible (the normal
CSD header is showing) the menu stays exactly as it is today. Additionally, the existing
"Notify on Next Command Finish" entry is renamed to "Notify on Command Exit", and a new
"Change Title" action sets the split's title-override (falling through to the tab title
display only when no tab title-override is set).

---

## Background

### Current context menu (decoration present or absent — one static model)

Defined entirely in Blueprint at:

```
src/apprt/gtk/ui/1.2/surface.blp  lines 275–394
```

Structure (sections = visual dividers in `GtkPopoverMenu`):

```
Section 1:
  Copy           (win.copy)
  Paste          (win.paste)
  Notify on Next Command Finish  (surface.notify-on-next-command-finish)

Section 2:
  Clear          (win.clear)
  Reset          (win.reset)

Section 3:
  Submenu "Split":
    Change Title…   (surface.prompt-title)
    Split Up        (split-tree.new-split target="up")
    Split Down      (split-tree.new-split target="down")
    Split Left      (split-tree.new-split target="left")
    Split Right     (split-tree.new-split target="right")
    Close Split     (split-tree.close-split)
  Submenu "Tab":
    Change Tab Title… (tab.prompt-tab-title)
    New Tab           (win.new-tab)
    Close Tab         (win.close-tab target="this")
  Submenu "Window":
    New Window    (win.new-window)
    Close Window  (win.close)

Section 4:
  Submenu "Config":
    Open Configuration   (app.open-config)
    Reload Configuration (app.reload-config)
```

The `PopoverMenu` widget (`context_menu`) is declared in the Blueprint template at line 39
and its `menu-model` is set statically to `context_menu_model` (line 41).

The right-click popup is triggered programmatically in `surface.zig` at line 3107:
```
src/apprt/gtk/class/surface.zig  lines 3107–3124
```

The `Surface.signals.menu` signal is emitted just before popup (line 3108); `Window.surfaceMenu`
handles it at `src/apprt/gtk/class/window.zig` line 1897 (currently just calls `syncActions`).

### Window decoration detection

`Window.getHeaderbarVisible()` at `src/apprt/gtk/class/window.zig` line 1222 is the
canonical predicate. It returns `false` when:
- CSDs are disabled (`winproto.clientSideDecorationEnabled()` returns false), OR
- the window is a quick terminal, OR
- the window is fullscreen, OR
- `gtk-titlebar` is false (for `.native` titlebar style), OR
- `gtk-titlebar-style = tabs` (tab bar replaces header bar)

"No window decoration" for the purposes of this plan means `!self.getHeaderbarVisible()`.
This check must be performed in `Window.surfaceMenu()` because `Window` has access to
the predicate and to the active surface's `context_menu` popover.

---

## Action Inventory

| Action name (GTK) | Label in new menu | Already exists? | Registration site |
|---|---|---|---|
| `win.new-window` | "New Window" | YES | `window.zig:577` |
| `win.new-tab` | "New Tab" | YES | `window.zig:576` |
| `win.split-right` | "Split Right" | YES | `window.zig:582` |
| `win.split-down` | "Split Down" | YES | `window.zig:585` |
| `surface.notify-on-next-command-finish` | "Notify on Command Exit" | YES (rename label only) | `surface.zig:1916` |
| `win.prompt-surface-title` | "Change Title…" | YES | `window.zig:578` |
| `win.toggle-tab-overview` | "Overview" | **NO — must add** | needs `window.zig` |
| `win.toggle-command-palette` | "Command Palette" | YES | `window.zig:591` |

Notes:
- `surface.prompt-title` (surface group, `surface.zig:1911`) and `win.prompt-surface-title`
  (`window.zig:578`) both call `.prompt_surface_title`. The new menu must use
  `win.prompt-surface-title` because `gio.Menu` items in a `PopoverMenu` look up actions
  in the widget's action-map hierarchy — `win.*` is always reachable.
- There is **no `win.toggle-tab-overview` action today**. The overview is toggled via
  `Window.toggleTabOverview()` (line 823) only via key-binding dispatch.
  A new action must be registered.

---

## Implementation Steps

### Step 1 — Add `win.toggle-tab-overview` action to Window

**File:** `src/apprt/gtk/class/window.zig`

1a. In `initActionMap()` (line 568), add to the `actions` array:
```zig
.init("toggle-tab-overview", actionToggleTabOverview, null),
```

1b. Add the handler function alongside other action handlers (e.g. after
`actionToggleTabBar` at line 2505):
```zig
fn actionToggleTabOverview(
    _: *gio.SimpleAction,
    _: ?*glib.Variant,
    self: *Window,
) callconv(.c) void {
    self.toggleTabOverview();
}
```

### Step 2 — Rename "Notify on Next Command Finish" label

**File:** `src/apprt/gtk/ui/1.2/surface.blp`  line 288

Change:
```
label: _("Notify on Next Command Finish");
```
to:
```
label: _("Notify on Command Exit");
```

The action name `surface.notify-on-next-command-finish` is **not** changed; only the
displayed label changes. The action name is referenced by action handler
`surface.zig:1916` and menu item at `surface.blp:289`; no code changes are needed
beyond the label.

### Step 3 — Add a second static menu model for the decoration-hidden case

**File:** `src/apprt/gtk/ui/1.2/surface.blp`

After the existing `menu context_menu_model { … }` block (currently lines 275–394),
add a new named menu:

```
menu context_menu_model_no_decoration {
  section {
    item {
      label: _("New Window");
      action: "win.new-window";
    }

    item {
      label: _("New Tab");
      action: "win.new-tab";
    }
  }

  section {
    item {
      label: _("Split Right");
      action: "win.split-right";
    }

    item {
      label: _("Split Down");
      action: "win.split-down";
    }
  }

  section {
    item {
      label: _("Notify on Command Exit");
      action: "surface.notify-on-next-command-finish";
    }
  }

  section {
    item {
      label: _("Change Title…");
      action: "win.prompt-surface-title";
    }
  }

  section {
    item {
      label: _("Overview");
      action: "win.toggle-tab-overview";
    }

    item {
      label: _("Command Palette");
      action: "win.toggle-command-palette";
    }
  }

  // The following items replace the existing "Window", "Tab", and "Split"
  // submenus. Those submenus are commented out below so they can be
  // re-enabled easily if needed.
  //
  // section {
  //   submenu {
  //     label: _("Split");
  //     item { label: _("Change Title…"); action: "surface.prompt-title"; }
  //     item { label: _("Split Up");      action: "split-tree.new-split"; target: "up"; }
  //     item { label: _("Split Down");    action: "split-tree.new-split"; target: "down"; }
  //     item { label: _("Split Left");    action: "split-tree.new-split"; target: "left"; }
  //     item { label: _("Split Right");   action: "split-tree.new-split"; target: "right"; }
  //     item { label: _("Close Split");   action: "split-tree.close-split"; }
  //   }
  //   submenu {
  //     label: _("Tab");
  //     item { label: _("Change Tab Title…"); action: "tab.prompt-tab-title"; }
  //     item { label: _("New Tab");           action: "win.new-tab"; }
  //     item { label: _("Close Tab");         action: "win.close-tab"; target: "this"; }
  //   }
  //   submenu {
  //     label: _("Window");
  //     item { label: _("New Window");   action: "win.new-window"; }
  //     item { label: _("Close Window"); action: "win.close"; }
  //   }
  // }
}
```

> Blueprint note: `GtkPopoverMenu` with `flags: nested` supports `section {}` blocks
> as visual separators (rendered as horizontal dividers). Each `section {}` is one
> divider group. The order above maps directly to the feature description order.

### Step 4 — Make surface.zig expose the `context_menu` popover to callers

**File:** `src/apprt/gtk/class/surface.zig`

The `priv.context_menu` field (line 717) is private. Window needs to call
`popover.setMenuModel()` on it. Add a public accessor method:

```zig
/// Returns the context menu popover for this surface.
/// Used by the Window to swap the menu model based on decoration state.
pub fn getContextMenu(self: *Self) *gtk.PopoverMenu {
    return self.private().context_menu;
}
```

Place this alongside other property accessors (e.g. near `getTitle` at line 2065).

### Step 5 — Swap the menu model at popup time in `Window.surfaceMenu`

**File:** `src/apprt/gtk/class/window.zig`

Modify `surfaceMenu` (line 1897) to swap the `PopoverMenu`'s model:

```zig
fn surfaceMenu(
    surface: *Surface,
    self: *Self,
) callconv(.c) void {
    self.syncActions();

    // When the window has no visible decoration (no header bar), show a
    // richer flat context menu so the user can still reach window/tab/split
    // actions without the header bar buttons.
    const no_deco = !self.getHeaderbarVisible();
    const popover = surface.getContextMenu();
    if (no_deco) {
        // Load the decoration-hidden menu model from the GResource bundle.
        // gtk.PopoverMenu.setMenuModel replaces the model in place; the
        // popover keeps its position target set by the mouse-click handler.
        const menu_model = gio.ext.menuFromResource(
            "/com/mitchellh/ghostty/ui/1.2/surface.ui",  // the compiled blp
            "context_menu_model_no_decoration",
        );
        popover.setMenuModel(menu_model);
    } else {
        // Restore the default model (declared as `menu-model` in Blueprint).
        const menu_model = gio.ext.menuFromResource(
            "/com/mitchellh/ghostty/ui/1.2/surface.ui",
            "context_menu_model",
        );
        popover.setMenuModel(menu_model);
    }
}
```

> **Important implementation note:** The GTK resource path and API for loading a named
> menu from a Blueprint-compiled resource needs to be confirmed with the existing
> `gresource.zig` helpers (`src/apprt/gtk/build/gresource.zig`). An alternative
> (simpler) approach: build the alternative `gio.Menu` programmatically in Zig code
> rather than loading it from a resource. This avoids needing to identify a named object
> within the compiled GResource and is the recommended fallback if resource lookup proves
> awkward.

**Recommended fallback (programmatic menu):**

Instead of resource loading, build the decoration-hidden menu as a `gio.Menu` object in
Zig at call time, then pass it to `popover.setMenuModel()`. Skeleton:

```zig
fn buildNoDecorationMenu() *gio.Menu {
    const menu = gio.Menu.new();

    const sec1 = gio.Menu.new();
    sec1.append(_("New Window"), "win.new-window");
    sec1.append(_("New Tab"), "win.new-tab");
    menu.appendSection(null, sec1.as(gio.MenuModel));

    const sec2 = gio.Menu.new();
    sec2.append(_("Split Right"), "win.split-right");
    sec2.append(_("Split Down"), "win.split-down");
    menu.appendSection(null, sec2.as(gio.MenuModel));

    const sec3 = gio.Menu.new();
    sec3.append(_("Notify on Command Exit"), "surface.notify-on-next-command-finish");
    menu.appendSection(null, sec3.as(gio.MenuModel));

    const sec4 = gio.Menu.new();
    sec4.append(_("Change Title\xe2\x80\xa6"), "win.prompt-surface-title");
    menu.appendSection(null, sec4.as(gio.MenuModel));

    const sec5 = gio.Menu.new();
    sec5.append(_("Overview"), "win.toggle-tab-overview");
    sec5.append(_("Command Palette"), "win.toggle-command-palette");
    menu.appendSection(null, sec5.as(gio.MenuModel));

    return menu;
}
```

Call this once and cache it in `Window.Private`, or call on every `surfaceMenu` invocation
(cheap since menus are reference-counted GObjects). If cached, it should be stored as
`?*gio.Menu` in `Private` and freed in `dispose`.

### Step 6 — (Optional) Keep Blueprint menu for documentation

The `context_menu_model_no_decoration` added in Step 3 can be kept purely as a
documentation artifact (it won't be loaded at runtime if the programmatic approach in
Step 5 is used) or removed if the programmatic path is chosen definitively.

---

## "Change Title" Feature — Split Title vs Tab Title

### Current title chain (tab.blp line 11)

The `GhosttyTab` widget's `title` property is computed via `closureComputedTitle`
(`src/apprt/gtk/class/tab.zig` line 501). Priority order (highest wins):

```
1. tab.title-override  (set by promptTabTitle → TitleDialog → Tab.setTitleOverride)
2. surface.title-override  (set by surface.prompt-title / promptTitle → TitleDialog → Surface.setTitleOverride)
3. surface.title  (set by terminal OSC sequence → Surface.setTitle)
4. config.title  (the configured window title, if any)
5. "Ghostty"  (hardcoded default)
```

### How "Change Title…" in the new menu works

The action `win.prompt-surface-title` calls `Window.actionPromptSurfaceTitle`
(`window.zig:2297`) which calls `self.performBindingAction(.prompt_surface_title)`.
This dispatches to `Surface.promptTitle()` (`surface.zig:1495`) which shows a
`TitleDialog` for `.surface` target. When confirmed, it calls `Surface.setTitleOverride`.

**Rule:** "if no tab title is set, use split title as the tab title display (split title
NEVER overwrites tab title)."

This rule is already satisfied by the existing priority chain: `tab.title-override` wins
over `surface.title-override`. Setting the split (surface) title via `surface.prompt-title`
populates `surface.title-override` at priority 2; a tab title-override at priority 1 will
always win. **No code change is needed** to implement this rule — it is already the
correct behaviour.

The only thing to ensure is that `win.prompt-surface-title` is used in the menu (not
`surface.prompt-title`), because `surface.prompt-title` is in the `surface` action group
which may not always be reachable from a `gio.Menu` item depending on widget ancestry.
`win.*` actions are always reachable.

---

## Conditional Menu (decoration hidden vs visible)

The switch is performed in `Window.surfaceMenu()` (called via the `Surface.signals.menu`
signal, emitted right before `popover.popup()` in `surface.zig:3108`).

Detection: `self.getHeaderbarVisible()` returns `false` when decoration is hidden.
This covers all cases: `window-decoration = none`, CSD disabled by window manager (SSD),
fullscreen, `gtk-titlebar = false`, and `gtk-titlebar-style = tabs`.

The existing menu is used unchanged when `getHeaderbarVisible()` returns `true`. The popover
still references the original Blueprint-declared `context_menu_model` as its initial
`menu-model`; calling `setMenuModel` with the original model restores it (or a `null` reset
before each popup avoids needing to call setMenuModel when decoration is visible, though
setting it every time is safe).

---

## Items to Comment Out

These sections in `src/apprt/gtk/ui/1.2/surface.blp` are **not removed** but are
commented out (Blueprint uses `//` line comments):

**Section 3 — "Split" / "Tab" / "Window" submenus** (lines 305–377):

```blueprint
// section {
//   submenu {
//     label: _("Split");
//     ...
//   }
//   submenu {
//     label: _("Tab");
//     ...
//   }
//   submenu {
//     label: _("Window");
//     ...
//   }
// }
```

These entries continue to exist in their current form in the original `context_menu_model`
(which is still shown when decoration is visible). The comments are only applied inside
`context_menu_model_no_decoration`, where those submenus are replaced by the flat top-level
items. The original `context_menu_model` is left fully intact.

---

## Files to Change

| File | Change |
|---|---|
| `src/apprt/gtk/ui/1.2/surface.blp` | 1. Rename "Notify on Next Command Finish" label (line 288). 2. Add `menu context_menu_model_no_decoration { … }` block after existing menu (or keep as doc-only). |
| `src/apprt/gtk/class/window.zig` | 1. Add `"toggle-tab-overview"` to `initActionMap()` array. 2. Add `actionToggleTabOverview()` handler. 3. Modify `surfaceMenu()` to swap menu model based on `getHeaderbarVisible()`. 4. (If programmatic menu) Add `buildNoDecorationMenu()` helper and optional caching in `Private`. |
| `src/apprt/gtk/class/surface.zig` | Add `getContextMenu()` public accessor. |

---

## Open Questions / Risks

1. **`setMenuModel` API availability:** `gtk.PopoverMenu.setMenuModel` is a standard GTK4
   API (`gtk_popover_menu_set_menu_model`). It must exist in the auto-generated `gobject`
   bindings (`deps.files.ghostty.org/gobject-2025-11-08-23-1.tar.zst`). If not, the
   fallback is to hold two `*gtk.PopoverMenu` widgets and toggle `visible` on them.

2. **`notify-on-next-command-finish` is a stateful boolean action.** The `GtkPopoverMenu`
   will render it with a checkmark automatically because the action has a boolean state.
   This works correctly for the new menu — no extra handling needed.

3. **i18n:** All new string literals must be wrapped in `_()` (the `i18n._()` macro from
   `src/os/main.zig`). This is already done in the Blueprint snippets above. The
   `gio.Menu.append()` call in Zig must also use `i18n._()`.

4. **"Overview" action name:** `win.toggle-tab-overview` does not exist today and must be
   registered in Step 1. The underlying `Window.toggleTabOverview()` already exists at
   `window.zig:823`.

5. **`surface.notify-on-next-command-finish` reachability from programmatic `gio.Menu`:**
   The `surface` action group is installed on the `GhosttySurface` widget itself
   (`surface.zig:1923`). Since the `PopoverMenu` is a child of the surface's widget tree,
   the action is reachable via GTK's action-map traversal. Confirmed safe.
