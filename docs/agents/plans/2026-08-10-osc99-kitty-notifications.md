# Plan: OSC 99 — Kitty Desktop Notification Protocol
Date: 2026-08-10
Priority: P1
Status: planned

## Goal

Implement the full [kitty desktop-notification protocol](https://sw.kovidgoyal.net/kitty/desktop-notifications/) (OSC 99) in this fork. Today Ghostty only supports the simple OSC 9 and OSC 777 `notify` forms, which carry nothing but a title and body. OSC 99 is a structured, chunked protocol whose fields map directly onto agent/harness needs:

- `i=` identifier + resend → live-updating status ("Claude: 3/7 tasks") by replacing an existing notification.
- `a=report` + `p=buttons` → an approval answered from the notification, with the pressed button index flowing back in-band over the pty.
- `o=unfocused` → suppress the redundant banner while the window is focused.
- `f=` app-name and `t=` type → per-agent filtering that plain desktop notifications can't do.
- `w=` auto-expiry → stale prompts disappear on their own.
- `p=?` → harnesses feature-detect OSC 99 support instead of sniffing `TERM_PROGRAM`.

The cmux fork demonstrates the parser fits comfortably inside libghostty.

**Reuse note (cmux):** `manaflow-ai/ghostty:src/terminal/osc/parsers/kitty_notification.zig` (229 lines, wiring commit `4713b7e23`) is a working base parser handling `p=`/`d=`/`e=`/`i=` and multi-chunk assembly — port its parser logic and chunk-accumulation pattern. Two caveats: (1) it is **orphaned in cmux's own tree** (not imported/dispatched at HEAD after an upstream `osc.zig` refactor), so re-integrate the state machine against our current `osc.zig`; (2) it is a **subset** of the spec (no `a=` actions, `u=` urgency, `w=` timeout, buttons, `close`/`alive`) — this plan is the superset. See `PROTOCOLS.md`.

## Scope

**In scope:**
- New OSC 99 parser handling the metadata keys: `i` (identifier), `d` (done/chunking 0|1), `p` (payload kind: `title`|`body`|`?`|`buttons`|`alive`), `a` (actions: `report`,`focus`,`-report`,`-focus`), `o` (only-when: `unfocused`|`invisible`|`always`), `u` (urgency 0-2), `f` (app name, base64), `t` (type/category, base64), `w` (expire-time ms), `c` (close), `e` (payload is base64), `g` (icon name).
- Chunked accumulation: multiple OSC 99 sequences sharing an `i=` concatenate their payloads until `d=1`.
- A richer internal notification command variant carrying identifier / actions / buttons / type / app-name / timeout / urgency / only-when, replacing the title+body-only `show_desktop_notification` for this path.
- Apprt plumbing (GTK + macOS): buttons, click-to-focus (already exists for OSC 9), activation reporting back to the pty, unfocused suppression, expiry, replace-by-identifier.
- `p=?` feature-detect reply written back to the pty.
- `a=report` activation/close reports written back to the pty as `ESC ] 99 ; i=<id> ; <event> ST`.

**Out of scope (future work):**
- Icon transmission via chunked image payload (`g=` name references only; no inline icon data decode initially).
- Sound/audio payloads (`s=`).
- Wayland/portal-specific action-button quirks beyond what `gio.Notification` exposes.

## Background: current state

- OSC state machine routes `9` at `src/terminal/osc.zig:751`; `.@"9"` only accepts `;` then falls to trailing capture (`osc.zig:920-926`). There is **no `.@"99"` state** — a second `9` currently lands in `.invalid`.
- Simple notifications produce `Command.show_desktop_notification { title, body }` (`osc.zig:94-100`), dispatched via `stream.zig:381` → `stream_handler.zig` → `Surface.zig:1127` (gated by `config.desktop-notifications`) → `Surface.zig:6146 showDesktopNotification()` (rate-limit 1/s + 5s dedup) → `performAction(.desktop_notification, …)` (`apprt/action.zig:811`).
- GTK sends a `gio.Notification` with `setDefaultActionAndTargetValue("app.present-surface", core_surface.id)` (`apprt/gtk/class/surface.zig:1810`) — click-to-focus already works. The gio notification *ID* is the body string (`surface.zig:1817`), so equal bodies already coalesce.
- macOS uses `UNUserNotificationCenter` with `userInfo["surface"]` for click-to-focus (`SurfaceView_AppKit.swift:1746/1793`) and `shouldPresentNotification`/`willPresent` for focus suppression (`AppDelegate.swift:883-902`).
- `src/terminal/osc/encoding.zig` already references the kitty notification spec and provides safe-utf8 / base64 helpers to reuse.

## Architecture Decisions

### A. Parser location and chunking state
The OSC parser (`osc.zig`) resets between sequences, so multi-chunk state cannot live there — mirror the iTerm2 multipart approach and hold accumulation state in `StreamHandler` (`src/termio/stream_handler.zig`). The parser emits per-chunk commands; the stream handler keys them by `i=` into a map, appending payload until `d=1`, then dispatches one notification.

Add a `.@"99"` state in `osc.zig` threaded like `777`, and a new parser `src/terminal/osc/parsers/osc99.zig` registered in the dispatch switch (~`osc.zig:978-1007`).

### B. Command variant
Introduce `Command.kitty_notification` carrying: `identifier: ?[]const u8`, `title/body` payloads, `actions` (report/focus flags), `buttons: []const []const u8`, `only_when`, `urgency`, `app_name`, `type`, `expire_ms`, `done: bool`, `close: bool`, `query: bool` (`p=?`). Keep the existing `show_desktop_notification` untouched for OSC 9/777. Wire the new variant through `stream.zig` and `Surface.zig`.

### C. Apprt payload
Extend `apprt/action.zig` `DesktopNotification` (or add `KittyNotification`) with identifier/buttons/type/timeout/only-when. GTK: `gio.Notification.addButton(label, "app.notify-action", variant{id,index})`; register a `notify-action` app action that writes the report back to the originating surface's pty. macOS: build `UNNotificationCategory` with `UNNotificationAction`s keyed by index; handle in the existing `didReceive` delegate and write the report to the pty. Replace-by-identifier maps to the gio notification ID / `UNNotificationRequest` identifier.

### D. Reporting back in-band
When `a=report` is set, activation and close events are written to the pty as `ESC ] 99 ; i=<id> ; <event> ST` (event = button index for buttons, or the kitty-defined activation token). `p=?` replies immediately with the supported-capabilities response. Reuse the stream handler's pty-write path used by DA/XTGETTCAP replies (`stream_handler.zig` device-attributes helpers).

### E. Only-when suppression
`o=unfocused`/`o=invisible` reuse the focus checks already present: macOS `shouldPresentNotification` (`AppDelegate.swift`), GTK surface focus state. If suppressed, the notification is dropped before reaching the OS.

## Files Touched

| File | Change |
|---|---|
| `src/terminal/osc.zig` | Add `.@"99"` state + transitions (parallel to `777`); add `Command.kitty_notification` variant; dispatch to `parsers.osc99.parse` |
| `src/terminal/osc/parsers/osc99.zig` | **New** — parse all metadata keys + payload; emit per-chunk commands |
| `src/terminal/osc/encoding.zig` | Reuse base64 / safe-utf8 helpers (no change expected) |
| `src/terminal/stream.zig` | Wire the new command key through the stream |
| `src/terminal/stream_terminal.zig` | No-op stub for the new command (test handler) |
| `src/termio/stream_handler.zig` | Chunk accumulation map keyed by `i=`; finalize + dispatch; `p=?` and `a=report` pty replies |
| `src/Surface.zig` | Handle the new notification message; extend rate-limit/dedup to key on identifier |
| `src/apprt/action.zig` | Extend/add notification payload with buttons/identifier/type/timeout/only-when |
| `src/apprt/gtk/class/surface.zig` | Buttons via `gio.Notification.addButton`; replace-by-id; report action |
| `src/apprt/gtk/class/application.zig` | Register `notify-action` app action → write report to surface pty |
| `macos/Sources/Ghostty/*` | `UNNotificationCategory`/`UNNotificationAction` buttons; delegate reports report/close to pty |

## Wire Format (reference)

```
ESC ] 99 ; <metadata> ; <payload> ST
  i=<id>            identifier (groups chunks; enables replace)
  d=0|1             more chunks follow (0) / done (1)
  p=title|body|?|buttons|alive   what the payload is
  a=report,focus,-report,-focus  actions on activation
  o=unfocused|invisible|always   only display when …
  u=0|1|2           urgency low/normal/critical
  f=<b64 app name>  application name
  t=<b64 type>      notification type/category
  w=<ms>            auto-expire timeout
  c=1               close notification with this id
  e=1               payload is base64-encoded
  g=<icon name>     named icon
```

## Phases

1. **Phase 1** — Plan (this document).
2. **Phase 2** — Parser `osc99.zig` + `.@"99"` state + `Command.kitty_notification`; unit tests for every key and chunking.
3. **Phase 3** — Stream handler accumulation + finalize + `p=?`/`a=report` pty replies.
4. **Phase 4** — `apprt/action.zig` payload + Surface message + identifier-keyed dedup.
5. **Phase 5** — GTK buttons / replace / report action.
6. **Phase 6** — macOS categories/actions + delegate reporting.
7. **Phase 7** — Build (`mise run build`) + targeted tests.

## Edge Cases

- Chunk with unknown/absent `i=` → treat as single-shot (implicit id).
- `d=0` stream never terminated → cap buffered bytes (reuse `max_bytes`) and time-bound; drop on overflow.
- `p=?` with no other payload → reply only, show nothing.
- Buttons on a platform/notification daemon that doesn't support actions → degrade to a plain notification (no crash).
- `c=1` for an unknown id → no-op.
- `o=unfocused` while focused → suppress entirely (no OS call).
- `w=0` → no auto-expiry (persist per daemon default).
- Report write when the pty is gone → drop silently.

## References

- https://sw.kovidgoyal.net/kitty/desktop-notifications/
- `src/terminal/osc/parsers/rxvt_extension.zig` — OSC 777 parser (pattern)
- `src/terminal/osc/parsers/iterm2.zig` + `stream_handler.zig` multipart — chunk-accumulation pattern
- `src/apprt/gtk/class/surface.zig:1789-1818` — existing gio.Notification path
- `macos/Sources/Ghostty/Surface View/SurfaceView_AppKit.swift:1746` — existing UN notification path
- cmux fork OSC 99 parser — proof-of-fit reference
