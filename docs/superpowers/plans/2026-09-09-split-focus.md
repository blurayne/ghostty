# Split Focus Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the current-window-only tab switcher with a searchable tree of every window, tab and split, where activating any row focuses that terminal.

**Architecture:** A `GtkTreeListModel` over `SplitFocusItem` GObjects built by walking `Application.getWindows()` → tab views → surface trees. A custom `GtkFilter` keeps any row that matches or has a matching descendant, because the stock `GtkStringFilter` orphans matches from their ancestors over a tree. Pure matching logic lives in its own file so it can be unit-tested without a compositor.

**Tech Stack:** Zig 0.16, GTK4 + libadwaita (GObject classes under `src/apprt/gtk/class/`), blueprint templates, Pango attributes.

**Spec:** `docs/superpowers/specs/2026-09-09-split-focus-design.md`

## Global Constraints

- **Action name** `toggle_split_focus`. `toggle_tab_switcher` stays as a deprecated `Action` variant that still parses and dispatches to the same handler — Ghostty has no alias mechanism; follow the `close_all_windows` precedent at `src/input/Binding.zig:788`.
- **`include/ghostty.h` must stay index-aligned with `Action.Key`.** Both `GHOSTTY_ACTION_TOGGLE_TAB_SWITCHER` and `GHOSTTY_ACTION_TOGGLE_SPLIT_FOCUS` exist, each in the position matching its Zig variant. A mismatch is a C ABI break, not a cosmetic test failure. The `apprt.action.Action.Key.test.ghostty.h Action.Key` test catches it.
- **Default keybind unchanged:** `ctrl+shift+k`, `cmd+shift+k` on macOS via `inputpkg.ctrlOrSuper`.
- **Config option** `@"split-focus-hide-unmatched": bool = true`, doc comment ending `/// Available since: 1.4.0`.
- **Blueprint has no `template` wrapper.** The dialog is the top-level object, exactly as `command-palette.blp`. Wrapping it in `Adw.Bin` is what froze the app (fixed in `79ac57e29`); do not reintroduce it.
- **Highlight uses `PangoAttrList`, not markup.** Terminal titles routinely contain `&` and `<`; attributes need no escaping.
- **Byte offsets, not character counts,** for highlight ranges.
- **Matching is ASCII case-insensitive substring**, first match only. No fuzzy matching.
- **Weak references** to windows and surfaces. A pane can close while the dialog is open; every activation re-checks and no-ops if the target is gone.

### Running builds and tests — read this first

`mise run zig-test` and `docker compose` are BROKEN on this machine (rootless Docker cannot start containers; the builder image has no GTK headers on the default include path). Use podman with the flatpak SDK. Create the helper once:

```bash
cat > /tmp/ghostty-zigrun.sh <<'SCRIPT'
#!/bin/bash
set -e
[ -d /opt/zig ] || { mkdir -p /opt && cp -a /usr/local/zig /opt/zig; }
mkdir -p /root/.cache/zig
exec flatpak run --devel --share=network \
  --filesystem=/workspace --filesystem=/opt/zig --filesystem=/root/.cache/zig \
  --env=PATH=/opt/zig:/app/bin:/usr/bin \
  --env=ZIG_GLOBAL_CACHE_DIR=/root/.cache/zig \
  --command=bash org.gnome.Sdk//50 -c "cd /workspace && zig $*"
SCRIPT
chmod +x /tmp/ghostty-zigrun.sh
```

**`ZT <args>`** below means:

```bash
cd /home/markusg/Private/ghostty && podman run --rm --privileged \
  -v "$PWD":/workspace:z -v /tmp/ghostty-zigrun.sh:/usr/local/bin/zigrun:ro \
  -w /workspace localhost/ghostty-flatpak-builder:latest bash -lc 'zigrun <args>'
```

`zig fmt` needs no SDK wrapper:

```bash
cd /home/markusg/Private/ghostty && podman run --rm -v "$PWD":/workspace:z -w /workspace \
  localhost/ghostty-flatpak-builder:latest bash -lc 'zig fmt --check <files>'
```

**Run builds in the background and poll**, they take 2–15 minutes:

```bash
(timeout 2400 podman run ... > /tmp/t.log 2>&1; echo "EXIT=$?" >> /tmp/t.log) &
for i in $(seq 1 100); do sleep 20; grep -q "EXIT=" /tmp/t.log && break; done; tail -40 /tmp/t.log
```

**Two pre-existing test failures. Do NOT fix them:** `termio.Exec.test.execCommand: shell command, empty passwd` and `… error passwd`. The test binary runs inside a flatpak sandbox, so `isFlatpak()` is true and it tries to spawn a host command against a service that isn't there. Baseline on this branch is **3857/3900 passing, 2 failing**. (If you see 3862/3905 quoted anywhere, that is the baseline for `feat/wait-after-failed-command`, which carries 5 tests this branch does not — `feat/split-focus` is based on `main`.)

**`zig build test` passing does NOT mean Ghostty compiles.** The test binary does not exercise the whole GTK apprt. Every task that touches apprt code must also run the exe build:

```
ZT build -Dflatpak=true -Doptimize=ReleaseFast -fno-sys=gtk4-layer-shell -Demit-macos-app=false
```

Debug exe builds fail on a pre-existing `src/tripwire.zig:160` error — always use `-Doptimize=ReleaseFast`.

**`-Dtest-filter` does not narrow the run much** (a filtered run still executes ~75 tests) and exit 0 with a filter that matches nothing looks identical to success. After adding tests, confirm they actually execute by temporarily inverting one assertion and checking the named test fails.

## File Structure

| File | Responsibility | Task |
|---|---|---|
| `src/apprt/gtk/class/split_focus_match.zig` | Pure matching: case-insensitive substring → byte range; field-level match rule | 3 |
| `src/apprt/gtk/class/split_focus_item.zig` | `SplitFocusItem` GObject, tree building, kind→surface resolution | 4 |
| `src/apprt/gtk/class/split_focus_filter.zig` | `GtkFilter` subclass; ancestor-retaining rule | 5 |
| `src/apprt/gtk/class/split_focus.zig` | The dialog: model wiring, search, selection, activation, highlight rendering | 6 |
| `src/apprt/gtk/ui/1.5/split-focus.blp` | Dialog template, top-level `Adw.Dialog` | 6 |
| `src/apprt/gtk/class/tab_switcher.zig`, `ui/1.5/tab-switcher.blp` | Deleted | 6 |

