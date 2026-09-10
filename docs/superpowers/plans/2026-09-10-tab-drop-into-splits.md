# Tab Drop Into Splits — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Drag a tab from the tab bar and drop it onto a pane's edge, merging that tab's terminals into the existing split layout.

**Architecture:** libadwaita's tab drag already advertises the public `AdwTabPage` GType, so a Surface's existing `GtkDropTarget` can accept it by adding that type — no custom drag source or payload. On drop, resolve the page to its `Tab`, take its whole surface tree, and graft it into the target's tree at the edge the cursor indicates. The datastructure's `split()` already accepts a whole tree and offsets handles, so multi-pane tabs need no new tree algebra.

**Tech Stack:** Zig 0.16, GTK4 + libadwaita, `src/apprt/gtk/class/`.

## Global Constraints

- **Config option** `@"tab-drop-layout": TabDropLayout = .flatten`, doc comment ending `/// Available since: 1.4.0`.
- **Flatten semantics** (the default): collapse the dropped tab's panes into siblings *along the drop axis only*. A subtree whose split runs the other way stays intact as one unit. Dropping `C|D` to the right yields `target | C | D`; dropping `B/C` to the right yields `target | (B/C)` with `B` and `C` still stacked. `preserve` grafts the whole tree as one subtree regardless.
- **Never unref a borrow.** `TabPage.getChild()` is transfer-none. `resolveSurface`-style borrows are not owned.
- **Do not sort.** Pane order within the dropped tab is preserved in both modes.
- **Reject self-drop**: dropping a tab onto a pane that already lives in that same tab must be a no-op, not a tree corruption.

### Running builds — the normal commands do not work here

`mise run zig-test` and `docker compose` are BROKEN on this machine. Use podman with the flatpak SDK; `/tmp/ghostty-zigrun.sh` already exists (recreate from the split-focus plan if missing).

Exe build — **the only build that analyses the GTK apprt**:
```bash
cd /home/markusg/Private/ghostty && podman run --rm --privileged \
  -v "$PWD":/workspace:z -v /tmp/ghostty-zigrun.sh:/usr/local/bin/zigrun:ro \
  -w /workspace localhost/ghostty-flatpak-builder:latest \
  bash -lc 'zigrun build -Dflatpak=true -Doptimize=ReleaseFast -fno-sys=gtk4-layer-shell -Demit-macos-app=false'
```

Test build:
```bash
... bash -lc 'zigrun build test -fno-sys=gtk4-layer-shell'
```

`zig fmt --check` needs no SDK wrapper:
```bash
cd /home/markusg/Private/ghostty && podman run --rm -v "$PWD":/workspace:z -w /workspace \
  localhost/ghostty-flatpak-builder:latest bash -lc 'zig fmt --check <files>'
```

**Run builds in the background and POLL** — 3–20 minutes each (the cache was recently cleared, so the first is cold):
```bash
(timeout 3000 podman run ... > /tmp/t.log 2>&1; echo "EXIT=$?" >> /tmp/t.log) &
for i in $(seq 1 150); do sleep 20; grep -q "EXIT=" /tmp/t.log && break; done; tail -40 /tmp/t.log
```

**Two pre-existing test failures. Do NOT fix them:** `termio.Exec.test.execCommand: shell command, empty passwd` and `… error passwd`. Debug exe builds fail on a pre-existing `src/tripwire.zig:160` error — always use `-Doptimize=ReleaseFast`.

**Zig analyses declarations lazily.** A new file of pure `pub fn`s is not compiled just because something imports it. Everything in this plan is reachable from existing call sites, so the exe build does cover it — but if you add an unreferenced helper, end the file with a `comptime` block naming it and prove that works by injecting a type error *inside* one of the named functions.

## File Structure

