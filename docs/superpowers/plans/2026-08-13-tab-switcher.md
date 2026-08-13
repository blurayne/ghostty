# Tab Switcher Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a keyboard-navigable tab switcher dialog (opened with `Ctrl+Shift+K`) that lists the current window's tabs, shows each tab's split count, lets you expand a tab to see its splits, and rename or close tabs from the dialog.

**Architecture:** Mirror the existing command palette. Add a `toggle_tab_switcher` keybind action wired exactly like `toggle_tab_overview`, routing to a new `win.toggle-tab-switcher` GTK action on the `Window`. The `Window` lazily creates a new `TabSwitcher` widget (an `adw.Bin` wrapping an `Adw.Dialog`, modeled on `CommandPalette`), holds it via `WeakRef`, and `present`s it over the window. The dialog uses a `Gtk.TreeListModel` (tab rows → split child rows) behind a `Gtk.SingleSelection` in a `Gtk.ListView`; each visible row is backed by a `TabSwitcherItem` GObject. A "Show splits" checkbox expands all rows; Right/Left arrows expand/collapse individual rows.

**Tech Stack:** Zig, GTK4, libadwaita (Adw), GObject via the `gobject`/`gtk`/`adw`/`gio`/`glib` Zig bindings, Blueprint UI (`.blp`) compiled into gresources.

## Global Constraints

- All builds/tests run **inside the dev container** via `mise`. Never run `zig build`/`flatpak-builder` on the host.
- Full GTK verification build: `mise run build` (artifact lands in `dist/build/com.mitchellh.ghostty.flatpak`). Install to test manually: `mise run install`.
- Core (non-GTK) compile check: `mise run zig-test -- -Dapp-runtime=none "-Dtest-filter=<name>"` (quote the filter after `--`).
- GTK widget code is **not unit-testable**; the gate for GTK tasks is "compiles via `mise run build`" plus the listed manual verification. Only Task 1 has a Zig unit test.
- Format Zig before committing: `docker compose run --rm builder zig fmt <files>`.
- Blueprint files live in `src/apprt/gtk/ui/1.5/` and must be registered in `src/apprt/gtk/build/gresource.zig`.
- Follow existing fork conventions: new GTK class files go in `src/apprt/gtk/class/`, use the `Common(Self, Private)` helper, `gobject.ext.defineClass`, template children via `bindTemplateChildPrivate`.
- Commit after each task with a `feat(gtk):`/`feat:` message ending in the `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>` trailer.
- Do NOT create issues or PRs.

---

## File Structure

- `src/input/Binding.zig` — add `toggle_tab_switcher` to the `Action` enum + surface scope + parse test.
- `src/input/command.zig` — add a command-palette default entry for `toggle_tab_switcher`.
- `src/apprt/action.zig` — add `toggle_tab_switcher` to the `Action` union and the `Key` enum.
- `src/Surface.zig` — dispatch `toggle_tab_switcher` to `performAction`.
- `src/apprt/gtk/class/application.zig` — route the apprt action to `win.toggle-tab-switcher`.
- `src/apprt/gtk/class/window.zig` — register `win.toggle-tab-switcher`, add `toggleTabSwitcher()` (lazy-create + `WeakRef` + present), and a `WeakRef(TabSwitcher)` private field.
- `src/apprt/gtk/class/tab_switcher.zig` — **new** — the `TabSwitcher` widget + the `TabSwitcherItem` GObject.
- `src/apprt/gtk/ui/1.5/tab-switcher.blp` — **new** — the dialog blueprint.
- `src/apprt/gtk/build/gresource.zig` — register the `tab-switcher` blueprint.
- `src/config/Config.zig` — add the default `Ctrl+Shift+K` keybinding.

---

## Task 1: `toggle_tab_switcher` keybind action (plumbing + stub handler)

Wire a new no-op-yet action end-to-end so the key press reaches a `Window` handler that just logs. This mirrors `toggle_tab_overview` exactly.

