# Plan: OSC 633 — VS Code Shell Integration
Date: 2026-08-10
Priority: P2
Status: planned

## Goal

Add compatibility parsing for VS Code's OSC 633 shell-integration protocol. The growing pile of xterm.js-targeting tools emit OSC 633 rather than OSC 133, and the key `OSC 633 ; E ; <commandline>` subcommand carries the actual command line in-band — metadata that classic OSC 133 does not. Even partial 633 support lets those tools run unchanged in Ghostty.

## Scope

**In scope:**
- New OSC 633 parser handling the semantic-prompt subcommands:
  - `A` prompt start, `B` command start (input begins), `C` command executed (output begins), `D[;<exit>]` command finished (with optional exit code).
  - `E ; <commandline> [; <nonce>]` — the command line for the current command (the headline feature).
  - `P ; <key>=<value>` — properties; at minimum `Cwd=<path>`.
- Map `A/B/C/D` onto the same internal semantic-prompt actions Ghostty already uses for OSC 133 (reuse `Terminal.semanticPrompt`), so prompt navigation / output selection / command_finished all work identically.
- Route `E` command text into the shared command-text storage introduced by the semantic-prompt-command-text plan (`2026-08-10-semantic-prompt-command-text.md`), so 633;E and 133;cmdline converge on one field.
- Route `P;Cwd=` into the existing pwd-report path (same effect as OSC 7 / iTerm2 `CurrentDir`).

**Out of scope (future work):**
- VS Code-specific properties beyond `Cwd` (e.g. `ContinuationPrompt`, `HasRichCommandDetection`, `IsWindows`).
- The `633 ; E` nonce security handshake (accept and ignore the nonce; do not enforce).
- Emitting OSC 633 from Ghostty's own shell-integration scripts (this is receive-side only).

## Background: current state

- `grep 633 src/` → zero matches. The OSC state machine routes the `6` prefix only to `66` (Kitty text sizing): `osc.zig:748` (`'6' => .@"6"`), `:860-861` (`.@"6"` → only `'6' => .@"66"`), `:995` (`.@"6" => null`). No 633 handling exists.
- OSC 133 parser: `src/terminal/osc/parsers/semantic_prompt.zig`, dispatched at `osc.zig:1003`. Internal application via `Terminal.semanticPrompt` (`Terminal.zig:1985-2101`); per-row `u2` state in `page.zig:2009-2022`; `command_finished` action carries exit code + duration (`action.zig:346/1015`).
- Ghostty already parses `cmdline`/`cmdline_url` options on OSC 133 (`semantic_prompt.zig:51-61`) but never plumbs them out — the 633 command-text work should share whatever storage that plan adds.

## Architecture Decisions

### A. State machine
Add a `.@"633"` state in `osc.zig` reached via `6 → 63 → 633`, parallel to how `133` is threaded. Register dispatch to a new parser `src/terminal/osc/parsers/vscode_shell.zig` (~`osc.zig:978-1007`).

### B. Reuse OSC 133 internals, not a parallel system
The 633 parser should translate subcommands into the **same** `Command`/semantic-prompt actions the 133 path emits, so there is one code path for prompt state, command tracking, and `command_finished`. `A/B/C` map to prompt-start / input-start / output-start; `D;<exit>` maps to end-command with exit code (same as `133;D;<exit>`). This keeps prompt navigation and the apprt actions unchanged.

### C. Command text convergence
`E ; <commandline>` decodes VS Code's escaping (backslash escapes for `;`, newlines, etc.) and stores into the shared command-text field. This depends on `2026-08-10-semantic-prompt-command-text.md` landing the storage + `CommandFinished` plumbing; sequence that plan first or land the storage field as part of this one.

### D. Cwd
`P;Cwd=<path>` reuses the existing pwd/report path (mirror how iTerm2 `CurrentDir` maps to `report_pwd`).

## Files Touched

| File | Change |
|---|---|
| `src/terminal/osc.zig` | Add `6→63→633` states; dispatch to `parsers.vscode_shell.parse` |
| `src/terminal/osc/parsers/vscode_shell.zig` | **New** — parse A/B/C/D/E/P; translate to shared semantic-prompt + command-text + pwd commands |
| `src/terminal/Terminal.zig` | Reuse `semanticPrompt`; store command text (shared field) |
| `src/termio/stream_handler.zig` | Route decoded command text + Cwd through existing handlers |

## Phases

1. **Phase 1** — Plan (this document).
2. **Phase 2** — `.@"633"` states + parser skeleton + subcommand tests.
3. **Phase 3** — Map A/B/C/D onto existing semantic-prompt path; verify `command_finished` fires with exit code.
4. **Phase 4** — `E` command-text decode into shared storage; `P;Cwd` into pwd path.
5. **Phase 5** — Build (`mise run build`) + targeted tests.

## Edge Cases

- `D` with no exit code → treat as success/unknown (match 133 behavior).
- `E` with backslash-escaped `;`/newlines → decode per VS Code escaping rules.
- Unknown subcommand letter → log debug, ignore (forward-compat).
- Unknown `P` key → ignore.
- Nonce present on `E` → accept and ignore.
- Interleaved 133 and 633 from the same shell → last-writer-wins on shared state (don't double-count commands).

## References

- https://code.visualstudio.com/docs/terminal/shell-integration#_vs-code-custom-sequences-osc-633-st
- `src/terminal/osc/parsers/semantic_prompt.zig` — OSC 133 parser to mirror
- `src/terminal/Terminal.zig:1985-2101` — `semanticPrompt`
- `docs/agents/plans/2026-08-10-semantic-prompt-command-text.md` — shared command-text storage