| File | Responsibility | Task |
|---|---|---|
| `src/config/Config.zig` | `tab-drop-layout` option + `TabDropLayout` enum | 1 |
| `src/datastruct/split_tree.zig` | `flattenAlong()` — decompose a tree along one axis | 1 |
| `src/apprt/gtk/class/split_tree.zig` | `moveTree()` — graft a whole tab's tree at an edge | 2 |
| `src/apprt/gtk/class/window.zig` | factor out the empty-and-close-source-tab block | 2 |
| `src/apprt/gtk/class/surface.zig` | accept `AdwTabPage`, branch the drop | 3 |

---

### Task 1: Config option and the flatten algebra

The only part with real unit tests: `flattenAlong` is pure tree manipulation.

**Files:**
- Modify: `src/config/Config.zig`
- Modify: `src/datastruct/split_tree.zig`

**Interfaces:**
- Produces: `Config.TabDropLayout = enum { flatten, preserve }`, `config.@"tab-drop-layout"`
- Produces: `pub fn flattenAlong(self: *const Self, gpa: Allocator, axis: Split.Direction) Allocator.Error![]Self` — the maximal subtrees of `self` when split along `axis`, in order. Caller owns the slice and must `deinit()` each tree.

- [ ] **Step 1: Add the config option**

In `src/config/Config.zig`, after the `@"split-focus-hide-unmatched"` declaration and its doc block:

```zig
/// How a tab's terminals are arranged when the tab is dropped onto an
/// existing split.
///
///   * `flatten` - the tab's panes become siblings of the pane you dropped
///     onto, as far as their own arrangement allows. A group split the
///     other way stays grouped: dropping a tab holding a left/right pair
///     onto the right edge gives you three panes in a row, but dropping
///     one holding a top/bottom pair gives you that pair, still stacked,
///     beside the target.
///
///   * `preserve` - the tab's layout is grafted in whole, as a single
///     unit, whatever its shape.
///
/// Available since: 1.4.0
@"tab-drop-layout": TabDropLayout = .flatten,
```

and beside the other config enums (near `ShellIntegration`, around line 8997):

```zig
pub const TabDropLayout = enum {
    flatten,
    preserve,
};
```

- [ ] **Step 2: Write the failing tests for `flattenAlong`**

In `src/datastruct/split_tree.zig`, beside the existing tests (the file already has `test "even tiling: 3 horizontal panes get equal ratios"` — follow its construction style, using `TestView` and `TestTree`):