**Files:**
- Modify: `src/input/Binding.zig` (Action enum near `toggle_tab_overview` ~line 606; surface-scope switch ~line 1483; add parse test near line 4686)
- Modify: `src/input/command.zig` (near the `toggle_tab_overview` command entry ~line 456)
- Modify: `src/apprt/action.zig` (Action union near `toggle_tab_overview` ~line 110; Key enum near line 391)
- Modify: `src/Surface.zig` (near the `toggle_tab_overview` dispatch arm)
- Modify: `src/apprt/gtk/class/application.zig` (performAction switch near `.toggle_tab_overview` ~line 789; helper near `Action.toggleTabOverview` ~line 3454)
- Modify: `src/apprt/gtk/class/window.zig` (initActionMap list ~line 623; add handler + `toggleTabSwitcher` stub)
- Modify: `src/config/Config.zig` (default keybinds init, near where other `ctrl+shift+*` binds are added)

**Interfaces:**
- Produces: `input.Binding.Action.toggle_tab_switcher` (tag, no payload); `apprt.action.Action.toggle_tab_switcher`; GTK action name `"win.toggle-tab-switcher"`; `Window.toggleTabSwitcher(self: *Window) void`.

- [ ] **Step 1: Add the Action enum variant (Binding.zig)**

Find the `toggle_tab_overview,` line in the `Action` enum and add after it:

```zig
    /// Open a keyboard-navigable tab switcher dialog for the current window.
    ///
    /// Only implemented on Linux (GTK).
    toggle_tab_switcher,
```

- [ ] **Step 2: Add to the surface-scope switch (Binding.zig)**

In the scope switch, find the group of surface-scoped actions containing `.toggle_tab_overview,` (around line 1483) and add `.toggle_tab_switcher,` in the same `=> .surface` group.

- [ ] **Step 3: Add the parse test (Binding.zig)**

Near the existing `test "parse: toggle_tab_overview"` (or the `toggle_split_header` test ~line 4686), add:

```zig
test "parse: toggle_tab_switcher" {
    const result = try Action.parse("toggle_tab_switcher");
    try std.testing.expectEqual(Action.toggle_tab_switcher, result);
}
```

- [ ] **Step 4: Run the parse test (expect PASS after build compiles)**

Run: `mise run zig-test -- -Dapp-runtime=none "-Dtest-filter=parse: toggle_tab_switcher"`
Expected: build compiles and the test passes (`EXIT=0`). If the apprt/action or command switches are not yet updated, compilation fails — do Steps 5–6 first, then re-run.

- [ ] **Step 5: Add the command-palette entry (command.zig)**

After the `.toggle_tab_overview => comptime &.{.{ ... }},` block add:

```zig
        .toggle_tab_switcher => comptime &.{.{
            .action = .toggle_tab_switcher,
            .title = i18n.N_("Tab Switcher"),
            .description = i18n.N_("Open the tab switcher for the current window."),
        }},
```

- [ ] **Step 6: Add to the apprt Action union + Key enum (apprt/action.zig)**

After `toggle_tab_overview,` in the `Action` union add:

```zig
    /// Open a keyboard-navigable tab switcher for the current window.
    ///
    /// Only implemented on Linux (GTK).
    toggle_tab_switcher,
```

And in the `Key` enum (the list that also contains `toggle_tab_overview`) add `toggle_tab_switcher,` in the same relative position.

- [ ] **Step 7: Dispatch from Surface.zig**

After the `.toggle_tab_overview => return try self.rt_app.performAction(...)` arm add:

```zig
        .toggle_tab_switcher => return try self.rt_app.performAction(
            .{ .surface = self },
            .toggle_tab_switcher,
            {},
        ),
```

- [ ] **Step 8: Route the apprt action to the GTK action (application.zig)**

In the `performAction` switch, after `.toggle_tab_overview => return Action.toggleTabOverview(target),` add:

```zig
            .toggle_tab_switcher => return Action.toggleTabSwitcher(target),
```

