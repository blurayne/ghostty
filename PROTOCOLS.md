# Terminal-Protocol Support Matrix: Upstream Ghostty vs. Our Fork vs. cmux
Date: 2026-08-10
Status: reference

Comparison of terminal/agent-protocol coverage across:
- **Upstream** — `ghostty-org/ghostty` `main`.
- **Our Fork** — this repository.
- **cmux** — the Ghostty fork vendored by [`manaflow-ai/cmux`](https://github.com/manaflow-ai/cmux). cmux consumes Ghostty as a `GhosttyKit.xcframework` built from the submodule `manaflow-ai/ghostty` (`main`, pinned at `f76c132e5`). Fork patch log: `manaflow-ai/cmux:docs/ghostty-fork.md`.

**Headline:** cmux adds **no new agent-facing wire protocols** beyond upstream. Its fork work is overwhelmingly macOS/iOS embedding and renderer-robustness patches. Its one protocol patch — an OSC 99 parser — is **orphaned/dead code** at the shipping HEAD (present but not imported/dispatched after an upstream `osc.zig` refactor). On protocol coverage, **our fork is ahead of both upstream and cmux** (sixel, iTerm2 image rendering, glyph protocol).

## Matrix (agent-relevant first)

| Protocol / feature | Upstream | Our Fork | cmux |
|---|---|---|---|
| **OSC 99 kitty notifications** | ❌ no parser | ❌ missing → [planned](docs/agents/plans/2026-08-10-osc99-kitty-notifications.md) | ⚠️ parser exists but **unwired** (`kitty_notification.zig`, not imported/dispatched at HEAD); subset only |
| **OSC 9 desktop notifications** | ✅ `parsers/osc9.zig` | ✅ + click-to-focus | ✅ inherited |
| **OSC 777 notify** | ✅ `parsers/rxvt_extension.zig` | ✅ notify + click-to-focus | ✅ inherited |
| **Click-to-focus on notifications** | app-layer | ✅ GTK + macOS | ~ upstream-equivalent (not separately verified) |
| **Bell → desktop notification** | ❌ | ❌ → [planned](docs/agents/plans/2026-08-10-bell-to-notification-bridge.md) | ❌ |
| **OSC 133 semantic prompt** | ✅ full (`semantic_prompt.zig`) | ✅ (+ `cmdline=` parsed) | ✅ + row-lifecycle fix (PR 176) |
| **OSC 133;P / redraw marker** | ✅ upstream (`prompt_start 'P'`, `redraw=`) | ✅ (`shell_redraws_prompt`) | ✅ inherited (no cmux-specific marker patch) |
| **OSC 9;4 progress (ConEmu)** | ✅ parsed | ✅ parsed **+ rendered, all 5 states** (GTK + macOS) | ✅ inherited (parsed) |
| **OSC 3008 context signal** | ✅ `parsers/context_signal.zig` | ⚠️ parsed, command text not plumbed → [planned](docs/agents/plans/2026-08-10-semantic-prompt-command-text.md) | ✅ inherited |
| **OSC 633 VS Code shell integration** | ❌ | ❌ → [planned](docs/agents/plans/2026-08-10-osc633-vscode-shell-integration.md) | ❌ |
| **iTerm2 OSC 1337 inline images** | ❌ parsed→`unimplemented`→dropped | ✅ rendered (+ multipart/percent/download) | ❌ (upstream behavior) |
| **iTerm2 `SetUserVar`** | ❌ dropped | ❌ parsed-but-ignored → [planned](docs/agents/plans/2026-08-10-iterm2-setuservar-capabilities.md) | ❌ |
| **iTerm2 capability queries** (ReportCellSize/ReportVariable/ShellIntegrationVersion/UnicodeVersion) | ❌ dropped | ❌ parsed-but-ignored → [planned](docs/agents/plans/2026-08-10-iterm2-setuservar-capabilities.md) | ❌ |
| **iTerm2 `Copy` / `CurrentDir`** | ✅ (only implemented 1337 keys) | ✅ | ✅ inherited |
| **Kitty graphics (APC G)** | ✅ full | ✅ | ✅ + bounded-storage hardening (merge `b7feeea5c`) |
| **Sixel (DCS q)** | ❌ (only a `sixel=4` DA enum stub) | ✅ decoder + render + DA1 `;4` | ❌ |
| **Glyph protocol (Rio APC, prefix `25a1`)** | ❌ | ✅ | ❌ |
| **Kitty text-sizing OSC 66 / DnD OSC 72 / clipboard OSC 5522** | ✅ | ✅ (via upstream) | ✅ inherited |

Legend: ✅ implemented · ⚠️ present but incomplete/unwired · ~ equivalent/unverified · ❌ absent.

## What cmux adds beyond upstream (not protocols)

From `manaflow-ai/cmux:docs/ghostty-fork.md` — relevant to embedding/robustness, not wire protocols:
- **Bounded Kitty graphics state** (merge `b7feeea5c`): caps per-screen image/placement memory + renderer damage tracking. Useful if unbounded Kitty-graphics memory growth ever surfaces.
- **Semantic-prompt row lifecycle** (PR 176, `afcda52a2`/`2d6e944e3`, `src/terminal/Terminal.zig`): clears stale OSC 133 prompt/continuation marks when printable output overwrites a row — keeps prompt-boundary detection accurate under TUI repaints.
- Embedded/`apprt` renderer plumbing (redraw ticketing, bounded mailbox turns, frame-lease rotation, scrollback replay viewport authority) — matters for embedding Ghostty in a custom app.

## Task B — which existing plans can reuse cmux code

| Plan | cmux code to borrow |
|---|---|
| [OSC 99](docs/agents/plans/2026-08-10-osc99-kitty-notifications.md) | ✅ **Yes.** `manaflow-ai/ghostty:src/terminal/osc/parsers/kitty_notification.zig` (229 lines) + wiring commit `4713b7e23`. Handles `p=`/`d=`/`e=`/`i=` and multi-chunk assembly. **Caveats:** (1) it's orphaned in cmux's own tree — port the parser logic + wiring *pattern*, re-integrate against our current `osc.zig`; (2) it's a **subset** — ignores `a=` actions, `u=` urgency, `w=` timeout, buttons, `close`/`alive`. Our plan is a superset; use cmux as the base parser + chunk-accumulation reference. |
| [Semantic-prompt command text](docs/agents/plans/2026-08-10-semantic-prompt-command-text.md) | ◑ Adjacent. cmux **PR 176** (row-lifecycle mark clearing) is a prerequisite for reliable command-region extraction under TUI repaints — worth porting alongside. The `cmdline`/`cmdline_url` decode machinery itself is upstream `semantic_prompt.zig`, already in our fork. |
| [iTerm2 SetUserVar + capabilities](docs/agents/plans/2026-08-10-iterm2-setuservar-capabilities.md) | ❌ None — cmux uses upstream `iterm2.zig` unchanged (all keys dropped). We'd be ahead of both. |
| [OSC 633](docs/agents/plans/2026-08-10-osc633-vscode-shell-integration.md) | ❌ None — absent in cmux. |
| [Bell → notification](docs/agents/plans/2026-08-10-bell-to-notification-bridge.md) | ❌ None — absent in cmux. |

## Sources
- `manaflow-ai/cmux`: `.gitmodules`, `docs/ghostty-fork.md`, `.github/workflows/build-ghosttykit.yml`
- `manaflow-ai/ghostty` @ `f76c132e5`: `src/terminal/osc/parsers/kitty_notification.zig`, `src/terminal/osc/parsers.zig`, `src/terminal/osc.zig`, PR 176, merge `b7feeea5c`, commit `4713b7e23`
- `ghostty-org/ghostty`: `src/terminal/osc/parsers/` (baseline), `src/terminal/osc/parsers/iterm2.zig` (unimplemented-key branch)
