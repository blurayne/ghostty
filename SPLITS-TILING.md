# Splits, Tiling & Drag-to-Reorder

> **What this is.** This is a personal fork of
> [ghostty-org/ghostty](https://github.com/ghostty-org/ghostty) that implements
> drag-and-drop reordering of split panes in the GTK (Linux/FreeBSD) app — the
> feature requested upstream in
> **[ghostty-org/ghostty#10224 — "GTK: Implement split drag and drop to reorder"](https://github.com/ghostty-org/ghostty/issues/10224)**.
>
> If you were forwarded here from that issue, this document explains **how the
> implementation works**, the **design rationale**, and **where the code lives**
> so you can evaluate or adapt it. It is descriptive, not a merge proposal — this
> is a casual fork with no upstream commitment.

The fork actually goes beyond #10224: in addition to reordering splits within a
single window, it supports moving panes **across tabs and across windows**,
**tearing off** a pane into a new window, and **even-tiling** redistribution.
Reorder-within-a-window (#10224) falls out as the simplest special case of a more
general "move a surface anywhere" operation.

---

## The core idea

The split layout is an **immutable tree** (`Surface.Tree`) with three primitives:
`remove`, `split`, and `iterator`. Because of that, "reorder" is **not** a bespoke
algorithm — it is just:

> **remove the dragged pane from the tree → re-`split`-insert it next to the drop
> target, on the chosen edge.**

Everything else is GTK drag-and-drop plumbing wrapped around that two-step
transform. The GTK widget hierarchy is regenerated from the model whenever the
tree changes (`setTree`), so there is no in-place widget surgery to get wrong.

---

## End-to-end flow

### 1. Drag source — on each split's header
`src/apprt/gtk/class/split_header.zig` (`initDragSource`, `onDragPrepare`)

Each pane's title bar is a `GtkDragSource` with the `.move` action. On `prepare`
it serializes a tiny payload into a `ContentProvider`:

```
Payload { pid: i32, uuid: [16]u8 }          // src/apprt/gtk/class/split_dnd.zig
MIME = "application/x-ghostty-split"
```

Note what is serialized: **the process PID and the surface's UUID** — *not* the
surface or its terminal state. `drag_begin` sets a drag icon (a snapshot of the
pane).

### 2. Drop target — on every surface
`src/apprt/gtk/class/surface.zig` (drop target setup; `onSplitDrop`)

Each surface has a dedicated `GtkDropTarget` listening for the split MIME
(serialized as `GBytes`):

- `enter` / `motion` / `leave` → reveal/hide a **drop-zone overlay** and toggle
  CSS classes so you can see which edge the pane will dock to
  (`dnd_zone_revealer`, `clearDndClasses`).
- `drop` → `onSplitDrop`, which performs the reorder.

### 3. The drop handler — `onSplitDrop`
`src/apprt/gtk/class/surface.zig`

1. Parse the payload from `GBytes`.
2. **Reject if `pid != getpid()`** — UUIDs are only meaningful within this
   process, so this blocks cross-process drops.
3. `findSurfaceByUuid` resolves the dragged surface (searching across all windows
   and tabs).
4. Reject a self-drop (`source == target`).
5. Resolve both panes' `SplitTree` ancestors and their node **handles**.
6. **Quadrant detection** (`quadrantFor`): the target pane is cut into four
   triangles by its two diagonals; the cursor position maps to
   `top` / `bottom` / `left` / `right`, which becomes a split `Direction`
   (`up` / `down` / `left` / `right`). *This is what decides which edge the
   dropped pane docks to.*
7. Call `moveSurfaceInto(source_tree, source_handle, target_handle, direction)`.

The quadrant math (`src/apprt/gtk/class/split_dnd.zig`):

```zig
pub fn quadrantFor(x: f64, y: f64, w: f64, h: f64) Quadrant {
    const norm_x = x / w;
    const norm_y = y / h;
    const above_tl_br = norm_y < norm_x;          // top-left → bottom-right diagonal
    const above_tr_bl = norm_y < (1.0 - norm_x);  // top-right → bottom-left diagonal
    return if (above_tl_br and above_tr_bl) .top
        else if (!above_tl_br and above_tr_bl) .left
        else if (above_tl_br and !above_tr_bl) .right
        else .bottom;
}
```

### 4. The model operation — `moveSurfaceInto`
`src/apprt/gtk/class/split_tree.zig`

This is the heart of #10224.

**Same-tree case** (literal "reorder within the window"):

```
old.remove(source_handle)               → tree without the dragged pane
find target's new handle (by identity)  → handles shift after removal, so re-find by pointer
wrap source surface in a 1-leaf tree
.split(target_handle, direction, 0.5)   → re-insert beside target at 50%
setTree(final)                          → GTK rebuilds widgets from the new tree
```

**Cross-tree case** (beyond #10224 — cross-tab / cross-window): same shape, but
the source is removed from its own tree (closing that tab if it becomes empty) and
inserted into the target's tree. A manual ref-count is held on the surface so it
survives reparenting across the two widget hierarchies.

---

## Why this design

- **Immutable tree (`remove` → `split`)** makes the operation correct by
  construction: no in-place mutation bugs, and the widget tree is regenerated from
  the model via `setTree`.
- **PID + UUID payload** avoids serializing terminal state and naturally scopes
  drops to the current process; resolution is a lookup, not a transfer.
- **Quadrant-by-diagonals** gives intuitive "dock to this edge" semantics with
  trivial, unit-tested math.
- **#10224 is the same-tree special case** of one general "move a surface
  anywhere" operation, so within-window reorder, cross-tab, and cross-window moves
  all share a single code path.

For an upstream-minded change that targets *only* #10224, the same-tree branch of
`moveSurfaceInto` plus the quadrant drop target is the whole feature; the
cross-tree branches are the fork's extensions.

---

## Key files

| File | Role |
|---|---|
| `src/apprt/gtk/class/split_dnd.zig` | DnD payload (`pid`+`uuid`), MIME, `quadrantFor` (+ unit tests) |
| `src/apprt/gtk/class/split_header.zig` | Drag source on each pane's header; serialization, drag icon |
| `src/apprt/gtk/class/surface.zig` | Drop target, drop-zone overlay, `onSplitDrop` |
| `src/apprt/gtk/class/split_tree.zig` | `moveSurfaceInto` — the remove→split reorder operation |

---

## Commit history

Issue: <https://github.com/ghostty-org/ghostty/issues/10224>

The implementation landed as a phased plan (P5–P11) plus UX and platform-compat
fixes. Links point at this fork (`blurayne/ghostty`); short SHAs resolve fine.

**Core move / reorder engine**

| Commit | Subject |
|---|---|
| [`912e6f5fe`](https://github.com/blurayne/ghostty/commit/912e6f5fe) | fix(gtk): P5 — fix double-deinit in moveSurfaceInto |
| [`e8507b7b4`](https://github.com/blurayne/ghostty/commit/e8507b7b4) | fix(gtk): P5 — remove redundant errdefer causing double-deinit in moveSurfaceInto |
| [`edcc22e04`](https://github.com/blurayne/ghostty/commit/edcc22e04) | feat(gtk): P6 — cross-tab and cross-window DnD |
| [`74b50bd78`](https://github.com/blurayne/ghostty/commit/74b50bd78) | feat(gtk): P7 — tear-off to new window, move_split_to_new_window |
| [`d06f778bc`](https://github.com/blurayne/ghostty/commit/d06f778bc) | feat(gtk): P11 — terminal mirroring / sourced pane (PtyHandle 1:N) |

**DnD UX / platform compatibility**

| Commit | Subject |
|---|---|
| [`0893ec15a`](https://github.com/blurayne/ghostty/commit/0893ec15a) | feat(gtk): drop-zone visual overlay during split drag |
| [`2e89ade04`](https://github.com/blurayne/ghostty/commit/2e89ade04) | fix(gtk): register split DnD deserializer for X11 XDND compatibility |
| [`e36d37575`](https://github.com/blurayne/ghostty/commit/e36d37575) | feat(gtk): tab bar as split drop target via adw extra-drag-types |
| [`602db3b24`](https://github.com/blurayne/ghostty/commit/602db3b24) | feat(gtk): font selector, color picker in config editor; tab DnD creates new tab |

**Splits / tiling polish & stabilization**

| Commit | Subject |
|---|---|
| [`2e356ca83`](https://github.com/blurayne/ghostty/commit/2e356ca83) | fix(gtk): final review — UAF in surface reparent, setTree null, tab transfer API |
| [`c24ba7cbe`](https://github.com/blurayne/ghostty/commit/c24ba7cbe) | fix(gtk): flatpak binding compat — signal names, c_int types, non-optional pages |
| [`46030d50d`](https://github.com/blurayne/ghostty/commit/46030d50d) | fix(gtk): flatpak binding compat — setIcon not setIconPaintable, one more getPage |
| [`39c647c7b`](https://github.com/blurayne/ghostty/commit/39c647c7b) | feat(gtk): split-header improvements |
| [`f08f90880`](https://github.com/blurayne/ghostty/commit/f08f90880) | feat(gtk): even-tiling split distribution |
| [`9eaa348a1`](https://github.com/blurayne/ghostty/commit/9eaa348a1) | feat(gtk): show split header for torn-off single pane |
| [`760035164`](https://github.com/blurayne/ghostty/commit/760035164) | fix(gtk): swapped callback args, config editor UAF, add config editor to menus |

**Notes / research**

| Commit | Subject |
|---|---|
| [`1c8e363ff`](https://github.com/blurayne/ghostty/commit/1c8e363ff) | docs(agents): ideas, plans, dnd research |

> Some commits (e.g. `760035164`, `602db3b24`) also bundle unrelated config-editor
> changes, so they are not 100% drag-and-drop-only.
