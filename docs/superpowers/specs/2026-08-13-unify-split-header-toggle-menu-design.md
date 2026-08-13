# Unify per-split toggle menu items with `toggle_*` commands

Date: 2026-08-13

## Goal

Every per-split context menu (the split header bar's right-click menu and the identical hover drag-handle menu) should offer three consistent toggle items — **Toggle Split Header**, **Toggle Tab Bar**, **Toggle Window Decorations** — and these should align with the keybind commands prefixed `toggle_`. To make the alignment real, add a new `toggle_tab_bar` keybind command so all three menu items correspond to a bindable command that also appears in the command palette.

## Background / current state

- **Per-split menus.** Both `src/apprt/gtk/ui/1.5/split-header.blp` (`header_context_menu_model`, lines 85–90) and `src/apprt/gtk/ui/1.5/surface-scrolled-window.blp` (lines 111–116) currently have a single item **"Toggle Titlebar"** → `split-tree.toggle-header`. These are the same logical context menu shown in two places.
- **Existing GTK actions.** `split-tree.toggle-header`, `win.toggle-tab-bar` (`window.zig` `actionToggleTabBar`), and `win.toggle-decoration` (`window.zig` `actionToggleDecoration` → `toggleWindowDecorations`) all exist. Both per-split menus already use `win.*` and `split-tree.*` actions, so all three resolve in context.
- **Existing keybind commands.** `toggle_split_header` (→ `split-tree.toggle-header`) and `toggle_window_decorations` exist. **There is no `toggle_tab_bar` keybind command** — the tab bar only has the GTK menu action `win.toggle-tab-bar`.
- **Label drift.** Current labels ("Toggle Titlebar", and in the window main menu "Toggle Window Decoration" / "Toggle Split Headers") don't match the command titles.

## Scope

In scope (decided with the user):

1. Add the three unified toggle items to **both** per-split menus, in a **single dedicated section**.
2. Add a real **`toggle_tab_bar`** keybind command, wired end-to-end and routed to `win.toggle-tab-bar` on GTK.

Out of scope: the window main menu (`window.blp`) labels stay as-is; no other refactoring.

## Design

### 1. Menu changes (primary ask)

In both `split-header.blp` and `surface-scrolled-window.blp`, replace the single "Toggle Titlebar" section with one dedicated section containing three items in this order:

| Label | GTK action (existing) | Matching keybind command |
|---|---|---|
| Toggle Split Header | `split-tree.toggle-header` | `toggle_split_header` (existing) |
| Toggle Tab Bar | `win.toggle-tab-bar` | `toggle_tab_bar` (new) |
| Toggle Window Decorations | `win.toggle-decoration` | `toggle_window_decorations` (existing) |

Blueprint fragment (identical in both files):

```blueprint
section {
  item {
    label: _("Toggle Split Header");
    action: "split-tree.toggle-header";
  }
  item {
    label: _("Toggle Tab Bar");
    action: "win.toggle-tab-bar";
  }
  item {
    label: _("Toggle Window Decorations");
    action: "win.toggle-decoration";
  }
}
```

Labels match the command titles exactly ("Decorations" plural; "Toggle Titlebar" renamed to "Toggle Split Header"). Menu items point at the GTK actions directly — the same pattern the menus already use. The keybind command is a parallel entry point, not something the menus route through.

### 2. New `toggle_tab_bar` keybind command

Mirror the exact wiring of the existing `toggle_split_header` command across the stack:

- **`src/input/Binding.zig`** — add `toggle_tab_bar` to the `Action` enum (near `toggle_split_header`) and include it in the surface-scope categorization list. Add a `parse` round-trip test mirroring `"parse: toggle_split_header"`.
- **`src/input/command.zig`** — add a `.toggle_tab_bar` command palette entry: title `"Toggle Tab Bar"`, description `"Toggle the tab bar visibility."`.
- **`src/apprt/action.zig`** — add `toggle_tab_bar` to the `Action` union and to its `Key` enum list.
- **`src/Surface.zig`** — add `.toggle_tab_bar => return try self.rt_app.performAction(.{ .surface = self }, .toggle_tab_bar, {})`.
- **`src/apprt/gtk/class/application.zig`** — add a `.toggle_tab_bar` branch that resolves the ancestor `Window` from the target surface and activates `win.toggle-tab-bar`, mirroring the `toggle_split_header` branch that resolves the ancestor `SplitTree` and activates `split-tree.toggle-header`.

### 3. macOS / cross-platform enum parity

The `Action` enum is shared across platforms, so keep the off-GTK side consistent by mirroring how `toggle_split_header` is handled:

- **`include/ghostty.h`** — add `GHOSTTY_ACTION_TOGGLE_TAB_BAR` to the C action enum.
- **`macos/Sources/Ghostty/Ghostty.App.swift`** — add a no-op `case GHOSTTY_ACTION_TOGGLE_TAB_BAR` (the tab bar is GTK-only), mirroring the `GHOSTTY_ACTION_TOGGLE_SPLIT_HEADER` no-op.
- **`macos/Sources/Ghostty/Ghostty.Command.swift`** — add `"toggle_tab_bar"` to `unsupportedActionKeys`.

This fork builds GTK via the dev container; macOS isn't built here, but keeping the enum in sync avoids a latent break.

## Testing

- **Unit:** `zig build test -Dtest-filter=...` for the `Binding.zig` `toggle_tab_bar` parse round-trip test.
- **Manual:** `mise run build`, then open a split and right-click both the split header and the hover drag-handle. Confirm all three items appear in one section and each toggles the correct affordance (split header visibility, tab bar visibility, window decorations).

## Non-goals

- Changing the window main menu (`window.blp`) labels.
- Adding a default key binding for `toggle_tab_bar` (the action is registered and bindable; no default chord is assigned).
- Any refactoring beyond what serves this change.
