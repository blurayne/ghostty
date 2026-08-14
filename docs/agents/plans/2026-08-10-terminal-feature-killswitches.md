# Plan: Terminal Feature Kill-Switches (disable risky/questionable sequences)
Date: 2026-08-10
Priority: P2
Status: planned

## Goal

Let users disable in-band terminal control features they consider a security risk, without changing today's defaults (everything stays enabled). Provide both **granular** switches (`disable-sixel`, `disable-osc <numbers>`, …) and a **preset** (`terminal-hardening = risky|questionable|all`) that maps onto the risk classes `termprobe` already defines (`SAFE`/`QUESTIONABLE`/`RISKY`). Ship an example "hardened" config that recommends disabling at least the RISKY set.

Rationale: in-band sequences are an attack surface — clipboard read (exfiltration), image/file transfer, notification action-reporting (writes back to the pty), title-report (injection), misleading hyperlinks, glyph spoofing. Upstream already gates some; this fork adds gates for the features it introduced plus a generic OSC blocklist.

## Reuse: gates that already exist (no new code)

| Risk feature | Existing option | File |
|---|---|---|
| OSC 52 clipboard read/write | `clipboard-read` / `clipboard-write` (ask/allow/deny) | `Config.zig:2497-2498` |
| Paste injection | `clipboard-paste-protection` (default true) | `Config.zig:2509` |
| Title read-back (injection) | `title-report` (default **false** already) | `Config.zig:2562` |
| OSC 8 hyperlinks | `link-osc8` (default true) | `Config.zig:1548` |
| Desktop notifications (OSC 9/777/99) | `desktop-notifications` (default true) | `Config.zig:3865` |
| Kitty-graphics/sixel/iTerm2 image memory | `image-storage-limit` | `Config.zig:2571` |

The example config uses these directly. This plan only adds what's missing.

## Scope — new options (all default = current behavior)

Granular booleans (default `false` = feature stays enabled):
- `disable-sixel` — drop the fork's DCS sixel path; also omit `;4` from the DA1 response.
- `disable-kitty-graphics` — drop APC `G` execution (memory limit alone doesn't disable).
- `disable-glyph-protocol` — drop APC `25a1` (glyph registration) execution.
- `disable-iterm2` — drop the OSC 1337 family (inline images, multipart, SetUserVar, reports).

Generic OSC blocklist:
- `disable-osc` — comma/repeatable list of OSC command numbers to ignore, e.g.
  `disable-osc = 9,777,99,1337,3008,633,66,5522`. Special value `all`. Default empty.

Preset (convenience; expands to the above + existing gates):
- `terminal-hardening = off | risky | questionable | all` (default `off`).
  - `risky` → disables the termprobe-RISKY set: OSC 52 (→ clipboard-read/write=deny), kitty-clipboard (OSC 5522), kitty-graphics, OSC 99 (→ desktop-notifications off).
  - `questionable` → RISKY plus: sixel, iTerm2 (images/SetUserVar), glyph, OSC 8 (→ link-osc8=false), OSC 9/777, title (already off), ReGIS, RequestAttention.
  - `all` → everything the fork can gate.
  Explicit granular options override the preset.

## Architecture

### A. Where to gate
Config is available in the stream handler / surface, not in the pure `osc.zig` parser (which resets per sequence). Gate at **dispatch**, in `src/termio/stream_handler.zig`, where typed `Command`s are handled:
- Add a resolved `DisabledFeatures` struct on the stream handler (computed once from config, incl. preset expansion) with: `osc: std.StaticBitSet or a small set of numbers`, `sixel`, `kitty_graphics`, `glyph`, `iterm2` bools.
- For OSC commands, add a helper `oscDisabled(number)` and a `commandOscNumber(cmd) ?u16` mapping (each `osc.Command` variant → its OSC number). At the top of the OSC dispatch, if disabled → return (ignore), matching how unknown/denied commands are already dropped.
- For sixel: guard the `.sixel` arm in `dcsCommand` (`stream_handler.zig:882`).
- For kitty graphics: guard before `kittyGraphics()` in the APC `G` path.
- For glyph: guard in the APC `25a1` executor (`src/terminal/apc/glyph/execute.zig`).
- For iTerm2: guard the `iterm2_*` arms.

### B. DA1 consistency
When `disable-sixel` (or preset covering it), omit the `;4` indicator in `deviceAttributes` (`stream_handler.zig:1280`) so capability probing matches actual behavior.

### C. Preset expansion
Resolve `terminal-hardening` into the concrete disable set at config finalize (in `Config.zig`), so the stream handler only ever reads the concrete flags. Existing gates (clipboard/link/notifications) are set by the preset too, unless the user set them explicitly.

## Files Touched

| File | Change |
|---|---|
| `src/config/Config.zig` | Add `disable-sixel`, `disable-kitty-graphics`, `disable-glyph-protocol`, `disable-iterm2`, `disable-osc` (list), `terminal-hardening` (enum) + preset expansion in finalize |
| `src/termio/stream_handler.zig` | Resolve `DisabledFeatures`; gate OSC dispatch (`commandOscNumber`), sixel, kitty-graphics, iTerm2; omit DA1 `;4` when sixel disabled |
| `src/terminal/apc/glyph/execute.zig` | Honor `disable-glyph-protocol` (skip register/query, still ack support=false) |
| `docs/agents/examples/hardened.conf` | Example hardened profile (created — see below) |

## Phases

1. **Phase 1** — Plan (this document) + example config.
2. **Phase 2** — Config options + `terminal-hardening` preset expansion + parse tests.
3. **Phase 3** — `commandOscNumber` map + OSC gate in stream handler + tests (feed OSC 9 with `disable-osc=9` → no notification action).
4. **Phase 4** — sixel / kitty-graphics / iTerm2 / glyph gates + DA1 `;4` omission.
5. **Phase 5** — Build & test in container (`mise run build`; core tests `zig build test -Dapp-runtime=none -Dtest-filter=...`).

## Edge Cases

- `disable-osc = all` — drop every OSC (including title 0/2); document as extreme.
- A number in `disable-osc` that maps to multiple commands (e.g. 1337) — gate all of them.
- Preset + explicit flag conflict — explicit wins.
- Disabling a feature that a running app depends on — silent ignore (no error to the app), consistent with unsupported behavior.
- `disable-sixel` must also stop advertising sixel (DA1 `;4`) to avoid apps sending sixel that's dropped.

## References

- `PROTOCOLS.md` — risk classification source (mirrors `termprobe`'s `risk_of`).
- `~/.local/bin/termprobe` — `risk_of()` for the RISKY/QUESTIONABLE mapping.
- Existing gates: `src/config/Config.zig:2497,2509,2562,1548,3865,2571`.
- `docs/agents/examples/hardened.conf` — recommended profile.
