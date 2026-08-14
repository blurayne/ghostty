# Plan: Bell → Desktop Notification Bridge
Date: 2026-08-10
Priority: P2
Status: planned

## Goal

Add an option to post a desktop notification when the terminal bell (BEL / 0x07) rings — the equivalent of iTerm2's "post notification on bell." Many agent CLIs whose only attention channel is the bell (including Claude Code's `terminal_bell` path) currently dead-end in Ghostty: the bell can flash the border, mark the tab, or beep, but it cannot raise an OS notification. This is the interim "just make BEL work" fix.

## Scope

**In scope:**
- A new flag on the existing `bell-features` config (e.g. `notification` / `system-notification`).
- When set, `.ring_bell` fires a desktop notification through the *existing* notification path, reusing the plumbing that `notify-on-command-finish` already uses.
- Respect the `desktop-notifications` master gate and the existing notification rate-limiting/dedup.
- Sensible default notification content ("Bell" title, surface/window title as body) with click-to-focus (already free via the existing notification path).

**Out of scope (future work):**
- Per-app / per-type filtering of bell notifications (that's OSC 99 territory).
- Configurable bell-notification text templates.
- Coalescing rapid repeated bells beyond the existing rate limit.

## Background: current state

- Bell path: `stream_handler.zig:231 .bell => self.bell()` → `:1011 bell()` → `.ring_bell` surface message → `Surface.zig:1146` (100ms rate limit) → `performAction(.ring_bell)` (`action.zig:314-316,426`).
- `bell-features` config: `@"bell-features": BellFeatures` (`Config.zig:3294`); packed struct at `Config.zig:9319-9327` = `{ system, audio, attention, title, border }`. **No notification flag exists.**
- GTK bell handler: `actionRingBell` in `apprt/gtk/class/window.zig:2568` (system→`native.beep()`, attention→`setUrgent`, title→🔔 prefix `tab.zig:545`, border→CSS overlay).
- macOS bell: visual/title/border via `@Published bell`; system alert sound; dock bounce for attention.
- **Template to reuse:** `notify-on-command-finish` is the one existing non-OSC event that raises a desktop notification. GTK `apprt/gtk/class/surface.zig:1188-1222` and macOS `Ghostty.App.swift:1571 commandFinished` both call the same `sendDesktopNotification`/`showUserNotification` paths used by OSC 9/777. The bell notification should call the identical helpers.

## Architecture Decisions

### A. Config surface
Add a `notification` bool to the `BellFeatures` packed struct (`Config.zig:9320`), default `false`. This keeps bell behavior additive and composable with existing flags (a user can have `border` + `notification`, etc.).

### B. Where the notification fires
Fire from the apprt bell handlers (`actionRingBell`), not from core, so it can reuse the platform's existing notification helper and focus/rate-limit machinery:
- GTK: in `window.zig:2568 actionRingBell`, when `bell-features.notification` is set and `desktop-notifications` is enabled, call the same `sendDesktopNotification` used by command-finish (`surface.zig`).
- macOS: in the bell handling path, when the flag is set, call `showUserNotification` (the command-finished path in `Ghostty.App.swift:1571` is the model).

### C. Suppression when focused
Reuse the existing focus-suppression behavior notifications already have (macOS `shouldPresentNotification`; GTK focus state), so a bell in the focused window doesn't spam a redundant banner. Optionally gate to unfocused-only by default within the bell path.

## Files Touched

| File | Change |
|---|---|
| `src/config/Config.zig` | Add `notification: bool = false` to `BellFeatures` (`:9320`); doc comment |
| `src/apprt/gtk/class/window.zig` | In `actionRingBell` (`:2568`), fire `sendDesktopNotification` when flag + gate set |
| `src/apprt/gtk/class/surface.zig` | Reuse/expose the command-finish notification helper for the bell caller |
| `macos/Sources/Ghostty/*` | In the bell path, call `showUserNotification` when the flag is set |

## Phases

1. **Phase 1** — Plan (this document).
2. **Phase 2** — Add `BellFeatures.notification` flag + config docs + parse test.
3. **Phase 3** — GTK: fire notification from `actionRingBell` via existing helper.
4. **Phase 4** — macOS: fire notification from the bell path via existing helper.
5. **Phase 5** — Build (`mise run build`) + manual verification (printf '\a' with flag on/off, focused vs unfocused).

## Edge Cases

- `desktop-notifications=false` master gate → never notify regardless of bell flag.
- Rapid bells → existing notification rate-limit/dedup prevents spam.
- Bell in focused window → suppressed by existing focus logic (no redundant banner).
- Flag off (default) → behavior identical to today (no regression).

## References

- iTerm2 "Post notification on bell" — Prefs → Profiles → Terminal
- `src/config/Config.zig:9319-9327` — `BellFeatures`
- `src/apprt/gtk/class/window.zig:2568` — `actionRingBell`
- `src/apprt/gtk/class/surface.zig:1188-1222` / `macos/Sources/Ghostty/Ghostty.App.swift:1571` — command-finish notification (template)
- `docs/agents/plans/2026-08-10-osc99-kitty-notifications.md` — richer notification path (future superset)