Then add a helper next to `toggleTabOverview` (inside the nested `Action` struct, near line 3454), mirroring it:

```zig
        pub fn toggleTabSwitcher(target: apprt.Target) bool {
            switch (target) {
                .app => return false,
                .surface => |v| {
                    const surface = v.rt_surface.surface;
                    const window = ext.getAncestor(
                        Window,
                        surface.as(gtk.Widget),
                    ) orelse return false;
                    window.toggleTabSwitcher();
                    return true;
                },
            }
        }
```

(Confirm the exact field access for the surface from the `target` by copying it verbatim from the adjacent `toggleTabOverview` helper — do not invent field names.)

- [ ] **Step 9: Register `win.toggle-tab-switcher` + stub handler (window.zig)**

In `initActionMap`'s action list (near `.init("toggle-tab-overview", actionToggleTabOverview, null),`) add:

```zig
            .init("toggle-tab-switcher", actionToggleTabSwitcher, null),
```

Add the handler near `actionToggleTabOverview`:

```zig
    fn actionToggleTabSwitcher(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Self,
    ) callconv(.c) void {
        self.toggleTabSwitcher();
    }
```

Add the stub method near `toggleTabOverview` (real body comes in Task 3):

```zig
    /// Toggle the tab switcher dialog for this window.
    pub fn toggleTabSwitcher(self: *Self) void {
        _ = self;
        log.info("toggle_tab_switcher invoked (stub)", .{});
    }
```

- [ ] **Step 10: Add the default keybinding (Config.zig)**

Find where default keybinds are registered (the `keybind.set`/`.parseAndPut`-style block for `ctrl+shift+*` binds). Add a binding for `ctrl+shift+k` → `toggle_tab_switcher`, copying the exact call style used by a neighboring default bind (e.g. the one for the command palette). Example shape (match the real API):

```zig
    try result.keybind.set.parseAndPut(alloc, "ctrl+shift+k=toggle_tab_switcher");
```

If the surrounding code uses a different helper, mirror it exactly.

- [ ] **Step 11: Format + full build**

Run:
```bash
docker compose run --rm builder zig fmt src/input/Binding.zig src/input/command.zig src/apprt/action.zig src/Surface.zig src/apprt/gtk/class/application.zig src/apprt/gtk/class/window.zig src/config/Config.zig
mise run build
```
Expected: `EXIT=0`, flatpak produced. Fix any compile errors (macOS enum parity is not required here since this is GTK-only, but if a macOS switch is exhaustive add a no-op `GHOSTTY_ACTION_TOGGLE_TAB_SWITCHER` case mirroring `toggle_split_header` — only if the build complains).

- [ ] **Step 12: Manual verify**

Run `mise run install`, launch Ghostty, press `Ctrl+Shift+K`. Expected: nothing visible, but the log shows `toggle_tab_switcher invoked (stub)` (check `flatpak run --command=... ` stderr or the journal). This confirms the whole chain works.

- [ ] **Step 13: Commit**

