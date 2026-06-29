# Ideas / Future Work

Parked features adjacent to the tiling work in
`docs/agents/plans/2026-06-22-ghostty-tiling-features.md`. Items here are intentionally
deferred until the in-flight plan ships and we have user feedback.

## Protocol references

- **iTerm2 OSC escape codes** — https://iterm2.com/documentation-escape-codes.html
  Comprehensive list of OSC 1337 keys. Many beyond the image protocol are still
  unimplemented (annotations, OpenURL, badges, marks, profiles, key labels,
  RequestAttention, StealFocus, SetBackgroundImageFile, etc.). Worth scanning
  whenever picking the next feature to add.

---

## P8 — Synchronized (Broadcast) Input

Per-tab keystroke fan-out so a user can drive several panes simultaneously
(common for fleet sysadmin work).

### Sketch

- New actions in `src/input/Binding.zig` + `src/apprt/action.zig`:
  - `toggle_broadcast_input` — toggles broadcast for the focused tab.
  - `toggle_broadcast_opt_out` — toggles whether the focused split is excluded
    from receiving (still sends).
- Per-tab broadcast bus living on the `Tab` widget. While active, every
  keystroke any non-opted-out split receives is also delivered to every other
  non-opted-out split's PTY in that tab. Disabling broadcast clears all
  opt-outs.
- Split header indicator slot (already present in the P4 widget, hidden) flips
  visible; clicking the indicator toggles per-split opt-out.
- Confirmation dialog gated on a new config key:
  ```
  broadcast-input-confirm = always|once|never   # default: once
  ```
  Dialog text: "Send keystrokes to all N splits in this tab?"
- No default keybind (`Ctrl+Shift+I` is `inspector:toggle` per §14).

### Open questions

- Where exactly to fan out: at the apprt key-event layer or at the core
  surface input layer? Apprt-layer keeps the broadcast logic out of the core
  but means key sequences/key-tables don't fan out — probably preferred since
  fan-out of multi-key sequences is fragile.
- Should opt-out persist across broadcast toggles? Spec says clear-on-disable,
  matches expectation.

---

## P9 — Save / Restore Tab Layout

Persist a tab's split tree to disk and rehydrate later.

### Format (§12 of the spec)

```jsonc
{
  "version": 1,
  "tab_title": "Build",
  "tree": {
    "type": "split",
    "orientation": "horizontal",
    "ratio": 0.5,
    "children": [
      { "type": "leaf", "cwd": "/home/user/src", "command": null, "title": null },
      {
        "type": "split", "orientation": "vertical", "ratio": 0.4,
        "children": [
          { "type": "leaf", "cwd": "/home/user/src/build", "command": "watch make", "title": "build" },
          { "type": "leaf", "cwd": "/home/user/src", "command": null, "title": null }
        ]
      }
    ]
  }
}
```

### Sketch

- `save_tab_layout` action — file save dialog → write the focused tab's tree
  to `.ghostty-layout.json`.
- `load_tab_layout` action — file picker → recreate the tree in a new tab,
  spawning a fresh shell per leaf in the recorded `cwd` (no PTY/scrollback
  persistence).
- Ratios are persisted; absolute pixels are not. Unknown JSON fields are
  ignored so the schema can evolve.
- No default keybinds (`Ctrl+Shift+S` and `Ctrl+Shift+O` would collide).

### Open questions

- Should layouts be auto-discovered from a per-user config dir? Or always
  explicit pick-a-file? Explicit is simpler and matches the spec.
- Versioning: lock at v1 and treat v2+ as unknown-incompatible? Or attempt
  best-effort load?

---

## macOS Feature Parity

The Linux plan touches the GTK app runtime exclusively. Mac AppKit needs the
following to reach parity:

### Plumbing only (cheap)

- Register the three new action enum variants in
  `macos/Sources/Ghostty/Ghostty.Action.swift` so user keybinds parse and
  `GhosttyPackage.swift` routes them. Without behavior, dispatch can log
  "unimplemented" the same way GTK does for actions like `reset_window_size`.
- `goto_split_index` on macOS should "just work" once dispatch is wired: the
  underlying split tree datastructure is shared Zig (`src/datastruct/split_tree.zig`),
  and `Iterator` is platform-agnostic. The Swift side only needs a small bridge
  to enumerate leaves in creation order on the active tab.

### Larger work

- **Split header bar on AppKit** — equivalent of P4. A small `NSView`
  per leaf with title / zoom / close, hooked into AppKit's NSDragSession.
- **DnD** — `NSPasteboard` type `application/x-ghostty-split` carrying the
  same `{pid, uuid}` payload. AppKit's `NSDraggingSource` and
  `NSDraggingDestination` protocols. Quadrant detection same math.
- **Tear-off to new window** — when AppKit reports `NSDragOperationNone`
  outside any window, invoke the existing new-window factory and reparent
  the surface.
### Tests

- `macos/Tests/Splits/SplitTreeTests.swift` already exercises the datastructure;
  extend it for any new operations introduced (zoom-swap).
- New tests for AppKit DnD logic (probably manual-only — UI test harness on
  macOS is heavyweight).

### Priority

Plumbing first (low cost, high reach). Header bar + DnD are next once we
have user demand. Tear-off after DnD.
the cross-platform PTY refactor.