Matching is split out because it is the only genuinely testable logic without a compositor, and both the filter and the highlighter need it.

---

### Task 1: Rename the action

**Files:**
- Modify: `src/input/Binding.zig` — add `toggle_split_focus`, deprecate `toggle_tab_switcher`
- Modify: `src/apprt/action.zig` — same two variants in `Action.Key`
- Modify: `include/ghostty.h` — add `GHOSTTY_ACTION_TOGGLE_SPLIT_FOCUS`
- Modify: `src/apprt/gtk/class/application.zig` — dispatch
- Modify: `src/config/Config.zig` — keybind default

**Interfaces:**
- Consumes: nothing
- Produces: `Action.toggle_split_focus` and `apprt.action.Action.Key.toggle_split_focus`, both dispatching to the existing `Action.toggleTabSwitcher` handler (renamed in Task 6)

- [ ] **Step 1: Add the new binding variant**

In `src/input/Binding.zig`, immediately after the existing `toggle_tab_switcher` declaration (around line 611), replacing its doc comment:

```zig
    /// Open a keyboard-navigable tree of every window, tab and split, and
    /// focus whichever one you choose.
    ///
    /// Only implemented on Linux (GTK).
    toggle_split_focus,

    /// Open a keyboard-navigable tab switcher for the current window.
    ///
    /// WARNING: This action has been deprecated and is an alias for
    /// `toggle_split_focus`. Use that instead.
    ///
    /// Only implemented on Linux (GTK).
    toggle_tab_switcher,
```

Order matters: `toggle_split_focus` comes first so it reads as the primary action.

- [ ] **Step 2: Add the same pair to the apprt action key**

In `src/apprt/action.zig`, find `toggle_tab_switcher` (around line 115) and make it:

```zig
    toggle_split_focus,
    toggle_tab_switcher,
```

Do the same at the second occurrence (around line 397) if the enum is repeated there — check both hits of `grep -n toggle_tab_switcher src/apprt/action.zig`.

- [ ] **Step 3: Add the C enum entry in the matching position**

In `include/ghostty.h`, find `GHOSTTY_ACTION_TOGGLE_TAB_SWITCHER` and insert the new entry **before** it, mirroring the Zig order:

```c
  GHOSTTY_ACTION_TOGGLE_SPLIT_FOCUS,
  GHOSTTY_ACTION_TOGGLE_TAB_SWITCHER,
```

- [ ] **Step 4: Dispatch the new action**

In `src/apprt/gtk/class/application.zig`, find the line `.toggle_tab_switcher => return Action.toggleTabSwitcher(target),` (around line 790) and make it handle both:

```zig
            .toggle_split_focus,
            .toggle_tab_switcher,
            => return Action.toggleTabSwitcher(target),
```

- [ ] **Step 5: Point the default keybind at the new action**

In `src/config/Config.zig`, the block around line 7245 currently binds `.toggle_tab_switcher`. Change the action only — the key stays the same:

```zig
        // Toggle split focus
        try self.set.put(
            alloc,
            .{ .key = .{ .unicode = 'k' }, .mods = inputpkg.ctrlOrSuper(.{ .shift = true }) },
            .toggle_split_focus,
        );
```

- [ ] **Step 6: Run the enum-alignment test**

```
ZT build test -fno-sys=gtk4-layer-shell -Dtest-filter=ghostty.h
```

Expected: no `apprt.action.Action.Key.test.ghostty.h Action.Key` failure. If it fails with `expected N, found M`, the C and Zig enum orders disagree — fix `include/ghostty.h`, do not touch the test.

- [ ] **Step 7: Run the binding parse tests and the exe build**

```
ZT build test -fno-sys=gtk4-layer-shell -Dtest-filter=Binding
ZT build -Dflatpak=true -Doptimize=ReleaseFast -fno-sys=gtk4-layer-shell -Demit-macos-app=false
```

Expected: only the 2 pre-existing `passwd` failures; exe build succeeds.

- [ ] **Step 8: Check formatting and commit**

```bash
podman run --rm -v "$PWD":/workspace:z -w /workspace localhost/ghostty-flatpak-builder:latest \
  bash -lc 'zig fmt --check src/input/Binding.zig src/apprt/action.zig src/apprt/gtk/class/application.zig src/config/Config.zig'

git add src/input/Binding.zig src/apprt/action.zig include/ghostty.h \
  src/apprt/gtk/class/application.zig src/config/Config.zig
git commit -m "input: rename toggle_tab_switcher to toggle_split_focus

The action will navigate windows and tabs as well as splits, so the old
name no longer describes it. Ghostty has no alias mechanism, so follow
the close_all_windows precedent: keep the old variant, mark it deprecated
in its doc comment, and dispatch it to the same handler. Existing configs
keep working.

Both C enum entries are added in the positions matching their Zig
variants -- this enum is a real ABI surface, not just a test fixture."
```

---

### Task 2: The config option

**Files:**
- Modify: `src/config/Config.zig` — new option after `@"wait-after-failed-command"`

**Interfaces:**
- Consumes: nothing
- Produces: `config.@"split-focus-hide-unmatched"` (`bool`, default `true`), read in Task 6

Nothing reads this yet. An unused config field is not an error in Zig, and keeping it a separate commit makes the config surface reviewable on its own.

- [ ] **Step 1: Add the option**

In `src/config/Config.zig`, immediately after the `@"wait-after-failed-command": bool = true,` declaration and its doc comment block:

```zig
/// Whether the split focus dialog hides rows that do not match the search.
///
/// When true, typing in the search box shows only matching rows and the
/// window and tab rows leading to them, expanded automatically. When false
/// the whole tree stays visible and matches are only highlighted.
///
/// The dialog's "Hide non-matching" checkbox overrides this for the current
/// session; this option sets what the checkbox starts as.
///
/// Available since: 1.4.0
@"split-focus-hide-unmatched": bool = true,
```

- [ ] **Step 2: Verify the config layer compiles**

```
ZT build test -fno-sys=gtk4-layer-shell -Dtest-filter=Config
```

Expected: only the 2 pre-existing `passwd` failures.

