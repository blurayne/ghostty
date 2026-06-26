---
date: 2026-06-26
branch: main
topic: "Even-Tiling Split Distribution"
tags: [plan, gtk, splits, config]
status: planned
---

# Plan: Even-Tiling Split Distribution

## Goal

Add a config setting that makes split creation distribute space evenly across all sibling panes
on the same axis. With 2 vertical splits at 1/2:1/2, adding a third vertical split gives
1/3:1/3:1/3 instead of the current 1/2:1/4:1/4. The setting has separate per-axis controls
(`split-tiling-horizontal`, `split-tiling-vertical`) and a combined fallback (`split-tiling`),
each accepting `traditional` (default, current behaviour) or `even` (new behaviour).

## Background

### Split tree data model

**`src/datastruct/split_tree.zig`** — generic `SplitTree(V)` used by every apprt.

- `Split` struct (line 100): `layout: Layout`, `ratio: f16`, `left: Node.Handle`, `right: Node.Handle`.
  The `ratio` is the fraction that the **left/top** child occupies of the combined space at
  that split node.
- `fn split(...)` (line 506): creates a new tree with a new split node inserted at `at`,
  consuming the supplied `ratio: f16`. The caller always passes `0.5`.
- `fn equalize(gpa)` (line 760): recomputes every split's `ratio` to be
  `weight(left) / (weight(left) + weight(right))`, where `weight` counts same-axis leaf
  descendants. This already implements the exact arithmetic needed for even tiling —
  inserting at 0.5 and then equalizing produces the correct per-node ratios for an
  N-way even split.
- `fn weight(from, layout, acc)` (line 798): counts leaf panes reachable in `layout`
  direction from `from`, treating cross-axis splits as weight 1.

### GTK split widget

**`src/apprt/gtk/class/split_tree.zig`** — `SplitTree` GObject + inner `SplitTreeSplit`.

- `SplitTree.newSplit(direction, parent_, overrides)` (line 221): the central entry point for
  creating a new split. Calls `old_tree.split(alloc, handle, direction, 0.5, &single_tree)`
  (line 281, comment "Always split equally for new splits"), then `self.setTree(&new_tree)`.
  This is **the primary change site**.
- `SplitTree.newSplitMirrored(source_uuid)` (line 301): same pattern, hardcodes `.right` and
  `0.5` on line 336.
- `SplitTree.moveSurfaceInto(...)` (lines 785, 853): two `old_tree.split(..., 0.5, ...)` call
  sites for same-tree and cross-tree DnD moves. These are interactive moves driven by the user
  placing a split manually — they should **not** be affected by even-tiling (the user chose a
  position implicitly via the drag quadrant).
- `SplitTree.actionEqualize(...)` (line 725): existing action that calls `old_tree.equalize()`.
  Even-tiling after `newSplit` is logically equivalent to always running this action on the
  new tree — so no new data-structure logic is required.
- Config access pattern (lines 939–943): `Application.default().getConfig()` → `config_obj.get()`
  → field access. Config object must be `unref`'d after use (line 941 `defer config_obj.unref()`).

### Config system

**`src/config/Config.zig`** — all settings are fields of the top-level `Config` struct.

- Similar enum-backed split settings for reference:
  - `@"split-header": SplitHeaderMode = .auto` (line 1117), enum defined at line 8763.
  - `@"split-title-doubleclick-action": SplitTitleDoubleclickAction = .rename` (line 1135),
    enum at line 8774.
- New fields follow the same pattern: a doc comment directly above the field, then the field
  declaration with a default.
- Enum types are defined as `pub const` at the bottom of the file (around line 8758+).

### Why equalize() is correct for even tiling

The binary tree structure means N even panes in a row are represented as a right-leaning chain:

```
split(ratio=1/N)
  left:  leaf_1
  right: split(ratio=1/(N-1))
           left:  leaf_2
           right: ...
```

`equalize()` already computes exactly this via the `weight` function: the root split's
`weight(left)=1`, `weight(right)=N-1`, so `ratio = 1/N`. Each subsequent node recurses
correctly. Therefore calling `equalize()` on the tree returned by `split(..., 0.5, ...)` gives
the correct even distribution without any new data-structure code.

## Implementation Steps

