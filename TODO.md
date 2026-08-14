# Ghostty Fork — Protocol Feature TODO

Tracks terminal / agent-protocol coverage in this fork. `[x]` = implemented here, `[ ]` = planned.
Detailed per-feature plans live in `docs/agents/plans/`. For an upstream-Ghostty vs. our-fork vs. cmux comparison, see [`PROTOCOLS.md`](PROTOCOLS.md).

## Notifications
- [ ] OSC 99 kitty desktop-notification protocol (buttons, `i=` replace, `a=report`, `o=unfocused`, `f=`/`t=`, `w=`, `p=?`) — [plan](docs/agents/plans/2026-08-10-osc99-kitty-notifications.md)
- [x] OSC 9 desktop notifications (+ click-to-focus, GTK & macOS)
- [x] OSC 777 `notify` (+ click-to-focus); other 777 verbs intentionally unsupported (none exist in the ecosystem)
- [x] Click-to-focus on notifications — raises the originating surface (GTK `present-surface`, macOS `userInfo["surface"]`)
- [ ] Bell → desktop notification bridge (iTerm2 "post notification on bell" equivalent) — [plan](docs/agents/plans/2026-08-10-bell-to-notification-bridge.md)

## Images
- [x] Kitty graphics (APC G)
- [x] Sixel (DCS q) — decoder + Kitty-pipeline render + DA1 `;4` — [plan](docs/agents/plans/2026-06-28-sixel-support.md)
- [x] iTerm2 OSC 1337 `File=` inline images (+ multipart, percent dims, download) — [plan](docs/agents/plans/2026-06-29-iterm2-image-protocol.md)
- [ ] iTerm2 OSC 1337 `SetUserVar=` + capability/report queries (`ReportCellSize`/`ReportVariable`/`ShellIntegrationVersion`/`UnicodeVersion`) — [plan](docs/agents/plans/2026-08-10-iterm2-setuservar-capabilities.md)
  - [ ] iTerm2 `ReportCellSize` + `UnicodeVersion` (focused) — [plan](docs/agents/plans/2026-08-10-iterm2-reportcellsize-unicodeversion.md)
- [x] Glyph protocol (APC `25a1`, register vector glyphs at PUA codepoints) — [plan](docs/agents/plans/2026-06-29-glyph-protocol.md)

## Shell integration
- [x] OSC 133 semantic prompt (A/B/C/D/I/L/N/P, exit code, duration)
- [x] OSC 133 redraw/continuation marker (`133;P`, `redraw=`/`redraw=last` → `shell_redraws_prompt`)
- [x] OSC 9;4 progress — parsed **and** rendered, all 5 states (remove/set/error/indeterminate/pause), GTK & macOS
- [x] Command exit status + duration exposed via `command_finished` apprt action / C ABI
- [ ] OSC 633 VS Code shell integration (A/B/C/D, `E`=commandline, `P;Cwd`) — [plan](docs/agents/plans/2026-08-10-osc633-vscode-shell-integration.md)
- [ ] Richer semantic-prompt data — expose command text (`cmdline=`) + activate OSC 3008 context signal — [plan](docs/agents/plans/2026-08-10-semantic-prompt-command-text.md)

## Security / hardening
- [x] Existing gates: `clipboard-read`/`clipboard-write` (OSC 52), `link-osc8` (OSC 8), `title-report` (off by default), `desktop-notifications` (OSC 9/777/99), `image-storage-limit`
- [ ] Feature kill-switches: `disable-sixel`, `disable-kitty-graphics`, `disable-glyph-protocol`, `disable-iterm2`, `disable-osc <numbers>`, `terminal-hardening` preset — [plan](docs/agents/plans/2026-08-10-terminal-feature-killswitches.md) · example: [hardened.conf](docs/agents/examples/hardened.conf)

## Explicitly not planned
- Sixel — done here despite upstream's decision not to support it.
- OSC 777 verbs other than `notify` — no such verbs exist in any terminal; intentionally omitted.
