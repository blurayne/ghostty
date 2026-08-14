# Plan: iTerm2 OSC 1337 — SetUserVar + Capability/Report Queries
Date: 2026-08-10
Priority: P2
Status: planned

## Goal

Fill the remaining non-image gaps in this fork's iTerm2 OSC 1337 support so iTerm2-targeting tooling detects Ghostty and can set user variables. The image side (`File=`, multipart, percent dims, download) is already complete (see `2026-06-29-iterm2-image-protocol.md`). This plan adds:

1. **`SetUserVar=<name>=<base64 value>`** — the imgcat/iTerm2 ecosystem's key/value channel (status lines, tmux-style user vars).
2. **Capability/report queries** — `ReportCellSize`, `ReportVariable`, `ShellIntegrationVersion`, `UnicodeVersion` — currently parsed then dropped with `log.debug("unimplemented OSC 1337")`. Answering these is what lets iTerm2 capability-probing tools recognize Ghostty instead of falling back to "unknown terminal".

## Scope

**In scope:**
- Parse `SetUserVar=name=<b64>` into a new `Command.iterm2_set_user_var { name, value }`; store in a per-terminal user-var map; provide a lookup accessor.
- Answer the report queries by writing iTerm2-format replies back to the pty:
  - `ReportCellSize` → cell height/width (and scale) in points.
  - `ReportVariable=<b64 name>` → the stored user var (or built-ins iTerm2 exposes, e.g. `session.name`), base64-encoded.
  - `ShellIntegrationVersion` → a version string in iTerm2's format.
  - `UnicodeVersion` → the Unicode version Ghostty's width tables target.

**Out of scope (future work):**
- Non-image, non-var control keys: `SetColors`, `SetMark`, `SetBadgeFormat`, `SetProfile`, `CursorShape`, `OpenURL`, `StealFocus`, `RequestAttention`, `SetBackgroundImageFile`, annotations, key labels.
- Exposing user vars to status-line UI (store + accessor only for now).

## Background: current state

- Parser `src/terminal/osc/parsers/iterm2.zig`; dispatched from `osc.zig:1009` (`.@"1337" => parsers.iterm2.parse`).
- Handled today: `File=` (`:365`), `MultipartFile=`/`FilePart=`/`FileEnd` (`:387-443`), `Copy=` (`:301`), `CurrentDir=` (`:348`).
- Unimplemented arms return `.invalid` + `log.debug("unimplemented OSC 1337")` at `iterm2.zig:445-479`: `SetUserVar` (`:471`), `ReportCellSize` (`:461`), `ReportVariable` (`:462`), `ShellIntegrationVersion` (`:472`), `UnicodeVersion` (`:474`).
- Pty-reply pattern to reuse: `stream_handler.zig deviceAttributes` (`:1267-1291`) shows how responses are written back to the terminal.

## Architecture Decisions

### A. User-var storage
Add a small owned `std.StringHashMapUnmanaged([]u8)` to `Terminal` (or `StreamHandler` if terminal-state churn is a concern). `SetUserVar` writes/overwrites; empty value deletes the key. Cap total entries and total bytes to bound memory. Provide `Terminal.getUserVar(name) ?[]const u8` for `ReportVariable` and future status-line use.

### B. Replies
Route report queries to the stream handler, which owns pty writes. Match iTerm2's exact reply framing (e.g. `ReportCellSize` → `ESC ] 1337 ; ReportCellSize=<h>;<w>;<scale> ST`). Base64-encode values where iTerm2 does. Keep a single helper `iterm2Reply(key, value)` to centralize framing.

### C. Parser changes
Replace the four `.invalid` arms with real command emission. `SetUserVar` decodes the base64 value with the existing `decodeBase64` helper. Report queries emit lightweight `Command.iterm2_report { which, arg }` variants that the stream handler turns into replies (parser stays free of pty access).

## Files Touched

| File | Change |
|---|---|
| `src/terminal/osc/parsers/iterm2.zig` | Parse `SetUserVar=`, `ReportCellSize`, `ReportVariable`, `ShellIntegrationVersion`, `UnicodeVersion`; emit new commands |
| `src/terminal/osc.zig` | Add `iterm2_set_user_var` + `iterm2_report` command variants |
| `src/terminal/stream.zig` / `stream_terminal.zig` | Wire + stub new commands |
| `src/terminal/Terminal.zig` | User-var map field + `setUserVar`/`getUserVar`; free on deinit/reset |
| `src/termio/stream_handler.zig` | Handle `iterm2_set_user_var`; answer report queries via `iterm2Reply` |

## Phases

1. **Phase 1** — Plan (this document).
2. **Phase 2** — User-var storage on `Terminal` + accessors + tests.
3. **Phase 3** — Parser: `SetUserVar` + four report queries → new commands; parser tests (`-Dtest-filter='OSC: 1337'`).
4. **Phase 4** — Stream handler: store var; write replies; reply-format tests.
5. **Phase 5** — Build (`mise run build`) + targeted tests.

## Edge Cases

- `SetUserVar=name=` (empty value) → delete key.
- `SetUserVar` with non-base64 value → log warning, ignore.
- `ReportVariable` for an unknown name → reply with empty base64 value (iTerm2 behavior).
- User-var map over cap → reject new keys, log warning.
- Report query when pty is gone → drop silently.

## References

- https://iterm2.com/documentation-escape-codes.html
- https://iterm2.com/documentation-variables.html
- `src/terminal/osc/parsers/iterm2.zig` — existing parser
- `src/termio/stream_handler.zig:1267` — pty-reply pattern (deviceAttributes)
- `docs/agents/plans/2026-06-29-iterm2-image-protocol.md` — image side (done)
- `docs/agents/plans/2026-08-10-iterm2-reportcellsize-unicodeversion.md` — focused breakout for `ReportCellSize` + `UnicodeVersion` (shares scaffolding)