```zig
test "flattenAlong: a single leaf yields itself" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var vA: TestView = .{ .label = "A" };
    var tA: TestTree = try .init(alloc, &vA);
    defer tA.deinit();

    const parts = try tA.flattenAlong(alloc, .right);
    defer {
        for (parts) |*p| p.deinit();
        alloc.free(parts);
    }

    try testing.expectEqual(@as(usize, 1), parts.len);
}

test "flattenAlong: splits along the same axis come apart" {
    const testing = std.testing;
    const alloc = testing.allocator;

    // A|B dropped along the horizontal axis must yield A and B, so they
    // become siblings of whatever they are dropped next to.
    var vA: TestView = .{ .label = "A" };
    var tA: TestTree = try .init(alloc, &vA);
    defer tA.deinit();
    var vB: TestView = .{ .label = "B" };
    var tB: TestTree = try .init(alloc, &vB);
    defer tB.deinit();

    var pair = try tA.split(alloc, .root, .right, 0.5, &tB);
    defer pair.deinit();

    const parts = try pair.flattenAlong(alloc, .right);
    defer {
        for (parts) |*p| p.deinit();
        alloc.free(parts);
    }

    try testing.expectEqual(@as(usize, 2), parts.len);
}

test "flattenAlong: a split across the axis stays whole" {
    const testing = std.testing;
    const alloc = testing.allocator;

    // A/B (stacked) dropped along the horizontal axis must stay one unit:
    // flattening it would destroy an arrangement the user built.
    var vA: TestView = .{ .label = "A" };
    var tA: TestTree = try .init(alloc, &vA);
    defer tA.deinit();
    var vB: TestView = .{ .label = "B" };
    var tB: TestTree = try .init(alloc, &vB);
    defer tB.deinit();

    var stacked = try tA.split(alloc, .root, .down, 0.5, &tB);
    defer stacked.deinit();

    const parts = try stacked.flattenAlong(alloc, .right);
    defer {
        for (parts) |*p| p.deinit();
        alloc.free(parts);
    }

    try testing.expectEqual(@as(usize, 1), parts.len);
}

test "flattenAlong: recurses through same-axis splits only" {
    const testing = std.testing;
    const alloc = testing.allocator;

    // (A|B)|C along the horizontal axis is three siblings: the nesting is
    // an artifact of how it was built, not a layout worth keeping.
    var vA: TestView = .{ .label = "A" };
    var tA: TestTree = try .init(alloc, &vA);
    defer tA.deinit();
    var vB: TestView = .{ .label = "B" };
    var tB: TestTree = try .init(alloc, &vB);
    defer tB.deinit();
    var vC: TestView = .{ .label = "C" };
    var tC: TestTree = try .init(alloc, &vC);
    defer tC.deinit();

    var ab = try tA.split(alloc, .root, .right, 0.5, &tB);
    defer ab.deinit();
    var abc = try ab.split(alloc, .root, .right, 0.5, &tC);
    defer abc.deinit();

    const parts = try abc.flattenAlong(alloc, .right);
    defer {
        for (parts) |*p| p.deinit();
        alloc.free(parts);
    }

    try testing.expectEqual(@as(usize, 3), parts.len);
}
```

- [ ] **Step 3: Run the tests to verify they fail**

```
zigrun build test -fno-sys=gtk4-layer-shell
```
Expected: compile error, no member named `flattenAlong`.

- [ ] **Step 4: Implement `flattenAlong`**

Add to the tree type in `src/datastruct/split_tree.zig`, beside `split()`:

```zig
/// The maximal subtrees of this tree when taken apart along `axis`, in
/// left-to-right / top-to-bottom order.
///
/// A split running the same way as `axis` is an arrangement the user
/// gets back for free once the pieces are re-inserted along that same
/// axis, so it comes apart. A split running the other way is a layout
/// they deliberately built, so it stays whole.
///
/// Caller owns the returned slice and must deinit each tree in it.
pub fn flattenAlong(
    self: *const Self,
    gpa: Allocator,
    axis: Split.Direction,
) Allocator.Error![]Self {
    var out: std.ArrayList(Self) = .empty;
    errdefer {
        for (out.items) |*t| t.deinit();
        out.deinit(gpa);
    }

    try self.flattenNode(gpa, .root, axis, &out);
    return out.toOwnedSlice(gpa);
}

fn flattenNode(
    self: *const Self,
    gpa: Allocator,
    handle: Node.Handle,
    axis: Split.Direction,
    out: *std.ArrayList(Self),
) Allocator.Error!void {
    const node = self.nodes[handle.idx()];
    switch (node) {
        .leaf => try out.append(gpa, try self.subtree(gpa, handle)),
        .split => |s| {
            if (!s.direction.sameAxis(axis)) {
                try out.append(gpa, try self.subtree(gpa, handle));
                return;
            }
            try self.flattenNode(gpa, s.left, axis, out);
            try self.flattenNode(gpa, s.right, axis, out);
        },
    }
}
```

`subtree(gpa, handle)` extracts the subtree rooted at `handle` as a standalone tree. If no such helper exists, write it: allocate `count(handle)` nodes, copy them, and rewrite handles relative to the new root — the handle-offsetting loop in `split()` (around `:540`) is the model.

`Split.Direction.sameAxis` also needs adding beside the direction enum:

```zig
/// Whether two directions lie on the same axis -- left/right are the
/// same axis as each other, up/down likewise.
pub fn sameAxis(self: Direction, other: Direction) bool {
    return self.isHorizontal() == other.isHorizontal();
}

pub fn isHorizontal(self: Direction) bool {
    return switch (self) {
        .left, .right => true,
        .up, .down => false,
    };
}
```

Check whether `isHorizontal` (or an equivalent) already exists before adding it.

- [ ] **Step 5: Run the tests to verify they pass**

```
zigrun build test -fno-sys=gtk4-layer-shell
```
Expected: 4 new tests pass; only the 2 pre-existing `passwd` failures.

- [ ] **Step 6: Prove the tests actually execute**

Invert one assertion (change an expected count), re-run, confirm the run names the test as failing, then revert.

- [ ] **Step 7: Format and commit**

```bash
git add src/config/Config.zig src/datastruct/split_tree.zig
git commit -m "split_tree: take a tree apart along one axis

flattenAlong returns the maximal subtrees of a tree when split along a
given axis. A split running the same way as the axis comes apart, since
re-inserting the pieces along that axis reproduces it; one running the
other way is a layout the user built, so it stays whole.

Plus tab-drop-layout, which chooses between this and grafting a dropped
tab's tree in one piece. Nothing reads either yet."
```

---

### Task 2: Grafting a whole tab's tree

**Files:**
- Modify: `src/apprt/gtk/class/split_tree.zig` — new `moveTree`
- Modify: `src/apprt/gtk/class/window.zig` — factor out source-tab teardown

**Interfaces:**
- Consumes: `flattenAlong`, `config.@"tab-drop-layout"`
- Produces: `pub fn moveTree(self: *SplitTree, source: *SplitTree, target: *Surface, dir: Direction) Allocator.Error!void`
- Produces: `pub fn closeEmptiedTab(surface_or_tree_widget: *gtk.Widget) void` in `window.zig` (name it as fits; see Step 2)

- [ ] **Step 1: Write `moveTree`**

Beside `moveSplit` in `src/apprt/gtk/class/split_tree.zig:497`. `moveSplit` wraps ONE surface via `Surface.Tree.init(alloc, source)` at :518 then calls `target_tree.split(...)`. `moveTree` differs only in what it inserts:

```zig
/// Move every terminal of `source`'s tree into this tree, at `dir`
/// relative to `target`.
///
/// Layout follows `tab-drop-layout`: `.preserve` grafts the source tree
/// in one piece; `.flatten` takes it apart along the drop axis first, so
/// its panes become siblings of the target rather than a nested group --
/// except for any subtree split the other way, which stays whole.
pub fn moveTree(
    self: *Self,
    source: *Self,
    target: *Surface,
    dir: Surface.Tree.Split.Direction,
) Allocator.Error!void {
    const app = Application.default();
    const alloc = app.allocator();

    const source_tree = source.getTree() orelse return;
    var target_tree = self.getTree() orelse return;
    const target_handle = target_tree.locate(target) orelse {
        log.warn("moveTree: target is not in this tree", .{});
        return;
    };

    const config_obj = app.getConfig();
    defer config_obj.unref();
    const layout = config_obj.get().@"tab-drop-layout";

    // Insert in reverse so each piece lands to the target's `dir` side in
    // the order the user saw them in the source tab.
    var parts: []Surface.Tree = switch (layout) {
        .preserve => blk: {
            const one = try alloc.alloc(Surface.Tree, 1);
            one[0] = try source_tree.clone(alloc);
            break :blk one;
        },
        .flatten => try source_tree.flattenAlong(alloc, dir),
    };
    defer {
        for (parts) |*p| p.deinit();
        alloc.free(parts);
    }

    var acc = try target_tree.clone(alloc);
    defer acc.deinit();
    var handle = target_handle;
    for (parts) |*part| {
        var next = try acc.split(alloc, handle, dir, 0.5, part);
        acc.deinit();
        acc = next;
        // Subsequent pieces attach to the piece just inserted, so they
        // end up in source order rather than reversed.
        handle = acc.locate(part.rootView() orelse target) orelse handle;
    }

    self.setTree(&acc);
    source.setTree(null);
}
```