```bash
git add src/input/Binding.zig src/input/command.zig src/apprt/action.zig src/Surface.zig src/apprt/gtk/class/application.zig src/apprt/gtk/class/window.zig src/config/Config.zig
git commit -m "feat: add toggle_tab_switcher action (Ctrl+Shift+K), stub handler

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 2: `TabSwitcher` widget skeleton — flat tab list, search, select, close-on-escape

Create the dialog widget + blueprint, backed by a flat `Gio.ListStore` of `TabSwitcherItem` (one per tab), with a search entry, keyboard navigation, Enter-to-switch, Escape-to-close. No splits/expansion yet.

**Files:**
- Create: `src/apprt/gtk/class/tab_switcher.zig`
- Create: `src/apprt/gtk/ui/1.5/tab-switcher.blp`
- Modify: `src/apprt/gtk/build/gresource.zig` (add the blueprint)
- Modify: `src/apprt/gtk/class/window.zig` (replace the stub `toggleTabSwitcher`, add `WeakRef(TabSwitcher)` field + import)

**Interfaces:**
- Consumes: `Window.getTabView() *adw.TabView`; tab enumeration `tab_view.getNPages()/getNthPage(i)`, `page.getChild()` + `gobject.ext.cast(Tab, child)`; `tab_view.setSelectedPage(page)`; `page.getTitle()`; `Tab.getSurfaceTree() ?*Surface.Tree` + `tree.iterator()` for split counting.
- Produces: `TabSwitcher` GObject with `pub fn new() *TabSwitcher`, `pub fn toggle(self: *TabSwitcher, window: *Window) void`, `pub fn close(self: *TabSwitcher) void`; `TabSwitcherItem` GObject with string prop `title`, uint prop `split-count`, and a weak `page` pointer.

- [ ] **Step 1: Register the blueprint (gresource.zig)**

In the blueprint list (~line 40-56) add, keeping alphabetical order near `tab`:

```zig
    .{ .major = 1, .minor = 5, .name = "tab-switcher" },
```

- [ ] **Step 2: Write the blueprint (tab-switcher.blp)**

Model on `command-palette.blp`. Create `src/apprt/gtk/ui/1.5/tab-switcher.blp`:

```blueprint
using Gtk 4.0;
using Adw 1;

