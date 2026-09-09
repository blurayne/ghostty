---
date: 2026-09-09
topic: "Split focus: a searchable tree of every window, tab and split"
tags: [spec, gtk, navigation, tab-switcher]
status: draft
supersedes: docs/superpowers/plans/2026-08-13-tab-switcher.md
---

# Split focus

## Problem

`toggle_tab_switcher` lists the tabs of the *current window* as a flat list, with a split count per tab and a "Show splits" checkbox that does nothing — its handler is an empty stub. You cannot see other windows, cannot see individual splits, and cannot jump to a split. With several windows each holding several tabs of several panes, there is no way to answer "where is the pane running the deploy script" other than looking through them by hand.

The feature is also unreleased and was, until today, unusable: presenting the dialog froze the app (fixed in `79ac57e29`). Tasks 3–5 of its original plan were never implemented. So this is a redesign of unfinished work, not a rewrite of something people depend on.

## Goal

One dialog showing **every window, tab and split** as a tree, searchable, where activating any row focuses the corresponding terminal.

## Decisions

| Question | Decision |
|---|---|
| Tree | Real `GtkTreeListModel` with expanders |
| Search | Keep ancestors of matches, auto-expand, hide non-matching |
| That behaviour | Toggleable by checkbox, default from config |
| Highlight | Invert only the matched characters |
| Row label | Title + working directory; search matches both |
| Header rows | Activating focuses their currently-active split |
| Preselection | Current split; holds while it still matches, else first match |
| Keyboard focus | Search entry, always |
| Action name | `toggle_split_focus`; `toggle_tab_switcher` kept as a deprecated variant that still works |

## Architecture

### Item model

A new `SplitFocusItem` GObject replaces `TabSwitcherItem`:

```zig
const Kind = enum { window, tab, split };

kind: Kind,
title: [:0]const u8,        // window/tab title, or surface title
pwd: ?[:0]const u8,         // splits only; null when unknown
window: WeakRef(Window),    // set for all kinds
page: ?*adw.TabPage,        // tab and split kinds
surface: WeakRef(Surface),  // split kind only
children: ?*gio.ListStore,  // window and tab kinds
```

Weak references throughout: the dialog must not keep a window or surface alive, and a pane can close while the dialog is open. Every activation path re-checks the weak ref and does nothing if it is gone.

### Building the tree

```
gtk.Application.getWindows()            → window rows
  window.getTabView()                    → getNPages / getNthPage
    page.getChild() → cast(Tab)          → tab rows
      tab.getSurfaceTree()               → tree.iterator() → split rows
```

A `GtkTreeListModel` wraps the root `GListStore`, with a create-child-model callback returning `item.children` for window and tab kinds and `null` for splits — that null is what makes a split a leaf.

Order is `getWindows()` order for windows, tab-view order for tabs, and tree-iterator order for splits. No sorting: positional stability matters more than alphabetical tidiness, because users navigate by remembered position.

### Filtering

`GtkStringFilter` cannot be used. Over a `GtkTreeListModel` it sees a flat sequence of `GtkTreeListRow`s and drops individual rows, so a matching split whose window and tab do not match loses its ancestors and renders orphaned at the wrong depth.

A custom `GtkFilter` subclass instead, with one rule:

> Keep a row if it matches, **or** if any of its descendants match.

Implemented by matching downward from the item — for a window, test the window title and recurse into tabs and splits — so no upward parent pointers are needed and the rule holds regardless of expansion state.

While a search is active, the view auto-expands so matches are visible without clicking. When the search is cleared, the tree returns to the expansion state it had before the search began (captured on the first keystroke of a search).

The checkbox switches the filter between this rule and pass-through. Highlighting is **independent** of the filter and applies in both modes — that is what makes the unchecked mode useful rather than merely noisy.

### Highlighting

Matched characters are drawn with foreground and background swapped, via a `PangoAttrList` on the label covering the matched byte range. Attributes rather than markup: no escaping of titles needed, and terminal titles routinely contain `&` and `<`.

Colours are resolved at render time from the row's style context and swapped. If a theme makes that unreliable, fall back to libadwaita's accent pair (`adw_style_manager_get_accent_color`, available since 1.6; the runtime here is 1.9.3), which is how GTK draws selected text.

Byte ranges, not character counts — a match inside a title containing non-ASCII must not shift the attribute range.

### Activation

Every row resolves to exactly one surface:

| Row | Target |
|---|---|
| split | its own surface |
| tab | `tab.getActiveSurface()` |
| window | `window.getActiveSurface()` |

Then: close the dialog, select the owning tab page if it is not current, present the window if it is not the active one, and `surface.grabFocus()`. Closing first avoids the dialog lingering over the newly focused window — the existing `activate()` already does this and the reason still holds.

### Selection and focus

On open: the row for the currently-focused surface is selected and scrolled into view. On each search change: selection holds if the selected row still passes the filter, otherwise it moves to the first visible row.