- [ ] **Step 3: Check formatting and commit**

```bash
podman run --rm -v "$PWD":/workspace:z -w /workspace localhost/ghostty-flatpak-builder:latest \
  bash -lc 'zig fmt --check src/config/Config.zig'
git add src/config/Config.zig
git commit -m "config: add split-focus-hide-unmatched

Sets what the split focus dialog's filter checkbox starts as. Nothing
reads it yet."
```

---

### Task 3: Pure matching and highlight ranges

The only logic here that can be tested without a compositor. Both the filter (Task 5) and the highlighter (Task 6) call it.

**Files:**
- Create: `src/apprt/gtk/class/split_focus_match.zig`
- Modify: `src/apprt/gtk/class.zig` — register the new file for tests

**Interfaces:**
- Consumes: nothing
- Produces:
  - `pub const Range = struct { start: usize, end: usize }`
  - `pub fn find(haystack: []const u8, needle: []const u8) ?Range`
  - `pub fn matchesFields(title: []const u8, pwd: ?[]const u8, needle: []const u8) bool`

- [ ] **Step 1: Write the failing tests**

Create `src/apprt/gtk/class/split_focus_match.zig` containing only the tests for now:

```zig
//! Pure matching logic for the split focus dialog. Kept separate from the
//! widgets so it can be tested without a compositor: everything else in
//! this feature needs a live GTK application to exercise.

const std = @import("std");

test "find: match at the start" {
    const r = find("deploy.sh", "dep") orelse return error.TestExpectedMatch;
    try std.testing.expectEqual(@as(usize, 0), r.start);
    try std.testing.expectEqual(@as(usize, 3), r.end);
}

test "find: match in the middle" {
    const r = find("./deploy.sh", "loy") orelse return error.TestExpectedMatch;
    try std.testing.expectEqual(@as(usize, 5), r.start);
    try std.testing.expectEqual(@as(usize, 8), r.end);
}

test "find: is case insensitive" {
    const r = find("Deploy", "dEp") orelse return error.TestExpectedMatch;
    try std.testing.expectEqual(@as(usize, 0), r.start);
    try std.testing.expectEqual(@as(usize, 3), r.end);
}

test "find: no match" {
    try std.testing.expect(find("deploy.sh", "zzz") == null);
}

test "find: an empty needle never highlights" {
    // An empty search box matches everything, but there is nothing to
    // invert -- returning a zero-length range would paint a stray cell.
    try std.testing.expect(find("deploy.sh", "") == null);
}

test "find: offsets are bytes, not codepoints" {
    // "über" is 5 bytes: u=1, ü=2, b=1, e=1, r=1. A Pango attribute range
    // is in bytes, so a match after a multi-byte character must not shift.
    const r = find("über-deploy", "deploy") orelse return error.TestExpectedMatch;
    try std.testing.expectEqual(@as(usize, 6), r.start);
    try std.testing.expectEqual(@as(usize, 12), r.end);
}

test "matchesFields: title matches" {
    try std.testing.expect(matchesFields("deploy.sh", null, "dep"));
}

test "matchesFields: pwd matches when the title does not" {
    try std.testing.expect(matchesFields("zsh", "/home/me/ghostty", "ghost"));
}

test "matchesFields: neither matches" {
    try std.testing.expect(!matchesFields("zsh", "/home/me/ghostty", "zzz"));
}

test "matchesFields: an absent pwd is not a match" {
    try std.testing.expect(!matchesFields("zsh", null, "ghost"));
}

test "matchesFields: an empty needle matches everything" {
    // An empty search box must not empty the tree.
    try std.testing.expect(matchesFields("zsh", null, ""));
}
```

- [ ] **Step 2: Register the file so its tests run**

In `src/apprt/gtk/class.zig`, find the `test { … }` block at the end and add:

```zig
    _ = @import("class/split_focus_match.zig");
```

If `class.zig` has no test block, add one:

```zig
test {
    _ = @import("class/split_focus_match.zig");
}
```

- [ ] **Step 3: Run the tests to verify they fail**

```
ZT build test -fno-sys=gtk4-layer-shell -Dtest-filter=find
```

Expected: compile error, `use of undeclared identifier 'find'`.

- [ ] **Step 4: Implement**

Add above the tests in `src/apprt/gtk/class/split_focus_match.zig`:

```zig
/// A byte range within a haystack. Pango attribute ranges are byte
/// offsets, so these are too.
pub const Range = struct {
    start: usize,
    end: usize,
};

/// Case-insensitive substring search, returning the byte range of the
/// first match. Returns null when the needle is empty: an empty search
/// box matches every row but has nothing to highlight.
///
/// Case folding is ASCII-only. A search for "STRASSE" will not match
/// "straße"; matching Unicode case folding is not worth the dependency
/// for a title search box.
pub fn find(haystack: []const u8, needle: []const u8) ?Range {
    if (needle.len == 0) return null;
    const idx = std.ascii.indexOfIgnoreCase(haystack, needle) orelse return null;
    return .{ .start = idx, .end = idx + needle.len };
}

/// Whether a row's own text matches, ignoring its descendants. An empty
/// needle matches everything so that clearing the search box restores the
/// whole tree.
pub fn matchesFields(title: []const u8, pwd: ?[]const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (find(title, needle) != null) return true;
    if (pwd) |p| if (find(p, needle) != null) return true;
    return false;
}
```

- [ ] **Step 5: Run the tests to verify they pass**

```
ZT build test -fno-sys=gtk4-layer-shell -Dtest-filter=find
ZT build test -fno-sys=gtk4-layer-shell -Dtest-filter=matchesFields
```

Expected: only the 2 pre-existing `passwd` failures.

- [ ] **Step 6: Confirm the tests actually execute**

A filter matching nothing also exits 0. Temporarily change the first test's expected `end` from `3` to `99`, re-run, and confirm the output names `split_focus_match.test.find: match at the start` as failing. Then change it back.

- [ ] **Step 7: Check formatting and commit**

```bash
podman run --rm -v "$PWD":/workspace:z -w /workspace localhost/ghostty-flatpak-builder:latest \
  bash -lc 'zig fmt --check src/apprt/gtk/class/split_focus_match.zig src/apprt/gtk/class.zig'
git add src/apprt/gtk/class/split_focus_match.zig src/apprt/gtk/class.zig
git commit -m "gtk: pure matching logic for split focus

Substring search returning byte ranges, plus the field-level match rule.
Split out because it is the only part of this feature testable without a
compositor, and both the tree filter and the highlighter need it."
```