template $GhosttyTabSwitcher: Adw.Bin {
  Adw.Dialog dialog {
    title: _("Tab Switcher");
    content-width: 500;
    content-height: 400;
    closed => $closed();

    Adw.ToolbarView {
      [top]
      Adw.HeaderBar {
        title-widget: Gtk.SearchEntry search {
          placeholder-text: _("Search tabs");
          activate => $search_activated();
          stop-search => $search_stopped();
        };

        [end]
        Gtk.CheckButton show_splits {
          label: _("Show splits");
          toggled => $show_splits_toggled();
        }
      }

      Gtk.ScrolledWindow {
        vexpand: true;
        hscrollbar-policy: never;

        Gtk.ListView view {
          single-click-activate: true;
          activate => $row_activated();

          model: Gtk.SingleSelection model {
            model: Gtk.FilterListModel filter_model {
              incremental: true;

              filter: Gtk.StringFilter {
                expression: expr item as <$GhosttyTabSwitcherItem>.title;
                search: bind search.text;
              };
            };
          };

          factory: BuilderListItemFactory {
            template ListItem {
              child: Gtk.Box {
                spacing: 8;

                Gtk.Label {
                  hexpand: true;
                  xalign: 0;
                  ellipsize: end;
                  label: bind (template.item as <$GhosttyTabSwitcherItem>).title;
                }

                Gtk.Label {
                  css-classes: ["dim-label", "numeric"];
                  label: bind (template.item as <$GhosttyTabSwitcherItem>).split-count-label;
                }
              };
            }
          };
        }
      }
    }
  }
}
```

Note: `split-count-label` is a string property (e.g. `"3 splits"`) so binding is trivial; define it in Task 2 Step 4. The `filter_model`'s `model` (the backing store) is set from Zig in Step 5 (leave it unset in the blp or set via code). The `show_splits` checkbox is wired in Task 3.

- [ ] **Step 3: Write the `TabSwitcherItem` GObject (tab_switcher.zig)**

Create `src/apprt/gtk/class/tab_switcher.zig`. Start with the item type, modeled on `command_palette.zig`'s `Command` GObject. It wraps one `adw.TabPage` and exposes `title` (string), `split-count` (uint), and a computed `split-count-label` (string). Store a plain `*adw.TabPage` pointer (the switcher is modal and short-lived, so no strong ref needed; guard against use if needed). Provide `pub fn new(page: *adw.TabPage, title: [:0]const u8, split_count: u32) *TabSwitcherItem` and getters. Register the three properties with `gobject.ext.registerProperties` and use `bindTemplateChildPrivate`-free property accessors like `command_palette.zig` does for `title`/`action-key`.

(The implementing agent: copy the property-registration boilerplate from `command_palette.zig`'s `Command` verbatim and adapt field names. Keep `getGObjectType` name `"GhosttyTabSwitcherItem"` to match the blueprint cast.)

- [ ] **Step 4: Write the `TabSwitcher` widget (tab_switcher.zig)**

Add the `TabSwitcher` `adw.Bin` subclass with `getGObjectType` name `"GhosttyTabSwitcher"` and template from resource `gresource.blueprint(.{ .major = 1, .minor = 5, .name = "tab-switcher" })`. Private template children: `dialog: *adw.Dialog`, `search: *gtk.SearchEntry`, `view: *gtk.ListView`, `model: *gtk.SingleSelection`, `filter_model: *gtk.FilterListModel`, `show_splits: *gtk.CheckButton`. Private state: `source: *gio.ListStore` (created in init, holding `TabSwitcherItem`), `window: ?*Window = null`.

Implement:
- `pub fn new() *TabSwitcher` — `gobject.ext.newInstance`, `refSink()`, `ref()` (self-owned like `CommandPalette.new`).
- `init` — `initTemplate`, create `source = gio.ListStore.new(TabSwitcherItem.getGObjectType())`, set `filter_model.setModel(source.as(gio.ListModel))`.
- `pub fn toggle(self, window: *Window)` — if dialog realized, close; else `self.populate(window)`, `dialog.present(window.as(gtk.Widget))`, `search.grabFocus()`. Store `self.private().window = window`.
- `fn populate(self, window)` — clear `source`, iterate the window's tabs (`window.getTabView()`, `getNPages`/`getNthPage`, `cast(Tab, page.getChild())`), compute split count via `tab.getSurfaceTree()` + `tree.iterator()` counting, append a `TabSwitcherItem.new(page, page.getTitle(), count)` for each.
- Template callbacks: `closed` → `dialogClosed` (unref self), `search_activated` → activate selected, `search_stopped` → close, `row_activated` → activate row. `show_splits_toggled` → no-op stub for now (implemented Task 3).
- `fn activate(self, pos)` — read the selected `TabSwitcherItem` from the visible `model` (not `source`), get its `page`, `self.private().window.?.getTabView().setSelectedPage(page)`, then `self.close()`.
- `pub fn close(self)` — `dialog.close()`.

Class registration: bind all template children, bind the callbacks, `gobject.ext.ensureType(TabSwitcherItem)` in `Class.init`.

- [ ] **Step 5: Wire the Window to present it (window.zig)**

Add import: `const TabSwitcher = @import("tab_switcher.zig").TabSwitcher;`. Add a private field near `command_palette: WeakRef(CommandPalette)`:

```zig
        tab_switcher: WeakRef(TabSwitcher) = .empty,
```

Replace the stub `toggleTabSwitcher` (from Task 1) with the real body, mirroring `toggleCommandPalette`:

```zig
    pub fn toggleTabSwitcher(self: *Self) void {
        const priv = self.private();
        const switcher = priv.tab_switcher.get() orelse sw: {
            const sw = TabSwitcher.new();
            priv.tab_switcher.set(sw);
            break :sw sw;
        };
        defer switcher.unref();
        switcher.toggle(self);
    }
```

(Confirm `WeakRef(TabSwitcher).get()` returns a reffed pointer needing `unref` by copying the exact pattern from `toggleCommandPalette`.)

- [ ] **Step 6: Format + full build**

```bash
docker compose run --rm builder zig fmt src/apprt/gtk/class/tab_switcher.zig src/apprt/gtk/class/window.zig
mise run build
```
Expected: `EXIT=0`. Fix blueprint/compile errors (common: property-name mismatches between `.blp` bindings and the GObject property names; the cast type name must be exactly `$GhosttyTabSwitcherItem`).

- [ ] **Step 7: Manual verify**

`mise run install`; open several tabs (some with splits). Press `Ctrl+Shift+K`. Expected: dialog lists each tab with its title and an `"N splits"` badge; typing filters; Up/Down moves selection; Enter switches to the highlighted tab and closes; Escape closes.

- [ ] **Step 8: Commit**

```bash
git add src/apprt/gtk/class/tab_switcher.zig src/apprt/gtk/ui/1.5/tab-switcher.blp src/apprt/gtk/build/gresource.zig src/apprt/gtk/class/window.zig
git commit -m "feat(gtk): tab switcher dialog with searchable tab list

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 3: Expandable splits (TreeListModel) + "Show splits" checkbox + Right/Left expand