Focus stays in the search entry for the dialog's whole lifetime. Up/Down/Page keys are forwarded from the entry to the list view via a key controller, so the list never takes focus and typing is never interrupted. Enter activates the selection; Escape closes.

## Config

```zig
/// Whether the split focus dialog hides rows that do not match the search.
/// When true, searching shows only matching rows and the branches leading to
/// them, expanded automatically. When false the whole tree stays visible and
/// matches are only highlighted. The dialog's checkbox overrides this for the
/// current session.
///
/// Available since: 1.4.0
@"split-focus-hide-unmatched": bool = true,
```

## Renaming

`toggle_tab_switcher` → `toggle_split_focus` across `src/input/Binding.zig`, `src/apprt/action.zig`, `include/ghostty.h`, `src/apprt/gtk/class/application.zig` and `src/apprt/gtk/class/window.zig`. The default keybind stays `ctrl+shift+k` / `cmd+shift+k`.

Ghostty has **no alias mechanism** for actions. Its one deprecation precedent is `close_all_windows` (`src/input/Binding.zig:788`): the enum variant stays, carries a `WARNING: This action has been deprecated` doc comment, and continues to parse. Follow that pattern rather than inventing aliasing:

- `toggle_tab_switcher` stays as an `Action` variant with a deprecation doc comment pointing at `toggle_split_focus`.
- It dispatches to the same handler, so existing configs keep working unchanged.
- It **remains listed** in `+list-actions`. There is no suppression mechanism and adding one is out of scope; the doc comment is how a user learns it is deprecated, consistent with `close_all_windows`.

`include/ghostty.h` therefore keeps `GHOSTTY_ACTION_TOGGLE_TAB_SWITCHER` **and** gains `GHOSTTY_ACTION_TOGGLE_SPLIT_FOCUS`, each in the position matching its `Action.Key` variant. The C enum and the Zig enum must stay index-aligned: the desync the tab-switcher entry originally caused was a real ABI break, fixed in `3978f21e5`, and must not be reintroduced. The `ghostty.h Action.Key` test is what catches this.

## Files

| File | Change |
|---|---|
| `src/apprt/gtk/class/split_focus.zig` | New; replaces `tab_switcher.zig`, holds the dialog and `SplitFocusItem` |
| `src/apprt/gtk/class/split_focus_filter.zig` | New; the ancestor-retaining `GtkFilter` subclass |
| `src/apprt/gtk/ui/1.5/split-focus.blp` | New; top-level `Adw.Dialog`, **not** wrapped in a template — the wrapper is what froze the app |
| `src/apprt/gtk/class/tab_switcher.zig` | Deleted |
| `src/apprt/gtk/ui/1.5/tab-switcher.blp` | Deleted |
| `src/apprt/gtk/build/gresource.zig` | Blueprint list updated |
| `src/input/Binding.zig`, `src/apprt/action.zig`, `include/ghostty.h` | Action rename + alias |
| `src/apprt/gtk/class/application.zig`, `window.zig` | Dispatch rename |
| `src/config/Config.zig` | New option; keybind default unchanged |

Splitting the filter into its own file keeps the dialog file from carrying both the widget lifecycle and the matching rules.

## Testing

**Unit** — the parts that are pure:

- Match rule: a window whose title does not match but whose split does is kept; one with no matching descendant is dropped; matching is case-insensitive.
- Highlight ranges: byte offsets are correct for an ASCII match, a match after a multi-byte character, no match, and a match at position 0.
- Kind→target resolution given a fabricated item.

**Manual** — the parts that need a compositor:

1. Two windows, several tabs, several splits. `Ctrl+Shift+K` shows all of them as a tree.
2. Current split is preselected and scrolled into view; focus is in the search box.
3. Type a string matching one split in a non-current window: its window and tab remain, other branches disappear, the match is inverted, Enter focuses that split in that window.
4. Uncheck the box: the whole tree returns, the match stays inverted.
5. Activate a window row → its active split focuses. Same for a tab row.
6. Close a pane elsewhere while the dialog is open, then activate its row → nothing happens, no crash.
7. `toggle_tab_switcher` in a config still binds and works, with a deprecation note.
8. Escape closes; `Ctrl+Shift+K` again closes.

## Out of scope

- **Reordering or closing** panes from the dialog. Navigation only.
- **Sorting or MRU ordering.** Positional order only.
- **Fuzzy matching.** Case-insensitive substring, matching the current behaviour.
- **macOS.** The GTK apprt only; libghostty gets the renamed action constant but no UI.

## Known dependency

`pwd` is populated only when shell integration reports the working directory. Shell integration is currently **not loading in the flatpak build** — the log shows `unable to open …/shell-integration/zsh: error.FileNotFound` followed by `no automatic shell integration will be injected`. Until that is fixed the pwd column will be empty. That is a separate defect, not a fault in this feature, and this spec does not depend on it being fixed first: an empty pwd degrades to title-only rows.
