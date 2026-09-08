---
date: 2026-09-08
topic: "Keep a split open when its command exits non-zero"
tags: [spec, surface, splits, config]
status: draft
---

# Keep a split open when its command exits non-zero

## Problem

Run something slow that fails in a split — `./deploy.sh`, a test suite, a build — and the split vanishes the instant it exits. The error output goes with it. You are left looking at the remaining panes with no idea what the failing one said.

This is not a missing feature so much as a gap in an existing one. Ghostty already keeps a surface open and shows a red "Command Failed" banner when a command fails — but only if it failed *fast*. `Surface.childExited()` (`src/Surface.zig:1281`) treats an exit as worth reporting only when `runtime_ms <= abnormal-command-exit-runtime` (default 250 ms). A command that ran for four seconds and then exited 1 falls through to the normal path, which sets the banner and then calls `self.close()` anyway at `src/Surface.zig:1358`. The banner is created and destroyed in the same breath.

## Current behaviour

| Case | Path | Result |
|---|---|---|
| Non-zero exit, ≤ 250 ms | abnormal branch, `return`s early | Stays open, red banner, detail block written ✅ |
| Non-zero exit, > 250 ms | normal path → `self.close()` | **Closes** ❌ |
| Exit 0 | normal path → `self.close()` | Closes (unless `wait-after-command`) |

Everything needed to display the failure already exists and is reused unchanged:

- `src/apprt/gtk/class/surface_child_exited.zig` — the `Adw.Banner` overlay, with `normal` / `abnormal` CSS classes and a "Command Failed" title driven off `data.exit_code`.
- `src/apprt/gtk/ui/1.3/surface-child-exited.blp` — its template, including the Close button.
- `src/apprt/gtk/class/surface.zig:2842 childExitedClose()` — Close button closes the surface.
- `src/Surface.zig:2868` — once `child_exited` is set, any key that encodes a character closes the surface.
- `src/Surface.zig:1362 childExitedAbnormally()` — writes the horizontal rule, command, runtime and exit code into the terminal.

## Goal

When a command in a **split** exits non-zero, the split stays open showing the banner and a detail block, regardless of how long the command ran. Controlled by a new config toggle, default on.

## Scope decision: splits only

The toggle applies only to surfaces that are part of a split. A lone window or tab still closes on a non-zero exit, exactly as today.

This is a deliberate narrowing, and it has a cost worth stating plainly: the same event produces different behaviour depending on layout. A failing `./deploy.sh` keeps its pane when run in a split and closes the window when run in a single pane. The justification is that closing a split destroys context the user still needs — the surviving panes make the loss obvious and annoying — whereas a lone window closing on shell exit is long-established terminal behaviour that this change should not disturb.

`wait-after-command` remains available for people who want the broader "never close" behaviour.

## Design

### 1. Config

`src/config/Config.zig`, immediately after `wait-after-command` (line 1420):

```zig
/// If true, keep a split open after the command running in it exits with a
/// non-zero exit code, instead of closing the split immediately. The split
/// shows the exit status and stays until dismissed with any keypress or the
/// banner's close button.
///
/// This only applies to surfaces that are part of a split. A lone window or
/// tab closes on exit as usual; use `wait-after-command` to keep those open
/// too.
///
/// Available since: 1.4.0
@"wait-after-failed-command": bool = true,
```

Derived into `Surface.DerivedConfig` alongside the existing `abnormal_command_exit_runtime_ms` (`src/Surface.zig:300` for the field, `:385` for the assignment):

```zig
wait_after_failed_command: bool,
// ...
.wait_after_failed_command = config.@"wait-after-failed-command",
```

### 2. Learning whether we are in a split

Core `Surface` has no concept of splits; the apprt does. The GTK surface already carries an `is-split` boolean property (`src/apprt/gtk/class/surface.zig:695`), bound from the split tree's own `is-split` and re-bound whenever the tree changes (`src/apprt/gtk/class/split_tree.zig:561`).

Core pulls it, matching how it already pulls `getContentScale()`, `getSize()`, `getTitle()` and `supportsClipboard()` from `rt_surface`.

The `is-split` property has no plain Zig getter today (it is declared with `privateFieldAccessor`, which generates only the GObject property plumbing). Add one to `src/apprt/gtk/class/surface.zig`, mirroring the hand-written `getTitle()` at line 2191:

```zig
pub fn getIsSplit(self: *Self) bool {
    return self.private().is_split;
}
```

Then in `src/apprt/gtk/Surface.zig` — the thin wrapper that delegates to the GObject surface:

```zig
pub fn isSplit(self: *const Self) bool {
    return self.surface.getIsSplit();
}
```

`src/apprt/embedded.zig` returns `false`. macOS manages splits on the Swift side and wiring that up is out of scope here; the practical effect is that macOS behaviour is unchanged. This is a stated limitation, not an oversight — see Follow-ups.

`src/apprt/none.zig` has `pub const Surface = struct {}` and is never used for real surfaces, so it needs nothing.

**Rejected alternatives.** Pushing `is_split` into core state on every change duplicates state and risks going stale across split re-parenting. Letting the apprt decide whether to close inverts control flow and scatters config policy across apprts.

### 3. The exit path

`src/Surface.zig:childExited()`. The fast-failure branch is untouched. The change is at the tail of the normal path, where `self.close()` currently runs unconditionally:

```zig
// Waiting after command we stop here.
if (self.config.wait_after_command) return;

// A command that failed in a split keeps the split open so the user can
// read what went wrong. Runtime doesn't matter here — unlike the abnormal
// branch above, this is about a command that ran and then failed, not one
// that never got started.
if (self.config.wait_after_failed_command and
    info.exit_code != 0 and
    self.rt_surface.isSplit())
{
    self.childExitedAbnormally(info, .nonzero_exit) catch |err| {
        log.err("error writing failed command message err={}", .{err});
    };
    return;
}

self.close();
```

On Darwin `info.exit_code` is unreliable (the `login` wrapper always yields 0), which the existing code already comments on at `src/Surface.zig:1288`. Since `isSplit()` returns `false` on embedded, the branch is unreachable on macOS and needs no extra guard.

### 4. Detail block: unconditional, and correctly worded

Two changes to `childExitedAbnormally()`.

**It must run even when the banner is shown.** Today the detail block is a *fallback*: `childExited()` tries `show_child_exited` first and `break :terminal`s past the terminal text if the apprt returns true. Since GTK always returns true when Adwaita supports banners, the detail block would never appear. The new branch calls `childExitedAbnormally()` directly, after the banner has been set, so the user gets both.

**The heading must not lie.** The current text is `"Ghostty failed to launch the requested command:"` — accurate for a fast crash, wrong for a command that launched fine and ran for four seconds. Add a reason parameter:

```zig
const ExitReason = enum {
    /// Exited so fast we assume it never really started.
    launch_failure,
    /// Ran, then exited with a non-zero status.
    nonzero_exit,
};

fn childExitedAbnormally(
    self: *Surface,
    info: apprt.surface.Message.ChildExited,
    reason: ExitReason,
) !void {
```

with the heading selected from it:

```zig
try t.printString(switch (reason) {
    .launch_failure => "Ghostty failed to launch the requested command:",
    .nonzero_exit => "Command exited with a non-zero status:",
});
```

The existing call site at `src/Surface.zig:1309` passes `.launch_failure`, preserving today's output exactly.

The closing line `"Press any key to close the window."` becomes `"Press any key to close the split."` for `.nonzero_exit`. The rule, command, `Runtime:` and `Exit Code:` lines are unchanged.

Resulting output:

```
$ ./deploy.sh
error: connection refused
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Command exited with a non-zero status:

./deploy.sh

Runtime: 4210 ms
Exit Code: 1

Press any key to close the split.
```

with the red "Command Failed" banner pinned to the bottom of the split.

## Dismissal

No new mechanism. Both existing paths already work once the surface stays alive:

- Any key that encodes a character closes it (`src/Surface.zig:2868`, gated on `child_exited`).
- The banner's Close button closes it (`src/apprt/gtk/class/surface.zig:2842`).

## Error handling

- `childExitedAbnormally()` can fail on allocation or terminal writes. The new call site logs and still returns without closing — a split kept open with no message is a better outcome than one that vanishes.
- Adwaita older than 1.3 selects `SurfaceChildExitedNoop`, whose `setData()` emits `close-request`, closing the surface. On such systems this feature cannot keep the split open; the detail block is written but the surface closes anyway. Acceptable — 1.3 shipped in 2023.

## Testing

The interesting logic is the branch condition, which depends on `rt_surface`, config and `info`. Unit tests over `Surface` need a full surface, so coverage is:

- **Unit**: `ExitReason` heading selection — pure, worth a test that both variants produce their expected string.
- **Manual**, on a GTK build:
  1. Split a tab. In one pane run `sh -c 'echo boom; sleep 1; exit 1'`. Pane stays open, red "Command Failed" banner, detail block shows Exit Code 1 and a runtime around 1000 ms.
  2. Same command in an unsplit window → window closes, as before.
  3. `sh -c 'sleep 1; exit 0'` in a split → split closes.
  4. `sh -c 'exit 1'` in a split (fast) → unchanged from today, heading still reads "Ghostty failed to launch the requested command:".
  5. Set `wait-after-failed-command = false` → case 1 closes the split.
  6. With the split held open, press a key → closes. Repeat, click the banner's Close → closes.
  7. `wait-after-command = true` still wins for zero exits.

## Files touched

| File | Change |
|---|---|
| `src/config/Config.zig` | New `wait-after-failed-command` option |
| `src/Surface.zig` | `DerivedConfig` field; new branch in `childExited()`; `ExitReason` param on `childExitedAbnormally()` |
| `src/apprt/gtk/Surface.zig` | New `isSplit()` |
| `src/apprt/gtk/class/surface.zig` | New `getIsSplit()` accessor over the existing `is_split` private field |
| `src/apprt/embedded.zig` | `isSplit()` returning `false` |

No build system changes. No new translatable strings in the GTK layer — the banner text is unchanged; the terminal detail block is not localized today and stays that way.

## Follow-ups, explicitly out of scope

- **macOS.** `embedded.isSplit()` returns `false`, so the feature is Linux/GTK only for now. Wiring it to the Swift split state is a separate change.
- **Darwin exit codes.** The `login` wrapper making `exit_code` always 0 is a pre-existing problem, noted at `src/Surface.zig:1288`, and blocks macOS support independently of the plumbing.
