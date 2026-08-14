# Plan: iTerm2 OSC 1337 — ReportCellSize & UnicodeVersion
Date: 2026-08-10
Priority: P3
Status: planned

## Goal

Implement two iTerm2 OSC 1337 controls the parser currently recognizes but drops (`iterm2.zig:461` `ReportCellSize`, `:474` `UnicodeVersion`):

- **`ReportCellSize`** — a *query*: the app asks for the pixel/point size of a character cell so it can lay out inline images and box drawing precisely. The terminal replies in-band.
- **`UnicodeVersion`** — a *stateful set/push/pop*: the app tells the terminal which Unicode version to use when measuring character widths (notably emoji: v9+ = wide, v8 = narrow), and can push/pop that setting around a region. No reply.

This is a focused subset of `2026-08-10-iterm2-setuservar-capabilities.md`; land whichever first and share the parser/dispatch scaffolding.

## Wire formats (iTerm2)

```
ReportCellSize
  request :  ESC ] 1337 ; ReportCellSize ST
  reply   :  ESC ] 1337 ; ReportCellSize=<height>;<width>;<scale> ST
             height, width = cell size in POINTS; scale = backing scale factor
             (e.g. 2.0 on HiDPI). points = pixels / scale. Older iTerm2 omitted
             the ;<scale> field — we always send it (apps tolerate/parse it).

UnicodeVersion
  set     :  ESC ] 1337 ; UnicodeVersion=<n> ST          (e.g. 8 or 9)
  push    :  ESC ] 1337 ; UnicodeVersion=push[ <label>] ST
  pop     :  ESC ] 1337 ; UnicodeVersion=pop[ <label>] ST
             (no reply; adjusts how ambiguous/emoji widths are measured)
```

## Background (current state)

- Parser `src/terminal/osc/parsers/iterm2.zig`: `ReportCellSize`/`UnicodeVersion` are enum members (`:242`,`:255`) that fall into the `unimplemented → .invalid` branch (`:445-479`).
- Cell metrics + reply path live in `src/termio/stream_handler.zig`: `self.size.cell.width`/`self.size.cell.height` (pixels) and `self.size.grid()`; replies are written with `self.messageWriter(.{ .write_stable = <bytes> })` (the pattern used by DA / pwd reports, e.g. `stream_handler.zig:868`).
- Backing scale: the `size` struct carries DPI/scale used elsewhere for cell sizing; confirm the exact field during impl (fallback: scale = 1.0 ⇒ points = pixels).
- Width measurement: `src/unicode/grapheme.zig` (`graphemeWidth`, `GraphemeWidthEffect`) + `props_uucode.zig` provide a *fixed* Unicode-version width table; there is no per-session version switch today.

## Architecture

### A. ReportCellSize (query → reply) — small, self-contained
1. Parse: in `iterm2.zig`, replace the `.ReportCellSize` unimplemented arm with emission of `Command.iterm2_report_cell_size` (void).
2. Dispatch: in `stream_handler.zig`, compute:
   - `scale` from the size struct (fallback 1.0),
   - `pt_w = cell.width / scale`, `pt_h = cell.height / scale` (format with one decimal),
   - build `ESC ] 1337 ; ReportCellSize=<pt_h>;<pt_w>;<scale> ST` and write via `messageWriter(.write_stable)`.
3. No terminal-state change.

### B. UnicodeVersion (stateful set/push/pop)
1. Parse: `UnicodeVersion=<rest>` into `Command.iterm2_unicode_version { op, value, label }` where `op ∈ {set, push, pop}`:
   - `=push`/`=pop` (optionally `push <label>` / `pop <label>`) → op with label,
   - `=<number>` → `set` with `value`.
2. State: add a small `unicode_version` field + a bounded stack to `Terminal` (`src/terminal/Terminal.zig`). `set` replaces current; `push` saves current (with optional label) and keeps it; `pop` restores the most recent matching label (or top of stack). Cap the stack depth (e.g. 32) to bound memory.
3. Behavior mapping (scoped): map `version >= 9` → wide emoji presentation, `< 9` → legacy narrow, by driving the existing width path (`GraphemeWidthEffect` / the emoji-width decision) **if** a compatible toggle exists. If integrating with the fixed uucode tables proves invasive, **store the version and expose it** (so `ReportVariable`/future queries can read it) and defer the actual width-switch — documented as a follow-up rather than silently claiming full width behavior.

### C. Command plumbing
Add `iterm2_report_cell_size: void` and `iterm2_unicode_version: Iterm2UnicodeVersion` to the `osc.Command` union (`src/terminal/osc.zig`), wire the keys through `src/terminal/stream.zig`, and add no-op stubs in `src/terminal/stream_terminal.zig` (test handler).

## Files Touched

| File | Change |
|---|---|
| `src/terminal/osc/parsers/iterm2.zig` | Parse `ReportCellSize` and `UnicodeVersion=…`; emit new commands |
| `src/terminal/osc.zig` | Add `iterm2_report_cell_size` + `iterm2_unicode_version` variants (+ `Iterm2UnicodeVersion` type) |
| `src/terminal/stream.zig` / `stream_terminal.zig` | Wire + stub the two commands |
| `src/termio/stream_handler.zig` | ReportCellSize reply (points+scale via `self.size.cell`); apply UnicodeVersion to `Terminal` |
| `src/terminal/Terminal.zig` | `unicode_version` field + bounded push/pop stack; (optional) hook into width measurement |

## Phases

1. **Phase 1** — Plan (this document).
2. **Phase 2** — `ReportCellSize`: parse + reply + tests (assert exact `ReportCellSize=<h>;<w>;<scale>` bytes for a known cell size/scale).
3. **Phase 3** — `UnicodeVersion`: parse set/push/pop (+label) + `Terminal` stack + tests (stack push/pop/label, cap).
4. **Phase 4** — (optional) wire version → emoji width behavior, or document store-only.
5. **Phase 5** — Build & test in container (`mise run build`; `zig build test -Dapp-runtime=none -Dtest-filter='OSC: 1337'`).

## Edge Cases

- `ReportCellSize` before the surface has a real size → reply with current best-known cell size (never 0; skip if size is unset).
- Non-integer scale (e.g. 1.5/2.0) → format scale with one decimal; points computed from it.
- `UnicodeVersion=` with a non-numeric, non-push/pop value → log debug, ignore.
- `UnicodeVersion=pop` on an empty stack → no-op.
- `push`/`pop` label mismatch → pop to nearest matching label, else top (match iTerm2 leniency).
- Stack overflow beyond cap → drop oldest / ignore new push, log debug.
- Reply write when the pty is gone → drop silently (same as other reports).

## References

- https://iterm2.com/documentation-escape-codes.html (ReportCellSize, UnicodeVersion)
- `src/terminal/osc/parsers/iterm2.zig:242,255,461,474` — parse sites
- `src/termio/stream_handler.zig` — `self.size.cell`, `messageWriter(.write_stable)` reply path
- `src/unicode/grapheme.zig`, `src/unicode/props_uucode.zig` — width measurement
- `docs/agents/plans/2026-08-10-iterm2-setuservar-capabilities.md` — sibling report-query plan (shares scaffolding)