Replace the flat store with a `Gtk.TreeListModel` so each tab row can expand to its split rows. Right/Left arrows expand/collapse the focused row (native `Gtk.TreeExpander` behavior); the "Show splits" checkbox expands/collapses all rows.

**Files:**
- Modify: `src/apprt/gtk/class/tab_switcher.zig`
- Modify: `src/apprt/gtk/ui/1.5/tab-switcher.blp`

**Interfaces:**
- Consumes: `Tab.getSurfaceTree() ?*Surface.Tree`, `tree.iterator()` yielding `entry.view: *Surface`, `Surface.getEffectiveTitle() ?[:0]const u8`.
- Produces: `TabSwitcherItem` gains a `kind` (tab|split) discriminator and, for tab items, a child `gio.ListStore` of split items; `TabSwitcher` builds a `gtk.TreeListModel` over the tab store.

- [ ] **Step 1: Extend `TabSwitcherItem` for split rows**

Add an enum field `kind: enum { tab, split }` and, for tab items, a lazily-built child model. Add `pub fn new` variants: `newTab(page, title, split_count)` and `newSplit(surface_title)`. Split items have `split-count` 0 and a `title` of the pane title; `split-count-label` returns `""` for split kind. Add `pub fn children(self) ?*gio.ListModel` returning the split child store for tab items (built on demand by iterating `tab.getSurfaceTree()`), or `null` for split items (leaf).

- [ ] **Step 2: Build the TreeListModel (tab_switcher.zig)**

In `init`/`populate`, wrap `source` in a `gtk.TreeListModel`:

```zig
const tree_model = gtk.TreeListModel.new(
    source.as(gio.ListModel),
    @intFromBool(false), // passthrough
    @intFromBool(false), // autoexpand
    createChildModel,     // create-func: fn(item, user_data) ?*gio.ListModel
    self,
    null,
);
```

`createChildModel` receives a `TabSwitcherItem` and returns its `children()` (a new ref) or null. Set `filter_model.setModel(tree_model.as(gio.ListModel))`. Keep `source` as the root store you repopulate.

Note: with a `TreeListModel`, each visible item exposed by `SingleSelection`/`ListView` is a `gtk.TreeListRow`; get the underlying `TabSwitcherItem` via `row.getItem()`. Update `activate()` and the string filter expression accordingly (the filter must read `TreeListRow.item.title`; if the `StringFilter` expression can't traverse `TreeListRow`, filter only tab rows by keeping `passthrough=false` and matching on the row's item via a custom expression — the implementing agent verifies the exact blueprint expression and falls back to a `Gtk.CustomFilter` in Zig if needed).

- [ ] **Step 3: Update the row factory for expanders (tab-switcher.blp)**

Wrap the row content in a `Gtk.TreeExpander` bound to the list item's `TreeListRow`:

```blueprint
child: Gtk.TreeExpander expander {
  list-row: bind template.item as <Gtk.TreeListRow>;

  child: Gtk.Box {
    spacing: 8;
    Gtk.Label {
      hexpand: true; xalign: 0; ellipsize: end;
      label: bind (expander.item as <$GhosttyTabSwitcherItem>).title;
    }
    Gtk.Label {
      css-classes: ["dim-label", "numeric"];
      label: bind (expander.item as <$GhosttyTabSwitcherItem>).split-count-label;
    }
  };
};
```

