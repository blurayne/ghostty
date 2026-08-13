# Running the Glyph Protocol examples in Ghostty

[raphamorim/glyph-protocol-examples](https://github.com/raphamorim/glyph-protocol-examples) is the reference example suite for the Glyph Protocol (the fork-custom APC protocol implemented here — see `src/terminal/apc/glyph.zig`). Each demo probes the terminal with the `s` verb, registers glyphs at Private Use Area codepoints, and prints lines exercising the three payload formats:

- `glyf` — five monochrome Nerd Font outlines (`branch`, `folder`, `home`, `heart`, Rust cog) at `U+100000`–`U+100009`.
- `colrv0` — layered colour glyphs ("Using Glyph protocol", emoji).
- `colrv1` — COLR v1 colour glyphs ("Rio Terminal Emulator", emoji).

## Prerequisites

### 1. Install the Ghostty capabilities (terminfo) file

The Glyph Protocol only responds inside the fork Ghostty build. Outside it — in the dev container, over SSH, or in another emulator — `TERM` falls back to `xterm-256color` and the `25a1` APC is ignored. Install Ghostty's terminfo so `TERM=xterm-ghostty` resolves everywhere on this machine:

```sh
# From the Ghostty source tree after a build (authoritative for this build):
tic -x -o ~/.terminfo zig-out/share/terminfo/ghostty.terminfo

# …or from the installed flatpak's compiled entry:
mkdir -p ~/.terminfo/x ~/.terminfo/g
cp ~/.local/share/flatpak/app/com.mitchellh.ghostty/current/active/files/share/terminfo/x/xterm-ghostty ~/.terminfo/x/
cp ~/.local/share/flatpak/app/com.mitchellh.ghostty/current/active/files/share/terminfo/g/ghostty       ~/.terminfo/g/
```

Verify:

```sh
infocmp -x xterm-ghostty >/dev/null && echo "ok"
```

For a system-wide install use `sudo tic -x /path/to/ghostty.terminfo` (writes to `/usr/share/terminfo`).

### 2. Run inside the fork Ghostty, not a multiplexer

Terminal multiplexers (tmux/screen) intercept the `25a1` APC before it reaches Ghostty. Run the demos in a plain Ghostty window (or enable tmux passthrough). To confirm your session actually reaches the protocol:

```sh
test/glyph-protocol.sh doctor
```

It reports `TERM_PROGRAM`, detects tmux/screen, and does a DA1 round-trip probe. You want `TERM_PROGRAM=ghostty` and a live channel.

## Support status in this fork

| Format | Advertised (`s`) | Registers | Renders |
|---|---|---|---|
| `glyf`   | yes | yes | **see below** |
| `colrv0` | no  | rejected (`UnsupportedFormat`) | no — line shows `(colrv0 not advertised by terminal)` |
| `colrv1` | no  | rejected (`UnsupportedFormat`) | no — line shows `(colrv1 not advertised by terminal)` |

> **Rendering status:** glyph *registration and storage* are complete, but the
> renderer integration that actually draws a registered outline in place of the
> PUA codepoint is tracked by `docs/agents/plans/2026-06-29-glyph-protocol.md`.
> Until that lands, the `glyf` demo rows register successfully but display as
> tofu. This section will be updated when rendering is wired up.

Colour (`colrv0`/`colrv1`) support is a separate, larger effort and is out of scope of the rendering plan.

## Running a demo

From a checkout of the examples repo (each row is self-contained; the `glyf` rows are the ones this fork can render):

| Directory | Language | Run |
|---|---|---|
| `ratatui`     | Rust       | `cd ratatui && cargo run` |
| `bubbletea`   | Go         | `cd bubbletea && go run .` |
| `ink`         | TypeScript | `cd ink && npm install && npm run build && npm start` |
| `ultraviolet` | Go         | `cd ultraviolet && go run .` |

All four print the same layout; only the language differs. The wire helpers at the top of each entry file are the whole protocol story (APC construction + base64 payloads).
