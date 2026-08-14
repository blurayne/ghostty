# Plan: Richer Semantic-Prompt Data — Command-Text Exposure
Date: 2026-08-10
Priority: P2
Status: planned

## Goal

Expose per-command **command text** (and, optionally, structured context) to embedders/orchestrators so tools like workmux/herdr can read structured command state instead of screen-scraping. This builds on Ghostty's existing OSC 133 investment: exit status and duration are already exposed via the `command_finished` apprt action, but the command text — although parsed — is dropped, and the OSC 3008 context signal is parsed then discarded.

## Scope

**In scope:**
1. **Command-text plumbing** — store the already-parsed OSC 133 `cmdline`/`cmdline_url` (`semantic_prompt.zig:51-61`) into a per-command field, and add it to the `CommandFinished` apprt action payload + its C ABI struct, so an embedder receives `{ command, exit_code, duration }` structured per command. This same storage is the convergence point for OSC 633 `E` (see `2026-08-10-osc633-vscode-shell-integration.md`).
2. **Activate OSC 3008 context signal** (optional, second phase) — the parser at `src/terminal/osc/parsers/context_signal.zig` already extracts `cmdline`, `cwd`, `exit`, `status`, `signal`, but the command is dropped into the "unimplemented OSC callback" branch (`stream.zig:2509-2511`). Route it to an action so context is exposed.

**Out of scope / already done:**
- Redraw/continuation marker: `133;P` is parsed as `prompt_start` and `redraw=`/`redraw=last` already feeds `flags.shell_redraws_prompt` (`Terminal.zig:2005-2007`, default `.true`, `Terminal.zig:99`). **Already implemented — document, do not re-build.**
- Exit code + duration exposure — already done via `CommandFinished` (`action.zig:346/1015-1031`, emitted `Surface.zig:1195-1204`).
- Screen-region boundary API (structured start/output regions) — remains screen-model-internal; not in scope.

## Background: current state

- OSC 133 parser captures `cmdline`/`cmdline_url` via `Command.writeCommandLine` (`semantic_prompt.zig:51-61`), with `$'...'` and percent decoding (tested `:445-717`). But grep shows **no consumer** in `Terminal.zig`, `stream_handler.zig`, `Surface.zig`, or `apprt/` — it is parsed then discarded.
- Command lifecycle: `C` → `.start_command` (`stream_handler.zig:1492`), `D` → `.stop_command` with exit code (`:1495-1504`); `Surface.zig` times `command_timer` (`:1176-1205`) and emits `command_finished` action with `exit_code: ?u8` + `duration` (`action.zig:1015-1031`, C ABI `ghostty_action_command_finished_s`).
- Note `Terminal.zig:2038-2041`: "We don't currently do explicit command tracking in any way" and `:2093-2098`: `end_command` resets semantic state — so there is no per-command record object yet; the command text must be threaded from parse → stop_command.
- **Reuse note (cmux):** cmux PR 176 (`afcda52a2`/`2d6e944e3`, `src/terminal/Terminal.zig`) clears stale OSC 133 prompt/continuation marks when printable output overwrites a row. Reliable command-region/command-text extraction under TUI repaints depends on this being repaint-aware, so port PR 176 alongside this work. The `cmdline`/`cmdline_url` decode itself is upstream `semantic_prompt.zig`, already present. See `PROTOCOLS.md`.
- OSC 3008: `context_signal.zig:80-124` parses rich fields; dropped at `stream.zig:2509-2511`.

## Architecture Decisions

### A. Thread command text through the command lifecycle
When the parser emits the `cmdline` option (typically on `133;C;cmdline=…`), carry the decoded text into the stream handler's command-in-progress state (a small owned buffer on `StreamHandler`, reset on `.start_command`, freed/replaced each command). On `.stop_command`, include it in the `command_finished` message → `CommandFinished` action.

This avoids inventing a full per-command record; it reuses the existing start/stop_command timing already in place for duration. It also gives OSC 633 `E` a single shared field to write into.

### B. C ABI extension
Add `command: [*:0]const u8` (nul-terminated, empty if unknown) to `ghostty_action_command_finished_s` and the Zig `CommandFinished` struct. Keep it optional/empty-safe so existing embedders that ignore it are unaffected. Follow the C-enum/struct conventions in `include/ghostty/`.

### C. OSC 3008 (phase 2, optional)
Replace the no-op branch (`stream.zig:2509-2511`) with an emission of a new `context_signal` action carrying cwd/exit/status/signal, mirroring how `command_finished` is plumbed. Gate behind the same shell-integration config so it's opt-in.

## Files Touched

| File | Change |
|---|---|
| `src/termio/stream_handler.zig` | Capture `cmdline` into in-progress command state; include in `.stop_command` |
| `src/Surface.zig` | Carry command text into the `command_finished` action payload |
| `src/apprt/action.zig` | Add `command` field to `CommandFinished` |
| `include/ghostty/*` | Add `command` to `ghostty_action_command_finished_s` (with `_MAX_VALUE` conventions where applicable) |
| `src/terminal/stream.zig` | (Phase 2) route OSC 3008 to a `context_signal` action instead of the no-op branch |

## Phases

1. **Phase 1** — Plan (this document).
2. **Phase 2** — Thread `cmdline` from parser → stream handler in-progress state → `.stop_command`.
3. **Phase 3** — Add `command` to `CommandFinished` (Zig + C ABI); GTK/macOS consume/log it.
4. **Phase 4** — (optional) Activate OSC 3008 → `context_signal` action.
5. **Phase 5** — Build (`mise run build`, plus `zig build -Demit-lib-vt` for ABI) + targeted tests.

## Edge Cases

- Command with no `cmdline` option → `command` is empty string (not null); embedders handle empty.
- `cmdline` sent without a following `D` (aborted) → cleared on next `.start_command`.
- Very long command lines → cap buffer; truncate with marker.
- 633 `E` and 133 `cmdline` both present → last-writer-wins on the shared field.
- ABI change → bump/verify libghostty-vt consumers; ensure empty-safe default.

## References

- `src/terminal/osc/parsers/semantic_prompt.zig:51-61` — `writeCommandLine` (parsed, unused)
- `src/apprt/action.zig:1015-1031` — `CommandFinished` (exit code + duration exposed)
- `src/termio/stream_handler.zig:1492-1504` — start/stop_command
- `src/terminal/osc/parsers/context_signal.zig` + `src/terminal/stream.zig:2509-2511` — OSC 3008 (parsed, no-op)
- `src/terminal/Terminal.zig:2005-2007` — `redraw=`/`shell_redraws_prompt` (already done)
- `docs/agents/plans/2026-08-10-osc633-vscode-shell-integration.md` — shared command-text consumer