`Gtk.TreeExpander` gives Right/Left expand/collapse and click expanders for free. The implementing agent confirms the exact bind expression names against GTK 4 (`item` vs `list-row.item`).

- [ ] **Step 4: Wire the "Show splits" checkbox**

Implement `show_splits_toggled`: when checked, expand every root row (iterate `tree_model.getNRows()`... actually iterate rows via `tree_model.getRow(i)` / `TreeListRow.setExpanded(true)`); when unchecked, collapse all. Keep a stored pointer to the `tree_model` in Private for this.

- [ ] **Step 5: Activation for split rows**

In `activate()`, if the selected item is a split, switch to its tab (`setSelectedPage`) and additionally focus that split's surface. Use the split's `*Surface` (store a weak pointer on the split `TabSwitcherItem`) and call the surface's `grabFocus()`/`present` path (mirror how the command palette's jump commands focus a surface — `surface.present()` in `command_palette.zig`). If focusing a specific split is non-trivial, at minimum switch to the tab.

- [ ] **Step 6: Format + full build**

```bash
docker compose run --rm builder zig fmt src/apprt/gtk/class/tab_switcher.zig
mise run build
```
Expected: `EXIT=0`.

- [ ] **Step 7: Manual verify**

`mise run install`. `Ctrl+Shift+K`: each tab row shows a disclosure expander. Right arrow expands a tab to show its split rows (pane titles); Left collapses. The "Show splits" checkbox expands/collapses all. Enter on a split row switches to that tab (and focuses the split if implemented).

- [ ] **Step 8: Commit**

```bash
git add src/apprt/gtk/class/tab_switcher.zig src/apprt/gtk/ui/1.5/tab-switcher.blp
git commit -m "feat(gtk): expandable splits in tab switcher (tree + show-splits toggle)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 4: Rename + close tabs from the dialog (F2 / Delete / Ctrl+W + row buttons)

Add per-row rename/close buttons and keyboard shortcuts operating on the highlighted tab row.

**Files:**
- Modify: `src/apprt/gtk/class/tab_switcher.zig`
- Modify: `src/apprt/gtk/ui/1.5/tab-switcher.blp`

**Interfaces:**
- Consumes: `Tab.promptTabTitle()` (or `Tab.setTitleOverride(?[:0]const u8)`), `adw.TabView.closePage(page)`, `gobject.ext.cast(Tab, page.getChild())`.
- Produces: dialog-local behavior only.

- [ ] **Step 1: Add row buttons (tab-switcher.blp)**

In the row factory `Gtk.Box`, after the labels add two `Gtk.Button`s (icon-only, `flat` style), visible only for tab rows (bind `visible` to a `TabSwitcherItem.is-tab` bool prop):

```blueprint
Gtk.Button rename_button {
  icon-name: "document-edit-symbolic";
  css-classes: ["flat"];
  visible: bind (expander.item as <$GhosttyTabSwitcherItem>).is-tab;
  clicked => $rename_clicked();
}
Gtk.Button close_button {
  icon-name: "window-close-symbolic";
  css-classes: ["flat"];
  visible: bind (expander.item as <$GhosttyTabSwitcherItem>).is-tab;
  clicked => $close_clicked();
}
```

The button callbacks need to know which item they belong to. Since `BuilderListItemFactory` templates can't easily pass the item to a Zig handler, prefer wiring these via a `Gtk.SignalListItemFactory` set up in Zig OR store the item pointer on the button as data in a `bind` step. The implementing agent picks the approach that compiles; a robust option is to switch the factory to a `SignalListItemFactory` created in Zig (`setup`/`bind` closures) so each button closes over its row item. If that's too large, implement the keyboard shortcuts (Step 2) first and make buttons operate on the currently-selected row via the same helpers.

- [ ] **Step 2: Add keyboard shortcuts**

Add a `Gtk.ShortcutController` (or a `key-pressed` `Gtk.EventControllerKey`) on the `view` (or dialog) handling:
- `F2` → rename the selected tab row's tab.
- `Delete` and `Ctrl+W` → close the selected tab row's tab.

Implement `renameSelected(self)`: get selected `TabSwitcherItem`, if `kind == .tab` get `page`, `cast(Tab, page.getChild())`, call `tab.promptTabTitle()`. (This opens the existing `TitleDialog`; the switcher can stay open or close first — close first to avoid modal-over-modal issues, matching how other flows present dialogs.)

Implement `closeSelected(self)`: get selected item's `page`, `window.getTabView().closePage(page)`, then remove that item from `source` and refresh (or just `populate` again). Guard the last-tab case (closing the only tab).

- [ ] **Step 3: Refresh after mutation**

After a close, re-run `populate(window)` so counts/rows stay correct; keep selection in range. After a rename, the tab's `title` updates via its existing binding, but the switcher's `TabSwitcherItem.title` is a snapshot — re-`populate` on the `TitleDialog` `set`, or simply re-populate when the switcher is next opened. Simplest correct behavior: re-populate after close; for rename, close the switcher (the rename dialog takes over).

- [ ] **Step 4: Format + full build**

```bash
docker compose run --rm builder zig fmt src/apprt/gtk/class/tab_switcher.zig
mise run build
```
Expected: `EXIT=0`.

- [ ] **Step 5: Manual verify**

`mise run install`. `Ctrl+Shift+K`: highlight a tab, press `F2` → rename dialog appears and renames the tab. Highlight a tab, press `Delete` or `Ctrl+W` → tab closes and the list updates. Row rename/close buttons perform the same actions.

- [ ] **Step 6: Commit**

```bash
git add src/apprt/gtk/class/tab_switcher.zig src/apprt/gtk/ui/1.5/tab-switcher.blp
git commit -m "feat(gtk): rename/close tabs from the tab switcher

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 5: Config docs + final polish