The `handle` walk is the fiddly part: verify against `split()`'s handle-offsetting whether the newly inserted subtree's root can be located that way. If `rootView()` does not exist, find the first leaf of `part` via its iterator and locate that instead. **Do not guess** — read `split()` at `src/datastruct/split_tree.zig:518` and confirm where the inserted nodes land.

If `clone` does not exist on the tree, check how `setTree` takes ownership — `moveSplit` may already show the right ownership dance. Follow it exactly.

- [ ] **Step 2: Factor out the source-tab teardown**

`Window.addTabWithSurface` (`window.zig:2450`) already empties a tree and closes the tab if it became empty — the block around `window.zig:2478-2489` (`setTree(null)` → `ext.getAncestor(Tab)` → `ext.getAncestor(adw.TabView)` → `tv.closePage(tv.getPage(...))`). Extract it into a function both callers use. Do not duplicate it.

**Critical:** the new caller runs inside a drop callback while libadwaita's drag machinery is still mid-teardown. Closing the page synchronously can hit "widget already has a parent" criticals or free the tab widget under Adw's feet. Defer it:

```zig
// Adw's tab box still holds reorder/detach state for the dragged page
// when our drop handler returns, and runs its own drag_end path right
// after. Tearing the page down synchronously races that. An idle
// callback lands after Adw has finished.
_ = glib.idleAdd(closeEmptiedTabIdle, page);
```

Follow whatever `glib.idleAdd` signature the bindings actually expose, and make the callback tolerate the page already being gone.

- [ ] **Step 3: Build**

```
zigrun build -Dflatpak=true -Doptimize=ReleaseFast -fno-sys=gtk4-layer-shell -Demit-macos-app=false
zigrun build test -fno-sys=gtk4-layer-shell
```
Expected: both clean, Task 1's tests still pass.

- [ ] **Step 4: Format and commit**

```bash
git add src/apprt/gtk/class/split_tree.zig src/apprt/gtk/class/window.zig
git commit -m "gtk: graft a whole tab's tree into another tree

moveTree is moveSplit for a whole tab rather than one pane: the
datastructure's split() already accepts a multi-node tree and offsets its
handles, so the only new work is choosing the pieces per tab-drop-layout.

The source tab's teardown is deferred to an idle callback -- Adw's drag
machinery is still mid-teardown when a drop handler returns, and closing
the page synchronously races it."
```

---

### Task 3: Accepting the drop

**Files:**
- Modify: `src/apprt/gtk/class/surface.zig`

**Interfaces:**
- Consumes: `SplitTree.moveTree`

- [ ] **Step 1: Accept the AdwTabPage type**

`surface.zig:1947` currently registers one type:

```zig
        var surface_drop_target_types = [_]gobject.Type{
            gobject.ext.types.uint64,
        };
```

Add `adw.TabPage.getGObjectType()`. libadwaita's tab drag advertises that public GType (verified against the library), alongside a private root-window content provider used only for the detach-to-new-window path — so a plain `GtkDropTarget` can receive it. The existing target already has `preload: true` and `actions: move` (`src/apprt/gtk/ui/1.2/surface.blp:288`); no new controller is needed.

- [ ] **Step 2: Branch the drop-value check**

`surface.zig:4216 propDropValue` calls `value.getUint64()` unconditionally, which is wrong once a second type can arrive. Branch on the GValue's type. For an `AdwTabPage`, reject the drop when the page's child `Tab` is the one this Surface already lives in — dropping a tab onto its own pane must be a no-op, not a tree corruption.

- [ ] **Step 3: Branch the drop handler**