---

### Task 4: The item model and tree building

**Files:**
- Create: `src/apprt/gtk/class/split_focus_item.zig`

**Interfaces:**
- Consumes: `split_focus_match.matchesFields`
- Produces:
  - `pub const SplitFocusItem = extern struct { … }` with `getGObjectType`
  - `pub const Kind = enum(c_int) { window, tab, split }`
  - `pub fn new(kind: Kind, …) *SplitFocusItem`
  - `pub fn getTitle(self: *SplitFocusItem) ?[:0]const u8`
  - `pub fn getPwd(self: *SplitFocusItem) ?[:0]const u8`
  - `pub fn getChildren(self: *SplitFocusItem) ?*gio.ListStore`
  - `pub fn resolveSurface(self: *SplitFocusItem) ?*Surface` — the row's target
  - `pub fn getPage(self: *SplitFocusItem) ?*adw.TabPage`
  - `pub fn getWindow(self: *SplitFocusItem) ?*Window` — strong ref, caller unrefs
  - `pub fn matchesDeep(self: *SplitFocusItem, needle: []const u8) bool`
  - `pub fn buildRoot(app: *gtk.Application) *gio.ListStore` — the whole tree

- [ ] **Step 1: Create the item class**

Create `src/apprt/gtk/class/split_focus_item.zig`. Follow the `TabSwitcherItem` pattern in `src/apprt/gtk/class/tab_switcher.zig` for the GObject boilerplate — `defineClass`, `Private`, `Common`, `Class.init` — and use `WeakRef` from `src/apprt/gtk/weak_ref.zig` for the window and surface fields.

```zig
const std = @import("std");
const adw = @import("adw");
const gio = @import("gio");
const gobject = @import("gobject");
const gtk = @import("gtk");

const Common = @import("../class.zig").Common;
const WeakRef = @import("../weak_ref.zig").WeakRef;
const Surface = @import("surface.zig").Surface;
const Tab = @import("tab.zig").Tab;
const Window = @import("window.zig").Window;
const match = @import("split_focus_match.zig");

const log = std.log.scoped(.gtk_ghostty_split_focus_item);

/// What a row stands for. Windows and tabs are containers; only splits
/// are terminals. All three are activatable -- a container resolves to
/// its currently-active split.
pub const Kind = enum(c_int) { window, tab, split };

pub const SplitFocusItem = extern struct {
    pub const Self = @This();
    pub const Parent = gobject.Object;
    parent: Parent,

    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "GhosttySplitFocusItem",
        .instanceInit = &init,
        .classInit = Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    const Private = struct {
        kind: Kind = .window,
        /// Owned, allocated with the GLib allocator.
        title: ?[:0]const u8 = null,
        pwd: ?[:0]const u8 = null,

        /// Weak throughout: the dialog must not keep a window or a
        /// surface alive, and either can close while it is open.
        window: WeakRef(Window) = .empty,
        surface: WeakRef(Surface) = .empty,
        page: ?*adw.TabPage = null,

        /// Non-null for window and tab kinds; null for splits, which is
        /// what makes a split a leaf in the tree model.
        children: ?*gio.ListStore = null,

        pub var offset: c_int = 0;
    };

    // ... GObject boilerplate: init, dispose, finalize (free title/pwd
    // with glib.free, unref children), Class.init registering the type.
    // Mirror TabSwitcherItem in tab_switcher.zig exactly.
};
```

The implementer should copy the boilerplate shape from `tab_switcher.zig` rather than inventing it; the only new parts are the extra fields and the accessors below.

- [ ] **Step 2: Add the accessors and the match recursion**

```zig
    pub fn getKind(self: *Self) Kind {
        return self.private().kind;
    }

    pub fn getTitle(self: *Self) ?[:0]const u8 {
        return self.private().title;
    }

    pub fn getPwd(self: *Self) ?[:0]const u8 {
        return self.private().pwd;
    }

    pub fn getChildren(self: *Self) ?*gio.ListStore {
        return self.private().children;
    }

    /// Whether this row or any row beneath it matches. This is the rule
    /// the tree filter needs: keeping only rows that match themselves
    /// would strip a matching split of its window and tab and render it
    /// orphaned at the wrong depth.
    pub fn matchesDeep(self: *Self, needle: []const u8) bool {
        const priv = self.private();
        if (match.matchesFields(
            priv.title orelse "",
            priv.pwd,
            needle,
        )) return true;

        const children = priv.children orelse return false;
        const n = children.as(gio.ListModel).getNItems();
        var i: c_uint = 0;
        while (i < n) : (i += 1) {
            const obj = children.as(gio.ListModel).getObject(i) orelse continue;
            defer obj.unref();
            const child = gobject.ext.cast(Self, obj) orelse continue;
            if (child.matchesDeep(needle)) return true;
        }
        return false;
    }
```

- [ ] **Step 3: Add target resolution**

```zig
    /// The surface this row focuses when activated. Windows and tabs
    /// resolve to their currently-active split, so every row does
    /// something useful. Returns null if the target has since closed.
    pub fn resolveSurface(self: *Self) ?*Surface {
        const priv = self.private();
        return switch (priv.kind) {
            .split => priv.surface.get(),
            .tab => tab: {
                const page = priv.page orelse break :tab null;
                const child = page.getChild();
                const tab = gobject.ext.cast(Tab, child) orelse break :tab null;
                break :tab tab.getActiveSurface();
            },
            .window => window: {
                const win = priv.window.get() orelse break :window null;
                defer win.unref();
                break :window win.getActiveSurface();
            },
        };
    }
```

Note the ownership asymmetry: `WeakRef.get()` returns a strong reference the caller must unref, while `getActiveSurface()` does not. The `.window` arm unrefs the window it took; the caller of `resolveSurface` is responsible for the returned surface per `getActiveSurface`'s contract — check that contract in `window.zig:1224` and match it.

- [ ] **Step 4: Add tree building**