**Files:**
- Modify: `src/config/Config.zig` (doc comment for the keybind, if a dedicated doc exists) — optional
- Modify: `TODO.md` / `PROTOCOLS.md` if they track feature coverage (per repo `CLAUDE.md`)

- [ ] **Step 1: Update the feature tracker**

If `TODO.md` tracks UI/GTK features, add a checked entry for the tab switcher. Keep it one line.

- [ ] **Step 2: Verify default binding + no regressions**

Run `mise run build` once more; `mise run install`; confirm `Ctrl+Shift+K` opens the switcher on a fresh config, and the command palette (`Ctrl+Shift+P`) and previous-tab (`Ctrl+Shift+Tab`) still work (no keybind collision).

- [ ] **Step 3: Commit**

```bash
git add -A
git commit -m "docs: track tab switcher feature

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Verification summary

- Task 1 gate: `parse: toggle_tab_switcher` unit test passes; `mise run build` green; key press logs the stub.
- Tasks 2–4 gates: `mise run build` green + the listed manual steps after `mise run install`.
- Whole-feature gate: `Ctrl+Shift+K` opens a searchable, keyboard-navigable tab list with split counts; Right/Left and the checkbox expand splits; F2/Delete/Ctrl+W and row buttons rename/close tabs; Enter switches tab (and focuses split when a split row is chosen).

## Known risk areas (call out during review)

- **Blueprint ↔ GObject property/name mismatches** are the most common failure; every `bind` expression and the `$GhosttyTabSwitcherItem` cast name must match the Zig-registered type/property exactly.
- **TreeListModel filtering**: the `StringFilter` expression must reach the item through `Gtk.TreeListRow`. If the declarative expression can't, fall back to a Zig `Gtk.CustomFilter`.
- **List item factory button callbacks**: `BuilderListItemFactory` can't easily route per-row button clicks to Zig with the row's item; a `SignalListItemFactory` built in Zig is the robust fallback.
- **Lifetime**: follow `CommandPalette`'s `refSink`/`ref`/`unref`-on-close ownership exactly to avoid leaks/UAF.