`surface.zig:4167 surfaceDrop` currently assumes a uint64 surface ID. Add an `AdwTabPage` branch:

```zig
// page -> Tab -> its SplitTree -> graft into ours at the cursor's edge.
const tab = gobject.ext.cast(Tab, page.getChild()) orelse return;
```

`TabPage.getChild()` is transfer-none — do not unref it. Then find the source `SplitTree` widget for that `Tab` (`Tab.getSurfaceTree()` at `tab.zig:315` gives the tree data; you need the widget — check what `Tab` exposes) and call `st.moveTree(source_tree, self, dir)` with `dir` from the existing `calcDropDirection(x, y)`.

`surfaceDropMotion`, `calcDropDirection` and `setDropOverlayDirection` (`:4204`, `:4247`, `:4233`) need no changes — the edge highlight already works for any accepted drag.

Return success so Adw sees the drop was handled and skips its own detach-to-new-window path.

- [ ] **Step 4: Build**

```
zigrun build -Dflatpak=true -Doptimize=ReleaseFast -fno-sys=gtk4-layer-shell -Demit-macos-app=false
zigrun build test -fno-sys=gtk4-layer-shell
```

- [ ] **Step 5: Format and commit**

```bash
git add src/apprt/gtk/class/surface.zig
git commit -m "gtk: accept a dropped tab onto a pane

Adw's tab drag advertises the public AdwTabPage GType, so the Surface
drop target can take it by adding that type -- no custom drag source and
no payload. The edge highlighting and direction calculation already in
place for pane drags apply unchanged."
```

- [ ] **Step 6: Build and install the flatpak**

```bash
printf '%s' "$(git rev-parse --short HEAD)" > .git-sha
podman run --rm --privileged -v "$PWD":/workspace:z \
  -v ghostty-flatpak-cache:/root/.local/share/flatpak \
  -w /workspace localhost/ghostty-flatpak-builder:latest \
  bash -lc 'export PATH=/root/.local/bin:$PATH; mise run _flatpak-build'
mise run backup-flatpak && mise run install
```

Then **quit and relaunch Ghostty**.

- [ ] **Step 7: Manual verification**

| # | Do | Expect |
|---|---|---|
| 1 | Tab with ONE pane → drop on another pane's right edge | Two panes side by side, source tab gone |
| 2 | Tab with `C\|D` → drop on right edge, `flatten` | Three panes in a row: target, C, D |
| 3 | Tab with `B/C` (stacked) → drop on right edge, `flatten` | Target beside the pair, pair still stacked |
| 4 | Same as 2 with `tab-drop-layout = preserve` | Target beside a nested `C\|D` group |
| 5 | Drop on top / bottom / left edges | Direction honoured, highlight matched the result |
| 6 | Drop a tab onto a pane inside that same tab | Nothing happens, no crash, tab intact |
| 7 | Drag a tab to the tab bar as before | Still reorders / moves normally |
| 8 | Drag a tab out to the desktop | Still detaches into a new window |
| 9 | Drop the LAST tab of a window onto a pane in another window | Source window closes cleanly |

Rows 7 and 8 matter most: this feature adds a drop target that competes with libadwaita's own tab handling, and breaking ordinary tab dragging would be a far worse regression than not having the feature.

## Notes for the implementer

- **The riskiest moment is the source tab teardown**, not the tree algebra. Adw is mid-drag when your handler runs. Graft synchronously, defer the close.
- **A `GtkDropTarget` accepting a GType only matches in-process**, since GType-valued content has no serializer. Cross-process tab drags simply will not match, which is what we want.
- The drag is tagged `adw-tab-bar-drag-origin` on the `GdkDrag` object if you ever need to verify provenance.
- **Unknown, needs a run to settle:** whether the source `AdwTabBox` leaves residual reorder state after a *foreign* drop target accepts its drag. If tab dragging misbehaves after a successful drop, that is the first place to look.