```zig
    /// Walk every window, tab and split of the application into a tree of
    /// items. Order is the application's window order, then tab-view
    /// order, then surface-tree order -- deliberately not sorted, because
    /// people navigate by remembered position.
    pub fn buildRoot(app: *gtk.Application) *gio.ListStore {
        const root = gio.ListStore.new(getGObjectType());

        var maybe_node: ?*glib.List = app.getWindows();
        while (maybe_node) |node| : (maybe_node = node.f_next) {
            const widget: *gtk.Widget = @ptrCast(@alignCast(node.f_data orelse continue));
            const win = gobject.ext.cast(Window, widget) orelse continue;

            const win_item = Self.new(.window, windowTitle(win), null);
            defer win_item.unref();
            win_item.private().window.set(win);
            const tabs = gio.ListStore.new(getGObjectType());
            win_item.private().children = tabs;

            const tab_view = win.getTabView();
            const n = tab_view.getNPages();
            var i: c_int = 0;
            while (i < n) : (i += 1) {
                const page = tab_view.getNthPage(i);
                const tab = gobject.ext.cast(Tab, page.getChild()) orelse continue;

                const tab_item = Self.new(.tab, std.mem.span(page.getTitle()), null);
                defer tab_item.unref();
                tab_item.private().window.set(win);
                tab_item.private().page = page;
                const splits = gio.ListStore.new(getGObjectType());
                tab_item.private().children = splits;

                if (tab.getSurfaceTree()) |tree| {
                    var it = tree.iterator();
                    while (it.next()) |entry| {
                        const surface = entry.view;
                        const split_item = Self.new(
                            .split,
                            surface.getTitle() orelse "",
                            surface.getPwd(),
                        );
                        defer split_item.unref();
                        split_item.private().window.set(win);
                        split_item.private().page = page;
                        split_item.private().surface.set(surface);
                        splits.append(split_item.as(gobject.Object));
                    }
                }

                tabs.append(tab_item.as(gobject.Object));
            }

            root.append(win_item.as(gobject.Object));
        }

        return root;
    }
```

`windowTitle(win)` is a small helper returning the window's title, falling back to `"Window"` when it has none — GTK windows can legitimately have a null title and an empty row label is unhelpful. Add `const glib = @import("glib");` to the imports for `glib.List`.

Verify `entry.view` is the field name on the iterator's `ViewEntry` — see `src/datastruct/split_tree.zig:205`. If it differs, use the actual field.

- [ ] **Step 5: Build**

```
ZT build -Dflatpak=true -Doptimize=ReleaseFast -fno-sys=gtk4-layer-shell -Demit-macos-app=false
```

The file is not referenced yet, so add a temporary `_ = @import("class/split_focus_item.zig");` to `src/apprt/gtk/class.zig`'s test block to force analysis, and run:

```
ZT build test -fno-sys=gtk4-layer-shell -Dtest-filter=find
```

Expected: compiles. There are no unit tests here — every function needs a live GTK application and real windows, which a test binary does not have. Task 6's manual verification is what exercises this.

- [ ] **Step 6: Check formatting and commit**

```bash
podman run --rm -v "$PWD":/workspace:z -w /workspace localhost/ghostty-flatpak-builder:latest \
  bash -lc 'zig fmt --check src/apprt/gtk/class/split_focus_item.zig src/apprt/gtk/class.zig'
git add src/apprt/gtk/class/split_focus_item.zig src/apprt/gtk/class.zig
git commit -m "gtk: split focus item model and tree building

Walks every window, tab and split into a tree of GObjects. Weak refs to
windows and surfaces throughout, since either can close while the dialog
is open. Windows and tabs resolve to their active split so every row is
activatable."
```

---

### Task 5: The ancestor-retaining filter

**Files:**
- Create: `src/apprt/gtk/class/split_focus_filter.zig`

**Interfaces:**
- Consumes: `SplitFocusItem.matchesDeep`
- Produces:
  - `pub const SplitFocusFilter = extern struct { … }` with `getGObjectType`
  - `pub fn new() *SplitFocusFilter`
  - `pub fn setNeedle(self: *SplitFocusFilter, needle: ?[:0]const u8) void`
  - `pub fn setEnabled(self: *SplitFocusFilter, enabled: bool) void`
  - `pub fn getNeedle(self: *SplitFocusFilter) ?[:0]const u8` — the highlighter in Task 6 needs the current search text, and the filter already owns it

- [ ] **Step 1: Create the filter class**

Create `src/apprt/gtk/class/split_focus_filter.zig`:

```zig
//! A GtkFilter for the split focus tree.
//!
//! GtkStringFilter cannot do this job. Over a GtkTreeListModel it sees a
//! flat sequence of GtkTreeListRow objects and drops them individually,
//! so a matching split whose window and tab do not match loses its
//! ancestors and renders orphaned at the wrong depth. This keeps a row if
//! it matches OR any of its descendants match.

const std = @import("std");
const glib = @import("glib");
const gobject = @import("gobject");
const gtk = @import("gtk");

const Common = @import("../class.zig").Common;
const SplitFocusItem = @import("split_focus_item.zig").SplitFocusItem;

pub const SplitFocusFilter = extern struct {
    pub const Self = @This();
    pub const Parent = gtk.Filter;
    parent: Parent,

    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "GhosttySplitFocusFilter",
        .instanceInit = &init,
        .classInit = Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    const Private = struct {
        /// Owned; the current search text. Null or empty matches all.
        needle: ?[:0]const u8 = null,
        /// When false the filter passes everything through, so the tree
        /// stays whole and only the highlighting marks matches.
        enabled: bool = true,
        pub var offset: c_int = 0;
    };

    fn init(self: *Self, _: *Class) callconv(.c) void {
        _ = self;
    }

    pub fn new() *Self {
        return gobject.ext.newInstance(Self, .{});
    }

    /// Set the search text and tell GTK how the result changed, so it can
    /// re-filter incrementally instead of rebuilding the whole list.
    pub fn setNeedle(self: *Self, needle: ?[:0]const u8) void {
        const priv = self.private();
        const old_len = if (priv.needle) |n| n.len else 0;
        const new_len = if (needle) |n| n.len else 0;

        if (priv.needle) |n| glib.free(@constCast(@ptrCast(n.ptr)));
        priv.needle = if (needle) |n| glib.ext.dupeZ(u8, n) else null;

        // A longer needle can only remove rows; a shorter one can only
        // add them. Anything else is a general change.
        const change: gtk.FilterChange = if (new_len > old_len)
            .more_strict
        else if (new_len < old_len)
            .less_strict
        else
            .different;
        self.as(gtk.Filter).changed(change);
    }

    pub fn setEnabled(self: *Self, enabled: bool) void {
        const priv = self.private();
        if (priv.enabled == enabled) return;
        priv.enabled = enabled;
        self.as(gtk.Filter).changed(if (enabled) .more_strict else .less_strict);
    }

    /// The current search text. Borrowed, owned by the filter. The
    /// highlighter needs it and the filter already holds it, so there is
    /// no reason for the dialog to keep a second copy in sync.
    pub fn getNeedle(self: *Self) ?[:0]const u8 {
        return self.private().needle;
    }
};
```