### Step 1 — Add config types

**File:** `src/config/Config.zig`

1a. Add the enum type (near line 8782, after `SplitTitleDoubleclickAction`):

```zig
pub const SplitTilingMode = enum {
    /// Each new split halves the space of the pane it splits (default).
    traditional,
    /// After each new split, redistribute all same-axis siblings evenly.
    even,
};
```

1b. Add the three config fields (near line 1128, after `@"split-header-auto-threshold"`):

```zig
/// How space is distributed when creating a new split pane.
///
/// `split-tiling` is the fallback used when the per-axis variants
/// (`split-tiling-horizontal`, `split-tiling-vertical`) are not explicitly
/// set. Setting `split-tiling` alone applies to both axes.
///
///   - traditional  Each new split halves the pane it is created from
///                  (default). With two vertical panes at 1/2:1/2, a third
///                  gives 1/2:1/4:1/4.
///   - even         After every new split, all sibling panes along the same
///                  axis are redistributed to equal widths/heights. With two
///                  vertical panes at 1/2:1/2, a third gives 1/3:1/3:1/3.
@"split-tiling": SplitTilingMode = .traditional,

/// Per-axis tiling mode for horizontal (left/right) splits.
/// Overrides `split-tiling` for horizontal splits when set.
/// See `split-tiling` for value descriptions.
@"split-tiling-horizontal": ?SplitTilingMode = null,

/// Per-axis tiling mode for vertical (up/down) splits.
/// Overrides `split-tiling` for vertical splits when set.
/// See `split-tiling` for value descriptions.
@"split-tiling-vertical": ?SplitTilingMode = null,
```

### Step 2 — Read config and equalize on new split

**File:** `src/apprt/gtk/class/split_tree.zig`

Modify `SplitTree.newSplit()` (starting at line 221).

After the `var new_tree = try old_tree.split(...)` block (currently lines 281–287) and
before `self.setTree(&new_tree)` (line 295), insert:

```zig
// If even-tiling is configured for this axis, equalize all split ratios.
const tiling_mode: configpkg.Config.SplitTilingMode = tiling: {
    const app = Application.default();
    const config_obj = app.getConfig();
    defer config_obj.unref();
    const config = config_obj.get();
    const layout: Surface.Tree.Split.Layout = switch (direction) {
        .left, .right => .horizontal,
        .up, .down   => .vertical,
    };
    break :tiling switch (layout) {
        .horizontal => config.@"split-tiling-horizontal" orelse config.@"split-tiling",
        .vertical   => config.@"split-tiling-vertical"   orelse config.@"split-tiling",
    };
};
if (tiling_mode == .even) {
    var equalized = try new_tree.equalize(alloc);
    new_tree.deinit();
    new_tree = equalized;
}
```

Note: `new_tree` must be declared `var` (it already is) and `defer new_tree.deinit()` is
already present on line 288, so reassigning `new_tree` before the defer fires is safe.

### Step 3 — Handle newSplitMirrored (optional parity)

**File:** `src/apprt/gtk/class/split_tree.zig`, `newSplitMirrored()` (line 301).

Mirror splits are always `.right` direction. Apply the same even-tiling check after line 336
(`var new_tree = try old_tree.split(alloc, handle, .right, 0.5, &single_tree)`):

```zig
const tiling_mode: configpkg.Config.SplitTilingMode = tiling: {
    const app = Application.default();
    const config_obj = app.getConfig();
    defer config_obj.unref();
    const config = config_obj.get();
    break :tiling config.@"split-tiling-horizontal" orelse config.@"split-tiling";
};
if (tiling_mode == .even) {
    var equalized = try new_tree.equalize(alloc);
    new_tree.deinit();
    new_tree = equalized;
}
```

### Step 4 — Verify DnD move sites are NOT equalized

**File:** `src/apprt/gtk/class/split_tree.zig`

`moveSurfaceInto()` at lines 785 and 853 intentionally keeps `0.5` and should not be changed.
The user is explicitly placing a pane via drag; redistributing all siblings would be surprising.
Document this decision with a brief comment at each site.

### Step 5 — Tests

**File:** `src/datastruct/split_tree.zig` (or a new test file)

Add unit tests exercising the equalize-after-split combination:

```zig
test "even tiling: 3-way horizontal" {
    // Build a tree: split right twice, equalize after each.
    // Expected ratio chain: root.ratio=1/3, root.right.ratio=1/2
}

test "even tiling: mixed axis does not cross-equalize" {
    // Vertical split inside a horizontal split.
    // Even-tiling horizontal should not disturb the vertical ratio.
}
```

The `weight()` function already has test coverage via `equalize()` — target the
post-split scenario.

## Config Schema

Exact Zig field definitions for `src/config/Config.zig`:

```zig
// --- enum type (add after SplitTitleDoubleclickAction, ~line 8782) ---

pub const SplitTilingMode = enum {
    /// Each new split halves the space of the pane it splits (default).
    traditional,
    /// After each new split, redistribute all same-axis siblings evenly.
    even,
};

// --- struct fields (add near line 1128, after split-header-auto-threshold) ---

/// How space is distributed when creating a new split pane.
///
/// `split-tiling` is the fallback used when the per-axis variants
/// (`split-tiling-horizontal`, `split-tiling-vertical`) are not explicitly
/// set. Setting `split-tiling` alone applies to both axes.
///
///   - traditional  Each new split halves the pane it is created from
///                  (default).
///   - even         After every new split, all sibling panes along the same
///                  axis are redistributed to equal widths/heights.
@"split-tiling": SplitTilingMode = .traditional,

/// Per-axis tiling mode for horizontal (left/right) splits.
/// Overrides `split-tiling` for horizontal splits when set.
/// See `split-tiling` for value descriptions.
@"split-tiling-horizontal": ?SplitTilingMode = null,

/// Per-axis tiling mode for vertical (up/down) splits.
/// Overrides `split-tiling` for vertical splits when set.
/// See `split-tiling` for value descriptions.
@"split-tiling-vertical": ?SplitTilingMode = null,
```

The `?SplitTilingMode = null` (optional) fields allow explicit "unset" semantics so the
fallback chain works cleanly. Ghostty's config parser handles optional enum fields.

## Edge Cases

1. **Single pane (no existing tree):** `newSplit` returns early before the equalize block when
   `self.getTree()` is null; no equalize call needed.

2. **Cross-axis splits:** `equalize()` and `weight()` already handle this correctly — they only
   count same-axis leaf descendants for each split node, so a horizontal even-tiling does not
   disturb the ratios of nested vertical splits and vice versa.

3. **DnD moves (`moveSurfaceInto`):** intentionally excluded. The user is placing a pane
   explicitly; redistributing siblings would violate the principle of least surprise.

4. **Mirror splits (`newSplitMirrored`):** always horizontal (`.right`). Even-tiling should
   apply here too for consistency (Step 3), but it is lower priority than the main path.

5. **Config reload:** `getConfig()` is called inside `newSplit` at the time of the split, so a
   live config reload takes effect for the next split. No special handling required.

6. **`equalize()` after `remove()`:** closing a pane currently does NOT re-equalize. This is
   intentional; the feature only triggers on creation. A future option (`split-tiling-on-close`)
   could extend it.

7. **f16 precision:** `equalize()` uses `f16` for the ratio (`s.ratio = weight_left_f16 /
   total_f16`). With up to ~30 panes the precision is sufficient (f16 mantissa is ~3 decimal
   digits). The existing `SplitTreeSplit.onIdle` already uses a 0.001 tolerance for ratio
   comparison, so accumulated rounding error will not cause jitter.

8. **`split-tiling-horizontal` / `split-tiling-vertical` both null:** the fallback
   `config.@"split-tiling"` is always set (defaults to `.traditional`), so the `orelse` chain
   always yields a concrete value.

## Files to Change

| File | Purpose |
|------|---------|
| `src/config/Config.zig` | Add `SplitTilingMode` enum + three config fields with doc strings |
| `src/apprt/gtk/class/split_tree.zig` | Read config and call `equalize()` in `newSplit()` (primary); optionally also in `newSplitMirrored()` |
| `src/datastruct/split_tree.zig` | Add unit tests for even-tiling post-split scenario (no logic changes needed) |

No new files are required. The existing `equalize()` / `weight()` functions in
`src/datastruct/split_tree.zig` are reused without modification.