Add the standard `Common`, `dispose`/`finalize` (freeing `needle`), and `Class` boilerplate following `tab_switcher.zig`.

- [ ] **Step 2: Implement the virtual match method**

In `Class.init`, override `GtkFilter`'s `match` virtual method:

```zig
        fn init(class: *Class) callconv(.c) void {
            gtk.Filter.virtual_methods.match.implement(class, &match);
        }
```

and implement it:

```zig
    /// GtkTreeListModel hands us GtkTreeListRow objects, not our items --
    /// unwrap before matching.
    fn match(self: *Self, item: *gobject.Object) callconv(.c) c_int {
        const priv = self.private();
        if (!priv.enabled) return 1;
        const needle = priv.needle orelse return 1;
        if (needle.len == 0) return 1;

        const row = gobject.ext.cast(gtk.TreeListRow, item) orelse return 1;
        const inner = row.getItem() orelse return 1;
        defer inner.unref();
        const focus_item = gobject.ext.cast(SplitFocusItem, inner) orelse return 1;

        return @intFromBool(focus_item.matchesDeep(needle));
    }
```

Returning 1 for anything unexpected is deliberate: a filter that hides rows it does not understand would silently empty the tree.

- [ ] **Step 3: Build**

```
ZT build -Dflatpak=true -Doptimize=ReleaseFast -fno-sys=gtk4-layer-shell -Demit-macos-app=false
```

Add a temporary `_ = @import("class/split_focus_filter.zig");` to `class.zig`'s test block to force analysis if the file is not yet referenced.

Expected: compiles. If `gtk.Filter.virtual_methods.match` does not exist under that name in the gobject bindings, find the correct path with:

```bash
grep -rn "virtual_methods" src/apprt/gtk/class/*.zig | head
```

and check the generated bindings under `zig-pkg/gobject-*/src/gtk4/gtk4.zig` for `Filter`.

- [ ] **Step 4: Check formatting and commit**

```bash
podman run --rm -v "$PWD":/workspace:z -w /workspace localhost/ghostty-flatpak-builder:latest \
  bash -lc 'zig fmt --check src/apprt/gtk/class/split_focus_filter.zig src/apprt/gtk/class.zig'
git add src/apprt/gtk/class/split_focus_filter.zig src/apprt/gtk/class.zig
git commit -m "gtk: ancestor-retaining filter for the split focus tree

GtkStringFilter drops tree rows individually, which orphans a matching
split from its window and tab. Keep any row that matches or has a
matching descendant, and pass everything through when disabled so the
checkbox can switch between filtering and highlight-only."
```

---

### Task 6: The dialog

The wiring, and the only task with user-visible behaviour.

**Files:**
- Create: `src/apprt/gtk/class/split_focus.zig`
- Create: `src/apprt/gtk/ui/1.5/split-focus.blp`
- Modify: `src/apprt/gtk/build/gresource.zig:53` — swap the blueprint entry
- Modify: `src/apprt/gtk/class/window.zig` — rename the field and method
- Modify: `src/apprt/gtk/class/application.zig` — rename the handler
- Modify: `src/apprt/gtk/class.zig` — replace the temporary test imports
- Delete: `src/apprt/gtk/class/tab_switcher.zig`, `src/apprt/gtk/ui/1.5/tab-switcher.blp`

**Interfaces:**
- Consumes: `SplitFocusItem.buildRoot`, `SplitFocusItem.resolveSurface`, `SplitFocusFilter.setNeedle`/`setEnabled`, `split_focus_match.find`, `config.@"split-focus-hide-unmatched"`
- Produces: `SplitFocus.new()`, `SplitFocus.toggle(window)`, `SplitFocus.close()`

- [ ] **Step 1: Write the blueprint**

Create `src/apprt/gtk/ui/1.5/split-focus.blp`. The dialog is the **top-level object** — no `template` wrapper, matching `command-palette.blp`. Wrapping it in `Adw.Bin` is what froze the app.

```blueprint
using Gtk 4.0;
using Adw 1;

Adw.Dialog dialog {
  title: _("Split Focus");
  content-width: 600;
  content-height: 500;
  closed => $closed();

  Adw.ToolbarView {
    [top]
    Adw.HeaderBar {
      title-widget: Gtk.SearchEntry search {
        placeholder-text: _("Search windows, tabs and splits");
        search-changed => $search_changed();
        activate => $search_activated();
        stop-search => $search_stopped();
      };

      [end]
      Gtk.CheckButton hide_unmatched {
        label: _("Hide non-matching");
        toggled => $hide_unmatched_toggled();
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
          };
        };
      }
    }
  }
}
```

The tree model, the filter and the item factory are set from Zig — the filter is a custom type and the factory needs to build Pango attributes per row, neither of which blueprint can express.

- [ ] **Step 2: Register the blueprint**

In `src/apprt/gtk/build/gresource.zig`, replace line 53:

```zig
    .{ .major = 1, .minor = 5, .name = "split-focus" },
```

- [ ] **Step 3: Write the dialog class**

Create `src/apprt/gtk/class/split_focus.zig`. Start from `tab_switcher.zig` — the dialog lifecycle, `toggle`, `close`, `dialogClosed`, `searchStopped` are all reusable — and change:

- `Parent = adw.Bin`, class name `GhosttySplitFocus`, blueprint name `split-focus`.
- In `init`, build the model chain:

```zig
        // Tree over the item store; splits have no child model, which is
        // what makes them leaves.
        const tree = gtk.TreeListModel.new(
            root.as(gio.ListModel),
            0, // passthrough: false, so rows are GtkTreeListRow
            1, // autoexpand: true, "always show everything"
            createChildModel,
            null,
            null,
        );
        priv.filter.* = SplitFocusFilter.new();
        priv.filter_model.setModel(tree.as(gio.ListModel));
        priv.filter_model.setFilter(priv.filter.as(gtk.Filter));
```

- `createChildModel` returns the item's children:

```zig
    fn createChildModel(item: *gobject.Object, _: ?*anyopaque) callconv(.c) ?*gio.ListModel {
        const focus_item = gobject.ext.cast(SplitFocusItem, item) orelse return null;
        const children = focus_item.getChildren() orelse return null;
        return children.as(gio.ListModel).ref();
    }
```

- [ ] **Step 4: Wire search, checkbox and selection**

```zig
    fn searchChanged(entry: *gtk.SearchEntry, self: *Self) callconv(.c) void {
        const priv = self.private();
        const text = std.mem.span(entry.as(gtk.Editable).getText());
        priv.filter.setNeedle(text);

        // Selection holds while the selected row still passes the filter;
        // otherwise fall to the first visible row so Enter always does
        // something.
        if (!self.selectionStillVisible()) self.selectFirst();
    }

    fn hideUnmatchedToggled(button: *gtk.CheckButton, self: *Self) callconv(.c) void {
        self.private().filter.setEnabled(button.getActive() != 0);
    }
```

- [ ] **Step 5: Wire the item factory with highlighting**

Set a `GtkSignalListItemFactory` from Zig and, in its `bind` handler, build the label text and a `PangoAttrList` inverting the matched range:

```zig
    fn bindItem(_: *gtk.SignalListItemFactory, list_item: *gtk.ListItem, self: *Self) callconv(.c) void {
        const row = gobject.ext.cast(gtk.TreeListRow, list_item.getItem() orelse return) orelse return;
        const item = gobject.ext.cast(SplitFocusItem, row.getItem() orelse return) orelse return;
        const label: *gtk.Label = @ptrCast(@alignCast(list_item.getChild() orelse return));

        const title = item.getTitle() orelse "";
        label.setText(title.ptr);

        // Invert only the matched characters. Attributes rather than
        // markup: terminal titles routinely contain & and <, and
        // attributes need no escaping.
        const needle = self.private().filter.needle() orelse return;
        const range = match.find(title, needle) orelse {
            label.setAttributes(null);
            return;
        };

        const swap = invertedColors(label.as(gtk.Widget));
        const attrs = pango.AttrList.new();
        defer attrs.unref();

        const fg = pango.attrForegroundNew(swap.fg.r, swap.fg.g, swap.fg.b);
        const bg = pango.attrBackgroundNew(swap.bg.r, swap.bg.g, swap.bg.b);
        fg.*.start_index = @intCast(range.start);
        fg.*.end_index = @intCast(range.end);
        bg.*.start_index = @intCast(range.start);
        bg.*.end_index = @intCast(range.end);
        attrs.insert(fg);
        attrs.insert(bg);
        label.setAttributes(attrs);
    }
```

with the colour resolution as its own function:

```zig
    const Rgb16 = struct { r: u16, g: u16, b: u16 };
    const Swap = struct { fg: Rgb16, bg: Rgb16 };

    /// The label's own colours, swapped. Pango wants 16-bit channels
    /// while GdkRGBA is 0..1 floats, hence the scaling.
    ///
    /// Reading the *current* colour is what makes this follow light and
    /// dark themes without a hardcoded palette. If a theme ever reports
    /// a fully transparent background -- some do, leaving the parent to
    /// paint it -- fall back to libadwaita's accent pair, which is how
    /// GTK itself draws selected text.
    fn invertedColors(widget: *gtk.Widget) Swap {
        const ctx = widget.getStyleContext();
        var color: gdk.RGBA = undefined;
        ctx.getColor(&color);

        var bg: gdk.RGBA = undefined;
        const have_bg = ctx.lookupColor("theme_bg_color", &bg) != 0;
        if (!have_bg or bg.f_alpha < 0.01) {
            const accent = adw.StyleManager.getDefault().getAccentColorRgba();
            return .{
                .fg = toRgb16(.{ .f_red = 1, .f_green = 1, .f_blue = 1, .f_alpha = 1 }),
                .bg = toRgb16(accent.*),
            };
        }

        // Swapped: the text colour becomes the background and vice versa.
        return .{ .fg = toRgb16(bg), .bg = toRgb16(color) };
    }

    fn toRgb16(c: gdk.RGBA) Rgb16 {
        return .{
            .r = @intFromFloat(std.math.clamp(c.f_red, 0, 1) * 65535),
            .g = @intFromFloat(std.math.clamp(c.f_green, 0, 1) * 65535),
            .b = @intFromFloat(std.math.clamp(c.f_blue, 0, 1) * 65535),
        };
    }
```

Add `const gdk = @import("gdk");` and `const pango = @import("pango");` to the imports. Verify the accent API name against the bindings — `grep -n "getAccentColorRgba\|accent_color" zig-pkg/gobject-*/src/adw1/adw1.zig | head` — and use whatever the generated binding actually calls it; libadwaita gained it in 1.6 and the runtime here is 1.9.3.

Indentation comes from `row.getDepth()`; set `label.setMarginStart(@intCast(depth * 16))`.

- [ ] **Step 5b: Wire pwd into the row**

Split rows show the pwd dimmed after the title. Use a `Gtk.Box` with two labels as the factory's child rather than a bare label, apply the highlight attributes to whichever of the two matched, and give the pwd label the `dim-label` CSS class. `getPwd()` returns null for window and tab rows and for splits whose working directory is unknown — hide the second label in that case rather than showing an empty gap.

- [ ] **Step 5c: Wire activation**

The blueprint's `activate => $row_activated()` needs a handler. This is the one path that has to survive a target closing while the dialog is open:

```zig
    fn rowActivated(_: *gtk.ListView, pos: c_uint, self: *Self) callconv(.c) void {
        const priv = self.private();

        // Read from the filtered model, not the source: pos is an index
        // into what the user can actually see.
        const obj = priv.model.as(gio.ListModel).getObject(pos) orelse return;
        defer obj.unref();
        const row = gobject.ext.cast(gtk.TreeListRow, obj) orelse return;
        const inner = row.getItem() orelse return;
        defer inner.unref();
        const item = gobject.ext.cast(SplitFocusItem, inner) orelse return;

        // Close first so the dialog does not linger over the window we
        // are about to focus.
        self.close();

        // The pane may have closed while the dialog was open. Weak refs
        // mean we find out here rather than crashing.
        const surface = item.resolveSurface() orelse {
            log.debug("split focus target no longer exists, ignoring", .{});
            return;
        };

        // Select the owning tab, raise its window if it is not the
        // active one, then focus the pane itself.
        if (item.getPage()) |page| {
            if (item.getWindow()) |win| {
                defer win.unref();
                win.getTabView().setSelectedPage(page);
                win.as(gtk.Window).present();
            }
        }
        surface.grabFocus();
    }
```

This needs two more accessors on `SplitFocusItem` — add them in Task 4's file alongside the others:

```zig
    pub fn getPage(self: *Self) ?*adw.TabPage {
        return self.private().page;
    }

    /// Returns a strong reference; the caller must unref.
    pub fn getWindow(self: *Self) ?*Window {
        return self.private().window.get();
    }
```

- [ ] **Step 6: Preselect the current split and focus the search box**

In `toggle()`, after `populate`:

```zig
        // Preselect the row for the surface the user is currently in, so
        // the dialog opens showing where they are.
        self.selectSurface(window.getActiveSurface());
        priv.hide_unmatched.setActive(@intFromBool(
            config.@"split-focus-hide-unmatched",
        ));
        priv.dialog.present(window.as(gtk.Widget));
        _ = priv.search.as(gtk.Widget).grabFocus();
```

Add a key controller on the search entry forwarding Up/Down/Page keys to the list view, so the list is driven without ever taking focus.

- [ ] **Step 7: Rename the window and application hooks**

In `src/apprt/gtk/class/window.zig`, rename the private field `tab_switcher` → `split_focus`, the type to `SplitFocus`, and `toggleTabSwitcher` → `toggleSplitFocus`. In `src/apprt/gtk/class/application.zig`, rename `Action.toggleTabSwitcher` → `Action.toggleSplitFocus` and update the dispatch arm added in Task 1.

- [ ] **Step 8: Delete the old implementation**

```bash
git rm src/apprt/gtk/class/tab_switcher.zig src/apprt/gtk/ui/1.5/tab-switcher.blp
```

Replace the temporary imports in `src/apprt/gtk/class.zig`'s test block with the permanent ones:

```zig
    _ = @import("class/split_focus_match.zig");
```

- [ ] **Step 9: Build and test**

```
ZT build test -fno-sys=gtk4-layer-shell
ZT build -Dflatpak=true -Doptimize=ReleaseFast -fno-sys=gtk4-layer-shell -Demit-macos-app=false
```

Expected: 2 pre-existing `passwd` failures only, and `EXE_OK`. A blueprint syntax error surfaces here as a `blueprint-compiler` failure.

- [ ] **Step 10: Commit**

```bash
git add -A
git commit -m "gtk: replace the tab switcher with split focus

A searchable tree of every window, tab and split. Activating any row
focuses that terminal; windows and tabs resolve to their active split.
Matched characters invert in both filter modes, which is what makes the
unfiltered mode useful.

The dialog is a top-level Adw.Dialog with no template wrapper -- the
wrapper is what froze the app when the tab switcher was presented."
```

- [ ] **Step 11: Build and install the flatpak**

```bash
printf '%s' "$(git rev-parse --short HEAD)" > .git-sha
podman run --rm --privileged -v "$PWD":/workspace:z \
  -v ghostty-flatpak-cache:/root/.local/share/flatpak \
  -w /workspace localhost/ghostty-flatpak-builder:latest \
  bash -lc 'export PATH=/root/.local/bin:$PATH; mise run _flatpak-build'
mise run backup-flatpak
mise run install
```

Then **quit and relaunch Ghostty** — flatpak leaves the running instance on its old files.

- [ ] **Step 12: Manual verification**

| # | Do | Expect |
|---|---|---|
| 1 | Two windows, several tabs, several splits. `Ctrl+Shift+K` | Tree shows every window, tab and split |
| 2 | Look at the dialog on open | Current split selected and scrolled into view; cursor in the search box |
| 3 | Type text matching one split in the *other* window | Its window and tab remain, other branches vanish, matched characters inverted |
| 4 | Press Enter | That split focuses, in that window |
| 5 | Reopen, uncheck "Hide non-matching", type the same text | Whole tree visible, match still inverted |
| 6 | Activate a window row | Its active split focuses |
| 7 | Activate a tab row | That tab's active split focuses |
| 8 | Open the dialog, close a pane elsewhere, activate its row | Nothing happens, no crash |
| 9 | Arrow keys after typing | Selection moves; the search box keeps focus and keeps accepting text |
| 10 | Set `split-focus-hide-unmatched = false`, reopen | Checkbox starts unchecked |
| 11 | `keybind = ctrl+shift+j=toggle_tab_switcher` in config | Still opens the dialog (deprecated alias works) |
| 12 | Escape, then `Ctrl+Shift+K` twice | Closes; toggles closed |

- [ ] **Step 13: Mark the spec implemented**

Set `status: draft` → `status: implemented` in `docs/superpowers/specs/2026-09-09-split-focus-design.md`, and add a line to `docs/superpowers/plans/2026-08-13-tab-switcher.md` noting it is superseded. Commit.

---

## Notes for the implementer

- **`gtk.TreeListModel.new` autoexpand is a boolean int**, not a Zig bool — pass `1`. Passthrough must be `0` so rows arrive as `GtkTreeListRow`, which the filter and factory both expect.
- **The filter receives `GtkTreeListRow`, not your item.** Unwrap with `row.getItem()` and unref the result.
- **`WeakRef.get()` returns a strong reference.** Unref it. `getActiveSurface()` does not — check `window.zig:1224` for its contract before assuming.
- **Do not sort.** Window, tab and split order is deliberate; people navigate by remembered position.
- **`pwd` will be empty in the current flatpak** because shell integration is not loading (`unable to open …/shell-integration/zsh`). Rows must degrade to title-only, not break. This is a separate defect and not a blocker.
